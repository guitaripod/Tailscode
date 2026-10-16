import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// What the running app says about its own screen, shared by the two lenses that read it. Inspect
/// points at a view and Quality lists what is wrong with some, and both draw on the one picture
/// the pane already shows, so the tree is read once, the selection is one selection, and an
/// outline that lands on the picture lands there for whichever lens asked.
///
/// The tree is asked for when either lens opens and again, once, when a build lands while one is
/// showing; hovering and pressing read the tree already held, so a pointer costs no round trip.
/// Everything held is let go when neither lens is on screen.
final class PreviewInspectModel: @unchecked Sendable {
    let outline: UnsafeMutablePointer<GtkWidget>
    var onChange: (() -> Void)?

    private let context: PreviewLensContext
    private(set) var hello: InspectHello?
    private(set) var tree: InspectTree?
    private(set) var audit: InspectAudit?
    private(set) var trail: [InspectNode] = []
    private(set) var hovered: InspectNode?
    private(set) var markedID: String?
    private(set) var failure: String?
    private(set) var isReading = false
    private var wantsAudit = false
    private var debounce = 0

    private static let slot = "inspect"

    init(context: PreviewLensContext) {
        self.context = context
        outline = tailscode_outline_new(
            { raw, kind, fx, fy in
                guard let raw else { return }
                Unmanaged<PreviewInspectModel>.fromOpaque(raw).takeUnretainedValue().pointer(kind, fx, fy)
            }, nil)!
        g_object_ref(UnsafeMutableRawPointer(outline))
        tailscode_outline_bind(outline, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        tailscode_outline_detach(outline)
        g_object_unref(UnsafeMutableRawPointer(outline))
    }

    var selected: InspectNode? { trail.last }

    var appName: String { hello?.app ?? "" }

    /// The view the panel describes: the one pinned, or else the one under the pointer.
    var shown: InspectNode? { trail.last ?? hovered }

    func setActive(_ active: Bool) {
        tailscode_outline_set_active(outline, active ? 1 : 0)
        if !active {
            hovered = nil
            paintHover()
        }
    }

    func read(audit wanted: Bool) {
        wantsAudit = wanted
        fetch(retries: 0)
    }

    /// A build landed while a lens is showing: read again once, a moment after the last such event,
    /// and a few times more if the rebuilt app has not yet started answering.
    func screenMayHaveChanged() {
        debounce += 1
        let ticket = debounce
        context.tasks.spawn(slot: "inspect-wait") { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            Gtk.onMain { [weak self] in
                guard let self, self.debounce == ticket else { return }
                self.fetch(retries: 3)
            }
        }
    }

    private func fetch(retries: Int) {
        guard let runner = context.runner() else {
            fail(PreviewLensFailure.unreachable)
            return
        }
        isReading = true
        let audited = wantsAudit
        context.tasks.spawn(slot: Self.slot) { [weak self] in
            var left = retries
            while true {
                do {
                    let hello = try await runner.inspectHello()
                    let tree = try await runner.inspectTree()
                    Gtk.onMain { [weak self] in self?.adopt(hello: hello, tree: tree) }
                    if audited {
                        let found = try await runner.inspectAudit()
                        Gtk.onMain { [weak self] in self?.adopt(audit: found) }
                    }
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    guard left > 0 else {
                        Gtk.onMain { [weak self] in self?.fail(PreviewLensFailure.words(for: error)) }
                        return
                    }
                    left -= 1
                    try? await Task.sleep(for: .milliseconds(1400))
                }
            }
        }
    }

    func adopt(hello newHello: InspectHello, tree newTree: InspectTree) {
        hello = newHello
        tree = newTree
        failure = nil
        isReading = false
        if let last = trail.last {
            trail = PreviewInspectReading.path(to: last.id, in: newTree)
        }
        if let marked = markedID, PreviewInspectReading.path(to: marked, in: newTree).isEmpty { markedID = nil }
        paint()
        onChange?()
    }

    func adopt(audit found: InspectAudit) {
        audit = found
        isReading = false
        onChange?()
    }

    private func fail(_ words: String) {
        failure = words
        isReading = false
        onChange?()
    }

    func release() {
        context.tasks.cancel(slot: Self.slot)
        context.tasks.cancel(slot: "inspect-wait")
        hello = nil
        tree = nil
        audit = nil
        trail = []
        hovered = nil
        markedID = nil
        failure = nil
        isReading = false
        setActive(false)
        paint()
    }

    func pointer(_ kind: Int32, _ fx: Double, _ fy: Double) {
        switch kind {
        case 0: hover(fractionX: fx, fractionY: fy)
        case 1: leave()
        default: press(fractionX: fx, fractionY: fy)
        }
    }

    private func chain(fractionX: Double, fractionY: Double) -> [InspectNode] {
        guard let tree, let hello else { return [] }
        let chain = PreviewInspectReading.chain(in: tree, hello: hello, fractionX: fractionX, fractionY: fractionY)
        return chain.count > 1 ? chain : []
    }

    func hover(fractionX: Double, fractionY: Double) {
        let node = chain(fractionX: fractionX, fractionY: fractionY).last
        guard node?.id != hovered?.id else { return }
        hovered = node
        paintHover()
        onChange?()
    }

    func leave() {
        guard hovered != nil else { return }
        hovered = nil
        paintHover()
        onChange?()
    }

    func press(fractionX: Double, fractionY: Double) {
        let found = chain(fractionX: fractionX, fractionY: fractionY)
        trail = found
        paintPinned()
        onChange?()
    }

    /// Pins a view by walking to a parent already on the trail, as the breadcrumb does.
    func select(depth: Int) {
        guard trail.indices.contains(depth) else { return }
        trail = Array(trail.prefix(depth + 1))
        paintPinned()
        onChange?()
    }

    func select(nodeID: String) {
        guard let tree else { return }
        let path = PreviewInspectReading.path(to: nodeID, in: tree)
        guard !path.isEmpty else { return }
        trail = path
        paintPinned()
        onChange?()
    }

    func clearSelection() {
        guard !trail.isEmpty || markedID != nil else { return }
        trail = []
        markedID = nil
        paint()
        onChange?()
    }

    func mark(nodeID: String?, fails: Bool) {
        markedID = nodeID
        paintMark(fails: fails)
    }

    /// What a person typed beside the view they are pointing at, preceded by who and what that
    /// view is. Sending selects nothing else and leaves the selection where it was.
    func sentence(saying typed: String) -> String? {
        let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let node = selected, !words.isEmpty else { return nil }
        return "\(PreviewInspectReading.context(for: node, app: appName))\n\n\(words)"
    }

    func askAgent(_ words: String) {
        context.ask(words)
    }

    private func rect(of node: InspectNode?) -> [Double] {
        guard let node, let hello else { return [] }
        let place = PreviewInspectReading.place(of: node, in: hello)
        return [place.x, place.y, place.width, place.height]
    }

    private static func ink(_ hex: String, _ fallback: PresenceRGB) -> [Double] {
        let rgb = PresenceRGB(hex: hex) ?? fallback
        return [rgb.red, rgb.green, rgb.blue]
    }

    private func set(group: Int32, _ rects: [Double], _ ink: [Double]) {
        rects.withUnsafeBufferPointer { rects in
            ink.withUnsafeBufferPointer { ink in
                tailscode_outline_set(outline, group, rects.baseAddress, Int32(rects.count / 4), ink.baseAddress)
            }
        }
    }

    private func paintHover() {
        let covered = hovered?.id == trail.last?.id
        set(group: 0, covered ? [] : rect(of: hovered), Self.ink(MatrixTheme.palette.info, PresenceRGB(red: 0.3, green: 0.6, blue: 1)))
    }

    private func paintPinned() {
        set(group: 1, rect(of: trail.last), Self.ink(MatrixTheme.palette.accent, PresenceRGB(red: 0.2, green: 0.8, blue: 0.4)))
        paintHover()
    }

    private var lastFails = true

    private func paintMark(fails: Bool) {
        lastFails = fails
        guard let tree, let markedID, let node = PreviewInspectReading.path(to: markedID, in: tree).last else {
            set(group: 2, [], Self.ink(MatrixTheme.palette.danger, PresenceRGB(red: 0.9, green: 0.2, blue: 0.2)))
            return
        }
        let hex = fails ? MatrixTheme.palette.danger : MatrixTheme.palette.warn
        set(group: 2, rect(of: node), Self.ink(hex, PresenceRGB(red: 0.9, green: 0.3, blue: 0.2)))
    }

    private func paint() {
        paintPinned()
        paintMark(fails: lastFails)
    }

    /// The desk changed its palette: every outline again, in the new inks.
    func retheme() {
        paint()
    }

    /// Where each outline stands for a picture drawn at this size, in its pixels: hover, pinned and
    /// marked, in that order.
    func plan(width: Int, height: Int) -> (hover: [[Double]], pinned: [[Double]], marked: [[Double]]) {
        var out = [Double](repeating: 0, count: 3 + 4 * 16)
        let written = tailscode_outline_plan(outline, Int32(width), Int32(height), &out, Int32(out.count))
        guard written >= 3 else { return ([], [], []) }
        let counts = out.prefix(3).map { Int($0) }
        var offset = 3
        var groups: [[[Double]]] = []
        for count in counts {
            groups.append((0..<count).map { index in Array(out[(offset + 4 * index)..<(offset + 4 * index + 4)]) })
            offset += 4 * count
        }
        return (groups[0], groups[1], groups[2])
    }

    var summary: String {
        let pinned = trail.last.map { "\($0.id)=\(PreviewInspectReading.shortClass($0.className))" } ?? "-"
        let kind = tree.map { "nodes=\($0.nodeCount)" } ?? "nodes=-"
        let found = audit.map { "findings=\($0.findings.count)" } ?? "findings=-"
        return "\(kind) pinned=\(pinned) hover=\(hovered?.id ?? "-") mark=\(markedID ?? "-") \(found)"
    }
}

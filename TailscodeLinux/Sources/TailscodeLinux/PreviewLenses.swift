import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The tasks a lens started and has not finished. Every one is registered with a ``PaneLifetime``
/// so leaving the lens, parking the pane or closing it ends them together, and the count of those
/// still owed is exact at every moment, which is what lets a harness prove a lens that was left
/// owns nothing.
final class LensTasks: @unchecked Sendable {
    private let lifetime = PaneLifetime()
    private let lock = NSLock()
    private var next = 0
    private var live: [Int: Task<Void, Never>] = [:]
    private var slots: [String: Int] = [:]

    var active: Int {
        lock.lock()
        defer { lock.unlock() }
        return live.count
    }

    /// Starts `work`. A task spawned into a slot replaces the one already there, so a quick second
    /// request never leaves the first running behind it.
    func spawn(slot: String? = nil, _ work: @escaping @Sendable () async -> Void) {
        lock.lock()
        var replaced: Task<Void, Never>?
        if let slot, let old = slots[slot] { replaced = live.removeValue(forKey: old) }
        let id = next
        next += 1
        let task = Task { [weak self] in
            await work()
            self?.finish(id)
        }
        live[id] = task
        if let slot { slots[slot] = id }
        lock.unlock()
        replaced?.cancel()
        lifetime.add { task.cancel() }
    }

    func cancel(slot: String) {
        lock.lock()
        var task: Task<Void, Never>?
        if let id = slots.removeValue(forKey: slot) { task = live.removeValue(forKey: id) }
        lock.unlock()
        task?.cancel()
    }

    func cancelAll() {
        lock.lock()
        let running = Array(live.values)
        live = [:]
        slots = [:]
        lock.unlock()
        for task in running { task.cancel() }
        lifetime.cancelAll()
    }

    private func finish(_ id: Int) {
        lock.lock()
        live.removeValue(forKey: id)
        lock.unlock()
    }
}

/// A JPEG decoded into a texture for a picture widget, held as the address the other panes pass
/// around. The caller owns the reference and gives it back with ``release(_:)`` once the widget
/// has taken its own copy.
enum LensDecode {
    static func bits(_ bytes: Data, longSide: Int32? = nil) -> UInt {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            var width: Int32 = 0
            var height: Int32 = 0
            let texture =
                longSide.map { tailscode_texture_scaled(base, gsize(bytes.count), $0, &width, &height) }
                ?? tailscode_texture_from_bytes(base, gsize(bytes.count))
            guard let texture else { return 0 }
            return UInt(bitPattern: UnsafeMutableRawPointer(texture))
        }
    }

    static func release(_ bits: UInt) {
        if let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
    }
}

/// Why a lens has nothing to show, in a sentence. A host without the route (404), or one that
/// cannot do the work on its platform (501), is an older or smaller host and is told as that;
/// every other failure is the Mac not answering. Neither is ever a dialog.
enum PreviewLensFailure {
    static var unreachable: String { PreviewReading.reachFailure(URLError(.cannotConnectToHost)) }

    static func words(for error: Error) -> String {
        if case AgentError.http(let code, _) = error, code == 404 || code == 501 {
            return Localized.text("This preview host cannot show this view yet")
        }
        return PreviewReading.reachFailure(error)
    }
}

/// The plain digits that pick a lens while a preview pane has the keyboard, and Escape, which
/// lets go of whatever the pane has pinned.
enum PreviewLensKeys {
    static func lens(for chord: KeyChord) -> PreviewLens? {
        guard !chord.control, !chord.alt, !chord.shift, let character = Keymap.scalar(chord.keyval) else {
            return nil
        }
        return PreviewLens(digit: character)
    }

    static func isEscape(_ chord: KeyChord) -> Bool {
        !chord.control && !chord.alt && !chord.shift && chord.keyval == Keymap.escape
    }
}

/// What a clip of frames says about the screen's smoothness. Frames exist only while the screen
/// moves, so a gap is a hitch when it is longer than a frame should be and shorter than a pause.
enum PreviewRewindReading {
    static let slowAfter: UInt64 = 40_000
    static let idleAfter: UInt64 = 400_000

    /// The index of every frame that arrived late: more than 40 ms after the one before it, and
    /// not more than 400 ms, past which the screen was simply still.
    static func slowFrames(_ microseconds: [UInt64]) -> [Int] {
        guard microseconds.count > 1 else { return [] }
        return (1..<microseconds.count).filter { index in
            let gap = microseconds[index] &- microseconds[index - 1]
            return microseconds[index] >= microseconds[index - 1] && gap > slowAfter && gap <= idleAfter
        }
    }

    static func line(_ count: Int) -> String {
        switch count {
        case 0: return Localized.text("No slow frames")
        case 1: return Localized.text("1 slow frame")
        default: return Localized.text("%@ slow frames", String(count))
        }
    }
}

/// What each lens is handed: the runner to ask, the picture on screen now, and the tasks it may
/// start. Nothing here outlives the lens being shown.
struct PreviewLensContext {
    let runner: () -> PreviewRunner?
    let livePicture: () -> Data?
    let ask: @Sendable (String) -> Void
    let tasks: LensTasks
}

/// A view the lens switcher can show. `open` is the moment a person arrives (or presses the lens
/// again), `close` releases everything heavy the view held, and the lens switcher cancels its
/// tasks before either.
protocol PreviewLensView: AnyObject {
    var root: UnsafeMutablePointer<GtkWidget> { get }
    var summary: String { get }
    func open()
    func close()
    func drive(_ command: String) -> Bool
    func fit(narrow: Bool)
}

extension PreviewLensView {
    func fit(narrow: Bool) {}
}

/// The quiet switcher over the stage: Look, Compare, Inspect, Quality, Matrix and Rewind. Look is
/// the picture and the chips exactly as the pane always drew them; Inspect and Quality keep that
/// same picture and add a panel beside it (under it, in a narrow pane) that reads the app's own
/// views; the others are the same running app read another way. Each is asked of the host only
/// when its lens is opened and ended when it is left.
final class PreviewLenses: @unchecked Sendable {
    static let offered: [PreviewLens] = [.look, .compare, .inspect, .quality, .matrix, .rewind]

    static let sideWidth: Int32 = 300
    static let sideHeight: Int32 = 210
    static let stackedBelow = 600
    static let glyphsBelow = 500
    static let narrowBelow = 480
    static let chipsBesidePanelFrom = 780
    static let touchChipsFit = 720

    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let content = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let frameScroller = gtk_scrolled_window_new()!
    private let stack = gtk_stack_new()!
    private let bar = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
    private let side = gtk_scrolled_window_new()!
    private let sideStack = gtk_stack_new()!
    private var chips: [PreviewLens: UnsafeMutablePointer<GtkWidget>] = [:]
    private let tasks: LensTasks
    private let compare: PreviewCompareView
    private let matrix: PreviewMatrixView
    private let rewind: PreviewRewindView
    private let inspectModel: PreviewInspectModel
    private let inspect: PreviewInspectView
    private let quality: PreviewQualityView
    private let page: UnsafeMutablePointer<GtkWidget>
    private let stageChips: UnsafeMutablePointer<GtkWidget>
    private let sensor: UnsafeMutablePointer<GtkWidget>
    private var seenBuild = 0
    private var isSuspended = false
    private(set) var isStacked = false
    private(set) var showsGlyphs = false
    private(set) var isNarrow = false
    private(set) var lastWidth = 0
    private(set) var carriesTouchChips = false
    var onLensChanged: (@Sendable () -> Void)?

    private(set) var current: PreviewLens = .look
    private let look: UnsafeMutablePointer<GtkWidget>

    init(
        look: UnsafeMutablePointer<GtkWidget>, stageChips: UnsafeMutablePointer<GtkWidget>,
        context: PreviewLensContext, inspect model: PreviewInspectModel
    ) {
        self.look = look
        self.stageChips = stageChips
        page = look
        tasks = context.tasks
        compare = PreviewCompareView(context: context)
        matrix = PreviewMatrixView(context: context)
        rewind = PreviewRewindView(context: context)
        inspectModel = model
        inspect = PreviewInspectView(model: model)
        quality = PreviewQualityView(model: model)
        sensor = tailscode_width_sensor_new(
            { raw, width, _ in
                guard let raw else { return }
                let lenses = Unmanaged<PreviewLenses>.fromOpaque(raw).takeUnretainedValue()
                Gtk.onMain { [weak lenses] in lenses?.fit(width: Int(width)) }
            }, nil)!
        g_object_ref(UnsafeMutableRawPointer(sensor))
        tailscode_width_sensor_bind(sensor, Unmanaged.passUnretained(self).toOpaque())
        model.onChange = { [weak self] in
            self?.inspect.paint()
            self?.quality.paint()
        }
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)
        gtk_widget_set_hexpand(stack, 1)
        gtk_widget_set_vexpand(stack, 1)
        gtk_stack_set_transition_type(op(stack), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_set_hhomogeneous(op(stack), 0)
        gtk_stack_set_vhomogeneous(op(stack), 0)
        gtk_stack_add_named(op(stack), look, PreviewLens.look.rawValue)
        gtk_stack_add_named(op(stack), compare.root, PreviewLens.compare.rawValue)
        gtk_stack_add_named(op(stack), matrix.root, PreviewLens.matrix.rawValue)
        gtk_stack_add_named(op(stack), rewind.root, PreviewLens.rewind.rawValue)
        buildSide()
        buildBar()
        gtk_box_append(ptr(content), bar)
        gtk_box_append(ptr(content), stack)
        gtk_widget_set_hexpand(content, 1)
        gtk_widget_set_vexpand(content, 1)
        gtk_scrolled_window_set_policy(op(frameScroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(op(frameScroller), content)
        gtk_widget_set_hexpand(frameScroller, 1)
        gtk_widget_set_vexpand(frameScroller, 1)
        gtk_box_append(ptr(root), sensor)
        gtk_box_append(ptr(root), frameScroller)
        paintBar()
    }

    deinit {
        tailscode_width_sensor_detach(sensor)
        g_object_unref(UnsafeMutableRawPointer(sensor))
    }

    private func buildSide() {
        gtk_stack_set_transition_type(op(sideStack), GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_add_named(op(sideStack), inspect.root, PreviewLens.inspect.rawValue)
        gtk_stack_add_named(op(sideStack), quality.root, PreviewLens.quality.rawValue)
        gtk_scrolled_window_set_policy(op(side), GTK_POLICY_EXTERNAL, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(op(side), sideStack)
        gtk_widget_set_vexpand(side, 1)
        gtk_widget_set_visible(side, 0)
        arrangeSide()
        gtk_box_append(ptr(page), side)
    }

    /// The panel sits beside a wide pane's picture and under a narrow pane's, since a phone's
    /// picture is tall and a beside-panel in a narrow pane would leave it a sliver.
    private func arrangeSide() {
        gtk_orientable_set_orientation(
            OpaquePointer(page), isStacked ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL)
        gtk_widget_set_size_request(side, isStacked ? -1 : Self.sideWidth, isStacked ? Self.sideHeight : -1)
        gtk_widget_set_vexpand(side, isStacked ? 0 : 1)
        gtk_widget_set_hexpand(side, 0)
        paintStageChips()
    }

    /// While a lens reads the views, a narrow pane gives the room the appearance chips took back to
    /// the picture, which is what that lens is about.
    private func paintStageChips() {
        gtk_widget_set_visible(stageChips, current.readsViews && isStacked ? 0 : 1)
        let crowded =
            (current.readsViews && !isStacked && lastWidth < Self.chipsBesidePanelFrom)
            || (carriesTouchChips && lastWidth < Self.touchChipsFit)
        gtk_orientable_set_orientation(
            OpaquePointer(stageChips), isNarrow || crowded ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL)
    }

    /// The touch chips joined or left the stage's row: seven chips do not fit side by side in a
    /// middling pane, so the rows stack until there is room.
    func setTouchChips(shown: Bool) {
        guard shown != carriesTouchChips else { return }
        carriesTouchChips = shown
        paintStageChips()
    }

    /// The pane's width changed: the panel moves under or beside the picture, and the chips lose
    /// their words when six of them no longer fit.
    func fit(width: Int) {
        guard width > 0 else { return }
        lastWidth = width
        let stacked = width < Self.stackedBelow
        if stacked != isStacked {
            isStacked = stacked
            arrangeSide()
        }
        let glyphs = width < Self.glyphsBelow
        if glyphs != showsGlyphs {
            showsGlyphs = glyphs
            paintChipWords()
        }
        let narrow = width < Self.narrowBelow
        if narrow != isNarrow {
            isNarrow = narrow
            for lens in Self.offered { view(of: lens)?.fit(narrow: narrow) }
        }
        paintStageChips()
    }

    private static func glyph(for lens: PreviewLens) -> String {
        switch lens {
        case .look: return "◉"
        case .compare: return "◐"
        case .inspect: return "⌖"
        case .quality: return "✓"
        case .matrix: return "▦"
        case .rewind: return "↺"
        }
    }

    private func buildBar() {
        gtk_widget_set_halign(bar, GTK_ALIGN_CENTER)
        Gtk.margins(bar, top: 8, bottom: 0, leading: 8, trailing: 8)
        Gtk.addClass(bar, "preview-lenses")
        for lens in Self.offered {
            let chip = Gtk.button(lens.title, css: ["preview-lens"]) { [weak self] in
                Gtk.onMain { [weak self] in self?.select(lens) }
            }
            let words = "\(lens.title) (\(lens.digit))"
            gtk_widget_set_tooltip_text(chip, words)
            tailscode_set_accessible_label(chip, lens.title)
            chips[lens] = chip
            gtk_box_append(ptr(bar), chip)
        }
    }

    private func paintChipWords() {
        for (lens, chip) in chips {
            gtk_button_set_label(ptr(chip), showsGlyphs ? Self.glyph(for: lens) : lens.title)
        }
    }

    private func paintBar() {
        for (lens, chip) in chips {
            Gtk.setTone(chip, lens == current ? "preview-lens-on" : nil, from: ["preview-lens-on"])
        }
    }

    private func view(of lens: PreviewLens) -> PreviewLensView? {
        switch lens {
        case .compare: return compare
        case .matrix: return matrix
        case .rewind: return rewind
        case .inspect: return inspect
        case .quality: return quality
        default: return nil
        }
    }

    var activeTasks: Int { tasks.active }

    var layoutWords: String {
        "width=\(lastWidth) layout=\(isStacked ? "stacked" : "beside") chips=\(showsGlyphs ? "glyphs" : "words") narrow=\(isNarrow)"
    }

    var summary: String {
        guard let shown = view(of: current) else { return "look \(layoutWords)" }
        return "\(shown.summary) \(layoutWords)"
    }

    /// Shows a lens. Pressing the one already showing asks it again, which is how a person takes
    /// a fresh look at the last ten seconds or the newest pictures.
    @discardableResult
    func select(_ lens: PreviewLens) -> Bool {
        guard Self.offered.contains(lens) else { return false }
        isSuspended = false
        tasks.cancelAll()
        if lens != current { view(of: current)?.close() }
        if !lens.readsViews { inspectModel.release() }
        current = lens
        gtk_stack_set_visible_child_name(op(stack), lens.readsViews ? PreviewLens.look.rawValue : lens.rawValue)
        if lens.readsViews { gtk_stack_set_visible_child_name(op(sideStack), lens.rawValue) }
        gtk_widget_set_visible(side, lens.readsViews ? 1 : 0)
        paintStageChips()
        paintBar()
        view(of: lens)?.open()
        onLensChanged?()
        return true
    }

    /// The pane stopped being shown or stopped running: nothing the lens started goes on, and what
    /// it held is let go. The lens that was showing is asked again when the pane is.
    func suspend() {
        tasks.cancelAll()
        isSuspended = true
        view(of: current)?.close()
        inspectModel.release()
        onLensChanged?()
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        view(of: current)?.open()
    }

    /// The pane was pointed somewhere else: back to the picture.
    func reset() {
        tasks.cancelAll()
        view(of: current)?.close()
        inspectModel.release()
        current = .look
        isSuspended = false
        seenBuild = 0
        gtk_stack_set_visible_child_name(op(stack), PreviewLens.look.rawValue)
        gtk_widget_set_visible(side, 0)
        paintStageChips()
        paintBar()
        onLensChanged?()
    }

    /// A new state from the runner. A build that finished while Compare is showing brings new
    /// pictures, and while Inspect or Quality is showing a new screen, so each is asked for once, a
    /// moment later, so a burst of events is one request.
    func stateArrived(_ state: PreviewState) {
        let built = state.recent.filter { $0.kind == "build.done" }.map(\.seq).max() ?? 0
        guard built > seenBuild else { return }
        seenBuild = built
        guard !isSuspended else { return }
        if current == .compare { compare.historyMayHaveChanged() }
        if current.readsViews { inspectModel.screenMayHaveChanged() }
    }

    /// Lets go of what is pinned on the picture. False when nothing was, so Escape is left for
    /// whoever else wants it.
    @discardableResult
    func escape() -> Bool {
        guard current.readsViews, inspectModel.selected != nil || inspectModel.markedID != nil else { return false }
        inspectModel.clearSelection()
        return true
    }

    func retheme() {
        compare.retheme()
        rewind.retheme()
        inspectModel.retheme()
    }

    func drive(_ command: String) -> Bool {
        view(of: current)?.drive(command) ?? false
    }

    var stageChipsAreStacked: Bool {
        gtk_orientable_get_orientation(OpaquePointer(stageChips)) == GTK_ORIENTATION_VERTICAL
    }

    var stageChipsWidth: Int {
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(stageChips, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, nil, nil)
        return Int(minimum)
    }

    var compareView: PreviewCompareView { compare }
    var matrixView: PreviewMatrixView { matrix }
    var rewindView: PreviewRewindView { rewind }
    var inspectView: PreviewInspectView { inspect }
    var qualityView: PreviewQualityView { quality }
    var model: PreviewInspectModel { inspectModel }
    var chipWords: [String] {
        Self.offered.compactMap { chips[$0] }.map { gtk_button_get_label(ptr($0)).map(String.init(cString:)) ?? "" }
    }
}

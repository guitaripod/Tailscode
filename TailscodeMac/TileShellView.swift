import AppKit
import TailscodeCore

/// One pane's room in the canvas: the frame the canvas places, the focus ring, the drop target,
/// the accessibility element, and whichever face the pane wears — the whole conversation, a
/// glance tile or the paused face. The conversation itself stays in the shell from birth to close;
/// a glance or a pause covers it and hides it rather than taking it out, so coming back to full is
/// the same view in the same place.
@MainActor
final class TileShellView: NSView {
    enum Face: Equatable {
        case full
        case glance
        case paused
    }

    let paneID: PaneID
    private(set) var face: Face = .full
    private(set) var body: NSView?
    private(set) lazy var glance = GlanceTileView()
    private(set) lazy var paused = ParkedFaceView()
    private var glanceBuilt = false
    private var pausedBuilt = false
    private var focused = false
    private var showsRing = false

    var onDragEntered: ((NSDraggingInfo) -> Bool)?
    var onDragExited: (() -> Void)?
    var onDragPerform: ((NSDraggingInfo) -> Bool)?

    init(paneID: PaneID) {
        self.paneID = paneID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        registerForDraggedTypes([.tailscodeChat])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    /// The conversation, filling the shell by its autoresizing mask: nothing joins it to the
    /// canvas but the frame the canvas sets.
    func install(body view: NSView) {
        guard body !== view else { return }
        body?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = bounds
        addSubview(view, positioned: .below, relativeTo: nil)
        body = view
    }

    /// Puts on a face. The conversation is hidden under a glance or a pause, never removed, so
    /// first responder and the scroll position are where they were when it comes back.
    func show(_ next: Face) {
        guard next != face else { return }
        face = next
        body?.isHidden = next != .full
        if next == .glance { buildGlance() }
        if next == .paused { buildPaused() }
        if glanceBuilt { glance.isHidden = next != .glance }
        if pausedBuilt { paused.isHidden = next != .paused }
        if next != .glance, glanceBuilt { glance.stopClock() }
    }

    private func buildGlance() {
        guard !glanceBuilt else { return }
        glanceBuilt = true
        fill(glance)
    }

    private func buildPaused() {
        guard !pausedBuilt else { return }
        pausedBuilt = true
        fill(paused)
    }

    private func fill(_ face: NSView) {
        face.translatesAutoresizingMaskIntoConstraints = true
        face.autoresizingMask = [.width, .height]
        face.frame = bounds
        addSubview(face)
    }

    var hasGlance: Bool { glanceBuilt }

    /// The accent hairline the focused pane wears once a second pane exists to tell it from.
    func setFocusRing(focused: Bool, shown: Bool) {
        self.focused = focused
        showsRing = shown
        restyle()
    }

    /// `CGColor`s keep the appearance they were made in, so the ring is made again whenever the
    /// appearance or the palette changes.
    func restyle() {
        if showsRing, focused {
            layer?.borderColor = MacTheme.Color.accent.withAlphaComponent(0.55).cgColor
            layer?.borderWidth = 1
        } else {
            layer?.borderWidth = 0
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDragEntered?(sender) == true ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDragEntered?(sender) == true ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExited?()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDragPerform?(sender) ?? false
    }

    /// Whatever face is showing, in the one order a screen reader walks a pane.
    override func accessibilityChildren() -> [Any]? {
        switch face {
        case .full: return body.map { [$0] } ?? []
        case .glance: return [glance]
        case .paused: return [paused]
        }
    }
}

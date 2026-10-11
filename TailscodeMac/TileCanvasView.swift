import AppKit
import TailscodeCore

/// The one flat container every pane of the window lives in, placed by frame from Core's
/// placement rather than by nested split controllers.
///
/// Panes, dividers and overlays are siblings in that order, so an overlay can never be hidden by a
/// pane and a divider always takes the pointer over the seam it draws. A pane is added once, when
/// it is born, and removed once, when it closes: a structural verb is a change of rectangles and a
/// zoom or an overflow is `isHidden`, so first responder, a half-typed composition, a scroll
/// position, a display link and a playing stream are never disturbed by the arrangement around
/// them. `reparents` counts every add of a pane that already had a superview, and the selftest
/// holds it at zero across a hammer of verbs.
///
/// The canvas is full-bleed under the toolbar, so each pane works out its own top inset from its
/// safe area exactly as it did inside the split controllers it replaces.
@MainActor
final class TileCanvasView: NSView {
    /// Told every layout pass, with the canvas's bounds, to place everything.
    var onLayout: ((NSRect) -> Void)?
    /// Told when the window's live resize starts and ends.
    var onLiveResize: ((Bool) -> Void)?
    /// Told when the appearance changes, because pane borders and divider lines are `CGColor`s.
    var onAppearance: (() -> Void)?
    /// The panes in reading order, for the accessibility tree and its rotor.
    var readingOrder: (() -> [NSView])?

    /// The layers above the panes: dividers first, then everything that floats over the panes.
    let dividerLayer = PassThroughView()
    let overlayLayer = PassThroughView()

    private(set) var reparents = 0
    private(set) var paneAdds = 0
    private(set) var paneRemovals = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for layer in [dividerLayer, overlayLayer] {
            layer.frame = bounds
            layer.autoresizingMask = [.width, .height]
            addSubview(layer)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Localized.text("Panes"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    /// The seams between panes are the canvas showing through the one-point gutter, so the canvas
    /// is the separator's colour and every seam is drawn by leaving it uncovered.
    override func updateLayer() {
        layer?.backgroundColor = MacTheme.Color.separator.cgColor
    }

    override func layout() {
        super.layout()
        onLayout?(bounds)
    }

    /// A pane joins the canvas under the dividers. A pane that already has a superview is a
    /// re-parent, which this design never does, and is counted so a check can prove it.
    func addPane(_ pane: NSView) {
        if pane.superview != nil { reparents += 1 }
        paneAdds += 1
        pane.translatesAutoresizingMaskIntoConstraints = true
        pane.autoresizingMask = []
        addSubview(pane, positioned: .below, relativeTo: dividerLayer)
    }

    func removePane(_ pane: NSView) {
        guard pane.superview === self else { return }
        paneRemovals += 1
        pane.removeFromSuperview()
    }

    func addDivider(_ divider: NSView) {
        divider.translatesAutoresizingMaskIntoConstraints = true
        divider.autoresizingMask = []
        dividerLayer.addSubview(divider)
    }

    /// An overlay hangs from the canvas's own safe area, under the toolbar, above every pane.
    func addOverlay(_ overlay: NSView) {
        overlayLayer.addSubview(overlay)
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        onLiveResize?(true)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onLiveResize?(false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        onAppearance?()
    }

    /// Panes in reading order, then the dividers, then whatever floats over them.
    override func accessibilityChildren() -> [Any]? {
        let panes = readingOrder?() ?? []
        let dividers = dividerLayer.subviews.filter { !$0.isHidden }
        let overlays = overlayLayer.subviews.filter { !$0.isHidden }
        return panes + dividers + overlays
    }

    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        [NSAccessibilityCustomRotor(label: Localized.text("Panes"), itemSearchDelegate: self)]
    }
}

extension TileCanvasView: @MainActor NSAccessibilityCustomRotorItemSearchDelegate {
    /// The rotor walks the visible panes in reading order, wrapping at neither end.
    func rotor(
        _ rotor: NSAccessibilityCustomRotor,
        resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters
    ) -> NSAccessibilityCustomRotor.ItemResult? {
        do {
            let panes = (readingOrder?() ?? []).filter { !$0.isHidden }
            guard !panes.isEmpty else { return nil }
            let current = searchParameters.currentItem?.targetElement as? NSView
            let index = current.flatMap { view in panes.firstIndex { $0 === view } }
            let next: Int
            switch (index, searchParameters.searchDirection) {
            case (nil, .previous): next = panes.count - 1
            case (nil, _): next = 0
            case (let at?, .previous): next = at - 1
            case (let at?, _): next = at + 1
            }
            guard panes.indices.contains(next) else { return nil }
            let result = NSAccessibilityCustomRotor.ItemResult(targetElement: panes[next])
            result.customLabel = panes[next].accessibilityLabel()
            return result
        }
    }
}

/// A layer of the canvas that takes no press of its own: a point over nothing it holds belongs to
/// whatever is underneath.
@MainActor
final class PassThroughView: NSView {
    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

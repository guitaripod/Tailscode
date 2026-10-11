import AppKit
import TailscodeCore

/// One seam between two sides of a split: a nine-point band a pointer can grab, centred on the
/// one-point gutter the canvas leaves uncovered.
///
/// A drag is Core's: each step converts the pointer into the parent rectangle's coordinates and
/// asks `SplitLayout.drag`, which clamps it so neither side drops below its minimum, and the
/// canvas lays out live on every step: every pane takes its new frame under the pointer, while
/// the transcripts hold their rows at the width they had and re-measure once when the drag ends.
/// A double click evens the whole arrangement out. The ratio is written once, when the drag
/// ends, and only if it moved.
///
/// To an assistive app it is a splitter with a value between 0 and 1, an orientation and a name
/// that says which panes it divides; increment and decrement move it by the keyboard step.
@MainActor
final class TileDividerView: NSView {
    let id: SplitID
    private(set) var placement: DividerPlacement
    /// The pointer went down on the seam and a drag may follow.
    var onDragBegan: ((SplitID) -> Void)?
    /// A drag step: where the first side should now end, from the parent's leading edge.
    var onDrag: ((SplitID, Double) -> Void)?
    /// The drag let go; `moved` is whether any step changed the ratio.
    var onDragEnded: ((SplitID, Bool) -> Void)?
    var onEqualize: (() -> Void)?
    /// An assistive increment or decrement, in points along the axis.
    var onStep: ((SplitID, Double) -> Void)?
    /// A key on the seam while it holds the keyboard; answers whether the seam moved or took it.
    var onKey: ((SplitID, DividerKey) -> Bool)?

    private let line = CALayer()
    private var hovered = false
    private var dragging = false
    private var grabOffset: Double = 0
    private var moved = false
    private var tracking: NSTrackingArea?

    init(placement: DividerPlacement) {
        self.id = placement.id
        self.placement = placement
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(line)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { onKey != nil }

    override func becomeFirstResponder() -> Bool {
        needsLayout = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsLayout = true
        return super.resignFirstResponder()
    }

    private var holdsKeyboard: Bool { window?.firstResponder === self }

    override func keyDown(with event: NSEvent) {
        guard let key = DividerSplitView.dividerKey(for: event), onKey?(id, key) == true else {
            return super.keyDown(with: event)
        }
    }

    private var vertical: Bool { placement.axis == .horizontal }

    /// Takes the divider's latest geometry: its band, the rectangle it divides and how far it may
    /// travel, and the words a screen reader says for it.
    func update(_ placement: DividerPlacement, label: String) {
        let axisChanged = placement.axis != self.placement.axis
        self.placement = placement
        let frame = NSRect(
            x: placement.hit.x, y: placement.hit.y, width: placement.hit.width,
            height: placement.hit.height)
        if self.frame != frame { self.frame = frame }
        if axisChanged { window?.invalidateCursorRects(for: self) }
        setAccessibilityLabel(label)
        setAccessibilityOrientation(vertical ? .vertical : .horizontal)
        setAccessibilityValue(NSNumber(value: fraction))
        setAccessibilityMinValue(NSNumber(value: 0))
        setAccessibilityMaxValue(NSNumber(value: 1))
        needsLayout = true
    }

    /// Where the seam sits as a share of the room it can divide.
    private var fraction: Double {
        let available = placement.parent.extent(along: placement.axis) - PaneSizing.gutter
        guard available > 0 else { return 0.5 }
        return min(1, max(0, placement.position / available))
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let thickness: CGFloat = hovered || dragging || holdsKeyboard ? 2 : 1
        if vertical {
            line.frame = NSRect(
                x: (bounds.width - thickness) / 2, y: 0, width: thickness, height: bounds.height)
        } else {
            line.frame = NSRect(
                x: 0, y: (bounds.height - thickness) / 2, width: bounds.width, height: thickness)
        }
        CATransaction.commit()
        restyle()
    }

    /// A seam at rest is the separator; under the pointer or while it moves it takes the accent,
    /// two points wide, so the band a person can grab is visible before they grab it.
    private func restyle() {
        let active = hovered || dragging || holdsKeyboard
        line.backgroundColor =
            (active ? MacTheme.Color.accent : MacTheme.Color.separator).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: vertical ? .resizeLeftRight : .resizeUpDown)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsLayout = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsLayout = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The pointer's place along the axis, in the parent rectangle's coordinates.
    private func along(_ event: NSEvent) -> Double {
        guard let canvas = superview?.superview else { return placement.position }
        let point = canvas.convert(event.locationInWindow, from: nil)
        return vertical
            ? Double(point.x) - placement.parent.x : Double(point.y) - placement.parent.y
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onEqualize?()
            return
        }
        window?.makeFirstResponder(self)
        dragging = true
        moved = false
        grabOffset = along(event) - placement.position
        needsLayout = true
        onDragBegan?(id)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let target = along(event) - grabOffset
        guard abs(target - placement.position) >= 0.5 else { return }
        moved = true
        onDrag?(id, target)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        needsLayout = true
        onDragEnded?(id, moved)
    }

    override func accessibilityPerformIncrement() -> Bool {
        onStep?(id, PaneSizing.keyboardStep)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onStep?(id, -PaneSizing.keyboardStep)
        return true
    }
}

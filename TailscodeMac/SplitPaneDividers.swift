import AppKit
import TailscodeCore

/// What a divider says about itself to assistive technology: the two panes it divides, and where
/// it stands between the extremes it can travel — Core's words, read live from the tree.
struct DividerAccessibilityReading {
    let label: String
    let value: String
    let position: Double
    let minimum: Double
    let maximum: Double
}

/// A split view whose divider answers a double click by evening the whole arrangement out. The
/// second click is intercepted before `NSSplitView` starts tracking a drag, and only when it
/// lands in the gap between the two subviews — a double click anywhere in a conversation is none
/// of this view's business.
///
/// Every split here has exactly one divider, so the view itself is the divider's keyboard focus: a
/// press on the gap takes it, and while it holds it the arrow keys move the divider by the
/// keyboard step, shift by the large one, and Home and End take it to its extremes. It is also
/// the divider's accessibility element — an adjustable splitter with a label, a position between
/// its extremes, and increment and decrement that step by the same nudge.
final class DividerSplitView: NSSplitView {
    var onDividerDoubleClick: (() -> Void)?
    var onDividerKey: ((DividerKey) -> Bool)?
    var accessibilityReading: (() -> DividerAccessibilityReading?)?
    private lazy var splitterElement = DividerAccessibilityElement(owner: self)

    override var acceptsFirstResponder: Bool { onDividerKey != nil }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func drawDivider(in rect: NSRect) {
        guard window?.firstResponder === self else { return super.drawDivider(in: rect) }
        MacTheme.Color.accent.setFill()
        rect.fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hitsDivider(point) {
            window?.makeFirstResponder(self)
            if event.clickCount == 2 {
                onDividerDoubleClick?()
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let key = Self.dividerKey(for: event), onDividerKey?(key) == true else {
            return super.keyDown(with: event)
        }
    }

    /// The divider key an event spells, or nil: an arrow steps, shift makes it large, Home and End
    /// go to the extremes, and anything with command, control or option is somebody else's chord.
    static func dividerKey(for event: NSEvent) -> DividerKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option]) else { return nil }
        let large = flags.contains(.shift)
        switch event.keyCode {
        case 123, 126: return .back(large: large)
        case 124, 125: return .forward(large: large)
        case 115: return .lowest
        case 119: return .highest
        default: return nil
        }
    }

    override func accessibilityChildren() -> [Any]? {
        guard accessibilityReading != nil else { return super.accessibilityChildren() }
        var children = (super.accessibilityChildren() ?? []).filter {
            ($0 as? NSAccessibilityProtocol)?.accessibilityRole() != .splitter
        }
        children.append(splitterElement)
        return children
    }

    /// Where the gap between the two subviews is, in this view's coordinates.
    var dividerRect: NSRect {
        guard arrangedSubviews.count == 2 else { return .zero }
        let ordered =
            isVertical
            ? arrangedSubviews.sorted { $0.frame.minX < $1.frame.minX }
            : arrangedSubviews.sorted { $0.frame.minY < $1.frame.minY }
        let low = isVertical ? ordered[0].frame.maxX : ordered[0].frame.maxY
        let high = isVertical ? ordered[1].frame.minX : ordered[1].frame.minY
        let thickness = max(high - low, dividerThickness)
        return isVertical
            ? NSRect(x: low, y: 0, width: thickness, height: bounds.height)
            : NSRect(x: 0, y: low, width: bounds.width, height: thickness)
    }

    fileprivate func step(_ key: DividerKey) -> Bool {
        onDividerKey?(key) ?? false
    }

    fileprivate func hitsDivider(_ point: NSPoint) -> Bool {
        guard !arrangedSubviews.contains(where: { $0.frame.contains(point) }) else { return false }
        let slop = max(dividerThickness, 4)
        for (left, right) in zip(arrangedSubviews, arrangedSubviews.dropFirst()) {
            let ordered =
                isVertical
                ? (left.frame.minX <= right.frame.minX ? (left, right) : (right, left))
                : (left.frame.minY <= right.frame.minY ? (left, right) : (right, left))
            let low =
                isVertical ? ordered.0.frame.maxX : ordered.0.frame.maxY
            let high =
                isVertical ? ordered.1.frame.minX : ordered.1.frame.minY
            let value = isVertical ? point.x : point.y
            if value >= low - slop, value <= high + slop { return true }
        }
        return false
    }
}

/// The divider as VoiceOver meets it: a splitter that says which two panes it divides, reads its
/// position as a value between the extremes it can travel, and steps by the keyboard nudge when
/// incremented or decremented. It stands in for the toolkit's own splitter, which knows neither
/// the clamp nor the names.
final class DividerAccessibilityElement: NSAccessibilityElement {
    private unowned let owner: DividerSplitView

    init(owner: DividerSplitView) {
        self.owner = owner
        super.init()
    }

    private var reading: DividerAccessibilityReading? { owner.accessibilityReading?() }

    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }

    override func accessibilityParent() -> Any? { owner }

    override func accessibilityLabel() -> String? { reading?.label }

    override func accessibilityValue() -> Any? { reading.map { NSNumber(value: $0.position) } }

    override func accessibilityValueDescription() -> String? { reading?.value }

    override func accessibilityMinValue() -> Any? { reading.map { NSNumber(value: $0.minimum) } }

    override func accessibilityMaxValue() -> Any? { reading.map { NSNumber(value: $0.maximum) } }

    override func accessibilityOrientation() -> NSAccessibilityOrientation {
        owner.isVertical ? .vertical : .horizontal
    }

    override func accessibilityFrame() -> NSRect {
        guard let window = owner.window else { return .zero }
        let inWindow = owner.convert(owner.dividerRect, to: nil)
        return window.convertToScreen(inWindow)
    }

    override func isAccessibilityFocused() -> Bool {
        owner.window?.firstResponder === owner
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        if focused { owner.window?.makeFirstResponder(owner) }
    }

    override func accessibilityPerformIncrement() -> Bool {
        owner.step(.forward(large: false))
    }

    override func accessibilityPerformDecrement() -> Bool {
        owner.step(.back(large: false))
    }
}

import AppKit
import TailscodeCore

/// A fact about the conversation as one divider line: a rule, the words in their tone, a quiet
/// chevron when there is a reader behind it, and a rule. It is what a compaction, a model change, a
/// restart and an undo in flight all wear, at the table's height, because none of them is something
/// anybody said and each says its whole fact in a line.
///
/// A line with a reader behind it is pressable the way a disclosure is: a plate under the pointer,
/// a click that acts on release, Space or Return once Full Keyboard Access puts it in the Tab loop.
@MainActor
final class SeamLineView: NSView, KeyboardPressable {
    private let middle = NSStackView()
    private let onPress: (() -> Void)?
    private let leadingRule = RowKit.Ground(frame: .zero)
    private let trailingRule = RowKit.Ground(frame: .zero)

    init(symbol: String, text: String, tint: NSColor, spoken: String, onPress: (() -> Void)?) {
        self.onPress = onPress
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 11 * MacTheme.UIScale.factor, weight: .medium))
        icon.contentTintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setAccessibilityElement(false)
        let label = RowKit.label(text, font: MacTheme.Ramp.font(.note), color: tint)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        middle.setViews([icon, label], in: .leading)
        if onPress != nil {
            let chevron = RowKit.label(
                "›", font: MacTheme.Ramp.font(.note), color: MacTheme.Color.tertiaryLabel)
            chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
            middle.addArrangedSubview(chevron)
        }
        middle.orientation = .horizontal
        middle.alignment = .centerY
        middle.spacing = MacTheme.Spacing.xs + 2
        middle.translatesAutoresizingMaskIntoConstraints = false

        for rule in [leadingRule, trailingRule] {
            rule.fill = MacTheme.Color.separator
            rule.translatesAutoresizingMaskIntoConstraints = false
            addSubview(rule)
        }
        addSubview(middle)
        let rest: CGFloat = 32
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: CGFloat(ChatLayout.metrics.seamRowHeight)),
            middle.centerXAnchor.constraint(equalTo: centerXAnchor),
            middle.centerYAnchor.constraint(equalTo: centerYAnchor),
            middle.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: rest),
            middle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -rest),
            leadingRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            leadingRule.trailingAnchor.constraint(
                equalTo: middle.leadingAnchor, constant: -MacTheme.Spacing.s),
            leadingRule.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingRule.heightAnchor.constraint(equalToConstant: 1),
            trailingRule.leadingAnchor.constraint(
                equalTo: middle.trailingAnchor, constant: MacTheme.Spacing.s),
            trailingRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingRule.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingRule.heightAnchor.constraint(equalToConstant: 1),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(onPress == nil ? .staticText : .button)
        setAccessibilityLabel(spoken)
        if onPress != nil {
            setAccessibilityHelp(Localized.text("Opens the summary"))
            HoverPlate.attach(
                to: middle, placement: .behind(PointerPlate.inlineOutset), radius: 6)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var label: String { (middle.arrangedSubviews[1] as? NSTextField)?.stringValue ?? "" }
    var isPressable: Bool { onPress != nil }

    override var acceptsFirstResponder: Bool { onPress != nil && NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var pressRect: NSRect { middle.frame.insetBy(dx: -MacTheme.Spacing.s, dy: 0) }

    override var focusRingMaskBounds: NSRect { pressRect }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: pressRect, xRadius: 6, yRadius: 6).fill()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if onPress != nil { addCursorRect(pressRect, cursor: .pointingHand) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let onPress, pressRect.contains(convert(event.locationInWindow, from: nil)) else {
            return super.mouseUp(with: event)
        }
        onPress()
    }

    override func mouseDown(with event: NSEvent) {
        guard onPress != nil, pressRect.contains(convert(event.locationInWindow, from: nil)) else {
            return super.mouseDown(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard onPress != nil, [49, 36, 76].contains(event.keyCode) else {
            return super.keyDown(with: event)
        }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }
}

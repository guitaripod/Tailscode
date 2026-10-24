import AppKit
import CodingAgentKit
import TailscodeCore

/// A fact about where a conversation came from or where its answering model changed, as one flat
/// line at the seam's height: a mark, its words, and a quiet chevron at the far edge when a reader
/// stands behind it. The words take the room the pane gives them, which is what lets them wrap when
/// it is narrow and stand on one line again when it grows. It has no plate and no rules, because it is a note in the margin of the transcript and not
/// a divider between two turns, and its words wrap rather than being cut when the pane is narrower
/// than they are.
///
/// A line with a reader behind it is pressable the way a seam is: a plate under the pointer, a
/// click that acts on release, Space or Return once Full Keyboard Access puts it in the Tab loop.
@MainActor
final class FlatNoteLineView: NSView, KeyboardPressable {
    private let content = NSStackView()
    private let words: NSTextField
    private let onPress: (() -> Void)?

    init(
        mark: NSView, text: NSAttributedString, spoken: String, help: String?,
        onPress: (() -> Void)?
    ) {
        self.onPress = onPress
        words = RowKit.attributedLabel(text)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        mark.setContentHuggingPriority(.required, for: .horizontal)
        mark.setContentCompressionResistancePriority(.required, for: .horizontal)
        mark.setAccessibilityElement(false)
        words.isSelectable = false
        words.maximumNumberOfLines = 0
        words.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.setViews([mark, words], in: .leading)
        if onPress != nil {
            let chevron = RowKit.label(
                "›", font: MacTheme.Ramp.font(.note), color: MacTheme.Color.tertiaryLabel)
            chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
            content.addArrangedSubview(chevron)
        }
        content.orientation = .horizontal
        content.distribution = .fill
        content.alignment = .centerY
        content.spacing = MacTheme.Spacing.s
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        let breathing: CGFloat = 2 * MacTheme.UIScale.factor
        NSLayoutConstraint.activate([
            heightAnchor.constraint(
                greaterThanOrEqualToConstant: CGFloat(ChatLayout.metrics.seamRowHeight)
                    * MacTheme.UIScale.factor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: breathing),
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -breathing),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(onPress == nil ? .staticText : .button)
        setAccessibilityLabel(spoken)
        if onPress != nil {
            if let help { setAccessibilityHelp(help) }
            HoverPlate.attach(to: content, placement: .behind(PointerPlate.inlineOutset), radius: 6)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var reading: String { words.stringValue }
    var isPressable: Bool { onPress != nil }

    override var acceptsFirstResponder: Bool { onPress != nil && NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var pressRect: NSRect { content.frame.insetBy(dx: -MacTheme.Spacing.s, dy: 0) }

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

extension TranscriptRow {
    /// The model's mark on the seam: a seven point dot in the hue the model wears everywhere else
    /// it is named, so the change reads before the words do.
    @MainActor
    private static func identityDot(for change: ModelSwitch) -> NSView {
        let selection = change.selection
        let chip = ModelChip(
            name: change.to,
            family: ModelTint.family(selection.modelID, providerID: selection.providerID),
            effort: nil)
        let dot = RowKit.Ground(frame: .zero)
        dot.fill = MacTheme.Color.modelIdentity(chip)
        dot.radius = 3.5
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
        return dot
    }

    /// The line where the answering model changed: `● Qwen Daily  from DeepSeek V4`, the new word
    /// first and in full ink, the old one after it in the quiet register.
    @MainActor
    static func modelSeam(_ change: ModelSwitch) -> NSView {
        let font = MacTheme.Ramp.font(.seamFootnote)
        let line = NSMutableAttributedString(
            string: change.to,
            attributes: [
                .font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
                .foregroundColor: MacTheme.Color.label,
            ])
        line.append(
            NSAttributedString(
                string: "  " + change.fromText,
                attributes: [.font: font, .foregroundColor: MacTheme.Color.secondaryLabel]))
        return FlatNoteLineView(
            mark: identityDot(for: change), text: line,
            spoken: Localized.text("Model changed to %@, %@", change.to, change.fromText),
            help: nil, onPress: nil)
    }

    /// The first line of a chat that was carried from another: where it came from, with the source
    /// in full weight, and a press that opens the brief the first message rode in on.
    @MainActor
    static func carried(_ reading: CarryReading, context: TranscriptContext) -> NSView {
        let font = MacTheme.Ramp.font(.seamFootnote)
        let line = NSMutableAttributedString(
            string: reading.line,
            attributes: [.font: font, .foregroundColor: MacTheme.Color.secondaryLabel])
        let lead = Localized.text("Continued from %@", reading.source)
        let source = (lead as NSString).range(of: reading.source, options: .backwards)
        if source.location != NSNotFound {
            line.addAttributes(
                [
                    .font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
                    .foregroundColor: MacTheme.Color.label,
                ], range: source)
        }
        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: "arrow.turn.up.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 11 * MacTheme.UIScale.factor, weight: .medium))
        glyph.contentTintColor = MacTheme.Color.tertiaryLabel
        let present = context.presentText
        return FlatNoteLineView(
            mark: glyph, text: line, spoken: reading.line,
            help: Localized.text("Opens the carried conversation"),
            onPress: {
                present?(
                    Localized.text("Carried conversation"), reading.summary, reading.brief, false)
            })
    }
}

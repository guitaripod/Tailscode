import AppKit
import TailscodeCore

/// What waits to ride along with the next prompt, each as one removable chip: the conversation a
/// new chat was carried from, then the files. A file's chip removes by id, never by position — two
/// queued clicks by position would delete the wrong file — and the carry's removes only the carry.
@MainActor
final class AttachmentChips: NSView {
    var onRemove: ((UUID) -> Void)?
    var onClearCarry: (() -> Void)?

    private let row = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.xs
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(_ attachments: [PendingAttachment], carry: ConversationBrief? = nil) {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        isHidden = attachments.isEmpty && carry == nil
        if let carry {
            let chip = CarryChipView(brief: carry) { [weak self] in self?.onClearCarry?() }
            row.addArrangedSubview(chip)
            chip.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
        }
        for attachment in attachments {
            let id = attachment.id
            let title =
                "\(attachment.name) · \(AttachmentIntake.sizeText(attachment.data.count))"
            let chip = RowKit.ActionButton(title: title) { [weak self] in
                self?.onRemove?(id)
            }
            chip.bezelStyle = .rounded
            chip.controlSize = .small
            chip.font = MacTheme.Ramp.font(.attachment)
            chip.image = NSImage(
                systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
            chip.imagePosition = .imageTrailing
            chip.imageHugsTitle = true
            chip.cell?.lineBreakMode = .byTruncatingMiddle
            chip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            chip.toolTip = Localized.text("Remove %@", attachment.name)
            chip.setAccessibilityLabel(Localized.text("Remove %@", attachment.name))
            chip.translatesAutoresizingMaskIntoConstraints = false
            row.addArrangedSubview(chip)
        }
    }
}

/// The one chip a carried chat's composer wears: where the conversation came from, how much of it
/// came, and an x that makes this a fresh chat instead. The words wrap rather than being cut, and
/// the x is a target a pointer can hit without aiming.
@MainActor
final class CarryChipView: NSView {
    static let clearSide: CGFloat = 28

    private let glyph = NSImageView()
    private let words = FittedWrapLabel()
    private let clear: RowKit.ActionButton
    let reading: String

    init(brief: ConversationBrief, onClear: @escaping () -> Void) {
        reading = brief.chip
        clear = RowKit.ActionButton(title: "", action: onClear)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        glyph.image = NSImage(systemSymbolName: "arrow.turn.up.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 11 * MacTheme.UIScale.factor, weight: .medium))
        glyph.contentTintColor = MacTheme.Color.accent
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)
        glyph.setAccessibilityElement(false)

        words.font = MacTheme.Ramp.font(.attachment)
        words.textColor = MacTheme.Color.label
        words.stringValue = brief.chip
        words.maximumNumberOfLines = 0

        let fresh = Localized.text("Start a fresh chat instead")
        clear.isBordered = false
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: fresh)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 12 * MacTheme.UIScale.factor, weight: .regular))
        clear.imagePosition = .imageOnly
        clear.contentTintColor = MacTheme.Color.secondaryLabel
        clear.toolTip = fresh
        clear.setAccessibilityLabel(fresh)
        clear.refusesFirstResponder = true
        clear.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            clear.widthAnchor.constraint(equalToConstant: Self.clearSide),
            clear.heightAnchor.constraint(equalToConstant: Self.clearSide),
        ])
        clear.setContentHuggingPriority(.required, for: .horizontal)
        clear.setContentCompressionResistancePriority(.required, for: .horizontal)

        let content = NSStackView(views: [glyph, words, clear])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = MacTheme.Spacing.xs + 2
        content.edgeInsets = NSEdgeInsets(
            top: 0, left: MacTheme.Spacing.s, bottom: 0, right: 0)
        content.translatesAutoresizingMaskIntoConstraints = false
        RowKit.ground(
            behind: content, fill: NSColor.quaternaryLabelColor,
            radius: Self.clearSide / 2)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var clearButton: NSButton { clear }
}

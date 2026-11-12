import AppKit
import TailscodeCore

/// A long paste waiting beside the box: what it is and how long, the first line that says
/// anything, and an x that takes it away. Pressing the rest opens the whole paste, where it can be
/// copied or put back in the box as words.
@MainActor
final class PasteChipView: NSView {
    static let glimpseWidth: CGFloat = 220

    private let open: RowKit.ActionButton
    private let clear: RowKit.ActionButton
    let reading: String

    init(paste: FoldedPaste, onOpen: @escaping () -> Void, onRemove: @escaping () -> Void) {
        reading = paste.label + " " + paste.glimpse
        open = RowKit.ActionButton(title: "", action: onOpen)
        clear = RowKit.ActionButton(title: "", action: onRemove)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let font = MacTheme.Ramp.font(.attachment)
        let words = NSMutableAttributedString(
            string: paste.label,
            attributes: [
                .font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
                .foregroundColor: MacTheme.Color.label,
            ])
        if !paste.glimpse.isEmpty {
            words.append(
                NSAttributedString(
                    string: "  " + paste.glimpse,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular),
                        .foregroundColor: MacTheme.Color.secondaryLabel,
                    ]))
        }
        open.isBordered = false
        open.attributedTitle = words
        open.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 11 * MacTheme.UIScale.factor, weight: .medium))
        open.imagePosition = .imageLeading
        open.imageHugsTitle = true
        open.contentTintColor = MacTheme.Color.accent
        open.cell?.lineBreakMode = .byTruncatingTail
        open.toolTip = Localized.text("Opens the pasted text")
        open.setAccessibilityLabel(paste.spoken)
        open.setAccessibilityHelp(Localized.text("Opens the pasted text"))
        open.refusesFirstResponder = true
        open.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        open.translatesAutoresizingMaskIntoConstraints = false

        let remove = Localized.text("Remove %@", FoldedPaste.title)
        clear.isBordered = false
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: remove)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 12 * MacTheme.UIScale.factor, weight: .regular))
        clear.imagePosition = .imageOnly
        clear.contentTintColor = MacTheme.Color.secondaryLabel
        clear.toolTip = remove
        clear.setAccessibilityLabel(remove)
        clear.refusesFirstResponder = true
        clear.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            clear.widthAnchor.constraint(equalToConstant: CarryChipView.clearSide),
            clear.heightAnchor.constraint(equalToConstant: CarryChipView.clearSide),
            open.widthAnchor.constraint(
                lessThanOrEqualToConstant: Self.glimpseWidth * MacTheme.UIScale.factor
                    + font.pointSize * 9),
        ])
        clear.setContentHuggingPriority(.required, for: .horizontal)
        clear.setContentCompressionResistancePriority(.required, for: .horizontal)

        let content = NSStackView(views: [open, clear])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = MacTheme.Spacing.xs
        content.edgeInsets = NSEdgeInsets(top: 0, left: MacTheme.Spacing.s, bottom: 0, right: 0)
        content.translatesAutoresizingMaskIntoConstraints = false
        RowKit.ground(
            behind: content, fill: NSColor.quaternaryLabelColor,
            radius: CarryChipView.clearSide / 2)
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

    var openButton: NSButton { open }
    var clearButton: NSButton { clear }
}

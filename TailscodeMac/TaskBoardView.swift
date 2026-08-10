import AppKit
import TailscodeCore

/// The agent's plan as one card: done struck through and quiet, the task it is on now in the
/// accent wearing its present-tense wording, what is still ahead dim, headed by the same line
/// the band would wear. The card is the fold of the whole transcript (``TaskBoard``), placed at
/// the last call that moved the list.
@MainActor
enum TaskBoardView {
    static func make(_ board: TaskBoard) -> NSView {
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 5
        card.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        card.wantsLayer = true
        card.layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
        card.layer?.cornerRadius = MacTheme.Radius.control
        card.translatesAutoresizingMaskIntoConstraints = false

        let header = RowKit.label(
            board.headline, font: MacTheme.Ramp.font(.sectionLabel),
            color: MacTheme.Color.accent)
        card.addArrangedSubview(header)
        card.setCustomSpacing(MacTheme.Spacing.s, after: header)

        for item in board.items {
            card.addArrangedSubview(row(item))
        }
        return card
    }

    private static func row(_ item: TaskBoard.Item) -> NSView {
        let glyph: String
        let tint: NSColor
        switch item.status {
        case .completed: glyph = "checkmark.circle.fill"; tint = MacTheme.Color.success
        case .inProgress: glyph = "circle.lefthalf.filled"; tint = MacTheme.Color.accent
        case .pending: glyph = "circle"; tint = MacTheme.Color.tertiaryLabel
        }
        let attributed = NSMutableAttributedString()
        if let image = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        {
            let attachment = NSTextAttachment()
            attachment.image = image.tinted(tint)
            attributed.append(NSAttributedString(attachment: attachment))
        }
        let done = item.status == .completed
        let text = item.status == .inProgress ? (item.activeForm ?? item.subject) : item.subject
        var attrs: [NSAttributedString.Key: Any] = [
            .font: MacTheme.Ramp.font(.panelFootnote),
            .foregroundColor: done ? MacTheme.Color.tertiaryLabel : MacTheme.Color.label,
        ]
        if done { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        attributed.append(NSAttributedString(string: "  \(text)", attributes: attrs))
        let label = NSTextField(labelWithAttributedString: attributed)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        return label
    }
}

extension NSImage {
    fileprivate func tinted(_ color: NSColor) -> NSImage {
        let tinted = NSImage(size: size, flipped: false) { rect in
            color.set()
            rect.fill()
            self.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }
}

import AppKit
import TailscodeCore

/// The agent's plan as one card: done struck through and quiet, the task it is on now in full
/// ink under an accent mark and wearing its present-tense wording, what is still ahead dim,
/// headed by the same line the band would wear. The card is the fold of the whole transcript
/// (``TaskBoard``), placed at the last call that moved the list.
@MainActor
enum TaskBoardView {
    static func make(_ board: TaskBoard) -> NSView {
        let card = RaisedCard()
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

    /// The line the agent is on now is the only one in full-strength ink: done is struck through
    /// and quiet, and what is still ahead is quiet too, because during a long run the one question
    /// a reader has is which line is live — and a 10pt glyph is not an answer to it.
    ///
    /// The glyph rides the line rather than sitting on its baseline, and the words that wrap keep
    /// clear of the glyph's column, so a long task does not run back underneath its own mark.
    private static func row(_ item: TaskBoard.Item) -> NSView {
        let glyph: String
        let tint: NSColor
        switch item.status {
        case .completed: glyph = "checkmark.circle.fill"; tint = MacTheme.Color.success
        case .inProgress: glyph = "circle.lefthalf.filled"; tint = MacTheme.Color.accent
        case .pending: glyph = "circle"; tint = MacTheme.Color.tertiaryLabel
        }
        let font = MacTheme.Ramp.font(.panelFootnote)
        let attributed = NSMutableAttributedString()
        if let image = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                .init(pointSize: 10 * MacTheme.UIScale.factor, weight: .semibold))
        {
            let attachment = NSTextAttachment()
            attachment.image = image.tinted(tint)
            attachment.bounds = CGRect(
                x: 0, y: font.descender, width: image.size.width, height: image.size.height)
            attributed.append(NSAttributedString(attachment: attachment))
        }
        let done = item.status == .completed
        let text = item.status == .inProgress ? (item.activeForm ?? item.subject) : item.subject
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = MacTheme.Spacing.l * MacTheme.UIScale.factor
        paragraph.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: item.status == .inProgress
                ? MacTheme.Color.label : MacTheme.Color.tertiaryLabel,
        ]
        if done { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        attributed.append(NSAttributedString(string: "  \(text)", attributes: attrs))
        attributed.addAttribute(
            .paragraphStyle, value: paragraph,
            range: NSRange(location: 0, length: attributed.length))
        let label = NSTextField(labelWithAttributedString: attributed)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        return label
    }
}

/// The card's raised fill, drawn rather than baked. A `CGColor` written into a layer keeps the
/// light it was resolved under, and the transcript rebuilds its rows for a change of theme or type
/// scale but not for the system crossing into dark on its own at sunset — which would leave a pale
/// block sitting on a dark transcript for the rest of the session.
@MainActor
private final class RaisedCard: NSStackView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
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

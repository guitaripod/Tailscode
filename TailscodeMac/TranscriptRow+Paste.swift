import AppKit
import TailscodeCore

extension TranscriptRow {
    /// A person's message as rows: their words behind the accent rule, and each long paste folded
    /// to one line under them. The first row keeps the message's own key, so a message that never
    /// held a paste keeps the identity it always had.
    static func promptRows(_ text: String, key: String, messageID: String) -> [TranscriptRow] {
        guard PasteFold.mayHold(text) else {
            return [TranscriptRow(key: key, kind: .userText(text, messageID: messageID))]
        }
        let reading = PasteFold.split(text, id: key)
        guard reading.isFolded else {
            return [TranscriptRow(key: key, kind: .userText(text, messageID: messageID))]
        }
        return reading.pieces.enumerated().map { index, piece in
            let pieceKey = index == 0 ? key : "\(key):f\(index)"
            switch piece {
            case .words(let words):
                return TranscriptRow(key: pieceKey, kind: .userText(words, messageID: messageID))
            case .paste(let paste):
                return TranscriptRow(
                    key: pieceKey, kind: .pastedText(paste, messageID: messageID, under: index > 0))
            }
        }
    }

    /// A folded paste in a sent message: behind the prompt's own rule, what it is and how long,
    /// the first line that says anything, and a press that opens the whole of it in the reader.
    @MainActor
    static func pastedLine(
        _ paste: FoldedPaste, messageID: String, context: TranscriptContext
    ) -> NSView {
        let font = MacTheme.Ramp.font(.seamFootnote)
        let line = NSMutableAttributedString(
            string: paste.label,
            attributes: [
                .font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
                .foregroundColor: MacTheme.Color.label,
            ])
        if !paste.glimpse.isEmpty {
            line.append(
                NSAttributedString(
                    string: "  " + paste.glimpse,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular),
                        .foregroundColor: MacTheme.Color.secondaryLabel,
                    ]))
        }
        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 11 * MacTheme.UIScale.factor, weight: .medium))
        glyph.contentTintColor = MacTheme.Color.accent
        let present = context.presentText
        let fold = FlatNoteLineView(
            mark: glyph, text: line, spoken: paste.spoken,
            help: Localized.text("Opens the pasted text"),
            onPress: {
                present?(FoldedPaste.title, paste.summary, paste.text, true)
            })

        let rule = RowKit.Ground(frame: .zero)
        rule.fill = MacTheme.Color.accent
        let row = PromptRow(messageID: messageID, text: paste.text, context: context)
        row.addSubview(rule)
        row.addSubview(fold)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            rule.topAnchor.constraint(equalTo: row.topAnchor),
            rule.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            rule.widthAnchor.constraint(equalToConstant: 2),
            fold.leadingAnchor.constraint(equalTo: rule.trailingAnchor, constant: MacTheme.Spacing.s + 2),
            fold.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            fold.topAnchor.constraint(equalTo: row.topAnchor),
            fold.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }
}

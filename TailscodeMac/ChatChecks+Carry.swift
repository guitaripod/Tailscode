import AppKit
import CodingAgentKit
import TailscodeCore

extension ChatChecks {
    private static func answer(_ id: String, model: String, words: String) -> ChatMessage {
        var made = message(id, .assistant, [MessagePart(id: "t", kind: .text(words))])
        made.providerID = "ollama"
        made.modelID = model
        return made
    }

    private static func lineView(_ row: TranscriptRow, in width: CGFloat) -> (NSView, CGFloat) {
        let column = TranscriptColumn()
        column.metrics = compact
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        stage(root)
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        let view = row.makeView(context: TranscriptContext())
        column.addArrangedSubview(view, spacing: row.spacing)
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        return (view, view.frame.height)
    }

    static func carrying(_ expect: (Bool, String) throws -> Void) throws {
        let brief = ConversationBrief(
            source: "Fix reconnect test",
            body: "Carried from the chat \u{201C}Fix reconnect test\u{201D}.\nUser: why\nAssistant: a race",
            kept: 6, total: 14, pictures: 0)
        let typed = "why does the reconnect test flake?"
        let first = message("u1", .user, [MessagePart(id: "q", kind: .text(brief.wrapped(with: typed)))])
        let second = message("u2", .user, [MessagePart(id: "q", kind: .text("try the fix with the fake clock"))])
        let before = answer("a1", model: "deepseek-v4", words: "It races the backoff timer.")
        let after = answer("a2", model: "qwen3:30b", words: "Injected a test clock.")
        let again = answer("a3", model: "qwen3:30b", words: "Run it fifty times.")

        let builder = TranscriptRowBuilder()
        let rows = builder.rows(for: [first, before, second, after])
        let seams = rows.filter { if case .modelSeam = $0.kind { return true } else { return false } }
        let carried = rows.filter { if case .carried = $0.kind { return true } else { return false } }
        try expect(seams.count == 1, "two models make one seam, not \(seams.count)")
        try expect(carried.count == 1, "a carried first message makes one carried row, not \(carried.count)")

        guard let seamAt = rows.firstIndex(where: { $0.key == "a2:modelseam" }),
            case .modelSeam(let change) = rows[seamAt].kind
        else { throw SelfTestFailure("carry: the seam is keyed by the answer it stands before") }
        try expect(
            rows[seamAt + 1].key.hasPrefix("a2:") && change.from != change.to,
            "the seam stands directly before the new model's answer and names both words")

        guard let carriedAt = rows.firstIndex(where: { $0.key.hasSuffix(":carried") }),
            case .carried(let reading) = rows[carriedAt].kind,
            case .userText(let bubble, let owner) = rows[carriedAt + 1].kind
        else { throw SelfTestFailure("carry: the carried line stands directly before the first bubble") }
        try expect(carriedAt == 0 && owner == "u1", "the carried line is the first row, before the first message")
        try expect(bubble == typed, "the bubble holds only the typed words, not \(bubble)")
        try expect(reading.source == "Fix reconnect test" && reading.brief == brief.body,
            "the carried row reads its source and keeps the brief for the reader")
        try expect(
            !rows.contains { $0.searchText.contains("Assistant: a race") },
            "search never reads the brief")
        try expect(
            MessageHoverBar.words(of: first) == typed, "copying the first message gives the typed words")

        let streaming = builder.rows(for: [first, before, second, after, again])
        try expect(
            streaming.filter { if case .modelSeam = $0.kind { return true } else { return false } }.count == 1,
            "a third answer by the same model adds no seam")
        try expect(
            Array(streaming.prefix(rows.count)) == rows, "the earlier rows keep their keys and values")
        try expect(
            TranscriptRowBuilder.referenceRows(for: [first, before, second, after, again], turnOpen: false)
                == builder.rows(for: [first, before, second, after, again]),
            "the memoised rebuild is the plain one, seam and carried line included")

        let onlyBrief = message("u0", .user, [MessagePart(id: "q", kind: .text(brief.wrapped(with: "")))])
        let bare = builder.rows(for: [onlyBrief])
        try expect(
            bare.count == 1 && bare[0].key == "u0:q:carried",
            "a carried message with nothing typed is the line alone, no empty bubble: \(bare.map(\.key))")

        guard case .modelSeam(let line) = seams[0].kind else { return }
        let bound = 24 * MacTheme.UIScale.factor
        let (seamView, tall) = lineView(seams[0], in: 600)
        try expect(
            tall <= bound && (seamView as? FlatNoteLineView)?.isPressable == false,
            "the seam is one flat line of at most 24 pt that nothing opens: \(tall)")
        let (_, narrow) = lineView(seams[0], in: 90)
        try expect(narrow > tall, "the seam wraps rather than truncating when the pane is narrow: \(narrow)")
        try expect(
            (seamView as? FlatNoteLineView).map {
                $0.reading.hasPrefix(line.to) && $0.reading.hasSuffix(line.fromText)
            } == true,
            "the seam reads the new word first, then the old one")

        let (carriedView, carriedHeight) = lineView(rows[carriedAt], in: 600)
        try expect(
            carriedHeight <= bound && (carriedView as? FlatNoteLineView)?.isPressable == true,
            "the carried line is one flat pressable line: \(carriedHeight)")
        let (_, carriedNarrow) = lineView(rows[carriedAt], in: 120)
        try expect(carriedNarrow > carriedHeight, "the carried line wraps in a narrow pane: \(carriedNarrow)")

        let chips = AttachmentChips()
        chips.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        stage(chips)
        var cleared = 0
        chips.onClearCarry = { cleared += 1 }
        chips.set([], carry: brief)
        chips.layoutSubtreeIfNeeded()
        guard let chip = chips.subviews.first?.subviews.first as? CarryChipView else {
            throw SelfTestFailure("carry: the composer's chips row holds the carry chip")
        }
        try expect(!chips.isHidden && chip.reading == "Fix reconnect test · 6 of 14", "the chip says where from and how much")
        try expect(
            chip.clearButton.frame.width >= 28 && chip.clearButton.frame.height >= 28,
            "the chip's x is a target of at least 28 pt")
        chip.clearButton.performClick(nil)
        try expect(cleared == 1, "pressing the x clears the carry and nothing else")
        chips.set([], carry: nil)
        try expect(chips.isHidden, "with no carry and no files the chips row is gone")
    }
}

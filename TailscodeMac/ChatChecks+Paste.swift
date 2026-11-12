import AppKit
import CodingAgentKit
import TailscodeCore

extension ChatChecks {
    /// A long paste folds: a chip beside the box that the draft keeps and the send writes out as a
    /// block after the words, and one line under the prompt in the transcript that opens it.
    static func pasting(_ expect: (Bool, String) throws -> Void) throws {
        let log = (1...40).map { "2026-11-11 12:00:\($0) worker \($0) failed to bind" }
            .joined(separator: "\n")
        let paste = FoldedPaste(text: log)
        func words(_ id: String, _ role: MessageRole, _ text: String) -> ChatMessage {
            message(id, role, [MessagePart(id: "q", kind: .text(text))])
        }
        let asked = words("u1", .user, PasteFold.wrap("why does this fail?", pastes: [paste]))
        let alone = words("u2", .user, PasteFold.wrap("", pastes: [paste]))
        let rows = TranscriptRowBuilder().rows(
            for: [asked, words("a1", .assistant, "The port is taken."), alone])
        let shown = rows.compactMap { row -> String? in
            switch row.kind {
            case .userText(let text, let id): return "\(id) words \(text)"
            case .pastedText(let folded, let id, let under): return "\(id) paste \(folded.lines) \(under)"
            default: return nil
            }
        }
        try expect(
            shown == ["u1 words why does this fail?", "u1 paste 40 true", "u2 paste 40 false"],
            "each prompt shows its words and folds its paste: \(shown)")
        try expect(
            rows.first { $0.key.hasPrefix("u1") }?.key == "u1:q", "a prompt's first row keeps its key")
        try expect(
            !rows.contains { $0.searchText.contains(PasteFold.tag) }
                && rows.contains { $0.searchText.contains("worker 17 failed") },
            "a search reads into the fold and never reads the tag")
        try expect(
            rows.filter { if case .pastedText = $0.kind { return $0.isPromptBlock } else { return false } }
                .count == 2, "a fold is part of what the person sent")
        try expect(
            MessageHoverBar.words(of: asked) == "why does this fail?\n\n" + log,
            "copying the message gives the words and the paste, no tags")

        let metrics = compact
        let under = ChatLayout.spacing(of: .pastedText(paste, messageID: "u", under: true))
        let lead = ChatLayout.spacing(of: .pastedText(paste, messageID: "u", under: false))
        try expect(
            ChatLayout.gap(from: .row(.prompt), to: under, metrics: metrics)
                == CGFloat(metrics.paragraphGap)
                && lead == .row(.prompt)
                && ChatLayout.gap(from: under, to: .row(.prose), metrics: metrics)
                    == ChatLayout.gap(from: .row(.prompt), to: .row(.prose), metrics: metrics),
            "a fold sits close under its words, a paste sent alone is a prompt, and an answer follows either as it follows a prompt")
        try expect(
            TranscriptRowBuilder.referenceRows(for: [asked, alone], turnOpen: false)
                == TranscriptRowBuilder().rows(for: [asked, alone]),
            "the memoised rebuild folds the same way")

        let context = TranscriptContext()
        var opened: (String, String?, String, Bool)?
        context.presentText = { title, subtitle, body, mono in opened = (title, subtitle, body, mono) }
        let line = TranscriptRow.pastedLine(paste, messageID: "u1", context: context)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        stage(root)
        root.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        let fold = line.subviews.compactMap { $0 as? FlatNoteLineView }.first
        try expect(
            line.frame.height <= 30 * MacTheme.UIScale.factor && fold?.isPressable == true,
            "a folded paste is one pressable line: \(line.frame.height)")
        try expect(
            fold?.reading.hasPrefix(paste.label) == true
                && fold?.reading.contains("2026-11-11 12:00:1 worker 1") == true,
            "the line says what it is and how long, then the first line")
        _ = fold?.accessibilityPerformPress()
        try expect(
            opened?.2 == log && opened?.3 == true, "pressing the line opens the whole paste, monospaced")

        let composer = ComposerView()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 260))
        stage(host)
        host.addSubview(composer)
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
            composer.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
            composer.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16),
        ])
        var sent: [String] = []
        composer.onSubmitPrompt = { text, _, _, _ in sent.append(text) }
        composer.insertText("why does this fail?")
        composer.addPaste(paste)
        host.layoutSubtreeIfNeeded()
        try expect(
            composer.currentText == "why does this fail?" && composer.pastes.count == 1,
            "a fold waits beside the box and the box keeps only the typed words")
        let chip = composer.chips.subviews.first?.subviews.first as? PasteChipView
        try expect(
            !composer.chips.isHidden && chip?.reading.hasPrefix(paste.label) == true,
            "the chip row shows the fold by its label")
        try expect(
            (chip?.clearButton.frame.width ?? 0) >= 28, "the chip's x is a target of at least 28 pt")
        let kept = PasteFold.undraft(composer.draftText)
        try expect(
            kept.words == "why does this fail?" && kept.pastes.map(\.text) == [log],
            "the draft keeps the fold")
        composer.unfoldPaste(paste.id)
        try expect(
            composer.pastes.isEmpty && composer.currentText.contains("worker 40 failed"),
            "Edit as text puts the paste back in the box as words")
        composer.clearIfUnchanged(from: composer.draftText)
        try expect(composer.fillIfEmpty(PasteFold.wrap("again", pastes: [paste])), "an empty box takes a message back")
        try expect(
            composer.currentText == "again" && composer.pastes.map(\.text) == [log],
            "a message handed back to the box comes back as words and a chip, never its tags")
        try expect(!composer.fillIfEmpty("more"), "a box holding a fold is not empty")
        composer.sendNow()
        try expect(
            sent == [PasteFold.wrap("again", pastes: [paste])] && composer.pastes.isEmpty
                && composer.chips.isHidden,
            "a send writes the words then the block, and empties the chip row: \(sent.map(\.count))")
        composer.addPaste(paste)
        composer.sendNow()
        try expect(
            sent.last == PasteFold.wrap("", pastes: [paste]), "a fold alone is a message")
    }
}

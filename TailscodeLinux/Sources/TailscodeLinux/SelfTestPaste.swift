import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// A long paste folds: a chip beside the box that the draft keeps and the send writes out as a
    /// block after the words, and one line under the prompt in the transcript that a search still
    /// reads into.
    static func checkFoldedPaste() throws -> Int {
        var claims = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure(label) }
            claims += 1
        }
        let log = (1...40).map { "2026-11-11 12:00:\($0) worker \($0) failed to bind" }
            .joined(separator: "\n")
        let paste = FoldedPaste(text: log)
        func message(_ id: String, _ role: MessageRole, _ text: String) -> ChatMessage {
            ChatMessage(
                id: id, role: role, agentType: .claudeCode,
                parts: [MessagePart(id: id + "-t", kind: .text(text))], createdAt: Date())
        }
        let messages = [
            message("u1", .user, PasteFold.wrap("why does this fail?", pastes: [paste])),
            message("a1", .assistant, "The port is taken."),
            message("u2", .user, PasteFold.wrap("", pastes: [paste])),
            message("u3", .user, "and now?"),
        ]
        let rows = TranscriptRowBuilder().rows(for: messages)
        let shown = rows.compactMap { row -> String? in
            switch row.kind {
            case .userText(let text, let id): return "\(id) words \(text)"
            case .pastedText(let folded, let id): return "\(id) paste \(folded.lines)"
            default: return nil
            }
        }
        try expect(
            shown == [
                "u1 words why does this fail?", "u1 paste 40", "u2 paste 40", "u3 words and now?",
            ], "each prompt shows its words and folds its paste: \(shown)")
        try expect(
            rows.first { $0.key.hasPrefix("u1") }?.key == "u1:u1-t",
            "a prompt's first row keeps the message's own key")
        try expect(
            !rows.contains { $0.searchText.contains(PasteFold.tag) },
            "nothing a search reads holds the tag")
        try expect(
            rows.contains {
                if case .pastedText = $0.kind { return $0.searchText.contains("worker 17 failed") }
                return false
            }, "a search reads into the fold")
        try expect(
            rows.filter { $0.chatClass == .prompt }.count == shown.count,
            "a fold is set as part of the prompt")
        try expect(
            rows.filter { if case .pastedText = $0.kind { true } else { false } }
                .allSatisfy { $0.isPromptBlock && !$0.announcesArrival },
            "a fold rises with its prompt and never fades in after its words")

        let metrics = TranscriptGaps.metrics
        let margins = TranscriptGaps.margins(for: rows, metrics: metrics)
        let folds = rows.indices.filter {
            if case .pastedText = rows[$0].kind { return true }
            return false
        }
        var asWords = rows
        if folds.count == 2 {
            asWords[folds[1]] = TranscriptRow(
                key: rows[folds[1]].key, kind: .userText("alone", messageID: "u2"))
        }
        let wordsMargins = TranscriptGaps.margins(for: asWords, metrics: metrics)
        try expect(
            folds.count == 2 && margins[folds[0]] == metrics.paragraphGap
                && margins[folds[1]] == wordsMargins[folds[1]],
            "a fold sits close under its own words, and a paste sent alone is spaced as any prompt: \(folds.map { margins[$0] }) vs \(folds.map { wordsMargins[$0] })")
        try expect(
            folds.allSatisfy {
                TranscriptGaps.margin(at: $0, in: rows, metrics: metrics) == margins[$0]
            }, "one row's margin agrees with the whole transcript's")

        guard gtk_init_check() != 0 else { return claims }
        MatrixTheme.install()
        tailscode_set_animations_enabled(0)
        let context = TranscriptContext()
        if let folded = rows.first(where: { if case .pastedText = $0.kind { true } else { false } }) {
            let widget = folded.makeWidget(context: context)
            var least: Int32 = 0
            var natural: Int32 = 0
            var ignoredA: Int32 = 0
            var ignoredB: Int32 = 0
            gtk_widget_measure(
                widget, GTK_ORIENTATION_VERTICAL, 600, &least, &natural, &ignoredA, &ignoredB)
            try expect(
                natural > 0 && natural <= 36, "a folded paste is one line in the transcript: \(natural)")
        }

        let host = MainWindow()
        let tile = TileHost(host: host)
        host.installTiling(tile)
        let window = gtk_window_new()!
        gtk_window_set_default_size(ptr(window), 900, 700)
        gtk_window_set_child(ptr(window), tile.container)
        gtk_window_present(ptr(window))
        defer { gtk_window_destroy(ptr(window)) }
        for pane in tile.orderedPanes { pane.kindOverride = .chat }
        _ = brainPump(0.3)
        guard let pane = tile.orderedPanes.first else { throw SelfTestFailure("paste: no pane") }
        pane.detachStreamForScript()
        pane.clearComposer()

        pane.insertAtCaret("why does this fail?")
        pane.addPaste(paste)
        try expect(
            pane.composerText() == "why does this fail?" && pane.pastes.count == 1,
            "a fold waits beside the box and the box keeps only the typed words")
        try expect(gtk_widget_get_visible(pane.attachmentsBox) != 0, "the chip row shows the fold")
        try expect(
            pane.composedText() == PasteFold.wrap("why does this fail?", pastes: [paste]),
            "a send writes the words, then the block")
        let kept = PasteFold.undraft(pane.draftText())
        try expect(
            kept.words == "why does this fail?" && kept.pastes.map(\.text) == [log],
            "the draft keeps the fold")

        pane.unfoldPaste(paste.id)
        try expect(
            pane.pastes.isEmpty && pane.composerText().contains("worker 40 failed"),
            "Edit as text puts the paste back in the box as words")

        pane.fillComposer(with: PasteFold.wrap("again", pastes: [paste]))
        try expect(
            pane.composerText() == "again" && pane.pastes.map(\.text) == [log],
            "a message handed back to the box comes back as words and a chip, never its tags")
        try expect(pane.composerHoldsWords, "a box with only a fold still holds something to send")
        let brief = ConversationBrief(
            source: "Earlier", body: "User: hi", kept: 1, total: 1, pictures: 0)
        pane.clearComposer()
        pane.fillComposer(with: brief.wrapped(with: PasteFold.wrap("again", pastes: [paste])))
        try expect(
            pane.composerText() == "again" && pane.pastes.map(\.text) == [log]
                && pane.carry?.source == "Earlier",
            "a carried message handed back gives back its words, its fold and its carry, no tags")
        pane.carry = nil
        pane.removePaste(pane.pastes[0].id)
        try expect(pane.pastes.isEmpty, "the chip's own control takes the fold away")
        pane.addPaste(paste)
        pane.clearComposer()
        try expect(
            pane.pastes.isEmpty && gtk_widget_get_visible(pane.attachmentsBox) == 0,
            "a box emptied for another chat takes its folds with it")
        return claims
    }
}

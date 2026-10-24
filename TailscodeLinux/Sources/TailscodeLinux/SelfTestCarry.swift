import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// A conversation that changed model and arrived with a brief reads as one seam where the model
    /// changed and one carried line at the top, the prompt beside it showing only what was typed,
    /// both as flat lines no taller than a seam is allowed to be.
    static func checkModelSeamAndCarry() throws -> Int {
        var claims = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure(label) }
            claims += 1
        }
        let catalog = [
            ModelInfo(id: "qwen-daily", name: "Qwen Daily", providerID: "llama"),
            ModelInfo(id: "deepseek-v4", name: "DeepSeek V4", providerID: "opencode"),
        ]
        let brief = ConversationBrief(
            source: "Fix reconnect test", body: "User: why\nAssistant: because", kept: 6, total: 14,
            pictures: 0)
        let typed = "why does the reconnect test flake?"
        func message(
            _ id: String, _ role: MessageRole, _ text: String, model: String? = nil,
            provider: String? = nil
        ) -> ChatMessage {
            ChatMessage(
                id: id, role: role, agentType: .openCode,
                parts: [MessagePart(id: id + "-t", kind: .text(text))], createdAt: Date(),
                providerID: provider, modelID: model)
        }
        let messages = [
            message("u1", .user, brief.wrapped(with: typed)),
            message("a1", .assistant, "It races the timer.", model: "deepseek-v4", provider: "opencode"),
            message("u2", .user, "try the fix with the fake clock"),
            message("a2", .assistant, "Injected a clock.", model: "qwen-daily", provider: "llama"),
        ]
        let builder = TranscriptRowBuilder()
        builder.setCatalog(catalog)
        let rows = builder.rows(for: messages)

        let seams = rows.enumerated().compactMap { index, row -> (Int, ModelSwitch)? in
            if case .modelSeam(let seam) = row.kind { return (index, seam) }
            return nil
        }
        try expect(seams.count == 1, "a change of model draws one seam: \(rows.map(\.kind))")
        try expect(
            seams[0].1.to == "Qwen Daily" && seams[0].1.from == "DeepSeek V4",
            "the seam names the new model and the old: \(seams[0].1.line)")
        try expect(
            rows[seams[0].0 + 1].key.hasPrefix("a2:"),
            "the seam stands directly before the answer the new model wrote")

        let carried = rows.enumerated().compactMap { index, row -> (Int, CarryReading)? in
            if case .carried(let reading) = row.kind { return (index, reading) }
            return nil
        }
        try expect(carried.count == 1, "a carried first message draws one carried line")
        try expect(
            carried[0].0 == 0 && carried[0].1.source == "Fix reconnect test"
                && carried[0].1.brief == "User: why\nAssistant: because",
            "the carried line leads the chat and holds the brief it rode in")
        let prompts = rows.compactMap { row -> String? in
            if case .userText(let text, _) = row.kind { return text }
            return nil
        }
        try expect(
            prompts == [typed, "try the fix with the fake clock"],
            "the first prompt shows only the typed words: \(prompts)")
        try expect(
            !rows.contains { $0.searchText.contains(CarryMark.tag) },
            "nothing a search reads holds the brief's tag")
        try expect(
            TranscriptRow.typedWords(brief.wrapped(with: typed)) == typed
                && TranscriptRow.typedWords(typed) == typed,
            "copy and undo read the typed words, and a plain message as it is")

        let bare = builder.rows(for: [message("u1", .user, brief.wrapped(with: ""))])
        try expect(
            bare.count == 1 && { if case .carried = bare[0].kind { return true } else { return false } }(),
            "a first message that is only the brief has the line and no prompt: \(bare.map(\.kind))")

        let later = builder.rows(
            for: [message("u0", .user, "hello"), message("u1", .user, brief.wrapped(with: typed))])
        try expect(
            !later.contains { if case .carried = $0.kind { return true } else { return false } },
            "only the first message is read for a brief")

        let streaming = messages.dropLast() + [
            ChatMessage(
                id: "a2", role: .assistant, agentType: .openCode,
                parts: [MessagePart(id: "a2-t", kind: .text("Inj"))], createdAt: Date(),
                isStreaming: true, providerID: "llama", modelID: "qwen-daily")
        ]
        let again = builder.rows(for: Array(streaming))
        try expect(
            again.filter { if case .modelSeam = $0.kind { return true } else { return false } }
                .count == 1,
            "an answer still being written already carries its seam")

        try expect(
            TranscriptGaps.metrics.seamRowHeight <= 24, "a seam line is no taller than 24 points")
        try expect(
            TranscriptRow.carriedMarkup(carried[0].1).contains("<b>Fix reconnect test</b>"),
            "the carried line sets its source in bold")
        guard gtk_init_check() != 0 else { return claims }
        MatrixTheme.install()
        let context = TranscriptContext()
        for row in [rows[seams[0].0], rows[carried[0].0]] {
            let widget = row.makeWidget(context: context)
            var least: Int32 = 0
            var natural: Int32 = 0
            var ignoredA: Int32 = 0
            var ignoredB: Int32 = 0
            gtk_widget_measure(
                widget, GTK_ORIENTATION_VERTICAL, 600, &least, &natural, &ignoredA, &ignoredB)
            try expect(
                natural > 0 && natural <= 24,
                "a seam or carried line measures one flat line at 600 px: \(natural)")
        }
        return claims
    }
}

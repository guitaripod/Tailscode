import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("What a notification says")
struct NoticeReadingTests {
    private static let finishedAt = Date(timeIntervalSince1970: 2_000_000)

    private static func state(
        _ status: BackendStatus, _ messages: [ChatMessage] = []
    ) -> ConversationState {
        ConversationState(
            messages: messages, status: status, connection: .live, hasLoadedTranscript: true)
    }

    private static func prompt(_ id: String = "u") -> ChatMessage {
        ChatMessage(
            id: id, role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "\(id)-t", kind: .text("fix it"))], createdAt: Date())
    }

    private static func answer(
        _ parts: [MessagePart], done: Bool = true, duration: TimeInterval? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: "a", role: .assistant, agentType: .claudeCode, parts: parts, createdAt: Date(),
            completedAt: done ? finishedAt : nil, isStreaming: !done, duration: duration)
    }

    private static func call(_ id: String, _ name: String, _ status: ToolStatus) -> MessagePart {
        MessagePart(id: id, kind: .tool(ToolCall(id: id, name: name, status: status)))
    }

    private static func text(_ words: String) -> MessagePart {
        MessagePart(id: "text-\(words.count)", kind: .text(words))
    }

    /// A question with the given option labels, asked one at a time, so the reading judges the
    /// item rather than the request around it.
    private static func item(
        _ labels: [String], multiple: Bool = false, custom: Bool = false
    ) -> QuestionRequest.Item {
        QuestionRequest.Item(
            question: "Which database?", header: "DB",
            options: labels.map { QuestionRequest.Option(label: $0, description: "") },
            multiple: multiple, custom: custom)
    }

    private static func asked(_ items: [QuestionRequest.Item]) -> QuestionRequest {
        QuestionRequest(id: "q", sessionID: "s", questions: items)
    }

    @Test("A finished turn says what it took, its first words and where a reply goes")
    func turnEndedReading() {
        let reading = NoticeReader.turnEnded(
            in: Self.state(
                .idle,
                [
                    Self.prompt(),
                    Self.answer([
                        Self.call("b", "Bash", .completed),
                        Self.call("r", "Read", .completed),
                        Self.text(
                            "**Done.** I added a [link](http://x.y) and `code`.\n```\nhidden\n```\nSecond line"
                        ),
                    ]),
                ]))
        #expect(reading.headline == "Finished")
        #expect(reading.facts.contains("2 tools"))
        #expect(reading.excerpt == "Done. I added a link and code. Second line")
        #expect(reading.replyPlaceholder == "Message your agent…")
        #expect(reading.retryPrompt == nil)
        #expect(reading.lead.hasPrefix("Finished"))
    }

    @Test("A turn of one tool says one tool, and a turn of none says nothing of tools")
    func toolCountFact() {
        let one = NoticeReader.turnEnded(
            in: Self.state(
                .idle, [Self.prompt(), Self.answer([Self.call("b", "Bash", .completed)])]))
        #expect(one.facts.contains("1 tool"))
        let none = NoticeReader.turnEnded(
            in: Self.state(.idle, [Self.prompt(), Self.answer([Self.text("Yes.")])]))
        #expect(none.facts.isEmpty)
    }

    @Test("A reported duration of 222 seconds reads as 4m, and one of 3 seconds reads as nothing")
    func durationFact() {
        let long = NoticeReader.turnEnded(
            in: Self.state(.idle, [Self.prompt(), Self.answer([Self.text("Yes.")], duration: 222)]))
        #expect(long.facts.first == "4m")
        let short = NoticeReader.turnEnded(
            in: Self.state(.idle, [Self.prompt(), Self.answer([Self.text("Yes.")], duration: 3)]))
        #expect(short.facts.isEmpty)
    }

    @Test("The diff fact is the tally of the turn's edits, with a real minus sign")
    func diffFact() {
        let edit = ToolCall(
            id: "e", name: "Edit", status: .completed,
            input: .object([
                "file_path": .string("/a/b.swift"),
                "old_string": .string("x"),
                "new_string": .string("x\ny\nz"),
            ]))
        let tally = ToolDiff.tally([edit])
        #expect(tally.added == 3)
        #expect(tally.removed == 1)
        let reading = NoticeReader.turnEnded(
            in: Self.state(
                .idle, [Self.prompt(), Self.answer([MessagePart(id: "e", kind: .tool(edit))])]))
        #expect(reading.facts.last == "+3 \u{2212}1")
        #expect(reading.facts.last == "+\(tally.added) \u{2212}\(tally.removed)")
    }

    @Test("A long answer is cut at a word boundary and marked, within the excerpt limit")
    func excerptCut() {
        let reading = NoticeReader.turnEnded(
            in: Self.state(
                .idle,
                [Self.prompt(), Self.answer([Self.text(String(repeating: "alpha ", count: 100))])]))
        #expect(reading.excerpt.hasSuffix("…"))
        #expect(reading.excerpt.count <= NoticeReader.excerptLimit + 1)
        let words = reading.excerpt.dropLast().split(separator: " ")
        #expect(!words.isEmpty)
        #expect(words.allSatisfy { $0 == "alpha" })
    }

    @Test("The excerpt comes from the latest turn only, so a turn of tools alone has none")
    func excerptIsThisTurnOnly() {
        let reading = NoticeReader.turnEnded(
            in: Self.state(
                .idle,
                [
                    Self.prompt("u1"),
                    Self.answer([Self.text("old answer")]),
                    Self.prompt("u2"),
                    Self.answer([Self.call("b", "Bash", .completed)]),
                ]))
        #expect(reading.excerpt.isEmpty)
    }

    @Test("A failed turn says so, tidies the reason and offers its prompt to send again")
    func turnFailedReading() {
        var failing = Self.state(.idle, [Self.prompt(), Self.answer([Self.text("partial")])])
        failing.lastFailure = BackendFailure(message: "boom   happened")
        let reading = NoticeReader.turnFailed(in: failing)
        #expect(reading.headline == "Failed")
        #expect(reading.excerpt == "boom happened")
        #expect(reading.retryPrompt == "fix it")
    }

    @Test("An approval names the command it would run, and falls back to the permission's title")
    func approvalReading() {
        let permission = PermissionRequest(
            id: "p", sessionID: "s", title: "Run command", toolName: "Bash")
        let pending = ToolCall(
            id: "b", name: "Bash", status: .pending,
            input: .object(["command": .string("rm -rf build/")]))
        let withCall = NoticeReader.approval(
            permission,
            in: Self.state(
                .running,
                [Self.prompt(), Self.answer([MessagePart(id: "b", kind: .tool(pending))], done: false)]))
        #expect(withCall.headline == "Needs approval")
        #expect(withCall.facts == ["Bash"])
        #expect(withCall.excerpt == "rm -rf build/")

        let withoutCall = NoticeReader.approval(
            permission, in: Self.state(.running, [Self.prompt()]))
        #expect(withoutCall.excerpt == "Run command")
    }

    @Test("A single question with two short options becomes two buttons and no reply field")
    func questionButtons() {
        let reading = NoticeReader.question(Self.asked([Self.item(["Postgres", "SQLite"])]))
        #expect(reading.headline == "Has a question")
        #expect(reading.excerpt == "Which database?")
        #expect(reading.choices == ["Postgres", "SQLite"])
        #expect(reading.replyPlaceholder == nil)
    }

    @Test("A question that accepts a free answer also asks for one in the reply field")
    func customQuestion() {
        let reading = NoticeReader.question(
            Self.asked([Self.item(["Postgres", "SQLite"], custom: true)]))
        #expect(reading.choices == ["Postgres", "SQLite"])
        #expect(reading.replyPlaceholder == "Your answer")
    }

    @Test("A multi-select question gets no buttons")
    func multipleQuestion() {
        let reading = NoticeReader.question(
            Self.asked([Self.item(["Postgres", "SQLite"], multiple: true)]))
        #expect(reading.choices.isEmpty)
    }

    @Test("Two questions in one request get no buttons and no reply field")
    func twoQuestions() {
        let reading = NoticeReader.question(
            Self.asked([Self.item(["Postgres"]), Self.item(["SQLite"])]))
        #expect(reading.choices.isEmpty)
        #expect(reading.replyPlaceholder == nil)
    }

    @Test("More than three options keep three buttons and list all five in the detail line")
    func fiveOptions() {
        let labels = ["Postgres", "SQLite", "MySQL", "Redis", "Mongo"]
        let reading = NoticeReader.question(Self.asked([Self.item(labels)]))
        #expect(reading.choices == ["Postgres", "SQLite", "MySQL"])
        #expect(reading.detail == "Postgres · SQLite · MySQL · Redis · Mongo")
    }

    @Test("An option longer than 32 characters rules out the buttons, and 32 still fits")
    func choiceWidthLimit() {
        let long = String(repeating: "x", count: 33)
        let tooLong = NoticeReader.question(Self.asked([Self.item([long, "SQLite"])]))
        #expect(tooLong.choices.isEmpty)
        let fits = String(repeating: "x", count: 32)
        let atLimit = NoticeReader.question(Self.asked([Self.item([fits, "SQLite"])]))
        #expect(atLimit.choices == [fits, "SQLite"])
    }

    @Test("Duplicate option labels rule out the buttons")
    func duplicateLabels() {
        let reading = NoticeReader.question(Self.asked([Self.item(["Postgres", "Postgres"])]))
        #expect(reading.choices.isEmpty)
    }

    @Test("A question with no options asks for a free answer and offers no buttons")
    func noOptions() {
        let reading = NoticeReader.question(Self.asked([Self.item([])]))
        #expect(reading.replyPlaceholder == "Your answer")
        #expect(reading.choices.isEmpty)
    }

    @Test("A turn-end alert carries the notice read from the conversation it came from")
    func watchCarriesTurnEndNotice() {
        var watch = ActivityWatch()
        let running = Self.state(
            .running, [Self.prompt(), Self.answer([Self.text("working")], done: false)])
        let opening = watch.observeConversation(
            profileID: "p", sessionID: "s", title: "Chat", state: running)
        #expect(opening.alerts.isEmpty)
        let settled = Self.state(
            .idle,
            [
                Self.prompt(),
                Self.answer([Self.call("r", "Read", .completed), Self.text("Done.")]),
            ])
        let alerts = watch.observeConversation(
            profileID: "p", sessionID: "s", title: "Chat", state: settled
        ).alerts
        #expect(alerts.count == 1)
        guard let alert = alerts.first else { return }
        #expect(alert.reason == .turnEnded)
        #expect(alert.body == "Your agent finished.")
        #expect(alert.notice != nil)
        #expect(alert.notice?.headline == "Finished")
    }

    @Test("A pending permission alert carries the permission and its approval notice")
    func watchCarriesApprovalNotice() {
        var watch = ActivityWatch()
        var pending = Self.state(
            .running, [Self.prompt(), Self.answer([Self.call("b", "Bash", .pending)], done: false)])
        pending.pendingPermissions = [
            PermissionRequest(id: "p", sessionID: "s", title: "Run command", toolName: "Bash")
        ]
        let alerts = watch.observeConversation(
            profileID: "p", sessionID: "s", title: "Chat", state: pending
        ).alerts
        #expect(alerts.count == 1)
        guard let alert = alerts.first else { return }
        #expect(alert.reason == .needsApproval)
        #expect(alert.permission != nil)
        #expect(alert.notice?.headline == "Needs approval")
    }

    @Test("A pending question alert carries the question and its question notice")
    func watchCarriesQuestionNotice() {
        var watch = ActivityWatch()
        var asking = Self.state(.running, [Self.prompt(), Self.answer([Self.text("Choosing")], done: false)])
        asking.pendingQuestions = [Self.asked([Self.item(["Postgres", "SQLite"])])]
        let alerts = watch.observeConversation(
            profileID: "p", sessionID: "s", title: "Chat", state: asking
        ).alerts
        #expect(alerts.count == 1)
        guard let alert = alerts.first else { return }
        #expect(alert.reason == .needsAnswer)
        #expect(alert.question != nil)
        #expect(alert.notice?.headline == "Has a question")
    }
}

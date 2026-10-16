import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("A notice on the wire")
struct NoticeWireTests {
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

    /// Options with no detail, one per label, in the order given.
    private static func options(_ labels: [String]) -> [NoticeWire.Option] {
        labels.map { NoticeWire.Option(label: $0) }
    }

    @Test("A notice survives the trip through userInfo, at the newest version")
    func roundTrip() throws {
        let wire = NoticeWire(
            kind: .question, text: "Which one?",
            options: [NoticeWire.Option(label: "A", detail: "first"), NoticeWire.Option(label: "B")],
            multiple: false, free: true, server: "arch", agent: "claudeCode")
        let object = try #require(wire.userInfoValue())
        let userInfo: [AnyHashable: Any] = [NoticeWire.key: object]
        let back = try #require(NoticeWire(userInfo: userInfo))
        #expect(back == wire)
        #expect(back.v == NoticeWire.version)
        #expect(object["v"] as? Int == NoticeWire.version)
    }

    @Test("Fields a notice does not set are absent from its userInfo, never null")
    func nilFieldsAbsent() throws {
        let object = try #require(NoticeWire(kind: .done).userInfoValue())
        #expect(Set(object.keys) == ["v", "kind"])
        #expect(object["kind"] as? String == "done")
        #expect(!object.values.contains { $0 is NSNull })
    }

    @Test("A userInfo with no notice, or a notice of an unknown kind, reads as no notice")
    func unreadableNotice() {
        #expect(NoticeWire(userInfo: [:]) == nil)
        let object: [String: Any] = ["v": 1, "kind": "bogus"]
        let userInfo: [AnyHashable: Any] = [NoticeWire.key: object]
        #expect(NoticeWire(userInfo: userInfo) == nil)
    }

    @Test("Keys a later version adds are ignored, and the notice still reads")
    func unknownKeysIgnored() throws {
        let object: [String: Any] = [
            "v": 2, "kind": "approval", "subject": "Bash", "text": "ls -la",
            "futureField": "later", "futureNested": ["a": 1],
        ]
        let userInfo: [AnyHashable: Any] = [NoticeWire.key: object]
        let wire = try #require(NoticeWire(userInfo: userInfo))
        #expect(wire.kind == .approval)
        let reading = NoticeWords.reading(wire)
        #expect(reading.headline == "Needs approval")
        #expect(reading.excerpt == "ls -la")
    }

    @Test("A finished turn reads its facts, a plain excerpt and a reply placeholder")
    func doneReading() {
        let wire = NoticeWire(
            kind: .done, seconds: 222, tools: 12, added: 24, removed: 6,
            text: "**Done.** I added a [link](http://x.y) and `code`.\n```\nhidden\n```\nSecond line")
        let reading = NoticeWords.reading(wire)
        #expect(reading.headline == "Finished")
        #expect(reading.facts == ["4m", "12 tools", "+24 \u{2212}6"])
        #expect(reading.excerpt == "Done. I added a link and code. Second line")
        #expect(reading.replyPlaceholder == "Message your agent…")
        #expect(reading.lead == "Finished · 4m · 12 tools · +24 \u{2212}6")
    }

    @Test("A short turn of one tool says one tool, and a done notice with no numbers has no facts")
    func doneFactsOmitted() {
        let short = NoticeWords.reading(NoticeWire(kind: .done, seconds: 3, tools: 1, text: "Yes."))
        #expect(short.facts == ["1 tool"])
        let bare = NoticeWords.reading(NoticeWire(kind: .done, text: "Yes."))
        #expect(bare.facts.isEmpty)
    }

    @Test("A failed turn tidies its reason, reads its facts and offers its prompt to send again")
    func failedReading() {
        let reading = NoticeWords.reading(
            NoticeWire(
                kind: .failed, seconds: 70, tools: 3, text: "boom   happened", prompt: "  fix it "))
        #expect(reading.headline == "Failed")
        #expect(reading.facts == ["1m", "3 tools"])
        #expect(reading.excerpt == "boom happened")
        #expect(reading.retryPrompt == "fix it")
    }

    @Test("A failed turn with a blank or missing prompt has nothing to send again")
    func failedBlankPrompt() {
        #expect(NoticeWords.reading(NoticeWire(kind: .failed, prompt: "   ")).retryPrompt == nil)
        #expect(NoticeWords.reading(NoticeWire(kind: .failed)).retryPrompt == nil)
    }

    @Test("An approval names the tool and the command it would run")
    func approvalReading() {
        let reading = NoticeWords.reading(
            NoticeWire(kind: .approval, text: "rm -rf build/", subject: "Bash"))
        #expect(reading.headline == "Needs approval")
        #expect(reading.facts == ["Bash"])
        #expect(reading.excerpt == "rm -rf build/")
        #expect(reading.passage == "rm -rf build/")
    }

    @Test("An approval with no subject names a tool in the fact")
    func approvalWithoutSubject() {
        let reading = NoticeWords.reading(NoticeWire(kind: .approval, text: "ls"))
        #expect(reading.facts == ["a tool"])
    }

    @Test("A single question with two short options becomes two buttons, with details kept")
    func questionButtons() {
        let asked = [
            NoticeWire.Option(label: "Postgres", detail: "relational"),
            NoticeWire.Option(label: "SQLite"),
        ]
        let reading = NoticeWords.reading(
            NoticeWire(kind: .question, text: "Which database?", options: asked, free: false))
        #expect(reading.headline == "Has a question")
        #expect(reading.choices == ["Postgres", "SQLite"])
        #expect(reading.replyPlaceholder == nil)
        #expect(reading.options == asked)
    }

    @Test("A question that takes a free answer also asks for one in the reply field")
    func freeQuestion() {
        let reading = NoticeWords.reading(
            NoticeWire(
                kind: .question, text: "Which database?",
                options: Self.options(["Postgres", "SQLite"]), free: true))
        #expect(reading.choices == ["Postgres", "SQLite"])
        #expect(reading.replyPlaceholder == "Your answer")
    }

    @Test("A multi-select question gets no buttons")
    func multipleQuestion() {
        let reading = NoticeWords.reading(
            NoticeWire(
                kind: .question, text: "Which database?",
                options: Self.options(["Postgres", "SQLite"]), multiple: true))
        #expect(reading.choices.isEmpty)
    }

    @Test("More than three options keep three buttons and list all five in the detail line")
    func fiveOptions() {
        let labels = ["Postgres", "SQLite", "MySQL", "Redis", "Mongo"]
        let reading = NoticeWords.reading(
            NoticeWire(kind: .question, text: "Which database?", options: Self.options(labels)))
        #expect(reading.choices == ["Postgres", "SQLite", "MySQL"])
        #expect(reading.detail == "Postgres · SQLite · MySQL · Redis · Mongo")
    }

    @Test("An option of 33 characters rules out the buttons")
    func longLabel() {
        let long = String(repeating: "x", count: 33)
        let reading = NoticeWords.reading(
            NoticeWire(
                kind: .question, text: "Which database?", options: Self.options([long, "SQLite"])))
        #expect(reading.choices.isEmpty)
    }

    @Test("Duplicate option labels rule out the buttons")
    func duplicateLabels() {
        let reading = NoticeWords.reading(
            NoticeWire(
                kind: .question, text: "Which database?",
                options: Self.options(["Postgres", "Postgres"])))
        #expect(reading.choices.isEmpty)
    }

    @Test("A question with no options and no free flag offers neither buttons nor a reply")
    func noOptionsNoFlag() {
        let reading = NoticeWords.reading(NoticeWire(kind: .question, text: "Which database?"))
        #expect(reading.choices.isEmpty)
        #expect(reading.replyPlaceholder == nil)
    }

    @Test("A long answer is cut at a word for the banner and again for the long look")
    func passageAndExcerpt() {
        let long = String(String(repeating: "alpha ", count: 134).prefix(800))
        let reading = NoticeWords.reading(NoticeWire(kind: .failed, text: long))
        #expect(reading.excerpt.hasSuffix("…"))
        #expect(reading.excerpt.count <= NoticeWords.excerptLimit + 1)
        #expect(reading.excerpt.dropLast().split(separator: " ").allSatisfy { $0 == "alpha" })
        #expect(reading.passage.hasSuffix("…"))
        #expect(reading.passage.count <= NoticeWords.passageLimit + 1)
        #expect(reading.passage.count > reading.excerpt.count)
        #expect(reading.passage.dropLast().split(separator: " ").allSatisfy { $0 == "alpha" })
    }

    @Test("A short answer has the same passage as excerpt")
    func shortPassageMatchesExcerpt() {
        let reading = NoticeWords.reading(NoticeWire(kind: .failed, text: "Yes."))
        #expect(reading.excerpt == "Yes.")
        #expect(reading.passage == reading.excerpt)
    }

    @Test("Durations read in seconds, minutes and hours, with one decimal under ten hours")
    func durations() {
        #expect(NoticeWords.duration(59) == "59s")
        #expect(NoticeWords.duration(60) == "1m")
        #expect(NoticeWords.duration(222) == "4m")
        #expect(NoticeWords.duration(3600) == "1.0h")
        #expect(NoticeWords.duration(40000) == "11h")
    }

    @Test("Each kind of notice wears the category, symbol and tone of its alert face")
    func presentationMatchesAlertFaces() {
        let faces: [(NoticeWire.Kind, AlertCategory, AlertFace)] = [
            (.done, .turn, .turnEnded),
            (.failed, .turnFailed, .turnFailed),
            (.approval, .approval, .needsApproval),
            (.question, .question, .needsAnswer),
            (.usage, .usage, .usage),
        ]
        #expect(faces.count == NoticeWire.Kind.allCases.count)
        for (kind, category, face) in faces {
            let presentation = NoticePresentation.of(kind)
            #expect(presentation.category == category.rawValue)
            #expect(presentation.symbol == face.symbol)
            #expect(presentation.tone.rawValue == face.tone.rawValue)
        }
    }

    @Test("Approvals and questions interrupt on time, and the rest arrive as active")
    func interruptions() {
        #expect(NoticePresentation.of(.approval).interruption == .timeSensitive)
        #expect(NoticePresentation.of(.question).interruption == .timeSensitive)
        #expect(NoticePresentation.of(.done).interruption == .active)
        #expect(NoticePresentation.of(.failed).interruption == .active)
        #expect(NoticePresentation.of(.usage).interruption == .active)
    }

    @Test("Relevance is strictly highest for approval, then question, failed, done and usage")
    func relevanceOrder() {
        let ranked: [NoticeWire.Kind] = [.approval, .question, .failed, .done, .usage]
        let values = ranked.map { NoticePresentation.of($0).relevance }
        #expect(values.count == NoticeWire.Kind.allCases.count)
        #expect(values == values.sorted(by: >))
        #expect(Set(values).count == values.count)
    }

    @Test("A finished turn reads the same from the conversation and from its wire notice")
    func readerAndWireAgree() {
        let state = Self.state(
            .idle,
            [
                Self.prompt(),
                Self.answer([
                    Self.call("b", "Bash", .completed),
                    Self.call("r", "Read", .completed),
                    Self.text("**Done.** I added a [link](http://x.y) and `code`.\nSecond line"),
                ]),
            ])
        let reading = NoticeReader.turnEnded(in: state)
        #expect(reading.headline == "Finished")
        #expect(reading == NoticeWords.reading(NoticeReader.wire(turnEnded: state)))
    }
}

import CodingAgentKit
import Foundation
import Testing
@testable import TailscodeCore

@Suite("Glance reading")
struct TileGlanceTests {
    private static func message(
        _ id: String, _ role: MessageRole, _ text: String, at seconds: TimeInterval = 0,
        model: String? = nil, effort: String? = nil, done: Bool = true
    ) -> ChatMessage {
        var message = ChatMessage(
            id: id, role: role, agentType: .claudeCode,
            parts: [MessagePart(id: id + "p", kind: .text(text))],
            createdAt: Date(timeIntervalSince1970: seconds),
            completedAt: done ? Date(timeIntervalSince1970: seconds + 1) : nil)
        message.modelID = model
        message.reasoningEffort = effort
        return message
    }

    private static func transcript(_ count: Int) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        messages.reserveCapacity(count)
        for index in 0..<(count - 2) {
            messages.append(
                message("m\(index)", index % 2 == 0 ? .user : .assistant, "older words \(index)",
                    at: Double(index), model: "opus"))
        }
        messages.append(message("q", .user, "fix the pager", at: Double(count)))
        messages.append(
            message("a", .assistant, "Reading the **failing** test, the `pager` clamps the offset.",
                at: Double(count + 1), model: "opus", effort: "high", done: false))
        return messages
    }

    @Test("A running turn reads its activity, tail, model, effort, start and queue")
    func runningTurn() {
        let state = ConversationState(messages: Self.transcript(10), status: .running)
        let reading = GlanceReading(state: state, queued: 2)
        #expect(reading.activity == .writing)
        #expect(reading.session == .running(nil))
        #expect(reading.tail == "Reading the failing test, the pager clamps the offset.")
        #expect(reading.model == "opus")
        #expect(reading.effort == "high")
        #expect(reading.turnStartedAt == Date(timeIntervalSince1970: 10))
        #expect(reading.queued == 2)
        #expect(reading.question == nil)
    }

    @Test("A settled conversation has no activity and no turn clock")
    func settled() {
        let state = ConversationState(messages: Self.transcript(6), status: .idle)
        let reading = GlanceReading(state: state)
        #expect(reading.activity == nil)
        #expect(reading.turnStartedAt == nil)
        #expect(reading.model == "opus")
    }

    @Test("A pending question or permission is the question")
    func question() {
        var state = ConversationState(messages: Self.transcript(4), status: .running)
        state.pendingPermissions = [PermissionRequest(id: "p", sessionID: "s", title: "Run rm -rf build\nsecond line")]
        #expect(GlanceReading(state: state).question == "Run rm -rf build")
        #expect(GlanceReading(state: state).activity == .needsApproval)
        state.pendingQuestions = [
            QuestionRequest(
                id: "q", sessionID: "s",
                questions: [.init(question: "Which branch?", header: "Branch", options: [], multiple: false, custom: true)])
        ]
        #expect(GlanceReading(state: state).question == "Which branch?")
        state.pendingQuestions = []
        state.pendingPermissions = [PermissionRequest(id: "p", sessionID: "s", toolName: "Bash")]
        #expect(GlanceReading(state: state).question == "Bash")
    }

    @Test("Background work is carried through")
    func background() {
        let work = BackgroundWork(tasks: 2)
        let state = ConversationState(messages: Self.transcript(4), status: .idle, backgroundWork: work)
        let reading = GlanceReading(state: state)
        #expect(reading.background == work)
        #expect(reading.session == .background(tasks: 2))
    }

    @Test("Markdown reads as plain words")
    func markdown() {
        let text = """
            # Plan
            > quoted **bold** and _emph_ and ~~gone~~
            - first [link](https://x.y) item
            * second ![alt](a.png)
            ---
            snake_case_name stays, <https://example.com> opens
            """
        #expect(
            GlanceReading.plain(text)
                == "Plan\nquoted bold and emph and gone\n• first link item\n• second alt\n\nsnake_case_name stays, https://example.com opens")
    }

    @Test("A code block is one ⟨code⟩ line, closed or still streaming")
    func codeFence() {
        let closed = "Before\n```swift\nlet a = 1\nlet b = 2\n```\nAfter"
        #expect(GlanceReading.plain(closed) == "Before\n⟨code⟩\nAfter")
        let open = "Writing it now:\n```\nfunc x() {\n"
        #expect(GlanceReading.plain(open) == "Writing it now:\n⟨code⟩")
    }

    @Test("A long message read from inside a fence still says code")
    func windowInsideFence() {
        let code = String(repeating: "let value = compute()\n", count: 400)
        let text = "Intro\n```\n" + code + "```\nDone now"
        #expect(text.utf8.count > GlanceReading.sourceLimit)
        #expect(GlanceReading.plain(text) == "⟨code⟩\nDone now")
    }

    @Test("The tail is the last 600 characters cut at a word, and maxChars asks for less")
    func tailCut() {
        let words = (0..<300).map { "word\($0)" }.joined(separator: " ")
        let state = ConversationState(
            messages: [Self.message("a", .assistant, words)], status: .idle)
        let reading = GlanceReading(state: state)
        #expect(reading.tail.count <= GlanceReading.tailLimit)
        #expect(reading.tail.hasPrefix("…word"))
        #expect(reading.tail.hasSuffix("word299"))
        let short = reading.tail(maxChars: 30)
        #expect(short.count <= 30)
        #expect(short.hasPrefix("…word"))
        #expect(short.hasSuffix("word299"))
        #expect(reading.tail(maxChars: 5000) == reading.tail)
        #expect(GlanceReading.cut("short text", to: 30) == "short text")
        #expect(GlanceReading.cut("anything", to: 0) == "")
    }

    @Test("The tail comes from the newest message that says anything")
    func tailFromRecent() {
        var tool = ChatMessage(id: "t", role: .assistant, agentType: .claudeCode, createdAt: Date())
        tool.parts = []
        let state = ConversationState(
            messages: [Self.message("u", .user, "hello"), Self.message("a", .assistant, "the answer"), tool],
            status: .idle)
        #expect(GlanceReading(state: state).tail == "the answer")
    }

    @Test("Reading is O(tail): 100,000 messages cost what 1,000 do")
    func boundedCost() {
        let small = ConversationState(messages: Self.transcript(1000), status: .running)
        let large = ConversationState(messages: Self.transcript(100_000), status: .running)
        func time(_ state: ConversationState) -> TimeInterval {
            _ = GlanceReading(state: state)
            let start = Date()
            for _ in 0..<50 { _ = GlanceReading(state: state) }
            return Date().timeIntervalSince(start) / 50
        }
        let smallCost = time(small)
        let largeCost = time(large)
        #expect(GlanceReading(state: large).tail == GlanceReading(state: small).tail)
        #expect(largeCost < 0.005)
        #expect(largeCost < max(smallCost * 10, 0.0005))
    }
}

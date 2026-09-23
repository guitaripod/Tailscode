import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("What a turn's Live Activity says")
struct LiveActivityTests {
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
        _ parts: [MessagePart], done: Bool = true, finish: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: "a", role: .assistant, agentType: .claudeCode, parts: parts, createdAt: Date(),
            completedAt: done ? finishedAt : nil, isStreaming: !done, finishReason: finish)
    }

    private static func call(_ id: String, _ name: String, _ status: ToolStatus) -> MessagePart {
        MessagePart(id: id, kind: .tool(ToolCall(id: id, name: name, status: status)))
    }

    private static func text(_ words: String) -> MessagePart {
        MessagePart(id: "text-\(words.count)", kind: .text(words))
    }

    @Test("Every detail's raw value is the wire word claude-bridge stamps, and none is renamed")
    func wireWords() {
        #expect(
            LiveActivityDetail.allCases.map(\.rawValue) == [
                "thinking", "writing", "tool", "compacting", "question", "approval", "finished",
                "answerless", "failed", "noResponse", "sendFailed", "interrupted", "cancelled",
                "lost",
            ])
        let known: Set<String> = ["thinking", "tool", "responding", "approval", "done", "error"]
        for detail in LiveActivityDetail.allCases {
            #expect(known.contains(detail.phase), "\(detail) has a phase no card can decode")
            #expect(!detail.line(tool: "Bash", toolCount: 3, background: 1).isEmpty)
            #expect(!detail.face(tool: "Bash").symbol.isEmpty)
        }
    }

    @Test("A running turn reads down to the tool that is out on the machine")
    func liveTool() {
        let reading = LiveActivityReading.live(
            in: Self.state(
                .running,
                [
                    Self.prompt(),
                    Self.answer(
                        [
                            Self.call("r", "Read", .completed),
                            Self.call("b", "Bash", .running),
                        ], done: false),
                ]))
        #expect(reading.detail == .tool)
        #expect(reading.tool == "Bash")
        #expect(reading.toolCount == 2)
        #expect(reading.line == "Running Bash")
        #expect(reading.face == LiveActivityFace(symbol: "terminal", tone: .live))
        #expect(reading.endedAt == nil)
    }

    @Test("A card taken back mid-turn starts its clock where the turn began")
    func turnStart() {
        let asked = Date(timeIntervalSince1970: 1_000)
        let prompt = ChatMessage(
            id: "u", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "t", kind: .text("go"))], createdAt: asked)
        #expect(LiveActivityReading.live(in: Self.state(.running, [prompt])).startedAt == asked)
        let earlier = ChatMessage(
            id: "a1", role: .assistant, agentType: .claudeCode, createdAt: asked,
            completedAt: asked.addingTimeInterval(60))
        let woke = asked.addingTimeInterval(900)
        let unprompted = ChatMessage(
            id: "a2", role: .assistant, agentType: .claudeCode, createdAt: woke, isStreaming: true)
        let reading = LiveActivityReading.live(
            in: Self.state(.running, [prompt, earlier, unprompted]))
        #expect(reading.startedAt == woke)
    }

    @Test("A turn that has started its answer is writing, and one that has not is thinking")
    func liveWritingAndThinking() {
        let writing = LiveActivityReading.live(
            in: Self.state(.running, [Self.prompt(), Self.answer([Self.text("Here")], done: false)]))
        #expect(writing.detail == .writing)
        #expect(writing.line == "Writing…")
        let thinking = LiveActivityReading.live(in: Self.state(.running, [Self.prompt()]))
        #expect(thinking.detail == .thinking)
        #expect(thinking.face.symbol == ActivityKind.thinking.icon.symbol)
    }

    @Test("A turn stopped for the person says who it is waiting on, and outranks every other card")
    func liveWaitingOnYou() {
        var asking = Self.state(.running, [Self.prompt()])
        asking.pendingPermissions = [PermissionRequest(id: "p", sessionID: "s", toolName: "Bash")]
        let approval = LiveActivityReading.live(in: asking)
        #expect(approval.detail == .approval)
        #expect(approval.detail.wantsYou)
        #expect(approval.face.tone == .attention)
        for detail in LiveActivityDetail.allCases where !detail.wantsYou {
            #expect(approval.detail.relevance > detail.relevance)
        }
    }

    @Test("Tools are counted from the last thing the person said, not across the conversation")
    func toolsCountThisTurnOnly() {
        let reading = LiveActivityReading.settled(
            from: Self.state(
                .idle,
                [
                    Self.prompt("u1"),
                    Self.answer([Self.call("old", "Edit", .completed)]),
                    Self.prompt("u2"),
                    Self.answer([
                        Self.call("a", "Grep", .completed), Self.call("b", "Edit", .completed),
                        Self.text("Done."),
                    ]),
                ]))
        #expect(reading.detail == .finished)
        #expect(reading.toolCount == 2)
        #expect(reading.endedAt == Self.finishedAt)
        #expect(reading.line == "Done · 2 tools")
        #expect(reading.face == LiveActivityFace(symbol: AlertFace.turnEnded.symbol, tone: .live))
    }

    @Test("A finished turn with nothing to count says only that it is done")
    func bareFinish() {
        let reading = LiveActivityReading.settled(
            from: Self.state(.idle, [Self.prompt(), Self.answer([Self.text("Yes.")])]))
        #expect(reading.line == "Done")
    }

    @Test("Work the machine is still carrying is part of how a turn ended")
    func backgroundIsCounted() {
        var carrying = Self.state(
            .idle,
            [
                Self.prompt(),
                Self.answer([Self.call("a", "Bash", .completed), Self.call("b", "Bash", .completed)]),
            ])
        carrying.backgroundWork = BackgroundWork(tasks: 2)
        let reading = LiveActivityReading.settled(from: carrying)
        #expect(reading.detail == .finished)
        #expect(reading.background == 2)
        #expect(reading.line == "Done · 2 tools · 2 tasks still running")
    }

    @Test("A turn that ended by asking is remembered as the question, not as done")
    func endedWithAQuestion() {
        var asking = Self.state(
            .idle, [Self.prompt(), Self.answer([Self.call("q", "AskUserQuestion", .running)])])
        asking.pendingQuestions = [QuestionRequest(id: "q", sessionID: "s", questions: [])]
        let reading = LiveActivityReading.settled(from: asking)
        #expect(reading.detail == .question)
        #expect(reading.line == "Waiting for your answer")
        #expect(reading.face.tone == .attention)
        #expect(reading.detail.phase == "approval")
    }

    @Test("A failure, a cut-off and an empty answer each read as what they were")
    func endingsThatAreNotDone() {
        var failing = Self.state(.idle, [Self.prompt(), Self.answer([Self.text("partial")])])
        failing.lastFailure = BackendFailure(message: "overloaded")
        #expect(LiveActivityReading.settled(from: failing).detail == .failed)
        #expect(LiveActivityReading.settled(from: failing).face.tone == .danger)

        var cut = Self.state(.idle, [Self.prompt()])
        cut.interruption = TurnInterruption(
            turnID: "t", prompt: "fix it", startedAt: Self.finishedAt, detectedAt: Self.finishedAt,
            progress: TurnInterruption.Progress(), queued: [], resumedAt: nil)
        let interrupted = LiveActivityReading.settled(from: cut)
        #expect(interrupted.detail == .interrupted)
        #expect(interrupted.face.symbol == InterruptedTurn.symbol)
        #expect(interrupted.detail.phase == "error")

        let empty = LiveActivityReading.settled(
            from: Self.state(
                .idle,
                [
                    Self.prompt(),
                    Self.answer(
                        [MessagePart(id: "s", kind: .unknown(type: "step-start"))], finish: "stop"),
                ]))
        #expect(empty.detail == .answerless)
        #expect(empty.line == "Nothing came back")
    }

    @Test("What went wrong outranks what finished, and a live turn outranks both")
    func relevanceOrder() {
        #expect(LiveActivityDetail.thinking.relevance > LiveActivityDetail.failed.relevance)
        #expect(LiveActivityDetail.failed.relevance > LiveActivityDetail.finished.relevance)
        #expect(LiveActivityDetail.question.relevance == LiveActivityDetail.approval.relevance)
    }

    @Test("Outcomes this device decided on its own wear their own words and faces")
    func localOutcomes() {
        #expect(LiveActivityDetail.cancelled.face(tool: nil) == LiveActivityFace(ActivityIcon.stopped))
        #expect(LiveActivityDetail.cancelled.phase == "done")
        #expect(LiveActivityDetail.noResponse.line(tool: nil) == "No response")
        #expect(LiveActivityDetail.sendFailed.line(tool: nil) == "Couldn't send")
        #expect(LiveActivityDetail.sendFailed.face(tool: nil).tone == .danger)
        #expect(LiveActivityDetail.lost.face(tool: nil).tone == .quiet)
        #expect(LiveActivityDetail.tool.line(tool: nil) == "Running tool")
        #expect(LiveActivityDetail.tool.face(tool: "mcp__zg__search").symbol == "magnifyingglass")
    }

    @Test("A settled card leaves the island after an hour and the Lock Screen after four")
    func linger() {
        let settled = Self.finishedAt
        #expect(LiveActivityLinger.islandEnds(settledAt: settled) == settled.addingTimeInterval(3600))
        #expect(
            LiveActivityLinger.lockScreenEnds(settledAt: settled)
                == settled.addingTimeInterval(4 * 3600))
        #expect(LiveActivityLinger.island < LiveActivityLinger.lockScreen)
    }
}

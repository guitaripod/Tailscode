import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

private let epoch = Date(timeIntervalSince1970: 1_000_000)

@Suite struct TranscriptNoteReadingTests {
    @Test("A model change names both models the way the person picked them")
    func modelChangeNamesBoth() {
        let line = TranscriptNoteReading.read(
            TranscriptNote(
                .model(
                    ModelSelection(providerID: "kimi-code", modelID: "k3"), effort: "high",
                    previous: ModelSelection(providerID: "llama-server", modelID: "qwen38"))),
            modelName: { $0.modelID == "k3" ? "Kimi K3" : nil })
        #expect(line.text == "Switched from qwen38 to Kimi K3 at high effort")
        #expect(line.tone == .quiet)
        #expect(line.spoken == "Note: Switched from qwen38 to Kimi K3 at high effort")
    }

    @Test("Every note has words and a face, and a failure wears attention")
    func everyNoteReads() {
        let subjects: [TranscriptNote.Subject] = [
            .agent("plan", previous: "build"), .agent("plan", previous: nil),
            .resumedAfterRestart,
            .workFinished("cargo test", work: .command, outcome: .completed),
            .workFinished("cargo test", work: .command, outcome: .failed),
            .workFinished("Audit the parser", work: .agent, outcome: .cancelled),
            .instructions("Loaded src/AGENTS.md"), .moved("/work/other"), .skill("review"),
            .remark("Something the server said"),
        ]
        for subject in subjects {
            let line = TranscriptNoteReading.read(TranscriptNote(subject))
            #expect(!line.text.isEmpty)
            #expect(!line.symbol.isEmpty)
            #expect(!line.glyph.isEmpty)
        }
        #expect(
            TranscriptNoteReading.read(TranscriptNote(.agent("plan", previous: "build"))).text
                == "Switched from the build agent to plan")
        #expect(
            TranscriptNoteReading.read(
                TranscriptNote(.workFinished("cargo test", work: .command, outcome: .failed))
            ).tone == .attention)
        #expect(
            TranscriptNoteReading.read(TranscriptNote(.instructions("Loaded src/AGENTS.md"))).text
                == "Loaded src/AGENTS.md")
    }

    @Test("A note message is found by its part")
    func noteIsFound() {
        let message = ChatMessage(
            id: "n", role: .system, agentType: .openCode,
            parts: [MessagePart(id: "n/note", kind: .note(TranscriptNote(.resumedAfterRestart)))],
            createdAt: epoch)
        #expect(TranscriptNoteReading.note(in: message)?.subject == .resumedAfterRestart)
        #expect(
            TranscriptNoteReading.note(
                in: ChatMessage(id: "u", role: .user, agentType: .openCode, createdAt: epoch))
                == nil)
    }
}

@Suite struct ProviderRetryReadingTests {
    private let wait = TurnRetry(
        attempt: 3, reason: "Rate limit reached for requests",
        nextAttemptAt: epoch.addingTimeInterval(75),
        remedy: TurnRetry.Remedy(
            title: "Usage limit", message: "You have used this plan's limit", label: "Upgrade",
            link: "https://example.com/upgrade"))

    @Test("The card leads with the provider's reason, the attempt and the countdown")
    func cardReads() throws {
        let card = try #require(ProviderRetryReading.read(wait, now: epoch))
        #expect(card.title == "Waiting on the provider")
        #expect(card.reason == "Rate limit reached for requests")
        #expect(card.attemptLine == "Attempt 3 failed, trying again in 1 min 15 s")
        #expect(card.remedy?.label == "Upgrade")
        #expect(card.remedy?.link == URL(string: "https://example.com/upgrade"))
        #expect(ProviderRetryReading.read(nil) == nil)
    }

    @Test("The countdown says now once the attempt is due, and has no clock without a time")
    func countdownEnds() {
        #expect(
            ProviderRetryReading.read(wait, now: epoch.addingTimeInterval(80))?.attemptLine
                == "Attempt 3 failed, trying again now")
        let unscheduled = TurnRetry(attempt: 1, reason: "")
        #expect(
            ProviderRetryReading.read(unscheduled)?.attemptLine
                == "Attempt 1 failed, the server will try again")
        #expect(
            ProviderRetryReading.read(unscheduled)?.reason
                == "The provider did not answer the last attempt.")
        #expect(ProviderRetryReading.nextChange(unscheduled) == nil)
    }

    @Test("The clock wakes exactly when the whole-second countdown changes")
    func nextChangeLandsOnTheSecond() throws {
        let now = epoch.addingTimeInterval(0.3)
        let change = try #require(ProviderRetryReading.nextChange(wait, now: now))
        #expect(abs(change.timeIntervalSince(epoch) - 1) < 0.000_1)
        #expect(
            ProviderRetryReading.read(wait, now: now)?.attemptLine
                != ProviderRetryReading.read(wait, now: change)?.attemptLine)
        #expect(ProviderRetryReading.nextChange(wait, now: epoch.addingTimeInterval(90)) == nil)
    }

    @Test("A wait is the turn's activity, ahead of any tool, and it turns rather than breathes")
    func waitIsTheActivity() {
        let running = ChatMessage(
            id: "a", role: .assistant, agentType: .openCode,
            parts: [
                MessagePart(
                    id: "t",
                    kind: .tool(ToolCall(id: "c", name: "bash", status: .running)))
            ], createdAt: epoch)
        let state = ConversationState(messages: [running], status: .running, retry: wait)
        #expect(ActivityKind.inFlight(in: state) == .retrying(attempt: 3))
        #expect(ActivityKind.retrying(attempt: 3).icon.motion == .turning)
        #expect(ActivityKind.retrying(attempt: 3).isInFlight)
        #expect(ActivityKind.everyState.contains(.retrying(attempt: 2)))
    }
}

@Suite struct RevertReadingTests {
    private func prompt(_ id: String, _ text: String) -> ChatMessage {
        ChatMessage(
            id: id, role: .user, agentType: .openCode,
            parts: [MessagePart(id: "\(id)/text", kind: .text(text))], createdAt: epoch)
    }

    private func answer(_ id: String) -> ChatMessage {
        ChatMessage(
            id: id, role: .assistant, agentType: .openCode,
            parts: [MessagePart(id: "\(id)/text", kind: .text("done"))], createdAt: epoch)
    }

    @Test("The banner counts what was set aside and says what happened to each file")
    func bannerReads() throws {
        let revert = SessionRevert(
            messageID: "u2",
            files: [
                SessionRevert.File(path: "hello.txt", change: .deleted, deletions: 1),
                SessionRevert.File(path: "src/a.swift", change: .modified, additions: 3, deletions: 2),
                SessionRevert.File(path: "gone.txt", change: .added),
            ])
        let banner = try #require(
            RevertReading.read(
                revert, setAside: [prompt("u2", "second"), answer("a2"), prompt("u3", "third")]))
        #expect(banner.title == "Wound back 2 messages")
        #expect(banner.files.map(\.change) == ["removed", "put back", "brought back"])
        #expect(banner.files.map(\.counts) == ["−1", "+3 −2", nil])
        #expect(banner.restoreTitle == "Restore")
        #expect(RevertReading.read(nil, setAside: []) == nil)
        let single = RevertReading.read(
            SessionRevert(messageID: "u3"), setAside: [prompt("u3", "third")])
        #expect(single?.title == "Wound back one message")
        #expect(single?.files.isEmpty == true)
    }

    @Test("A long list of files is cut where a surface runs out of room, never one short of it")
    func longListsAreCut() throws {
        func banner(_ count: Int) throws -> RevertBanner {
            try #require(
                RevertReading.read(
                    SessionRevert(
                        messageID: "u",
                        files: (0..<count).map {
                            SessionRevert.File(path: "f\($0)", change: .modified, additions: 1)
                        }),
                    setAside: [prompt("u", "x")]))
        }
        let seven = try banner(7).files(upTo: 6)
        #expect(seven.shown.count == 7)
        #expect(seven.more == nil)
        let nine = try banner(9).files(upTo: 6)
        #expect(nine.shown.map(\.path) == ["f0", "f1", "f2", "f3", "f4", "f5"])
        #expect(nine.more == "3 more files")
    }

    @Test("The words wound back to come back for the composer")
    func promptComesBack() {
        #expect(RevertReading.prompt(in: [prompt("u2", "say it again"), answer("a2")]) == "say it again")
        #expect(RevertReading.prompt(in: [answer("a2")]) == nil)
        #expect(RevertReading.prompt(in: []) == nil)
    }

    @Test("The confirmation names the stop, the one part of a press Restore cannot give back")
    func confirmationNamesTheStop() {
        let stopping = RevertReading.confirmMessage(stopping: true)
        #expect(stopping.hasPrefix("The turn that is running stops."))
        #expect(stopping != RevertReading.confirmMessage(stopping: false))
    }

    @Test("The demo world winds back and shows the lines a server writes")
    func demoCoversIt() async throws {
        #expect(DemoWorld.openCode.capabilities.supportsRevert)
        let transcript = try await DemoWorld.openCode.messages(for: "demo-o1")
        let lines = transcript.compactMap(TranscriptNoteReading.note(in:)).map {
            TranscriptNoteReading.read(
                $0, modelName: { $0.modelID == "gpt-5.1-codex" ? "GPT-5.1 Codex" : nil }
            ).text
        }
        #expect(
            lines == [
                "Background command finished: go test ./internal/auth/...",
                "Switched from claude-sonnet-5 to GPT-5.1 Codex at high effort",
            ])
        let revert = try await DemoWorld.openCode.revert(sessionID: "demo-o1", to: "o1u1")
        #expect(RevertReading.read(revert, setAside: [])?.files.count == 2)
        try await DemoWorld.openCode.restoreRevert(sessionID: "demo-o1")
    }

    @Test("Only your own messages offer it, and only where the server can")
    func offeredOnlyWherePossible() {
        let can = BackendCapabilities(
            supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
            supportsMultipleSessions: true, supportsModelSelection: false,
            supportsAttachments: false, supportsRevert: true)
        let cannot = BackendCapabilities(
            supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
            supportsMultipleSessions: true, supportsModelSelection: false,
            supportsAttachments: false)
        #expect(RevertReading.offersUndo(on: prompt("u", "x"), capabilities: can))
        #expect(!RevertReading.offersUndo(on: answer("a"), capabilities: can))
        #expect(!RevertReading.offersUndo(on: prompt("u", "x"), capabilities: cannot))
    }
}

@Suite struct HoldingInterruptionTests {
    @Test("Only a server that holds unattended work names the price of waiting")
    func priceOnlyWhereItIsPaid() throws {
        let held = TurnInterruption(
            turnID: "t", prompt: "go", startedAt: epoch, detectedAt: epoch.addingTimeInterval(60))
        let free = TurnInterruption(
            turnID: "t", prompt: "go", startedAt: epoch, detectedAt: epoch.addingTimeInterval(60),
            holdsUnattendedWork: false)
        #expect(try #require(InterruptedTurnReading.read(held)).cost != nil)
        #expect(try #require(InterruptedTurnReading.read(free)).cost == nil)
    }
}

@Suite struct StepSpendTests {
    @Test("A turn answered in several steps is one turn with every tier it reported")
    func stepsAreOneTurn() throws {
        func step(_ id: String, cost: Double, output: Int, cacheRead: Int, at seconds: Double)
            -> ChatMessage
        {
            ChatMessage(
                id: id, role: .assistant, agentType: .openCode, createdAt: epoch,
                completedAt: epoch.addingTimeInterval(seconds), costUSD: cost,
                modelID: "glm-5.3-flash",
                usage: MessageUsage(input: 100, output: output, reasoning: 5, cacheRead: cacheRead))
        }
        let messages = [
            ChatMessage(
                id: "u1", role: .user, agentType: .openCode,
                parts: [MessagePart(id: "t", kind: .text("refactor it"))], createdAt: epoch),
            step("a1", cost: 0.01, output: 20, cacheRead: 1000, at: 5),
            step("a2", cost: 0.02, output: 30, cacheRead: 2000, at: 9),
            ChatMessage(
                id: "u2", role: .user, agentType: .openCode,
                parts: [MessagePart(id: "t", kind: .text("again"))], createdAt: epoch),
            step("a3", cost: 0.04, output: 10, cacheRead: 0, at: 20),
        ]
        let spend = try #require(SessionSpend(messages: messages))
        #expect(spend.turnCount == 2)
        #expect(spend.turns.first?.prompt == "refactor it")
        #expect(abs((spend.turns.first?.costUSD ?? 0) - 0.03) < 0.000_1)
        #expect(spend.turns.first?.seconds == 9)
        #expect(spend.tiers.contains { $0.id == "cacheRead" && $0.tokens == 3000 })
        #expect(spend.models.first?.turns == 2)
    }
}

import AgentTestSupport
import CodingAgentKit
import Foundation
import Testing
@testable import TailscodeCore

@Suite("Soak world", .serialized)
struct SoakWorldTests {
    @Test("the spec string reads panes, rate, rows and an optional turn length")
    func parsesTheSpec() {
        let spec = SoakWorld.Configuration(parsing: "5:80:600")
        #expect(spec?.panes == 5)
        #expect(spec?.tokensPerSecond == 80)
        #expect(spec?.rows == 600)
        #expect(spec?.turnSeconds == 240)
        #expect(SoakWorld.Configuration(parsing: "3:200:10:30")?.turnSeconds == 30)
        #expect(spec?.paragraphCharacters == 0)
        #expect(SoakWorld.Configuration(parsing: "1:80:200:30:8000")?.paragraphCharacters == 8000)
        #expect(SoakWorld.Configuration(parsing: "1:80:200:30:x") == nil)
        #expect(SoakWorld.Configuration(parsing: "0:80:600") == nil)
        #expect(SoakWorld.Configuration(parsing: "5:x:600") == nil)
        #expect(SoakWorld.Configuration(parsing: "5:80") == nil)
    }

    @Test("every soak session serves a transcript of exactly K messages")
    func transcriptLength() async throws {
        let backend = SoakWorld.backend(.init(panes: 3, tokensPerSecond: 80, rows: 600))
        for index in 1...3 {
            let messages = try await backend.messages(for: SoakWorld.sessionID(index))
            #expect(messages.count == 600)
            #expect(messages.contains { $0.role == .user })
            #expect(messages.contains { message in
                message.parts.contains { if case .tool = $0.kind { true } else { false } }
            })
            #expect(messages.contains { message in
                message.parts.contains {
                    if case .text(let text) = $0.kind { text.contains("```swift") } else { false }
                }
            })
        }
        let listed = try await backend.listSessions()
        #expect(listed.count == 200)
        #expect(listed.prefix(3).map(\.id) == ["soak-1", "soak-2", "soak-3"])
    }

    @Test("a reply streams roughly R tiny deltas a second for the turn's length")
    func replyRate() {
        for rate in [40.0, 80, 200] {
            let configuration = SoakWorld.Configuration(
                panes: 1, tokensPerSecond: rate, rows: 0, turnSeconds: 60)
            let steps = SoakWorld.replyTurn(configuration)
            var deltas = 0
            var longest = 0
            var seconds = 0.0
            for step in steps {
                let components = step.delay.components
                seconds += Double(components.seconds) + Double(components.attoseconds) / 1e18
                if case .partTextDelta(_, _, let delta) = step.event {
                    deltas += 1
                    longest = max(longest, delta.count)
                }
            }
            #expect(deltas == configuration.turnTokens)
            #expect(longest <= 6)
            let perSecond = Double(deltas) / seconds
            #expect(perSecond > rate * 0.85 && perSecond <= rate * 1.01, "rate \(rate): \(perSecond)")
        }
    }

    @Test("a paragraph length makes each text segment one unbroken paragraph of that length")
    func longParagraphReply() {
        let configuration = SoakWorld.Configuration(
            panes: 1, tokensPerSecond: 80, rows: 0, turnSeconds: 30, paragraphCharacters: 2000)
        var segments: [String: String] = [:]
        for step in SoakWorld.replyTurn(configuration) {
            if case .partTextDelta(_, let part, let delta) = step.event {
                segments[part ?? "", default: ""] += delta
            }
        }
        let first = segments["t0"] ?? ""
        #expect(first.count == 2000)
        #expect(!first.contains("\n"))
    }

    @Test("a send on the installed server streams the reply live at about R events a second")
    func liveStream() async throws {
        let backend = SoakWorld.install(
            .init(panes: 1, tokensPerSecond: 200, rows: 4, turnSeconds: 1))
        #expect(SoakWorld.backend(for: SoakWorld.profile.id) === backend)
        let events = backend.events(for: SoakWorld.sessionID(1))
        let started = ContinuousClock.now
        let counter = Task {
            var deltas = 0
            var replayed = 0
            for try await event in events {
                switch event {
                case .messageUpserted where deltas == 0: replayed += 1
                case .partTextDelta: deltas += 1
                case .status(.idle) where deltas > 0: return (replayed, deltas)
                default: break
                }
            }
            return (replayed, deltas)
        }
        try await Task.sleep(for: .milliseconds(100))
        try await backend.send(SendPrompt(text: "go"), to: SoakWorld.sessionID(1))
        let (replayed, deltas) = try await counter.value
        let elapsed = ContinuousClock.now - started
        #expect(replayed >= 4)
        #expect(deltas == 200)
        #expect(elapsed >= .milliseconds(900))
        #expect(elapsed < .seconds(5))
    }

    @Test("only the soak server pushes list changes, one per live session a second")
    func listPushes() async throws {
        let backend = SoakWorld.install(
            .init(panes: 2, tokensPerSecond: 50, rows: 0, turnSeconds: 2, listedSessions: 10))
        #expect(await DemoWorld.claude.sessionListChanges() == nil)
        let changes = try #require(await backend.sessionListChanges())
        try await backend.send(SendPrompt(text: "go"), to: SoakWorld.sessionID(1))
        var upserted: [String] = []
        for await change in changes {
            if case .upsert(let session) = change { upserted.append(session.id) }
            if upserted.count == 4 { break }
        }
        #expect(Set(upserted) == ["soak-1", "soak-2"])
    }
}

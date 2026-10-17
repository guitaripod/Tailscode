import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// The range demo is a debugging aid behind `TAILSCODE_DEMO_RANGE`: the default demo world, which
/// the screenshot scripts depend on, must not know it exists, and with it on the conversation has
/// to hold everything the Range sheet draws.
@Suite("Range demo")
struct RangeDemoTests {
    private var messages: [ChatMessage] {
        DemoWorld.rangeScript.compactMap { step in
            if case .messageUpserted(let message, _) = step.event { return message }
            return nil
        }
    }

    @Test("The session is listed only when the variable is set")
    func gated() async throws {
        let listed = try await DemoWorld.claude.listSessions().map(\.id)
        #expect(listed.contains(DemoWorld.rangeSessionID) == DemoWorld.rangeDemoEnabled)
        let unchanged = ["demo-c1", "demo-c3", "demo-c2", "demo-c5", "demo-c6", "demo-c4"]
        #expect(listed.filter { $0 != DemoWorld.rangeSessionID } == unchanged)
    }

    @Test("The transcript has seven growing turns and a warm cache")
    func transcript() {
        let messages = messages
        #expect(messages.filter { $0.role == .user }.count == 7)
        let footprints = messages.compactMap { $0.context?.read }
        #expect(footprints == [96_000, 104_000, 112_000, 119_000, 126_000, 135_000, 148_000])
        #expect(messages.allSatisfy { $0.role == .user || $0.duration != nil })
    }

    @Test("The range reads a burn, a composition and a warm cache from it")
    func readings() throws {
        let messages = messages
        let fill = try #require(ContextFill.read(messages: messages, sessionModel: "claude-haiku-4-5"))
        #expect(fill.window == 200_000)
        #expect((fill.fraction ?? 0) > 0.7)
        let burn = try #require(ContextBurn.read(messages: messages, fill: fill))
        #expect(burn.turnsLeft != nil)
        #expect(ContextComposition.read(messages: messages, fill: fill) != nil)
        let cache = try #require(CacheWarmth.read(messages: messages, isRunning: false))
        #expect(cache.remaining != nil)
    }
}

import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Which agents are out now")
struct SubagentPresenceTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func agent(
        _ id: String, active: Bool, completed: Bool = false, ago: TimeInterval = 10
    ) -> SubagentSummary {
        SubagentSummary(
            id: id, title: id, updatedAt: now.addingTimeInterval(-ago), isActive: active,
            isCompleted: completed)
    }

    @Test("Under work that is over, no agent is out, whatever its record claims")
    func anEndedTurnLeavesNoneLive() {
        let presence = SubagentPresence(
            agents: [Self.agent("a", active: true), Self.agent("b", active: true)],
            hold: .over(at: nil))
        #expect(presence.liveCount == 0)
        #expect(presence.settledCount == 2)
        #expect(presence.dockable(among: presence.agents).isEmpty)
    }

    @Test("Under an open turn only an active agent that has not reported is out")
    func anOpenTurnCountsTheMoving() {
        let presence = SubagentPresence(
            agents: [
                Self.agent("moving", active: true),
                Self.agent("done", active: false, completed: true),
                Self.agent("reported", active: true, completed: true),
                Self.agent("quiet", active: false),
            ], hold: .going)
        #expect(presence.live.map(\.id) == ["moving"])
        #expect(presence.settledCount == 3)
        #expect(presence.finishedCount == 2)
    }

    @Test("Only a live agent may dock after the last message")
    func onlyLiveAgentsDock() {
        let presence = SubagentPresence(
            agents: [Self.agent("moving", active: true), Self.agent("old", active: false, completed: true)],
            hold: .going)
        #expect(presence.dockable(among: presence.agents).map(\.id) == ["moving"])
    }

    @Test("A band speaks of the agents that worked for the answer on screen, not earlier fan-outs")
    func theBandForgetsEarlierTurns() {
        let prompt = Self.now.addingTimeInterval(-100)
        let agents = [
            Self.agent("this-turn", active: false, completed: true, ago: 50),
            Self.agent("an-hour-ago", active: false, completed: true, ago: 3_600),
        ]
        let presence = SubagentPresence(agents: agents, hold: .over(at: nil), since: prompt)
        #expect(presence.current.map(\.id) == ["this-turn"])
        #expect(SubagentPresence(agents: agents, hold: .over(at: nil)).current.isEmpty)
    }

    @Test("Lists put what is happening first, then what happened, newest first")
    func listsLeadWithTheLive() {
        let presence = SubagentPresence(
            agents: [
                Self.agent("older-done", active: false, completed: true, ago: 500),
                Self.agent("newer-done", active: false, completed: true, ago: 5),
                Self.agent("live", active: true),
            ], hold: .going)
        #expect(presence.ordered.map(\.id) == ["live", "newer-done", "older-done"])
    }

    @Test("An idle band shows nothing for a session whose agents are all old")
    func anIdleBandIsQuietForOldAgents() {
        var facts = StatusFacts()
        facts.agents = [Self.agent("old", active: true, ago: 7_200)]
        facts.lastPromptAt = Self.now
        #expect(!facts.segments.contains { $0.id == "agents" })
        facts.agents = [Self.agent("fresh", active: false, completed: true, ago: -5)]
        #expect(facts.segments.contains { $0.id == "agents" })
    }
}

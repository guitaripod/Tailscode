import CodingAgentKit
import Foundation

/// Which of a session's subagents are out *now*, and the one rule that follows from it: only an
/// agent that is out may ask for room at the end of a conversation.
///
/// A server lists every agent the session ever started, and its record of each goes on claiming it
/// is active for as long as its window lasts — ninety seconds after its last write, half an hour
/// for a fan-out. Read at face value that put a wall of finished agents under every long
/// conversation, and a `▸ 12✓` on every idle one. The work that holds an agent is the witness
/// that settles it (`AgentHold`): an agent cannot be out inside a turn that is over, so under work
/// that has ended every agent is history, and history belongs at the call that spawned it — never
/// in the way of the composer.
public struct SubagentPresence: Sendable, Equatable {
    public let agents: [SubagentSummary]
    public let hold: AgentHold
    /// When the prompt the reader is looking at was sent. What an agent did after it belongs to
    /// the answer on screen; what it did before belongs to a turn that is history.
    public let since: Date?

    public init(agents: [SubagentSummary], hold: AgentHold, since: Date? = nil) {
        self.agents = agents
        self.hold = hold
        self.since = since
    }

    /// Out on the machine right now: the work that holds it is open, the record says it is
    /// moving, and it has not reported finishing.
    public func isLive(_ agent: SubagentSummary) -> Bool {
        guard case .going = hold else { return false }
        return agent.isActive && !agent.isCompleted
    }

    public var live: [SubagentSummary] { agents.filter(isLive) }

    /// Everything that is not out: finished, idle, or claimed active by a record the turn has
    /// outlived.
    public var settled: [SubagentSummary] { agents.filter { !isLive($0) } }

    public var liveCount: Int { agents.count(where: isLive) }

    public var settledCount: Int { agents.count - liveCount }

    public var finishedCount: Int { settled.count(where: \.isCompleted) }

    public var hasLive: Bool { liveCount > 0 }

    /// The agents a band may speak of: the ones out now, and the ones that worked for the turn on
    /// screen. A fan-out from an hour ago is in the transcript at its call and in the list, and
    /// says nothing under the composer, where a count of finished agents is read as work still
    /// happening.
    public var current: [SubagentSummary] {
        guard let since else { return live }
        return agents.filter { isLive($0) || $0.updatedAt >= since }
    }

    /// The agents no spawning call claimed that may be drawn after the last message. A finished
    /// one that cannot be matched to a call in the loaded part of the transcript is not news, so
    /// it waits behind the list (`StatusFacts` menu, the overflow menu) instead of docking.
    public func dockable(among unattached: [SubagentSummary]) -> [SubagentSummary] {
        unattached.filter(isLive)
    }

    /// Live agents first, newest first within each side, so a list reads what is happening and
    /// then what happened.
    public var ordered: [SubagentSummary] {
        agents.sorted { lhs, rhs in
            let left = isLive(lhs)
            if left != isLive(rhs) { return left }
            if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
            return lhs.updatedAt > rhs.updatedAt
        }
    }
}

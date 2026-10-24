import Foundation

/// Which sessions the board spends a connection on.
///
/// The list feed says little about a session nobody opened — running or not, how many agents,
/// background work — so the board watches the ones that are running, which costs a subscription
/// each. That is why it is capped: a person with nine agents going sees six of them in full and
/// the rest as listed, said plainly, rather than nine half-known rows.
public enum AgentWatch {
    public static let cap = 6

    public struct Candidate: Sendable, Equatable {
        public let key: String
        public let isRunning: Bool
        /// A session already known to be waiting on the person, from a notification or a watch
        /// that heard it: the one thing that must never be left unwatched.
        public let waiting: Bool
        public let updatedAt: Date
        public let held: Bool
        /// A session the person asked to watch from the board's "listed" row: it takes a slot from
        /// the least recent held one.
        public let pinned: Bool
        /// A watched session that has just stopped is kept a few seconds more, to hear how it
        /// ended.
        public let lingering: Bool

        public init(
            key: String, isRunning: Bool, waiting: Bool = false, updatedAt: Date, held: Bool = false,
            pinned: Bool = false, lingering: Bool = false
        ) {
            self.key = key
            self.isRunning = isRunning
            self.waiting = waiting
            self.updatedAt = updatedAt
            self.held = held
            self.pinned = pinned
            self.lingering = lingering
        }
    }

    public struct Plan: Sendable, Equatable {
        public let attach: [String]
        public let release: [String]
        /// Running sessions the cap leaves unwatched.
        public let listedOnly: [String]
    }

    public static func plan(candidates: [Candidate], cap: Int = AgentWatch.cap) -> Plan {
        let wanted = candidates.filter { $0.isRunning || $0.waiting || ($0.held && $0.lingering) }
        let ranked = wanted.sorted { lhs, rhs in
            if lhs.waiting != rhs.waiting { return lhs.waiting }
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            if lhs.held != rhs.held { return lhs.held }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.key < rhs.key
        }
        let chosen = Set(ranked.prefix(cap).map(\.key))
        let held = Set(candidates.filter(\.held).map(\.key))
        return Plan(
            attach: ranked.filter { chosen.contains($0.key) && !held.contains($0.key) }.map(\.key),
            release: candidates.filter { $0.held && !chosen.contains($0.key) }.map(\.key),
            listedOnly: ranked.filter { !chosen.contains($0.key) }.map(\.key))
    }
}

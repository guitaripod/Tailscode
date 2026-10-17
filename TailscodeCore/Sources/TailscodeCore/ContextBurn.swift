import CodingAgentKit
import Foundation

/// How fast a conversation is filling its context window, and so how many more turns fit.
///
/// A window's share says how full it is; what a person plans a conversation around is how long it
/// lasts. The footprint after each turn — what the model was handed on its last request
/// (`ChatMessage.context`) — is a record of exactly that, and the difference between two turns is
/// what the later one added. Carried forward at the recent pace it says how many more fit: *about*
/// that many, because a turn that reads a large file adds more than ten that talk, and the biggest
/// single turn is named alongside so the estimate is never mistaken for a promise.
///
/// A compaction is a refill, not a drop in the curve: the count restarts at the seam (or at any
/// footprint that falls to under 70% of the turn before it, which is a summary however it was
/// made), and nothing before it is carried into the rate.
public struct ContextBurn: Sendable, Equatable {
    public struct Turn: Sendable, Equatable {
        public let messageID: String
        public let footprint: Int
        /// This turn follows a compaction (or an equivalent fall): the footprints before it are
        /// another life of the window.
        public let startsEpoch: Bool
    }

    public struct Addition: Sendable, Equatable {
        public let tokens: Int
        public let messageID: String
    }

    /// Every turn with a footprint, oldest first. Bounded to the recent past unless the whole
    /// conversation was asked for.
    public let turns: [Turn]
    /// Turns since the window was last refilled, which a rate may be read from.
    public let epochTurns: Int
    /// What a turn adds on average over the last few, nil while it is not growing.
    public let growth: Int?
    public let remaining: Int?
    public let turnsLeft: Int?
    /// The single turn of this life of the window that added the most, where the whole
    /// conversation was read.
    public let biggest: Addition?

    public static let recentTurns = 5
    /// Three growths are the least a rate is read from.
    public static let minTurns = 4
    public static let minFill = 0.5
    /// Beyond this many turns there is nothing to say, so nothing is said.
    public static let newsworthyTurns = 20
    public static let urgentTurns = 4
    /// A footprint that falls below this share of the turn before it is a refill.
    public static let refillBelow = 0.7
    /// A turn must add at least this much, and this share of what is left, to be named.
    public static let notableAddition = 10_000
    public static let notableShare = 0.25

    public var isNews: Bool { turnsLeft.map { $0 <= Self.newsworthyTurns } ?? false }

    public var tone: ContextFill.Tone {
        guard let turnsLeft else { return .quiet }
        if turnsLeft <= Self.urgentTurns { return .danger }
        return turnsLeft <= Self.newsworthyTurns ? .attention : .quiet
    }

    /// The biggest turn as a share of what is left, when it is big enough to name.
    public var notableAddition: (addition: Addition, share: Double)? {
        guard let biggest, let remaining, remaining > 0, biggest.tokens >= Self.notableAddition
        else { return nil }
        let share = Double(biggest.tokens) / Double(remaining)
        return share >= Self.notableShare ? (biggest, share) : nil
    }

    public static func read(
        messages: [ChatMessage], fill: ContextFill?, wholeConversation: Bool = false
    ) -> ContextBurn? {
        let limit = wholeConversation ? nil : recentTurns + 1
        let turns = footprints(in: messages, newest: limit)
        guard !turns.isEmpty else { return nil }
        let start = turns.lastIndex(where: \.startsEpoch) ?? 0
        let epoch = Array(turns[start...])

        let deltas = zip(epoch, epoch.dropFirst()).map { $1.footprint - $0.footprint }
        let recent = deltas.suffix(recentTurns)
        var growth: Int?
        if epoch.count >= minTurns, !recent.isEmpty {
            let mean = recent.reduce(0, +) / recent.count
            if mean > 0 { growth = mean }
        }

        let remaining = fill?.remaining
        var turnsLeft: Int?
        if let growth, let remaining, let fraction = fill?.fraction, fraction >= minFill {
            let left = Int((Double(remaining) / Double(growth)).rounded())
            turnsLeft = left <= 99 ? left : nil
        }

        var biggest: Addition?
        if wholeConversation,
            let index = deltas.indices.max(by: { deltas[$0] < deltas[$1] }), deltas[index] > 0
        {
            biggest = Addition(tokens: deltas[index], messageID: epoch[index + 1].messageID)
        }
        return ContextBurn(
            turns: turns, epochTurns: epoch.count, growth: growth, remaining: remaining,
            turnsLeft: turnsLeft, biggest: biggest)
    }

    /// The footprint after each turn, oldest first. A turn is everything answered between two
    /// prompts, so the footprint is the last request of it — a server that writes a message per
    /// step still has one turn. Read from the newest end and stopped at `limit` turns or the first
    /// refill, so asking it on every streamed token costs the recent past and not the length of
    /// the conversation.
    static func footprints(in messages: [ChatMessage], newest limit: Int?) -> [Turn] {
        var collected: [Turn] = []
        var taken = false
        for message in messages.reversed() {
            if message.parts.contains(where: { $0.isCompaction }) {
                guard limit == nil else { break }
                if !collected.isEmpty {
                    collected[collected.count - 1] = collected[collected.count - 1].startingEpoch()
                }
                taken = false
                continue
            }
            if message.role == .user {
                taken = false
                continue
            }
            guard message.role == .assistant, !taken, let context = message.context, !context.isEmpty
            else { continue }
            taken = true
            let older = Turn(messageID: message.id, footprint: context.total, startsEpoch: false)
            if let newer = collected.last,
                Double(newer.footprint) < Double(older.footprint) * refillBelow
            {
                collected[collected.count - 1] = newer.startingEpoch()
                if limit != nil { break }
            }
            collected.append(older)
            if let limit, collected.count >= limit { break }
        }
        return collected.reversed()
    }
}

extension ContextBurn.Turn {
    fileprivate func startingEpoch() -> ContextBurn.Turn {
        ContextBurn.Turn(messageID: messageID, footprint: footprint, startsEpoch: true)
    }
}

extension MessagePart {
    fileprivate var isCompaction: Bool {
        if case .compaction = kind { return true }
        return false
    }
}

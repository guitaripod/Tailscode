import CodingAgentKit
import Foundation

/// What a conversation has cost, arranged for reading rather than for accounting.
///
/// The server does the counting — it has the CLI's own transcript, which is the only complete
/// record — and this turns the report into the handful of things a person actually wants: what the
/// whole conversation cost, which turns were expensive, where the money went between fresh tokens
/// and cache, and which model spent it. Every client draws the same five sections from this; none
/// of them do arithmetic of their own.
///
/// The money is an estimate and says so everywhere. A subscription bills a flat fee, so the figure
/// is what these tokens would have cost on the metered API — the number that makes one
/// conversation comparable to another, and the number that is wrong to present as a bill.
public struct SessionSpend: Sendable, Equatable {
    /// One bar in the per-turn chart: what it cost, how tall that is next to the others, and
    /// enough of the prompt to know which turn it was.
    public struct Turn: Sendable, Equatable {
        public let at: Date
        public let costUSD: Double
        public let tokens: Int
        public let model: String?
        public let seconds: Double?
        public let prompt: String?
        /// `0...1` against the most expensive turn in the conversation.
        public let share: Double
    }

    /// One tier of tokens, priced. The split is the point: a conversation whose money went to
    /// cache reads is cheap per token and long; one whose money went to output is the opposite.
    public struct Tier: Sendable, Equatable {
        public let id: String
        public let label: String
        public let tokens: Int
        public let costUSD: Double
        public let share: Double
    }

    public struct ModelShare: Sendable, Equatable {
        public let model: String
        public let label: String
        public let turns: Int
        public let tokens: Int
        public let costUSD: Double
        public let share: Double
    }

    public let costUSD: Double
    public let estimated: Bool
    public let turns: [Turn]
    public let tiers: [Tier]
    public let models: [ModelShare]
    public let totalTokens: Int
    public let turnCount: Int
    public let span: TimeInterval?
    public let startedAt: Date?
    /// Nil when nothing was spent — a conversation with no priced turn has no average.
    public let averageUSD: Double?
    /// What it is costing an hour, and nil until there is enough clock under it to mean anything:
    /// four minutes of work extrapolates to a figure that is arithmetically true and completely
    /// misleading, so a short session simply does not state a rate.
    public let perHourUSD: Double?
    public let priciest: Turn?
    /// Where the numbers came from, said plainly, because a figure whose provenance is unclear is
    /// worse than no figure.
    public let source: String

    public var isEmpty: Bool { turns.isEmpty && costUSD <= 0 }

    /// How much clock a rate needs before it is worth stating.
    private static let rateFloor: TimeInterval = 900

    /// From the server's own reading of the transcript — the complete account, including turns run
    /// from a terminal or another client, and the only one that knows the token tiers.
    public init(report: SessionSpendReport) {
        let peak = report.turns.map(\.costUSD).max() ?? 0
        self.turns = report.turns.map { turn in
            Turn(
                at: turn.at, costUSD: turn.costUSD, tokens: turn.tokens.total, model: turn.model,
                seconds: turn.seconds, prompt: turn.prompt,
                share: peak > 0 ? turn.costUSD / peak : 0)
        }
        self.costUSD = report.costUSD
        self.estimated = report.estimated
        self.totalTokens = report.tokens.total
        self.turnCount = report.turns.count
        self.startedAt = report.startedAt
        if let start = report.startedAt, let end = report.endedAt {
            self.span = max(0, end.timeIntervalSince(start))
        } else {
            self.span = nil
        }
        self.tiers = Self.tiers(of: report)
        let modelPeak = report.byModel.map(\.costUSD).max() ?? 0
        self.models = report.byModel.map { share in
            ModelShare(
                model: share.model, label: ModelBadge.shortName(share.model), turns: share.turns,
                tokens: share.tokens.total, costUSD: share.costUSD,
                share: modelPeak > 0 ? share.costUSD / modelPeak : 0)
        }
        self.averageUSD = report.turns.isEmpty ? nil : report.costUSD / Double(report.turns.count)
        if let span, span >= Self.rateFloor, report.costUSD > 0 {
            self.perHourUSD = report.costUSD / (span / 3600)
        } else {
            self.perHourUSD = nil
        }
        self.priciest = turns.max { $0.costUSD < $1.costUSD }
        self.source = report.estimated
            ? Localized.text("Estimated from the transcript at API list prices")
            : Localized.text("Reported by the provider")
    }

    /// From what this device already holds, for a backend that prices its own messages but has no
    /// spend route. Coarser by design: a transcript knows what each answer cost and nothing about
    /// which tier the tokens were, so the panel shows the turns and says the rest is unavailable.
    public init?(messages: [ChatMessage]) {
        var turns: [SessionSpendReport.Turn] = []
        var prompt: String?
        var promptAt: Date?
        for message in messages {
            if message.role == .user {
                prompt = message.parts.compactMap(\.text).first.map { String($0.prefix(160)) }
                promptAt = message.createdAt
                continue
            }
            guard message.role == .assistant, let cost = message.costUSD, cost > 0 else { continue }
            turns.append(
                SessionSpendReport.Turn(
                    at: promptAt ?? message.createdAt,
                    seconds: message.completedAt.map {
                        max(0, $0.timeIntervalSince(promptAt ?? message.createdAt))
                    },
                    model: message.modelID, calls: 1,
                    tokens: SessionSpendReport.Tokens(output: message.totalTokens ?? 0),
                    costUSD: cost, prompt: prompt))
            prompt = nil
            promptAt = nil
        }
        guard !turns.isEmpty else { return nil }
        var byModel: [String: SessionSpendReport.ModelShare] = [:]
        for turn in turns {
            let key = turn.model ?? Localized.text("unknown")
            var slot = byModel[key]
                ?? SessionSpendReport.ModelShare(
                    model: key, turns: 0, tokens: SessionSpendReport.Tokens(), costUSD: 0)
            slot.turns += 1
            slot.tokens.output += turn.tokens.output
            slot.costUSD += turn.costUSD
            byModel[key] = slot
        }
        self.init(
            report: SessionSpendReport(
                costUSD: turns.reduce(0) { $0 + $1.costUSD },
                tokens: SessionSpendReport.Tokens(
                    output: turns.reduce(0) { $0 + $1.tokens.output }),
                turns: turns, byModel: byModel.values.sorted { $0.costUSD > $1.costUSD },
                startedAt: turns.first?.at, endedAt: turns.last?.at, estimated: false))
    }

    private static func tiers(of report: SessionSpendReport) -> [Tier] {
        tierSplit(tokens: report.tokens, costUSD: report.costUSD)
    }

    /// The four tiers, each priced by its own share of the total, dropping any the window never
    /// used — an empty legend row is a row that has to be read to learn nothing. Shared with the
    /// account-wide analytics, which splits a month the same way a panel splits a conversation.
    public static func tierSplit(tokens: SessionSpendReport.Tokens, costUSD: Double) -> [Tier] {
        let weights: [(String, String, Int, Double)] = [
            ("output", Localized.text("Answer"), tokens.output, 1.0),
            ("cacheWrite", Localized.text("Cache written"), tokens.cacheWrite, 0.25),
            ("cacheRead", Localized.text("Cache read"), tokens.cacheRead, 0.02),
            ("input", Localized.text("Fresh input"), tokens.input, 0.2),
        ]
        let weighted = weights.map { Double($0.2) * $0.3 }
        let sum = weighted.reduce(0, +)
        var result: [Tier] = []
        for (index, entry) in weights.enumerated() where entry.2 > 0 {
            let fraction = sum > 0 ? weighted[index] / sum : 0
            result.append(
                Tier(
                    id: entry.0, label: entry.1, tokens: entry.2,
                    costUSD: costUSD * fraction, share: fraction))
        }
        return result.sorted { $0.costUSD > $1.costUSD }
    }

    /// Money at the precision it is worth reading: dollars for real spend, cents below a dollar,
    /// and a floor so a turn that cost a hundredth of a cent says so rather than reading as free.
    public static func money(_ value: Double) -> String {
        if value <= 0 { return "$0" }
        if value < 0.01 { return "<$0.01" }
        if value < 1 { return String(format: "$%.2f", value) }
        if value < 100 { return String(format: "$%.2f", value) }
        return String(format: "$%.0f", value)
    }

    /// The label the band wears: money if there is any, the token count if there is not. Prefixed
    /// with `~` when the money was priced rather than reported, which is the whole warning.
    public var badge: String {
        guard costUSD > 0 else { return StatusFacts.tokens(totalTokens) }
        return (estimated ? "~" : "") + Self.money(costUSD)
    }

    public static func duration(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    /// The lines the panel's header states, in the order they answer "so what?": what it cost, over
    /// how many turns, in how long, at what rate.
    public var headline: [(String, String)] {
        var rows: [(String, String)] = []
        rows.append((Localized.text("Turns"), "\(turnCount)"))
        if let averageUSD {
            rows.append((Localized.text("Each"), Self.money(averageUSD)))
        }
        if let span, span > 0 {
            rows.append((Localized.text("Over"), Self.duration(span)))
        }
        if let perHourUSD {
            rows.append((Localized.text("An hour"), Self.money(perHourUSD)))
        }
        rows.append((Localized.text("Tokens"), StatusFacts.tokens(totalTokens)))
        return rows
    }
}

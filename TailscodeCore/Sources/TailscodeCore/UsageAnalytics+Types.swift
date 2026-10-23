import CodingAgentKit
import Foundation

extension UsageAnalytics {
    public enum Trend: Sendable, Equatable {
        case up
        case down
        case flat
    }

    /// One bar in the chart over time. Empty stretches are present and zero — a gap in a month is
    /// information, not a missing bar — and a bar is a day, a week or a month depending on how
    /// much time the reader asked to see (``UsageWindow/grain``).
    public struct DayBar: Sendable, Equatable {
        public let key: String
        /// What this bar is, in words: a day as `Sun Aug 9`, a week as `Sep 8–14`, a month as
        /// `September`. Every reading of a bar — the tooltip, the peak annotation, the line a
        /// screen reader is given — says this rather than assembling one of its own.
        public let title: String
        public let costUSD: Double
        public let money: String
        /// What the day is worth in the unit the account actually has — the money, or the tokens
        /// where every model in the window ran for free. This is the string a bar is labelled
        /// with; ``money`` stays the money for anything that specifically means money.
        public let value: String
        public let tokens: Int
        public let turns: Int
        public let toolCalls: Int
        /// `0...1` against the biggest day in the window, measured the same way ``value`` is.
        public let share: Double
        public let isToday: Bool
    }

    /// One meter row: models, providers, projects, tools, machines all draw as a label, a fill
    /// and the numbers that justify it.
    public struct Meter: Sendable, Equatable {
        public let label: String
        public let detail: String
        /// The trailing value: money for a row that spent some, otherwise the word for what a
        /// zero there means — read from ``door`` — and a share for a row counted rather than priced.
        public let money: String?
        /// `0...1` against the largest row of its section.
        public let share: Double
        /// True when this row did real work and nothing was billed for it at all. A zero here is
        /// a price, never an absence, and the row must not be drawn as an empty one. A plan's
        /// tokens are not free: the month was paid for, this ledger simply cannot divide it.
        public let isFree: Bool
        /// Which kind of door the row's tokens went through, where the row is a model, a provider
        /// or a machine. It is what makes a cost of nothing legible: hardware the person owns, a
        /// plan they already pay for, or a rate the server does not have.
        public let door: ModelDoorKind?
        /// How fast the model has run on this device, where the speed ledger has watched enough
        /// turns to say ("74 tok/s"). Only a model on the person's own machine carries one: its
        /// speed is a property of their hardware, where a hosted model's belongs to the provider's
        /// load that hour.
        public let speed: String?

        public init(
            label: String, detail: String, money: String?, share: Double, isFree: Bool = false,
            door: ModelDoorKind? = nil, speed: String? = nil
        ) {
            self.label = label
            self.detail = detail
            self.money = money
            self.share = share
            self.isFree = isFree
            self.door = door
            self.speed = speed
        }

        /// What a row wears at its trailing edge: the speed where there is one, then the money
        /// word. A client draws this and composes nothing of its own.
        public var trailing: String? {
            let parts = [speed, money].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// What ran on the person's own hardware, arranged to lead the page for an account that does
    /// most of its work there. The money cannot say any of it: a local model costs nothing, so the
    /// facts that matter are how much it did, how that divides between reading and writing, which
    /// model did it, how fast, and how much room its window has.
    public struct LocalWork: Sendable, Equatable {
        /// One tile in the stats row: a label, the number, and a dim line that qualifies it.
        public struct Stat: Sendable, Equatable {
            public let label: String
            public let value: String
            public let detail: String?
        }

        public let title: String
        public let headline: String
        /// The work: fresh tokens, cache reads left out, summed over every model on a local door.
        public let tokens: Int
        /// `0...1` of the window's fresh tokens across every door.
        public let share: Double
        /// What the models wrote and what they read, where the ledger separates the two. Nil when
        /// it cannot, so a surface says nothing rather than splitting a number it never had.
        public let generated: Int?
        public let read: Int?
        /// Turns on a local door, where the servers counted them; nil is not zero.
        public let turns: Int?
        /// Days with local work in them, where every machine that ran a local model ran nothing
        /// else, so the daily buckets are the local model's alone; nil when they are shared.
        public let activeDays: Int?
        public let stats: [Stat]
        public let models: [Meter]
        /// What the list left out when there were more local models than it will show.
        public let caption: String?
    }

    /// One thing worth saying about the window, typed by what it is about so a surface that
    /// already draws the models or the tools can leave out the line that repeats them.
    public struct Insight: Sendable, Equatable {
        public enum Topic: Sendable, Equatable {
            case model
            case cache
            case tool
            case subagents
            case streak
            case clock
        }

        public let topic: Topic
        public let text: String
    }

    public struct HourBar: Sendable, Equatable {
        public let label: String
        public let turns: Int
        public let share: Double
    }

    /// One brag-worthy fact, ready to wear: an SF Symbol where the client has them, a single
    /// glyph where a column is all there is.
    public struct Record: Sendable, Equatable {
        public let id: String
        public let symbolName: String
        public let glyph: String
        public let title: String
        public let value: String
        public let detail: String?
    }
}

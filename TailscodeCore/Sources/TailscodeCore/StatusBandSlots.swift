import Foundation

/// The room each fact on the status band keeps for itself, so a fact holds its place while its own
/// words change.
///
/// The band is a row of instruments sized by their text, and the text moves: a clock goes from
/// `59s` to `1m 0s`, a share from 9% to 78%, a count from 999 to 1.0k, a phase from a verb to a
/// tool's long name. Left to the layout, every such change slides each fact to its right sideways.
/// A client measures a fact's natural width, asks for the held width, and gives the fact that much
/// room as a minimum, never a maximum: a narrow pane still compresses or drops the fact. The held
/// width only ever grows within a conversation, so each fact settles on the widest thing it has
/// said and then stands still; the slots are cleared when the pane shows another conversation.
///
/// Units are the client's own — points or pixels — because only the client measures.
public struct StatusBandSlots: Sendable, Equatable {
    /// The most of the band a single fact may hold, so one absurd tool name cannot pin the band
    /// wide for the rest of the conversation.
    public static let shareLimit = 0.45

    private var held: [String: Double] = [:]

    public init() {}

    /// The widest `id` has been, never more than ``shareLimit`` of the band when the band's width is
    /// known. Also what a client reads back for a fact whose words did not change.
    @discardableResult
    public mutating func widen(_ id: String, to width: Double, in band: Double? = nil) -> Double {
        let measured = width.isFinite ? max(0, width) : 0
        let ceiling = Self.ceiling(in: band)
        held[id] = max(held[id] ?? 0, min(measured, ceiling))
        return min(held[id] ?? 0, ceiling)
    }

    public func width(of id: String, in band: Double? = nil) -> Double {
        min(held[id] ?? 0, Self.ceiling(in: band))
    }

    public mutating func reset() {
        held.removeAll()
    }

    private static func ceiling(in band: Double?) -> Double {
        guard let band, band.isFinite, band > 0 else { return .infinity }
        return band * shareLimit
    }
}

extension StatusBandSlots {
    /// Every glyph a fact's leading slot can wear: each state's mark, each tool's, and the frames a
    /// sweep cycles through. A client measures all of them in the band's own font and gives the
    /// slot the widest, so the mark can change — or a pulse can sweep through four of them sixty
    /// times a second — without moving the words beside it. The one-column claim in Core holds for
    /// a monospaced face only, and a symbol like ⚒ is drawn in a fallback font whose advance is not
    /// the band font's, which is why the slot is measured rather than assumed.
    public static var leadingGlyphs: [String] {
        var glyphs = ActivityKind.everyState.map(\.icon.glyph)
        glyphs += ActivityKind.toolKinds.map { ActivityKind.glyph(forTool: $0) }
        glyphs += ActivityIcon.sweepCycle
        glyphs += [StatusMark.done, StatusMark.failed, StatusMark.idle, StatusMark.open]
        var seen = Set<String>()
        return glyphs.filter { seen.insert($0).inserted }
    }
}

extension StatusFacts {
    /// A name no band is wide enough for, for the claim that one fact cannot pin the band.
    public static let rehearsalAbsurdTool =
        "mcp__plugin_revenuecat_RevenueCat__get-overview-metrics-for-every-project-and-app"

    /// The band over twenty-odd minutes of one turn, for a client's harness to feed its band and
    /// prove that nothing beside a fact moves while the fact changes: the clock rolls from seconds
    /// to minutes and into two digits of them, the share climbs and the window is lost with the
    /// ring that drew it, the count crosses 1.0k and 1.0M, and the phase goes from a word to a
    /// tool's long name and back.
    public static var rehearsal: [StatusFacts] {
        let bash = ActivityKind.usingTool(name: "Bash", kind: .shell)
        let long = ActivityKind.usingTool(name: "mcp__github__create_issue", kind: .other)
        return [
            moment(.working, elapsed: 58, used: 18_000, window: 200_000, tokens: 999),
            moment(bash, elapsed: 62, used: 40_000, window: 200_000, tokens: 1000),
            moment(long, elapsed: 599, used: 90_000, window: 200_000, tokens: 12_400),
            moment(.working, elapsed: 600, used: 156_000, window: 200_000, tokens: 205_200),
            moment(.thinking, elapsed: 1372, used: 205_200, window: nil, tokens: 1_000_000),
            moment(.writing, elapsed: 1373, used: 20_000, window: 200_000, tokens: 999),
        ]
    }

    /// One instant of the rehearsal: a turn working at `activity`, with the window part full.
    public static func moment(
        _ activity: ActivityKind, elapsed: TimeInterval, used: Int, window: Int?, tokens: Int,
        queued: Int = 0
    ) -> StatusFacts {
        var facts = StatusFacts()
        facts.phase = .working
        facts.activity = activity
        facts.elapsed = elapsed
        facts.context = ContextFill(used: used, window: window, model: nil, basis: .reported)
        facts.lastTurnTokens = tokens
        facts.queued = queued
        return facts
    }
}

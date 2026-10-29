import Foundation

/// How often the wall may draw, one function every client obeys.
public enum WallCadence {
    public enum Thermal: Sendable, Comparable {
        case nominal, fair, serious, critical
    }

    /// Frames a second the wall may draw at; 0 draws nothing, and at a critical thermal state the
    /// client draws one still frame on entering and no more.
    public static func cap(
        effectsLive: Bool, breathing: Bool, dimmedCalm: Bool, hidden: Bool, lowPower: Bool,
        thermal: Thermal, proMotion: Bool
    ) -> Int {
        if hidden || thermal == .critical { return 0 }
        if dimmedCalm && !effectsLive { return 1 }
        let wanted = wantedRate(effectsLive: effectsLive, breathing: breathing, proMotion: proMotion)
        var cap = wanted
        if thermal == .serious { cap = min(cap, 15) }
        if lowPower { cap = min(cap, 20) }
        return cap
    }

    /// Whether the ambient field moves at all.
    public static func fieldRuns(lowPower: Bool, thermal: Thermal, style: WallStyle) -> Bool {
        !(lowPower || thermal >= .serious || style.still || style.field == .none)
    }

    private static func wantedRate(effectsLive: Bool, breathing: Bool, proMotion: Bool) -> Int {
        if effectsLive { return proMotion ? 60 : 30 }
        return breathing ? 30 : 1
    }
}

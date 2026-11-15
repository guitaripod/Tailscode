import Foundation

/// How often the wall may draw, one function every client obeys.
public enum WallCadence {
    public enum Thermal: Sendable, Comparable {
        case nominal, fair, serious, critical
    }

    /// Frames a second the wall may draw at; 0 draws nothing, and at a critical thermal state the
    /// client draws one still frame on entering and no more.
    ///
    /// `smooth` is the rate a wall whose frames cost the GPU rather than the main thread can hold
    /// on its display (`smoothRate(refreshHz:)`); given, breathing and effects run at it instead of
    /// thirty and sixty. `strained` is a main thread that is already behind, which holds even such
    /// a wall to thirty.
    public static func cap(
        effectsLive: Bool, breathing: Bool, dimmedCalm: Bool, hidden: Bool, lowPower: Bool,
        thermal: Thermal, proMotion: Bool, smooth: Int? = nil, strained: Bool = false
    ) -> Int {
        if hidden || thermal == .critical { return 0 }
        if dimmedCalm && !effectsLive { return 1 }
        var wanted = wantedRate(effectsLive: effectsLive, breathing: breathing, proMotion: proMotion)
        if let smooth, smooth > 0, breathing || effectsLive {
            wanted = strained ? min(smooth, 30) : smooth
        }
        var cap = wanted
        if thermal == .serious { cap = min(cap, 15) }
        if lowPower { cap = min(cap, 20) }
        return cap
    }

    /// Whether the ambient field moves at all.
    public static func fieldRuns(lowPower: Bool, thermal: Thermal, style: WallStyle) -> Bool {
        !(lowPower || thermal >= .serious || style.still || style.field == .none)
    }

    /// How many of a display's refreshes each frame of a smooth wall lasts: every one up to 100 Hz,
    /// every second up to 200, and so on, so motion never runs slower than fifty frames a second on
    /// any display of fifty hertz or more, never asks for more than a hundred, and every frame stays
    /// up for the same number of refreshes.
    public static func stride(refreshHz: Double) -> Int {
        guard refreshHz.isFinite, refreshHz > 0 else { return 1 }
        return max(1, Int((refreshHz / 100).rounded(.up)))
    }

    /// The frames a second that stride gives on a display of `refreshHz`, rounded to whole frames:
    /// 60 at 60 Hz and 120 Hz, 72 at 144, 83 at 165, 80 at 240.
    public static func smoothRate(refreshHz: Double) -> Int {
        guard refreshHz.isFinite, refreshHz > 0 else { return 60 }
        return Int((refreshHz / Double(stride(refreshHz: refreshHz))).rounded())
    }

    private static func wantedRate(effectsLive: Bool, breathing: Bool, proMotion: Bool) -> Int {
        if effectsLive { return proMotion ? 60 : 30 }
        return breathing ? 30 : 1
    }
}

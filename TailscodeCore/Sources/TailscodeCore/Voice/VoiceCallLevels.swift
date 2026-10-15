import Foundation

/// Turns the raw loudness a client reads into the value it draws: it rises quickly, so a word is
/// seen when it starts, and falls slowly, so the light does not flicker between syllables.
public enum VoiceCallLevels {
    public static let attack: TimeInterval = 0.04
    public static let release: TimeInterval = 0.22

    /// Where a drawn level stands after `dt` seconds of heading for `target`, both in `0...1`.
    public static func smoothed(previous: Double, target: Double, dt: TimeInterval) -> Double {
        let from = clamped(previous)
        let goal = clamped(target)
        guard dt > 0 else { return from }
        let tau = goal > from ? attack : release
        let closed = 1 - exp(-dt / tau)
        return clamped(from + (goal - from) * closed)
    }

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

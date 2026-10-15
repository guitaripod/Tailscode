import Foundation

/// The single pass of light that announces a fresh mark. Position is read from absolute time, so a
/// capsule scrolled into view mid-pass arrives already in step.
public enum BetaSheen {
    public static let duration = 1.4

    /// Where the light is across the capsule, 0 left of it and 1 right of it, or nil when nothing
    /// is drawn: reduced motion, before the pass starts, or after it ended.
    public static func progress(elapsed: TimeInterval, reducedMotion: Bool) -> Double? {
        guard !reducedMotion, (0...duration).contains(elapsed) else { return nil }
        let t = elapsed / duration
        return 0.5 - 0.5 * cos(Double.pi * t)
    }
}

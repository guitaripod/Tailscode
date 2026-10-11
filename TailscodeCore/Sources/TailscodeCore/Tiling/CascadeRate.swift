import Foundation

/// How fast the written-not-pasted reveal may move, as a function of how many panes are streaming
/// at once and how much the window is shedding.
///
/// One answer streaming alone is the product's best moment and gets the display's own rate, up to
/// 120 Hz, because a reveal at thirty reads as a hand that stutters. Every further streaming pane
/// is another transcript laid out and committed on the same main thread after each frame, which
/// is where two thirds of a streaming window's busy time goes, so the rate steps down with the
/// count: sixty for two, thirty for three or more. A pane that is not the focused one never goes
/// above thirty. The governor's level caps the result from busy up, and reveals stop altogether
/// where its budget stops them.
public enum CascadeRate {
    /// The display's best rate, asked for by a lone streaming pane.
    public static let panel: Double = 120
    /// Two panes streaming.
    public static let pair: Double = 60
    /// Three or more, and the most a peer ever runs at.
    public static let crowd: Double = 30

    /// A rate to hand a display clock: it never runs below `minimum` when the system can help it,
    /// never above `maximum`, and prefers `preferred`.
    public struct Range: Sendable, Equatable {
        public var minimum: Double
        public var maximum: Double
        public var preferred: Double

        public init(minimum: Double, maximum: Double, preferred: Double) {
            self.minimum = minimum
            self.maximum = maximum
            self.preferred = preferred
        }
    }

    /// The most frames a second the reveal may move on. Zero means no clock at all.
    ///
    /// `streaming` counts the panes with a turn running on screen; none and one both mean the pane
    /// has the window to itself. At calm the table decides; from busy up the governor's own tick
    /// cap applies on top of it, and from loaded up nothing exceeds thirty.
    public static func ceiling(
        streaming: Int, level: ShedLevel, focused: Bool = true
    ) -> Double {
        var rate: Double
        switch streaming {
        case ...1: rate = panel
        case 2: rate = pair
        default: rate = crowd
        }
        if !focused { rate = min(rate, crowd) }
        guard level > .calm else { return rate }
        let cap = TileGovernor.animation(level: level, reducedMotion: false).tickCap
        rate = min(rate, cap)
        if level >= .loaded { rate = min(rate, crowd) }
        return rate
    }

    /// The range a display link is given for that ceiling.
    public static func range(
        streaming: Int, level: ShedLevel, focused: Bool = true
    ) -> Range {
        let top = ceiling(streaming: streaming, level: level, focused: focused)
        let floor: Double
        switch top {
        case panel...: floor = 60
        case pair...: floor = 30
        default: floor = min(top, 10)
        }
        return Range(minimum: floor, maximum: top, preferred: top)
    }

    /// Whether a pane may run the reveal at all: only the focused pane, and only at the levels
    /// whose budget lets text be written rather than handed over whole.
    public static func reveals(focused: Bool, level: ShedLevel, reducedMotion: Bool = false) -> Bool {
        guard focused else { return false }
        return TileGovernor.animation(level: level, reducedMotion: reducedMotion).cascade == .focusedOnly
    }
}

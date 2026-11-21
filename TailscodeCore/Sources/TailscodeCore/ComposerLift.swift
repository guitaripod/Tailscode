import Foundation

/// How tall a prompt box is. At rest it is as tall as its words up to six lines, which is what a
/// box may take from the conversation above it without being asked; past that the words scroll
/// and a handle on the box's top edge offers the page. Pulled up, the box follows the finger to as
/// tall as the words need and no taller than the window allows, and goes back to six lines when it
/// is pulled down, sent, or left.
public enum ComposerLift {
    public static let restingLines = 6

    /// The tallest the words may be at rest, for a line of this height.
    public static func restingCap(lineHeight: Double) -> Double {
        (lineHeight * Double(restingLines)).rounded(.up) + 2
    }

    /// The height the words are given: what they need, held between one line and the cap.
    public static func height(natural: Double, cap: Double, floor: Double) -> Double {
        min(max(floor, natural), max(floor, cap))
    }

    /// Whether the handle shows: there are words out of sight at rest, or the box is up and has
    /// to be able to come down.
    public static func offersHandle(natural: Double, resting: Double, lifted: Bool) -> Bool {
        lifted || natural > resting + 0.5
    }

    /// The most the words can take once lifted: what they need, but never past the room the
    /// window has and never under the resting cap.
    public static func ceiling(natural: Double, resting: Double, page: Double) -> Double {
        max(resting, min(natural, page))
    }

    /// The cap while the handle is held. It tracks the finger between the resting cap and the
    /// ceiling and gives way softly past either, so the box never feels bolted at its ends.
    ///
    /// - Parameter travel: how far the finger has moved since it took the handle, upward positive.
    public static func dragged(
        from start: Double, travel: Double, resting: Double, ceiling: Double
    ) -> Double {
        let wanted = start + travel
        if wanted > ceiling { return ceiling + give(wanted - ceiling) }
        if wanted < resting { return resting - give(resting - wanted) }
        return wanted
    }

    private static let slack = 36.0

    private static func give(_ over: Double) -> Double {
        slack * (1 - 1 / (over / slack * 0.6 + 1))
    }

    /// Where a released handle comes to rest. A flick decides; without one, whichever end is
    /// nearer.
    ///
    /// - Parameter velocity: points a second, upward positive.
    public static func settlesLifted(
        cap: Double, velocity: Double, resting: Double, ceiling: Double
    ) -> Bool {
        if velocity > flick { return true }
        if velocity < -flick { return false }
        return cap - resting > (ceiling - resting) / 2
    }

    private static let flick = 320.0

    /// The motion every change of the box's height rides, so a line arriving, the handle let go
    /// and the box closing on a send are one hand.
    public static let response = 0.34
    public static let damping = 0.86
}

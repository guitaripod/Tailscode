import Foundation

/// The measurements of a chat's chrome, written once so three clients cannot drift into three
/// dialects.
///
/// The screen around a conversation used to carry nine kinds of pill: heights from 16 to 34,
/// corner radii of 0, 2, 3, 6, 8, 14, 17, 18 and 23, three fonts and two kinds of fill, each chosen
/// where it was needed. The chips were not wrong one at a time; together they read as a screen
/// nobody designed. This is the scale they are all drawn from. A client turns a number into points
/// or pixels and adds nothing — the same rule the type ramp has.
public enum ChatChrome {
    /// Where the chip is worn: a finger and a pointer ask for different heights, and the Mac and
    /// Linux ask for the same one.
    public enum Surface: Sendable {
        case touch
        case pointer
    }

    /// One chip's box. `height` is what is drawn; `hit` is what answers a press, which on a
    /// touch screen is larger than the chip and is reached by outsetting the target rather than
    /// by drawing a taller chip.
    public struct ChipMetrics: Sendable, Equatable {
        public let height: Double
        public let hit: Double
        public let iconSize: Double
        public let padding: Double
        public let iconGap: Double
        public let spacing: Double
    }

    public static func chip(on surface: Surface) -> ChipMetrics {
        switch surface {
        case .touch:
            return ChipMetrics(
                height: 30, hit: 44, iconSize: 12, padding: 11, iconGap: 5, spacing: 6)
        case .pointer:
            return ChipMetrics(
                height: 24, hit: 24, iconSize: 12, padding: 9, iconGap: 5, spacing: 6)
        }
    }

    /// The only corner radii the chat uses. A chip and a pill are capsules, so they have no
    /// number: their radius is half their height.
    public enum Radius {
        public static let control = 10.0
        public static let card = 14.0
        public static let composer = 20.0
        public static let sheet = 24.0
    }

    /// The font every chip, pill and band segment is set in. One role, so the three sizes of
    /// type a row of chips used to wear are one.
    public static let chipRole = TypeRole.chip

    /// What a chip is for, because a pill that reads a fact and a pill that makes a choice must
    /// not look alike.
    public enum Kind: Sendable, CaseIterable {
        /// Read, and opens the account behind it: context, spend, branch.
        case fact
        /// Something is happening or is wanted: agents out, work in the background, a goal.
        case live
        /// Makes a choice: the model and its effort, the lane.
        case control
    }

    public struct Fill: Sendable, Equatable {
        public let opaque: Bool
        /// Share of the ink colour mixed into the canvas to make the fill, so the fill is a
        /// colour on its own and never the translucent grey that lets text show through a chip.
        public let inkShare: Double
        public let outlined: Bool
    }

    public static func fill(_ kind: Kind) -> Fill {
        switch kind {
        case .fact: return Fill(opaque: true, inkShare: 0.07, outlined: false)
        case .live: return Fill(opaque: true, inkShare: 0.07, outlined: false)
        case .control: return Fill(opaque: true, inkShare: 0.04, outlined: true)
        }
    }

    /// Meaning rides the glyph and the dot, never the ink and never the fill: a tinted text on a
    /// tinted capsule fails the contrast the palette was corrected for, and a fact that exists
    /// only in a tint is lost to anyone who cannot see it.
    public static func glyphTone(_ kind: Kind, tone: ActivityTone) -> ActivityTone {
        switch kind {
        case .fact, .control: return tone
        case .live: return tone == .quiet ? .live : tone
        }
    }

    /// How many facts one row holds before the rest scroll, so a chat never grows a second row of
    /// chips above its composer.
    public static let factRowRows = 1

    /// Gap between the last line of the transcript and whatever sits above the composer.
    public static let transcriptToChrome = 12.0
}

import Foundation

/// A point in the head's design space: 640 by 420, y down, the same on every client.
public struct NeuralPoint: Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// Which of the app's tones a part of the head wears. `identity` is the model family's own hue,
/// worn by the eye of a settled turn. The raw values travel on the wire.
public enum NeuralTone: String, Sendable, Hashable {
    case live
    case attention
    case danger
    case quiet
    case identity
}

/// Which of the theme's inks a zone's dot is drawn in; each client resolves it in its own colours.
public enum NeuralGlyphInk: Sendable, Hashable {
    case text
    case info
    case accent
    case special
    case textDim
    case say
}

/// The head's silhouette, its zones and the formulas for the small drawing, with nothing but
/// Foundation, so the app, the Live Activity widget and both notification extensions compile this
/// one file by path and draw the same head. `NeuralZone`, `NeuralGlyph` and `NeuralGlyphPlan` all
/// read their numbers from here: the outline and the dot formulas exist once.
public enum NeuralGlyphGeometry {
    /// How many zones the head has, and so how many counts a glyph carries.
    public static let zoneCount = 6

    /// Where each zone sits in design space, by zone index: think, sense, act, shell, delegate, say.
    public static let zoneCenters: [NeuralPoint] = [
        NeuralPoint(456, 150), NeuralPoint(204, 162), NeuralPoint(348, 104),
        NeuralPoint(240, 284), NeuralPoint(396, 250), NeuralPoint(520, 306),
    ]

    /// The ink each zone's dot wears, by zone index.
    public static let zoneInks: [NeuralGlyphInk] = [.text, .info, .accent, .special, .textDim, .say]

    /// The zones' draw order: the five working zones, then the jaw.
    public static let zoneOrder: [Int] = [0, 1, 2, 3, 4, 5]

    /// The crop of the design space the head's silhouette fills: x, y, width, height.
    public static let viewBox = (x: 68.0, y: 6.0, width: 566.0, height: 368.0)

    /// The head's silhouette, closed, in design space.
    public static let outline: [NeuralPoint] = [
        NeuralPoint(196, 412), NeuralPoint(196, 372), NeuralPoint(136, 322),
        NeuralPoint(98, 268), NeuralPoint(80, 196), NeuralPoint(100, 118), NeuralPoint(162, 56),
        NeuralPoint(258, 24), NeuralPoint(372, 16), NeuralPoint(484, 40), NeuralPoint(556, 98),
        NeuralPoint(580, 160), NeuralPoint(614, 184), NeuralPoint(620, 238),
        NeuralPoint(586, 254), NeuralPoint(584, 296), NeuralPoint(544, 330),
        NeuralPoint(486, 346), NeuralPoint(436, 352), NeuralPoint(384, 374),
        NeuralPoint(384, 412),
    ]

    /// The eye bar, closed.
    public static let eyeBar: [NeuralPoint] = [
        NeuralPoint(538, 190), NeuralPoint(622, 187), NeuralPoint(627, 238), NeuralPoint(546, 247),
    ]

    public static let eyeHaloCenter = NeuralPoint(586, 216)
    public static let eyeHaloRadius = 46.0
    public static let eyeHaloOpacity = 0.28

    public static func radius(forCount count: Int) -> Double { 44 + 12 * Double(min(count, 4)) }

    public static func opacity(forCount count: Int, dim: Bool = false) -> Double {
        (0.62 + 0.1 * Double(min(count, 4))) * (dim ? 0.4 : 1)
    }

    public static let activeRingGrowth = 34.0
    public static let activeRingStroke = 15.0
    public static let failureRingGrowth = 16.0
    public static let failureRingStroke = 18.0

    /// The height a glyph of this width is drawn at.
    public static func height(forWidth width: Double) -> Double {
        (width * viewBox.height / viewBox.width).rounded()
    }
}

/// The colours the small head wears away from the app, in numbers, so a SwiftUI widget and a UIKit
/// notification face paint the same one. They are the system's own greens, oranges and reds,
/// because the Lock Screen, the island and a notification are drawn by processes that never see
/// the app's theme, and the zone inks follow the mock's matrix palette.
public enum NeuralGlyphColors {
    public struct RGBA: Sendable, Equatable {
        public let red: Double
        public let green: Double
        public let blue: Double
        public let alpha: Double

        public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        /// `#rrggbb`, or nil for anything that is not exactly that.
        public init?(hex: String) {
            guard let valid = NeuralGlyphWire.validHex(hex),
                let value = UInt32(valid.dropFirst(), radix: 16)
            else { return nil }
            self.init(
                Double(value >> 16 & 0xff) / 255, Double(value >> 8 & 0xff) / 255,
                Double(value & 0xff) / 255)
        }
    }

    public static func live(dark: Bool) -> RGBA {
        dark ? RGBA(0.188, 0.820, 0.345) : RGBA(0.204, 0.780, 0.349)
    }

    public static func attention(dark: Bool) -> RGBA {
        dark ? RGBA(1.0, 0.624, 0.039) : RGBA(1.0, 0.584, 0.0)
    }

    public static func danger(dark: Bool) -> RGBA {
        dark ? RGBA(1.0, 0.271, 0.227) : RGBA(1.0, 0.231, 0.188)
    }

    public static func quiet(dark: Bool) -> RGBA {
        dark ? RGBA(1, 1, 1, 0.6) : RGBA(0, 0, 0, 0.5)
    }

    /// What the silhouette is filled with, and what outlines it.
    public static func panel(dark: Bool) -> RGBA {
        dark ? RGBA(0, 0, 0, 0.62) : RGBA(1, 1, 1, 0.9)
    }

    public static func stroke(dark: Bool) -> RGBA {
        dark ? RGBA(1, 1, 1, 0.88) : RGBA(0, 0, 0, 0.78)
    }

    public static func zone(_ ink: NeuralGlyphInk, dark: Bool) -> RGBA {
        switch ink {
        case .text: return dark ? RGBA(1, 1, 1, 0.92) : RGBA(0, 0, 0, 0.82)
        case .info: return RGBA(0.31, 0.74, 0.88)
        case .accent: return live(dark: dark)
        case .special: return RGBA(0.62, 0.50, 0.95)
        case .textDim: return dark ? RGBA(1, 1, 1, 0.55) : RGBA(0, 0, 0, 0.5)
        case .say: return RGBA(0.34, 0.82, 0.68)
        }
    }

    /// The eye's colour: the card's tone, or, for a turn that ended well, who answered.
    public static func eye(_ plan: NeuralGlyphPlan, dark: Bool) -> RGBA {
        switch plan.eyeTone {
        case .live: return live(dark: dark)
        case .attention: return attention(dark: dark)
        case .danger: return danger(dark: dark)
        case .quiet: return quiet(dark: dark)
        case .identity:
            return plan.hueHex(dark: dark).flatMap(RGBA.init(hex:)) ?? quiet(dark: dark)
        }
    }
}

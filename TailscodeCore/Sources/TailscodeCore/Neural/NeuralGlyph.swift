import Foundation

/// The head as data for the places it is drawn small, 28 to 46 pt: SwiftUI paths, Core Graphics
/// and cairo all draw the same outline, the same dots and the same eye. A dot stands for a zone
/// that has steps, grows with how many it has, and carries a ring where a step failed and was
/// never recovered, or where the work is now. Authored in the mock's `glyph()` (`engine.js`).
public struct NeuralGlyph: Sendable, Equatable {
    public struct Ring: Sendable, Equatable {
        public let radius: Double
        public let strokeWidth: Double
    }

    public struct Dot: Sendable, Equatable {
        public let zone: NeuralZone
        public let center: NeuralPoint
        public let radius: Double
        public let opacity: Double
        /// How many steps the zone holds.
        public let count: Int
        /// The ring on the zone where the work is now.
        public let activeRing: Ring?
        /// The ring on a zone with a failure nobody recovered.
        public let failureRing: Ring?
        /// The zone of the turn's last step while it is live: its dot may breathe.
        public let isLive: Bool
    }

    public struct Halo: Sendable, Equatable {
        public let center: NeuralPoint
        public let radius: Double
        public let opacity: Double
    }

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

    public static let eyeHalo = Halo(center: NeuralPoint(586, 216), radius: 46, opacity: 0.28)

    /// The zones' draw order: the five working zones, then the jaw.
    public static let zoneOrder: [NeuralZone] = [.think, .sense, .act, .shell, .delegate, .say]

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

    public let dots: [Dot]
    /// What the eye bar and its halo wear.
    public let eyeTone: NeuralTone

    /// `live` marks the zone of the last step as breathing; `dim` is a glyph in a row that is
    /// not the turn being looked at.
    public init(
        steps: [NeuralStep], eyeTone: NeuralTone, activeZone: NeuralZone? = nil, live: Bool = false,
        dim: Bool = false
    ) {
        var counts = [Int](repeating: 0, count: NeuralZone.allCases.count)
        var failed = [Bool](repeating: false, count: NeuralZone.allCases.count)
        for step in steps {
            counts[step.zone.rawValue] += 1
            if step.status == .failed && !step.recovered { failed[step.zone.rawValue] = true }
        }
        let lastZone = steps.last?.zone
        var dots: [Dot] = []
        for zone in Self.zoneOrder {
            let count = counts[zone.rawValue]
            guard count > 0 else { continue }
            let radius = Self.radius(forCount: count)
            dots.append(
                Dot(
                    zone: zone, center: zone.center, radius: radius,
                    opacity: Self.opacity(forCount: count, dim: dim), count: count,
                    activeRing: activeZone == zone
                        ? Ring(
                            radius: radius + Self.activeRingGrowth,
                            strokeWidth: Self.activeRingStroke) : nil,
                    failureRing: failed[zone.rawValue]
                        ? Ring(
                            radius: radius + Self.failureRingGrowth,
                            strokeWidth: Self.failureRingStroke) : nil,
                    isLive: live && lastZone == zone))
        }
        self.dots = dots
        self.eyeTone = eyeTone
    }
}

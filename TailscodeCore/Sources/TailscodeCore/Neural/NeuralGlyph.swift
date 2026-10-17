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
    public static let viewBox = NeuralGlyphGeometry.viewBox

    /// The head's silhouette, closed, in design space.
    public static let outline: [NeuralPoint] = NeuralGlyphGeometry.outline

    /// The eye bar, closed.
    public static let eyeBar: [NeuralPoint] = NeuralGlyphGeometry.eyeBar

    public static let eyeHalo = Halo(
        center: NeuralGlyphGeometry.eyeHaloCenter, radius: NeuralGlyphGeometry.eyeHaloRadius,
        opacity: NeuralGlyphGeometry.eyeHaloOpacity)

    /// The zones' draw order: the five working zones, then the jaw.
    public static let zoneOrder: [NeuralZone] = [.think, .sense, .act, .shell, .delegate, .say]

    public static func radius(forCount count: Int) -> Double {
        NeuralGlyphGeometry.radius(forCount: count)
    }

    public static func opacity(forCount count: Int, dim: Bool = false) -> Double {
        NeuralGlyphGeometry.opacity(forCount: count, dim: dim)
    }

    public static let activeRingGrowth = NeuralGlyphGeometry.activeRingGrowth
    public static let activeRingStroke = NeuralGlyphGeometry.activeRingStroke
    public static let failureRingGrowth = NeuralGlyphGeometry.failureRingGrowth
    public static let failureRingStroke = NeuralGlyphGeometry.failureRingStroke

    /// The height a glyph of this width is drawn at.
    public static func height(forWidth width: Double) -> Double {
        NeuralGlyphGeometry.height(forWidth: width)
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
        let plan = NeuralGlyphCounts(steps).plan(
            eyeTone: eyeTone, active: activeZone, live: live ? steps.last?.zone : nil, dim: dim)
        self.dots = plan.dots.compactMap { dot in
            guard let zone = NeuralZone(rawValue: dot.zone) else { return nil }
            return Dot(
                zone: zone, center: dot.center, radius: dot.radius, opacity: dot.opacity,
                count: dot.count,
                activeRing: dot.activeRing.map {
                    Ring(radius: $0.radius, strokeWidth: $0.strokeWidth)
                },
                failureRing: dot.failureRing.map {
                    Ring(radius: $0.radius, strokeWidth: $0.strokeWidth)
                },
                isLive: dot.isLive)
        }
        self.eyeTone = eyeTone
    }
}

import Foundation

/// What a small drawing of the head needs, as counts and names rather than steps: how many steps
/// each zone holds, which zones failed and were never put right, where the work is now, and what
/// the eye wears.
///
/// A Live Activity's content state and a notification's `userInfo` carry this, so the Lock Screen,
/// the Dynamic Island, the notification's face and its long look draw the turn's head without the
/// transcript. Every field is optional on the wire and every one is additive: a server that sends
/// none of them still gets a head, with only an eye in the tone the card already carries. Only
/// Foundation is imported, because the widget and both notification extensions compile this file
/// by path.
public struct NeuralGlyphWire: Codable, Sendable, Hashable {
    /// Steps per zone in zone order: think, sense, act, shell, delegate, say. A list of any other
    /// length is not a glyph's.
    public var zones: [Int]
    /// A bit per zone (think is bit 0) with a failure nobody recovered.
    public var failed: Int?
    /// The zone index carrying the ring where the work is, or where it stopped.
    public var active: Int?
    /// The eye's tone, a `NeuralTone` raw value; absent reads as quiet.
    public var eye: String?
    /// The family's hue as `#rrggbb` for a dark ground, worn by an eye whose tone is `identity`.
    public var hue: String?
    /// The same family's hue for a light ground.
    public var hueLight: String?
    /// How many of the sense zone's calls were file reads; the rest searched.
    public var reads: Int?
    /// How many distinct files the act zone wrote, where that is fewer than its calls.
    public var files: Int?

    public init(
        zones: [Int], failed: Int? = nil, active: Int? = nil, eye: String? = nil,
        hue: String? = nil, hueLight: String? = nil, reads: Int? = nil, files: Int? = nil
    ) {
        self.zones = zones
        self.failed = failed
        self.active = active
        self.eye = eye
        self.hue = hue
        self.hueLight = hueLight
        self.reads = reads
        self.files = files
    }

    /// Whether the counts are a glyph's: one per zone, none negative.
    public var isDrawable: Bool {
        zones.count == NeuralGlyphGeometry.zoneCount && zones.allSatisfy { $0 >= 0 }
    }

    /// Every step the turn took.
    public var steps: Int { isDrawable ? zones.reduce(0, +) : 0 }

    public var eyeTone: NeuralTone { eye.flatMap(NeuralTone.init(rawValue:)) ?? .quiet }

    /// Whether the zone at `index` holds a failure nobody recovered.
    public func hasFailure(inZone index: Int) -> Bool {
        guard let failed, (0..<NeuralGlyphGeometry.zoneCount).contains(index) else { return false }
        return failed >> index & 1 == 1
    }

    /// The hue an identity eye wears on the given ground, if the sender gave one that reads.
    public func hueHex(dark: Bool) -> String? {
        let candidate = dark ? hue ?? hueLight : hueLight ?? hue
        return candidate.flatMap(Self.validHex)
    }

    /// `#rrggbb` as sent, or nil for anything a drawing should not trust.
    public static func validHex(_ text: String) -> String? {
        guard text.count == 7, text.first == "#",
            text.dropFirst().allSatisfy({ $0.isHexDigit })
        else { return nil }
        return text.lowercased()
    }

    /// The same head when something other than a transcript decided how the turn ended (a send
    /// that never left, a server's own failure): the counts stay as they were, the eye wears the
    /// new tone and no zone is ringed, because the work is no longer anywhere.
    public func retoned(_ tone: NeuralTone) -> NeuralGlyphWire {
        var copy = self
        copy.eye = tone.rawValue
        copy.active = nil
        copy.hue = nil
        copy.hueLight = nil
        return copy
    }

    /// What to draw, or nil for a glyph whose counts are not one per zone, which is drawn as the
    /// plain head.
    public func plan(dim: Bool = false) -> NeuralGlyphPlan? {
        guard isDrawable else { return nil }
        return NeuralGlyphPlan(
            counts: zones, failed: failed ?? 0, active: active, eyeTone: eyeTone,
            hue: hue, hueLight: hueLight, dim: dim)
    }
}

/// A head ready to draw, in the primitives every renderer shares: the silhouette, a dot per zone
/// that has steps with the rings it wears, and an eye. SwiftUI paths, Core Graphics and cairo all
/// read this and add only colour, so no client re-derives a radius or an opacity.
public struct NeuralGlyphPlan: Sendable, Equatable {
    public struct Ring: Sendable, Equatable {
        public let radius: Double
        public let strokeWidth: Double
    }

    public struct Dot: Sendable, Equatable {
        /// The zone's index: think, sense, act, shell, delegate, say.
        public let zone: Int
        public let center: NeuralPoint
        public let radius: Double
        public let opacity: Double
        /// How many steps the zone holds.
        public let count: Int
        public let ink: NeuralGlyphInk
        /// The ring on the zone where the work is now.
        public let activeRing: Ring?
        /// The ring on a zone with a failure nobody recovered.
        public let failureRing: Ring?
        /// The zone of the turn's last step while it is live: its dot may breathe.
        public let isLive: Bool
    }

    public let dots: [Dot]
    public let eyeTone: NeuralTone
    public let hue: String?
    public let hueLight: String?

    /// - Parameters:
    ///   - counts: steps per zone, one per zone.
    ///   - failed: a bit per zone with a failure nobody recovered.
    ///   - active: the zone carrying the ring where the work is.
    ///   - live: the zone of the last step while the turn runs.
    ///   - dim: a glyph in a row that is not the turn being looked at.
    public init(
        counts: [Int], failed: Int = 0, active: Int? = nil, live: Int? = nil,
        eyeTone: NeuralTone, hue: String? = nil, hueLight: String? = nil, dim: Bool = false
    ) {
        var dots: [Dot] = []
        for zone in NeuralGlyphGeometry.zoneOrder where counts.indices.contains(zone) {
            let count = counts[zone]
            guard count > 0 else { continue }
            let radius = NeuralGlyphGeometry.radius(forCount: count)
            dots.append(
                Dot(
                    zone: zone, center: NeuralGlyphGeometry.zoneCenters[zone], radius: radius,
                    opacity: NeuralGlyphGeometry.opacity(forCount: count, dim: dim), count: count,
                    ink: NeuralGlyphGeometry.zoneInks[zone],
                    activeRing: active == zone
                        ? Ring(
                            radius: radius + NeuralGlyphGeometry.activeRingGrowth,
                            strokeWidth: NeuralGlyphGeometry.activeRingStroke) : nil,
                    failureRing: failed >> zone & 1 == 1
                        ? Ring(
                            radius: radius + NeuralGlyphGeometry.failureRingGrowth,
                            strokeWidth: NeuralGlyphGeometry.failureRingStroke) : nil,
                    isLive: live == zone))
        }
        self.dots = dots
        self.eyeTone = eyeTone
        self.hue = hue
        self.hueLight = hueLight
    }

    /// The plain head: the silhouette and an eye, for a card whose sender sent no counts.
    public static func plain(eyeTone: NeuralTone) -> NeuralGlyphPlan {
        NeuralGlyphPlan(
            counts: [Int](repeating: 0, count: NeuralGlyphGeometry.zoneCount), eyeTone: eyeTone)
    }

    /// The hue an identity eye wears on the given ground.
    public func hueHex(dark: Bool) -> String? {
        let candidate = dark ? hue ?? hueLight : hueLight ?? hue
        return candidate.flatMap(NeuralGlyphWire.validHex)
    }
}

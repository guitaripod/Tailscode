import Foundation

/// The picture a tailnet scan makes while it runs, as arithmetic rather than as drawing.
///
/// Looking for servers is a wait with nothing to read, and a spinner says only that something is
/// happening. A radar says what is happening: the sweep is the probe going round, each ring is a
/// distance, and every machine that answers takes a place on the dial and stays there. So the
/// picture is the progress bar, and it is worth watching.
///
/// Toolkit-free on purpose, like every other moving thing here: this file decides where the sweep
/// is and how bright each blip is at an absolute time, and a client's painter only rasterises the
/// numbers. Three desks then draw the same scan at the same speed rather than three animations
/// that merely resemble each other.
public enum RadarTone: String, Sendable, Equatable, CaseIterable {
    /// An agent answered and needs nothing to connect.
    case ready
    /// Something answered and wants a password.
    case locked
    /// A machine worth asking that has not answered yet.
    case pending
}

/// One machine's fixed place on the dial. The angle and radius come from its name, so a rescan
/// puts the same machine back where the reader last saw it rather than shuffling the sky.
public struct RadarBlip: Sendable, Equatable {
    public let key: String
    public let tone: RadarTone
    public let bornAt: TimeInterval

    public init(key: String, tone: RadarTone, bornAt: TimeInterval) {
        self.key = key
        self.tone = tone
        self.bornAt = bornAt
    }

    public var angle: Double { TailnetRadar.angle(for: key) }
    public var radius: Double { TailnetRadar.radius(for: key) }
}

/// A blip as one frame wants it drawn: where it is, how bright, and how big.
public struct RadarSpark: Sendable, Equatable {
    public let angle: Double
    public let radius: Double
    public let light: Double
    public let scale: Double
    public let tone: RadarTone

    public init(angle: Double, radius: Double, light: Double, scale: Double, tone: RadarTone) {
        self.angle = angle
        self.radius = radius
        self.light = light
        self.scale = scale
        self.tone = tone
    }
}

/// Everything one frame of the dial needs. A painter reads this and nothing else.
public struct RadarFrame: Sendable, Equatable {
    public let sweep: Double
    public let sweepLight: Double
    /// The ring travelling outward under the sweep, as a radius in `0...1` and its own fade. A
    /// scan that has stopped has no ping, and its light is zero.
    public let ping: Double
    public let pingLight: Double
    public let sparks: [RadarSpark]
    /// True when nothing in this frame will differ from the next one, which is a client's cue to
    /// stop its clock rather than repaint a finished picture sixty times a second.
    public let settled: Bool

    public init(
        sweep: Double, sweepLight: Double, ping: Double, pingLight: Double, sparks: [RadarSpark],
        settled: Bool
    ) {
        self.sweep = sweep
        self.sweepLight = sweepLight
        self.ping = ping
        self.pingLight = pingLight
        self.sparks = sparks
        self.settled = settled
    }
}

public enum TailnetRadar {
    /// One lap of the sweep. Slow enough to read as a search rather than a spinner, fast enough
    /// that a machine found just behind the arm lights within a couple of seconds.
    public static let sweepPeriod: TimeInterval = 2.6
    public static let pingPeriod: TimeInterval = 2.6
    /// The fixed rings, as fractions of the dial's radius.
    public static let rings: [Double] = [0.34, 0.64, 0.94]
    /// How long a newly found machine takes to settle into its place.
    public static let entry: TimeInterval = 0.55
    /// How bright a machine stays between passes of the sweep. A blip that went dark would read
    /// as a server that came and went.
    public static let rest: Double = 0.46
    /// How quickly the sweep's wake fades behind the arm, in radians.
    public static let wake: Double = 1.5
    public static let innerRadius: Double = 0.40
    public static let outerRadius: Double = 0.94

    /// Where a machine sits on the dial: stable in its name, so the same tailnet always draws the
    /// same constellation.
    public static func angle(for key: String) -> Double {
        Double(hash(key) % 3600) / 3600 * 2 * Double.pi
    }

    public static func radius(for key: String) -> Double {
        let span = outerRadius - innerRadius
        return innerRadius + Double((hash(key) / 3600) % 1000) / 1000 * span
    }

    /// One frame of the dial at an absolute time.
    ///
    /// - Parameter scanning: whether probes are still out. A finished scan holds the arm still and
    ///   every machine it found at full light — the picture is then a result, not an animation.
    /// - Parameter reducedMotion: the desk asked for no movement, so the dial is drawn at rest
    ///   with everything it knows already visible. Nothing is hidden by taking the motion away.
    public static func frame(
        at time: TimeInterval, blips: [RadarBlip], scanning: Bool, reducedMotion: Bool = false
    ) -> RadarFrame {
        guard scanning, !reducedMotion else {
            return RadarFrame(
                sweep: 0, sweepLight: 0, ping: 0, pingLight: 0,
                sparks: blips.map {
                    RadarSpark(
                        angle: $0.angle, radius: $0.radius, light: 1, scale: 1, tone: $0.tone)
                },
                settled: true)
        }
        let sweep = 2 * Double.pi * fraction(time / sweepPeriod)
        let ping = fraction(time / pingPeriod)
        return RadarFrame(
            sweep: sweep,
            sweepLight: 1,
            ping: ping,
            pingLight: max(0, 1 - ping) * 0.5,
            sparks: blips.map { spark(for: $0, at: time, sweep: sweep) },
            settled: false)
    }

    /// A blip is brightest as the arm crosses it and fades behind it, which is the whole grammar
    /// of a radar — but never below `rest`, because the reader has already been told this machine
    /// is there and taking it away would be a lie told sixty times a second.
    private static func spark(for blip: RadarBlip, at time: TimeInterval, sweep: Double)
        -> RadarSpark
    {
        let behind = fraction((sweep - blip.angle) / (2 * Double.pi)) * 2 * Double.pi
        let lit = exp(-behind / wake)
        let age = max(0, time - blip.bornAt)
        let settling = min(1, age / entry)
        let scale = settling < 1 ? 0.4 + 1.1 * settling - 0.5 * settling * settling : 1
        return RadarSpark(
            angle: blip.angle, radius: blip.radius,
            light: min(1, rest + (1 - rest) * lit) * settling,
            scale: scale, tone: blip.tone)
    }

    private static func fraction(_ value: Double) -> Double {
        let wrapped = value - value.rounded(.down)
        return wrapped < 0 ? wrapped + 1 : wrapped
    }

    /// FNV-1a over the name's bytes. Any stable hash would do; `hashValue` would not — Swift
    /// seeds it per process, so the constellation would move every launch.
    private static func hash(_ key: String) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        return value
    }
}

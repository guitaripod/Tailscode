import Foundation

/// Whether the presence orb is on. Off by default and labeled alpha wherever it is offered: a
/// GPU that never rests is a cost somebody must choose, not a default they discover in a battery
/// graph. One key on every client, like the theme.
public enum PresenceOrbSetting {
    public static let defaultsKey = "tailscode.presenceOrb"
    public static let didChange = Notification.Name("tailscode.presenceOrb.didChange")

    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    public static func setEnabled(_ value: Bool) {
        if value {
            UserDefaults.standard.set(true, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// The tempo and proportions of the orb, in one place so the same creature lives on three desks.
///
/// The orbit and wobble periods are deliberately irrational against each other and against the
/// shared breath: cycles that divide evenly lock into a visible beat, and the orb reads as a
/// machine counting rather than something alive. The smoothing constants are the orb's manners —
/// a state may change in a frame, but the body that carries it always arrives.
public enum PresenceTuning {
    public static let maxSatellites = 6
    public static let orbitPeriod: TimeInterval = 11.3
    public static let wobblePeriod: TimeInterval = 5.7
    public static let wobbleDepth = 0.035
    public static let coreRadius = 0.30
    public static let satelliteRadius = 0.105
    public static let orbitRadius = 0.52
    public static let colorTime: TimeInterval = 0.9
    public static let formTime: TimeInterval = 0.55
    /// How lit an idle body is. Idle is a presence at rest, not an absence — but it must be dim
    /// enough that anything actually happening reads as an event.
    public static let idleEnergy = 0.32
    public static let settleThreshold = 0.004
}

/// A colour the simulation can do arithmetic on. Palettes speak hex and toolkits speak their own
/// colour types; the orb's smoothing needs plain channels in the middle.
public struct PresenceRGB: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init?(hex: String) {
        guard let channels = Contrast.channels(hex) else { return nil }
        self.init(red: channels.red, green: channels.green, blue: channels.blue)
    }

    func approached(_ target: PresenceRGB, by amount: Double) -> PresenceRGB {
        PresenceRGB(
            red: red + (target.red - red) * amount,
            green: green + (target.green - green) * amount,
            blue: blue + (target.blue - blue) * amount)
    }

    func distance(to other: PresenceRGB) -> Double {
        max(abs(red - other.red), max(abs(green - other.green), abs(blue - other.blue)))
    }
}

/// The four inks the orb may wear, resolved by the client from its palette (or the platform's own
/// colours under System) so the simulation never holds a hex. The slots are the shared tone
/// meanings and nothing else: the orb is an instrument, and an instrument with private colours
/// would be saying something the rest of the app is not.
public struct PresenceColors: Sendable, Equatable {
    public var live: PresenceRGB
    public var attention: PresenceRGB
    public var danger: PresenceRGB
    public var quiet: PresenceRGB

    public init(live: PresenceRGB, attention: PresenceRGB, danger: PresenceRGB, quiet: PresenceRGB)
    {
        self.live = live
        self.attention = attention
        self.danger = danger
        self.quiet = quiet
    }

    func ink(for tone: ActivityTone?) -> PresenceRGB {
        switch tone {
        case .live: return live
        case .attention: return attention
        case .danger: return danger
        case .quiet, nil: return quiet
        }
    }
}

/// What the orb is being asked to say: the whole of what this device watches, distilled to one
/// tone, one motion and a count. The reading is ruthless on purpose — a creature that tried to
/// show every session's state at once would show none of them.
public struct PresenceSignal: Sendable, Equatable {
    public var tone: ActivityTone?
    public var motion: ActivityMotion
    public var satellites: Int
    public var ultracode: Bool

    public init(
        tone: ActivityTone? = nil, motion: ActivityMotion = .still, satellites: Int = 0,
        ultracode: Bool = false
    ) {
        self.tone = tone
        self.motion = motion
        self.satellites = min(max(0, satellites), PresenceTuning.maxSatellites)
        self.ultracode = ultracode
    }

    /// The aggregate over every conversation, in the order a reader cares: a turn waiting on the
    /// person outranks everything and knocks; any work in flight breathes, wearing one satellite
    /// per open turn; a failure holds the danger colour perfectly still — a broken thing must
    /// never be animated into looking merely busy, or cute; an unreachable server rests quiet;
    /// and idle is a body at rest, not a body pretending to work.
    public static func aggregate(_ kinds: [ActivityKind?], ultracode: Bool = false)
        -> PresenceSignal
    {
        let present = kinds.compactMap { $0 }
        let inFlight = present.filter(\.isInFlight)
        if present.contains(where: \.wantsYou) {
            return PresenceSignal(
                tone: .attention, motion: .attention, satellites: inFlight.count,
                ultracode: ultracode)
        }
        if !inFlight.isEmpty {
            return PresenceSignal(
                tone: .live, motion: .working, satellites: inFlight.count, ultracode: ultracode)
        }
        if present.contains(.failed) {
            return PresenceSignal(tone: .danger, motion: .still, ultracode: ultracode)
        }
        if present.contains(.offline) {
            return PresenceSignal(tone: .quiet, motion: .still, ultracode: ultracode)
        }
        return PresenceSignal(ultracode: ultracode)
    }

    /// The sentence a screen reader says for the whole orb. Motion and colour are its entire
    /// vocabulary and both are invisible there, so the words carry everything.
    public var spoken: String {
        if tone == .attention { return Localized.text("A conversation needs you") }
        if satellites > 0 {
            return satellites == 1
                ? Localized.text("A conversation is working")
                : Localized.text("%@ conversations are working", "\(satellites)")
        }
        switch tone {
        case .danger: return Localized.text("The last turn failed")
        case .quiet: return Localized.text("A server is not answering")
        default: return Localized.text("Nothing is running")
        }
    }
}

/// One body at one instant, in the orb's own unit space: the centre at the origin, everything
/// inside a radius of one. The first blob is the core; the rest are satellites, weighted by how
/// far each has emerged. A renderer rasterises exactly this and adds nothing.
public struct PresenceFrame: Sendable, Equatable {
    public struct Blob: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var radius: Double
        public var weight: Double

        public init(x: Double, y: Double, radius: Double, weight: Double) {
            self.x = x
            self.y = y
            self.radius = radius
            self.weight = weight
        }
    }

    public var blobs: [Blob]
    public var color: PresenceRGB
    public var energy: Double
    public var intensity: Double
    public var rainbow: Double
    public var rainbowPhase: Double
    public var rainbowGlow: Double
    /// True once nothing in the frame can change without a new signal — the client's cue to draw
    /// this frame once and stop its clock, because stillness rendered sixty times a second is a
    /// fan spinning for a picture that is finished.
    public var settled: Bool

    public init(
        blobs: [Blob], color: PresenceRGB, energy: Double, intensity: Double, rainbow: Double,
        rainbowPhase: Double, rainbowGlow: Double, settled: Bool
    ) {
        self.blobs = blobs
        self.color = color
        self.energy = energy
        self.intensity = intensity
        self.rainbow = rainbow
        self.rainbowPhase = rainbowPhase
        self.rainbowGlow = rainbowGlow
        self.settled = settled
    }
}

/// The orb's whole behaviour, toolkit-free: a signal is a destination, and the field is the body
/// that travels there. Colour, energy, the emergence of each satellite and the rainbow's presence
/// all approach their targets on short time constants, evaluated from absolute time so a dropped
/// frame costs a frame and never the phase — and so three renderers given the same clock draw the
/// same creature.
public struct PresenceField: Sendable {
    public private(set) var signal: PresenceSignal
    private var colors: PresenceColors
    private var color: PresenceRGB
    private var energy: Double
    private var rainbow: Double
    private var weights: [Double]
    private var lastTime: TimeInterval?

    public init(colors: PresenceColors) {
        self.signal = PresenceSignal()
        self.colors = colors
        self.color = colors.ink(for: nil)
        self.energy = PresenceTuning.idleEnergy
        self.rainbow = 0
        self.weights = Array(repeating: 0, count: PresenceTuning.maxSatellites)
    }

    public mutating func set(signal: PresenceSignal) {
        self.signal = signal
    }

    /// A theme change swaps the inks and lets the body glide to them; the creature is not rebuilt
    /// because the walls were repainted.
    public mutating func set(colors: PresenceColors) {
        self.colors = colors
    }

    private var energyTarget: Double {
        switch signal.tone {
        case .live, .attention: return 1
        case .danger: return 0.62
        case .quiet: return 0.42
        case nil: return PresenceTuning.idleEnergy
        }
    }

    public mutating func frame(at time: TimeInterval, reduceMotion: Bool = false) -> PresenceFrame
    {
        let step = min(max(time - (lastTime ?? time), 0), 0.25)
        lastTime = time
        let colorAmount = approach(step, PresenceTuning.colorTime)
        let formAmount = approach(step, PresenceTuning.formTime)

        color = color.approached(colors.ink(for: signal.tone), by: colorAmount)
        energy += (energyTarget - energy) * formAmount
        rainbow += ((signal.ultracode ? 1.0 : 0.0) - rainbow) * formAmount
        for index in weights.indices {
            let target = index < signal.satellites ? 1.0 : 0.0
            weights[index] += (target - weights[index]) * formAmount
        }

        let motion = signal.motion.honoring(reduceMotion: reduceMotion)
        let moving = motion.isAnimated || (rainbow > PresenceTuning.settleThreshold && !reduceMotion)
        let settled =
            !moving
            && color.distance(to: colors.ink(for: signal.tone)) < PresenceTuning.settleThreshold
            && abs(energy - energyTarget) < PresenceTuning.settleThreshold
            && abs(rainbow - (signal.ultracode ? 1 : 0)) < PresenceTuning.settleThreshold
            && weightsSettled
        if settled {
            color = colors.ink(for: signal.tone)
            energy = energyTarget
            rainbow = signal.ultracode ? 1 : 0
            for index in weights.indices {
                weights[index] = index < signal.satellites ? 1 : 0
            }
        }

        let aura = Ultracode.aura(at: time)
        return PresenceFrame(
            blobs: blobs(at: moving ? time : 0),
            color: color,
            energy: energy,
            intensity: motion.intensity(at: time),
            rainbow: rainbow,
            rainbowPhase: aura.phase,
            rainbowGlow: aura.glow,
            settled: settled)
    }

    private var weightsSettled: Bool {
        for (index, weight) in weights.enumerated() {
            let target = index < signal.satellites ? 1.0 : 0.0
            if abs(weight - target) >= PresenceTuning.settleThreshold { return false }
        }
        return true
    }

    /// The core at the origin and each satellite on its own slow orbit. Angles come from the
    /// clock, spaced by the golden angle and drifting in alternating directions at slightly
    /// different rates, so the arrangement never repeats and never looks dealt from a template.
    /// A time of zero is the resting arrangement — what reduced motion and stillness show.
    private func blobs(at time: TimeInterval) -> [PresenceFrame.Blob] {
        var result = [
            PresenceFrame.Blob(x: 0, y: 0, radius: PresenceTuning.coreRadius, weight: 1)
        ]
        let golden = 2.399963229728653
        for (index, weight) in weights.enumerated() {
            guard weight > 0.001 else { continue }
            let direction: Double = index.isMultiple(of: 2) ? 1 : -1
            let rate = 1 + Double(index) * 0.13
            let angle =
                Double(index) * golden
                + direction * 2 * .pi * time * rate / PresenceTuning.orbitPeriod
            let wobble =
                time == 0
                ? 0
                : sin(2 * .pi * time / PresenceTuning.wobblePeriod + Double(index) * golden)
                    * PresenceTuning.wobbleDepth
            let reach = (PresenceTuning.orbitRadius + wobble) * weight
            result.append(
                PresenceFrame.Blob(
                    x: cos(angle) * reach,
                    y: sin(angle) * reach,
                    radius: PresenceTuning.satelliteRadius * weight,
                    weight: weight))
        }
        return result
    }

    /// The fraction of the remaining distance one step covers, from the time constant: an
    /// exponential approach, so arriving is smooth at every frame rate and immune to jitter.
    private func approach(_ step: TimeInterval, _ constant: TimeInterval) -> Double {
        1 - exp(-step / constant)
    }
}

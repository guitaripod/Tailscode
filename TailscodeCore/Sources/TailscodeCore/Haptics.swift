import Foundation

/// Every physical cue the app can give a hand, named by what it means rather than by what it
/// feels like. A cue is the unit a client asks for; how hard it lands is the user's setting, not
/// the call site's business — which is why no call site names an intensity.
public enum HapticCue: String, Sendable, CaseIterable, Codable {
    case tap
    case selection
    case step
    case send
    case received
    case needsYou
    case success
    case warning
    case error

    /// What a cue is for. Sending a prompt to a machine somewhere else means waiting, and the
    /// wait is where a phone in a pocket earns its haptics: the cues that report on a turn are
    /// the ones worth designing first, and they lead everywhere the cues are listed.
    public enum Group: String, Sendable, CaseIterable {
        case waiting
        case everyday
        case outcome

        public var title: String {
            switch self {
            case .waiting: return Localized.text("While you wait")
            case .everyday: return Localized.text("Touch")
            case .outcome: return Localized.text("Outcomes")
            }
        }

        public var cues: [HapticCue] {
            switch self {
            case .waiting: return [.send, .step, .needsYou, .received]
            case .everyday: return [.tap, .selection]
            case .outcome: return [.success, .warning, .error]
            }
        }
    }

    public var title: String {
        switch self {
        case .tap: return Localized.text("Tap")
        case .selection: return Localized.text("Selection")
        case .step: return Localized.text("Progress")
        case .send: return Localized.text("Sent")
        case .received: return Localized.text("Turn finished")
        case .needsYou: return Localized.text("Needs you")
        case .success: return Localized.text("Success")
        case .warning: return Localized.text("Warning")
        case .error: return Localized.text("Error")
        }
    }

    public var detail: String {
        switch self {
        case .tap: return Localized.text("Buttons and rows")
        case .selection: return Localized.text("Pickers, expanding, unfolding")
        case .step: return Localized.text("A step of the work lands while you wait")
        case .send: return Localized.text("Your message leaves and the wait begins")
        case .received: return Localized.text("The agent is done and it is your turn")
        case .needsYou: return Localized.text("The agent stopped to ask permission")
        case .success: return Localized.text("A thing worked")
        case .warning: return Localized.text("A thing wants a second look")
        case .error: return Localized.text("A thing failed")
        }
    }
}

/// One event inside a cue. `duration` of zero is a transient — the Taptic Engine's sharp crack;
/// anything longer is a continuous body that sustains under it. Layering the two is the only way
/// to exceed what a single canned impact can deliver: the crack gives the attack, the body gives
/// the mass, and two cracks a few milliseconds apart read as one heavier blow rather than two.
public struct HapticBeat: Sendable, Equatable {
    public let start: Double
    public let duration: Double
    public let intensity: Double
    public let sharpness: Double

    /// Below this setting the beat is dropped rather than merely quietened. A gentle setting
    /// should be a single light tick, not a scaled-down triple thump — reinforcement is what
    /// makes a cue heavy, so it is the first thing to go when the user asks for less.
    public let floor: Double

    public init(
        start: Double = 0, duration: Double = 0, intensity: Double, sharpness: Double,
        floor: Double = 0
    ) {
        self.start = start
        self.duration = duration
        self.intensity = intensity
        self.sharpness = sharpness
        self.floor = floor
    }

    public var isContinuous: Bool { duration > 0 }
}

/// What a cue is made of. Every one is written to be pleasant at the top of the slider rather
/// than as hard as the hardware can hit: a rounded body with a soft attack, at most one beat of
/// reinforcement, and sharpness kept low — a sharp, stacked pattern reads as an alarm, and none
/// of these are alarms. Volume is the user's dial; character is not.
public enum HapticRecipe {
    public static func beats(for cue: HapticCue) -> [HapticBeat] {
        switch cue {
        case .tap:
            return [HapticBeat(intensity: 0.6, sharpness: 0.35)]
        case .selection:
            return [HapticBeat(intensity: 0.45, sharpness: 0.5)]
        case .step:
            return [HapticBeat(intensity: 0.34, sharpness: 0.25)]
        case .send:
            return [
                HapticBeat(duration: 0.05, intensity: 0.45, sharpness: 0.12),
                HapticBeat(intensity: 0.62, sharpness: 0.4),
            ]
        case .received:
            return [
                HapticBeat(duration: 0.12, intensity: 0.5, sharpness: 0.05),
                HapticBeat(start: 0.07, intensity: 0.6, sharpness: 0.3, floor: 0.2),
            ]
        case .needsYou:
            return [
                HapticBeat(intensity: 0.5, sharpness: 0.28),
                HapticBeat(start: 0.12, intensity: 0.62, sharpness: 0.32, floor: 0.2),
            ]
        case .success:
            return [
                HapticBeat(intensity: 0.48, sharpness: 0.25),
                HapticBeat(start: 0.085, intensity: 0.62, sharpness: 0.4, floor: 0.2),
            ]
        case .warning:
            return [
                HapticBeat(intensity: 0.55, sharpness: 0.22),
                HapticBeat(start: 0.13, intensity: 0.5, sharpness: 0.22, floor: 0.25),
            ]
        case .error:
            return [
                HapticBeat(duration: 0.13, intensity: 0.55, sharpness: 0.08),
                HapticBeat(intensity: 0.6, sharpness: 0.35),
                HapticBeat(start: 0.1, intensity: 0.55, sharpness: 0.3, floor: 0.3),
            ]
        }
    }

    /// The shortest gap between two of the same cue. A turn can complete a dozen tool calls in a
    /// second, and a tick per completion is a rattle rather than a report — the wait should be
    /// felt as progress, not as noise.
    public static func minimumGap(for cue: HapticCue) -> Double {
        switch cue {
        case .step: return 0.5
        case .selection, .tap: return 0.03
        default: return 0.08
        }
    }

    /// The cue as it should be played at this setting: reinforcement below its floor is dropped,
    /// what survives is driven by `HapticStrength.drive`, and an empty result means silence.
    public static func scaled(_ cue: HapticCue, strength: Double) -> [HapticBeat] {
        guard strength > HapticStrength.silence else { return [] }
        let drive = HapticStrength.drive(strength)
        return beats(for: cue).compactMap { beat in
            guard strength >= beat.floor else { return nil }
            return HapticBeat(
                start: beat.start, duration: beat.duration,
                intensity: min(1, beat.intensity * drive), sharpness: beat.sharpness,
                floor: beat.floor)
        }
    }
}

/// How hard the phone is allowed to hit, as one number the user owns.
public enum HapticStrength {
    public static let range: ClosedRange<Double> = 0...1
    /// Full power out of the box: the point of the setting is to be dialled down from the
    /// hardware's ceiling, not up towards it from a timid default.
    public static let standard: Double = 1
    /// Anything at or under this is off — a slider dragged to the end must be silent, not a
    /// whisper too faint to notice but still costing a Taptic Engine start.
    public static let silence: Double = 0.02

    public static func clamped(_ value: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, value.isFinite ? value : standard))
    }

    /// Amplitude is perceived compressively and the Taptic Engine's bottom quarter is barely
    /// felt at all, so a linear slider would spend most of its travel on nothing. The curve
    /// starts where sensation starts and bends so the middle of the slider feels like a middle.
    public static func drive(_ strength: Double) -> Double {
        let value = clamped(strength)
        guard value > silence else { return 0 }
        return 0.28 + 0.72 * pow(value, 1.25)
    }

    public static func label(_ strength: Double) -> String {
        let value = clamped(strength)
        switch value {
        case ...silence: return Localized.text("Off")
        case ...0.2: return Localized.text("Whisper")
        case ...0.4: return Localized.text("Light")
        case ...0.62: return Localized.text("Firm")
        case ...0.85: return Localized.text("Strong")
        default: return Localized.text("Max")
        }
    }

    public static func percent(_ strength: Double) -> Int {
        Int((clamped(strength) * 100).rounded())
    }

    /// The named stops. `Max` is not a euphemism — it is every beat the recipe has at the
    /// hardware's ceiling, which is what someone who wants to feel it through a pocket asks for.
    public static let presets: [(title: String, value: Double)] = [
        (Localized.text("Subtle"), 0.3),
        (Localized.text("Firm"), 0.6),
        (Localized.text("Strong"), 0.85),
        (Localized.text("Max"), 1.0),
    ]

    /// The step a keyboard or an accessibility gesture moves by.
    public static let step: Double = 0.05
}

/// What a client without Core Haptics can do instead, named toolkit-free. A device that cannot
/// compose events still has canned impacts, and a cue that falls back has to keep its meaning —
/// a send stays heavier than a tap — even though its strength can then only be approximated.
public enum HapticFallback: Sendable, Equatable {
    case impact(style: Style, intensity: Double)
    case selection
    case notification(Notification)

    public enum Style: Sendable, Equatable {
        case light, medium, heavy, soft, rigid
    }

    public enum Notification: Sendable, Equatable {
        case success, warning, error
    }

    public static func of(_ cue: HapticCue, strength: Double) -> HapticFallback? {
        guard strength > HapticStrength.silence else { return nil }
        let drive = HapticStrength.drive(strength)
        switch cue {
        case .tap: return .impact(style: .light, intensity: drive * 0.85)
        case .selection: return .selection
        case .step: return .impact(style: .soft, intensity: drive * 0.5)
        case .send: return .impact(style: .medium, intensity: drive * 0.85)
        case .received: return .impact(style: .soft, intensity: drive)
        case .needsYou: return .notification(.warning)
        case .success: return .notification(.success)
        case .warning: return .notification(.warning)
        case .error: return .notification(.error)
        }
    }
}

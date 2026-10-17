import Foundation

extension NeuralFrame {
    /// How long one crunch takes, in and out.
    public static let crunchPeriod: TimeInterval = 2.6

    /// Where a reduced-motion compaction is held: halfway in.
    static let reducedCrunch: Float = 0.5

    /// Every number a renderer reads for one instant, a faithful port of `frameFor()` and of the
    /// page logic around it in the browser mock (`hero2.js`, `f.js`). Pure and allocation-free
    /// beyond the arrays the result carries.
    ///
    /// `hover` lights one zone and steps the rest back, and `provenance` lights the zones that
    /// hold a quoted step and dims the others; both are for a head at rest, since a head that is
    /// breathing is showing where the work is. Reduced motion holds every state still in its own
    /// tone: no breath, beat, sweep, ripple or ear animation, and a compaction held halfway.
    public static func at(
        time: TimeInterval, state: NeuralState, face: NeuralFace = .unknown,
        meters: NeuralMeters = .none, reduceMotion: Bool = false, hover: NeuralZone? = nil,
        provenance: Set<NeuralZone>? = nil
    ) -> NeuralFrame {
        var frame = NeuralFrame()
        frame.effort = Float(face.effort)
        frame.hollow = face.hollow
        frame.rainbow = face.rainbow
        frame.ribs = meters.ribs

        let motion = state.motion.honoring(reduceMotion: reduceMotion)
        let level = Float(motion.level(at: time))
        let stateTone: NeuralTone = state.tone == .identity ? .quiet : state.tone
        frame.sweepTone = stateTone
        let earAnimated = meters.call.map { !reduceMotion && $0.motion.isAnimated } ?? false
        let animated = state.isAnimated(reduceMotion: reduceMotion)
        frame.settled = !animated && !earAnimated

        if case .dark = state.effect {
            for index in 0..<NeuralChannel.count { frame.intensity[index] = 0.05 }
            frame.intensity[eye] = 0
            frame.intensity[seam] = 0.06
            return frame
        }

        if case .dim(let dim) = state.effect {
            for index in 0..<zones { frame.intensity[index] = dim }
            frame.intensity[link] = dim
            frame.intensity[eye] = 0.35
            frame.toneOverride[eye] = stateTone
        }

        if let zone = state.zone {
            for index in 0..<zones { frame.intensity[index] = 0.3 }
            frame.intensity[zone.rawValue] = motion == .still ? 1.0 : 0.5 + 0.85 * level
            if state.tone != .live { frame.toneOverride[zone.rawValue] = stateTone }
            frame.intensity[link] = 0.7
        }

        if state.tone != .identity { frame.toneOverride[eye] = stateTone }
        frame.intensity[eye] = eyeIntensity(state: state, motion: motion, level: level)

        if state.failure, let zone = state.zone {
            for index in 0..<zones { frame.intensity[index] = 0.1 }
            frame.intensity[link] = 0.2
            frame.intensity[star] = 0.3
            frame.intensity[zone.rawValue] = 0.9
            frame.toneOverride[zone.rawValue] = stateTone
            frame.intensity[seam] = 0.15
        }

        if motion == .sweep {
            frame.sweep = Float(motion.sweepPhase(at: time))
            frame.sweepAmount = state.tone == .quiet ? 0.5 : (state.effect.isDim ? 0.55 : 0.9)
        }

        var crunch: Float = 0
        if state.effect == .crunch {
            crunch = reduceMotion ? reducedCrunch : crunchLevel(at: time)
            frame.crunch = crunch
            frame.intensity[seam] = 0.3 + 0.7 * crunch
        }

        if state.effect == .orbit {
            frame.orbit = true
            for index in 0..<zones { frame.intensity[index] = 0.28 }
        }

        if state.wearsIdentity {
            frame.toneOverride[eye] = .identity
            frame.intensity[eye] = 1
        }

        frame.toneOverride[rib] = meters.contextTone
        frame.intensity[rib] = meters.isEstimate ? 0.5 : 1
        if state.effect == .crunch { frame.ribs = meters.ribs * (1 - 0.55 * crunch) }

        if let ear = meters.call {
            frame.toneOverride[self.ear] = ear.tone
            frame.intensity[self.ear] = earIntensity(ear, time: time, reduceMotion: reduceMotion)
        }
        frame.intensity[visor] = 0.25

        if let zone = state.zone, state.tone == .live, motion != .still {
            frame.ripple = 1
            frame.active = zone.center
        }

        if !animated {
            if let hover { emphasise(hover: hover, in: &frame) }
            if let provenance { emphasise(provenance: provenance, in: &frame) }
        }
        return frame
    }

    private static let zones = NeuralZone.allCases.count
    private static let link = NeuralChannel.link.rawValue
    private static let star = NeuralChannel.star.rawValue
    private static let seam = NeuralChannel.seam.rawValue
    private static let eye = NeuralChannel.eye.rawValue
    private static let rib = NeuralChannel.rib.rawValue
    private static let ear = NeuralChannel.ear.rawValue
    private static let visor = NeuralChannel.visor.rawValue

    /// The compaction's crunch: a cosine in and out, zero at the start of each period.
    static func crunchLevel(at time: TimeInterval) -> Float {
        let turns = time / crunchPeriod
        let phase = turns - turns.rounded(.down)
        return Float(0.5 - 0.5 * cos(2 * Double.pi * phase))
    }

    /// A state with a tone lets the eye carry it; one at rest in the quiet tone has the eye held
    /// back; a held state is fully lit and a moving one rides the motion.
    private static func eyeIntensity(state: NeuralState, motion: NeuralMotion, level: Float) -> Float
    {
        if state.effect.isDim { return 0.35 }
        if state.tone == .quiet { return 0.4 }
        return motion == .still ? 1 : 0.35 + 0.65 * level
    }

    private static func earIntensity(
        _ ear: NeuralMeters.Ear, time: TimeInterval, reduceMotion: Bool
    ) -> Float {
        guard !reduceMotion else { return 1 }
        switch ear.motion {
        case .breath: return Float(0.2 + 0.9 * NeuralMotion.breathLevel(at: time))
        case .sweep: return Float(0.2 + 0.7 * (0.5 + 0.5 * sin(time * 6)))
        case .heartbeat, .still: return 1
        }
    }

    private static func emphasise(hover: NeuralZone, in frame: inout NeuralFrame) {
        for index in 0..<zones { frame.intensity[index] = 0.3 }
        frame.intensity[hover.rawValue] = 1.2
        frame.intensity[link] = 0.6
    }

    private static func emphasise(provenance: Set<NeuralZone>, in frame: inout NeuralFrame) {
        for zone in NeuralZone.allCases {
            frame.intensity[zone.rawValue] = provenance.contains(zone) ? 1.15 : 0.22
        }
        frame.intensity[link] = 0.5
    }
}

extension NeuralEffect {
    var isDim: Bool {
        if case .dim = self { return true }
        return false
    }
}

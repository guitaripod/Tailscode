import Foundation

/// Which hand writes the answer.
///
/// The cascade is one effect with two rasterisers, not two effects. `StreamCascade` decides what a
/// glyph at a given distance behind the leading edge is worth — its heat, the specular band over
/// it, how far it has entered — and both renderers spend exactly those numbers. What differs is
/// where the arithmetic is done and therefore what it is allowed to cost: the settled renderer
/// re-tints twenty-six characters of an attributed string on the main thread every frame, which
/// bounds the effect to a colour per glyph and nothing else, while the alpha renderer hands the
/// same glyphs to the GPU as geometry and can afford a per-glyph transform, light that leaves the
/// letterform, and a leading edge that is a nib rather than a boundary.
///
/// It is a choice rather than an upgrade because the two are honestly different trades, and the
/// person reading answers all day is the one who should make it. Alpha means the pipeline is new
/// and the surfaces it does not cover yet fall back rather than break.
public enum StreamRenderer: String, CaseIterable, Sendable {
    /// Colour on an attributed string, painted by the platform's own text stack. Every glyph the
    /// app can render, every accessibility affordance, no GPU.
    case classic
    /// The same wave rasterised by a shader over per-glyph geometry, on the display's own clock.
    case aurora

    public static let `default` = StreamRenderer.classic

    public var title: String {
        switch self {
        case .classic: return Localized.text("Classic")
        case .aurora: return Localized.text("Aurora")
        }
    }

    /// One line, for a row that has no room to argue.
    public var summary: String {
        switch self {
        case .classic:
            return Localized.text("A colour wave over the words, painted by the text system")
        case .aurora:
            return Localized.text("The same wave on the GPU — ink that lands, light that spills")
        }
    }

    /// The whole case, for the screen that exists to be read before the switch is thrown.
    public var detail: String {
        switch self {
        case .classic:
            return Localized.text(
                "The leading edge of the answer is warmed toward the accent and a specular band travels back through it, one colour per character. It costs nothing but the tint, works on every device, and is what every answer has been written with until now."
            )
        case .aurora:
            return Localized.text(
                "Every character near the edge becomes its own piece of geometry on the GPU. Ink lands rather than appears — each glyph settles the last fraction of its own height, prisms apart into colour and back, and sheds a little light onto the page around it. A nib rides the leading edge so the answer reads as something being written rather than something being uncovered. Frames come from the display's own clock at up to 120Hz, and the work per frame is one buffer of uniforms, not one pass over the text."
            )
        }
    }

    /// What a reader who gets no picture is told.
    public var spoken: String {
        switch self {
        case .classic: return Localized.text("Classic reveal, painted by the text system")
        case .aurora: return Localized.text("Aurora reveal, rendered on the graphics processor")
        }
    }

    public var isAlpha: Bool { self == .aurora }
}

/// Which renderer this device writes with. One key, like the theme, so a client that grows the
/// pipeline later reads the same answer rather than inventing a second switch.
///
/// Classic is the stored absence: a device that has never been asked, and a device that turned the
/// alpha renderer back off, are the same device, and neither should carry a key saying so.
public enum StreamRendererSetting {
    public static let defaultsKey = "tailscode.streamRenderer"
    public static let didChange = Notification.Name("tailscode.streamRenderer.didChange")

    public static var choice: StreamRenderer {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
            let choice = StreamRenderer(rawValue: raw)
        else { return .default }
        return choice
    }

    public static var isAurora: Bool { choice == .aurora }

    public static func set(_ choice: StreamRenderer) {
        if choice == .default {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(choice.rawValue, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// The sentence both hands write on the screen where one of them is chosen, and exactly when each
/// piece of it lands.
///
/// It is a script rather than a timer because the two previews have to be comparable: the same
/// characters at the same moments, or the difference a reader sees is the schedule rather than the
/// hand. And it is a script with a *stall* in it on purpose — a real turn stops to run something,
/// and the whole reason the transcript holds a buffer is what happens to the reveal when it does.
/// A demonstration that only ever showed text arriving smoothly would be showing the easy half.
public enum StreamRendererDemo {
    public static let text = Localized.text(
        "Held in a buffer and played back out at a speed that changes slowly — so a model that stops to **think** reads as a hand slowing, never as a dropped frame."
    )

    /// Seconds from the start of the loop, and how many characters have arrived by then. The gaps
    /// are uneven and one of them is long, because that is what a stream looks like.
    public static let beats: [(at: Double, characters: Int)] = [
        (0.10, 14), (0.28, 31), (0.44, 39), (0.71, 62), (0.86, 74), (1.02, 88),
        (1.64, 96), (1.78, 118), (1.93, 133), (2.10, 152),
    ]

    /// How long the finished sentence rests before the loop begins again. Long enough to read it.
    public static let hold: Double = 2.1

    public static var loop: Double { (beats.last?.at ?? 0) + hold }

    /// How much of the sentence has arrived this far into the loop. Never fewer characters than a
    /// moment ago: a stream that went backwards is not a stream.
    ///
    /// The last beat is the turn ending, so it delivers whatever is left rather than a count — the
    /// script is written against a sentence somebody may reword, and a schedule that could leave
    /// the final clause unwritten would be a demonstration of a bug.
    public static func arrived(at elapsed: Double) -> Int {
        guard let final = beats.last, elapsed < final.at else { return text.count }
        var count = 0
        for beat in beats where elapsed >= beat.at { count = max(count, beat.characters) }
        return min(count, text.count)
    }
}

/// Whether anything is still arriving.
///
/// The wave is measured in characters behind the leading edge, which is exactly right while text
/// is coming: distance is proportional to age, so no per-character timestamps are needed and the
/// effect survives a re-render. But it carries one assumption — that the edge keeps moving — and a
/// reveal that has caught up with everything it was given breaks it. The last character then sits
/// at distance zero for as long as the row lives, and every term that expresses *arriving* stays
/// pinned at full: the glyph never finishes falling, its colour never closes back together, and it
/// goes on shedding light. On the settled renderer that is invisible, because arriving is only a
/// colour there. On this one it is a smear across the final word.
///
/// So the arrival terms are held on a second, tiny clock: the moment the pacer runs dry they
/// complete, and the moment anything arrives they are live again. Falling is eased because a
/// glyph mid-landing must not be snapped into place; rising is immediate because the very next
/// character has to land properly rather than fade up into landing. What stays is what is
/// deliberately a resting state — the heat, the band, and the nib, which rests rather than goes
/// out because an answer paused on a tool call has not finished.
public struct AuroraArrival: Sendable {
    public private(set) var level: Double = 1
    private var clock: Double?

    public init() {}

    @discardableResult
    public mutating func advance(to time: Double, settled: Bool) -> Double {
        defer { clock = time }
        guard settled else {
            level = 1
            return level
        }
        guard let previous = clock else {
            level = 0
            return level
        }
        let elapsed = min(max(time - previous, 0), 0.1)
        level -= level * (1 - exp(-elapsed / AuroraField.arrivalFall))
        if level < 0.002 { level = 0 }
        return level
    }
}

/// One glyph's whole state at one moment, for the renderer that can afford to move it.
///
/// Everything here is a pure function of how far the glyph sits behind the leading edge, so it
/// needs no per-character timestamps, survives a re-render, and looks identical at 60 and 120Hz —
/// the same three reasons `StreamCascade` measures its wave in characters rather than in seconds.
/// The colour terms are `CascadeSample`'s and are not restated: this is only what the settled
/// renderer has no way to spend.
public struct AuroraGlyph: Sendable, Equatable {
    /// How far the glyph still has to fall, as a fraction of its own height. Ink lands: a
    /// character arrives fractionally high and settles, which is the difference between a letter
    /// appearing and a letter being written.
    public let rise: Double
    /// How much smaller than final the glyph still is. Small on purpose — a glyph that grows a
    /// noticeable amount reads as a zoom, and this is a nib touching paper.
    public let contraction: Double
    /// The glyph's own tilt on arrival, in radians, seeded per character so a word does not land
    /// as one rigid block.
    public let tilt: Double
    /// How far apart the colour channels are pulled at this distance. Light through a moving edge
    /// separates and comes back together; the fringe is the reason the newest characters read as
    /// lit rather than merely tinted.
    public let dispersion: Double
    /// How much light this glyph spills onto the page around it.
    public let bloom: Double
    /// How willing the glyph is to shed an ember. Embers ride the top of the wave and die inside
    /// it — nothing may still be burning where the text has settled, because settled text is the
    /// one thing in this app that holds perfectly still.
    public let ember: Double

    public static let settled = AuroraGlyph(
        rise: 0, contraction: 0, tilt: 0, dispersion: 0, bloom: 0, ember: 0)
}

/// The alpha renderer's own constants, and the reference implementation of everything the shader
/// does per glyph.
///
/// The shader is the second implementation of this arithmetic, not the first. That is a deliberate
/// duplication with a rule attached: every constant crosses into the shader as a uniform read from
/// here, and `AuroraTests` asserts the shape of each curve — where it starts, where it ends, and
/// that it is monotone in between — so a shader that drifts fails a test rather than merely
/// looking different. Nothing about the effect is decided in MSL.
///
/// The whole design premise is that the per-frame cost is a uniform buffer. Geometry is rebuilt
/// when text arrives, roughly ten times a second; between arrivals the reveal moves, the band
/// travels and the embers burn entirely inside the vertex and fragment stages, so a frame costs
/// one small memcpy and one draw call regardless of how much has been written.
public enum AuroraField {
    /// How far behind the edge a glyph is still landing, in characters. Deliberately longer than
    /// `StreamCascade.entry`, which only fades: a fade may finish in two characters, but a fall
    /// that stops that abruptly reads as a jolt.
    public static let landing = 3.6
    /// How far the glyph falls, as a fraction of its own height.
    public static let riseHeight = 0.26
    /// How much smaller a glyph starts.
    public static let contractionDepth = 0.075
    /// The widest a glyph's arrival tilt may be, in radians — a little under two degrees.
    public static let tiltDepth = 0.032
    /// How far behind the edge the colour channels are still separated, in characters.
    public static let dispersionReach = 7.5
    /// The channel separation at the edge, as a fraction of a glyph's height.
    public static let dispersionDepth = 0.07
    /// How far light spills from a hot glyph, as a fraction of its height.
    public static let bloomRadius = 0.42
    /// How bright that spill is at the edge.
    public static let bloomPeak = 0.34
    /// How far behind the edge embers may still burn, in characters. Short: the wave is
    /// twenty-six characters wide and nothing may still be moving at the end of it.
    public static let emberReach = 11.0
    /// How many embers a character's worth of edge is worth at full burn.
    public static let emberDensity = 1.6
    /// How long one ember lives, in seconds.
    public static let emberLife = 0.62
    /// How far an ember rises over its life, as a fraction of a glyph's height.
    public static let emberDrift = 1.15
    /// The nib's width and how far past the last glyph it sits, both as fractions of a glyph's
    /// height. The nib is not a cursor: it is the lit point of contact, so it overlaps the
    /// character it just wrote rather than waiting in the space after it.
    public static let nibWidth = 0.085
    public static let nibLead = 0.06
    /// How far the nib's own glow reaches.
    public static let nibGlow = 0.9
    /// How much of a glyph's height the padding around its quad must cover for the bloom, the
    /// dispersion fringe and the embers to have somewhere to land. Everything the shader draws
    /// outside a letterform lives inside this margin, so a margin too small is an effect with a
    /// straight edge cut through it.
    public static var quadMargin: Double { max(bloomRadius, emberDrift) + 0.35 }

    /// Where the glyph `distance` characters behind the leading edge is in its arrival.
    ///
    /// `distance` is fractional because the reveal is: a pacer running at its floor rate moves the
    /// edge once every few frames, and a wave stepped in whole characters at that speed reads as a
    /// stutter in an effect whose entire purpose is to not be one.
    public static func glyph(distance: Double, seed: Int) -> AuroraGlyph {
        guard distance >= 0 else { return .settled }
        let landed = ease(min(1, distance / landing))
        let remaining = 1 - landed
        let fringe = max(0, 1 - distance / dispersionReach)
        let heat = pow(max(0, 1 - distance / Double(StreamCascade.span)), 2.2)
        let burn = max(0, 1 - distance / emberReach)
        return AuroraGlyph(
            rise: remaining * riseHeight,
            contraction: remaining * contractionDepth,
            tilt: remaining * tiltDepth * wobble(seed),
            dispersion: fringe * fringe * dispersionDepth,
            bloom: heat * bloomPeak,
            ember: burn * burn * burn)
    }

    /// A glyph's own character, from its position in the answer. Deterministic so a row that
    /// scrolls away and comes back lands the same way it was going to, and cheap enough that the
    /// shader computes it rather than being handed it.
    public static func wobble(_ seed: Int) -> Double {
        let hashed = Double((seed &* 2_654_435_761) % 1_000) / 1_000
        return hashed * 2 - 1
    }

    /// Ease-out, shared with the transcript's entrances so the whole product lands on one curve.
    public static func ease(_ t: Double) -> Double { StreamCascade.ease(t) }

    /// How long the arrival effects take to finish once nothing is arriving any more.
    public static let arrivalFall = 0.22

    /// Where the nib sits, in characters from the start of the text: at the last written glyph
    /// rather than in the gap after it, so the light is on the ink and not on the paper.
    public static func nibPosition(progress: Double) -> Double { max(0, progress - nibLead) }

    /// How hard the nib burns. It is the one part of the effect that answers the pacer's speed
    /// rather than the reveal's position: a hand writing fast presses brighter, and a hand that
    /// has stopped leaves a point of light resting on the page rather than going out — an answer
    /// paused on a tool call has not finished, and a nib that vanished would say it had.
    public static let nibRest = 0.34

    public static func nibStrength(rate: Double, tuning: CadenceTuning = .standard) -> Double {
        guard rate > 0 else { return nibRest }
        let span = max(tuning.maximumRate - tuning.minimumRate, 1)
        let eased = ease(min(1, max(0, rate - tuning.minimumRate) / span))
        return nibRest + (1 - nibRest) * eased
    }
}

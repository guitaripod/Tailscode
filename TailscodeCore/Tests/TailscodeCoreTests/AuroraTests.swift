import Foundation
import Testing

@testable import TailscodeCore

/// The shader is the second implementation of `AuroraField`, not the first, and a duplicated
/// formula drifts unless something holds it. These assert the *shape* of every curve the vertex
/// and fragment stages redo — where it starts, where it ends, and that it is monotone in between —
/// so a shader edited into disagreement fails here rather than merely looking different on a phone
/// nobody is holding.
@Suite("Aurora stream renderer")
struct AuroraTests {
    @Test("A glyph at the leading edge has everything left to do")
    func atTheEdge() {
        let glyph = AuroraField.glyph(distance: 0, seed: 7)
        #expect(glyph.rise == AuroraField.riseHeight)
        #expect(glyph.contraction == AuroraField.contractionDepth)
        #expect(glyph.dispersion == AuroraField.dispersionDepth)
        #expect(glyph.bloom == AuroraField.bloomPeak)
        #expect(glyph.ember == 1)
    }

    @Test("A glyph the wave has passed is doing nothing at all")
    func settled() {
        let past = AuroraField.glyph(distance: Double(StreamCascade.span) + 1, seed: 3)
        #expect(past == .settled)
        #expect(AuroraField.glyph(distance: -1, seed: 3) == .settled)
    }

    /// Settled text is the one thing in this app that holds perfectly still, so nothing the alpha
    /// renderer draws may still be moving where the wave has ended. Every term has to be finished
    /// well before the span, not merely small at it.
    @Test("Nothing is still moving by the end of the wave")
    func stillnessAtTheTail() {
        let end = Double(StreamCascade.span)
        #expect(AuroraField.landing < end)
        #expect(AuroraField.dispersionReach < end)
        #expect(AuroraField.emberReach < end)
        let last = AuroraField.glyph(distance: end, seed: 11)
        #expect(last.rise == 0)
        #expect(last.contraction == 0)
        #expect(last.tilt == 0)
        #expect(last.dispersion == 0)
        #expect(last.ember == 0)
        #expect(last.bloom < 0.0001)
    }

    @Test("Every term falls away with distance and never comes back")
    func monotone() {
        var previous = AuroraField.glyph(distance: 0, seed: 5)
        for step in 1...120 {
            let glyph = AuroraField.glyph(distance: Double(step) * 0.25, seed: 5)
            #expect(glyph.rise <= previous.rise + 1e-9)
            #expect(glyph.contraction <= previous.contraction + 1e-9)
            #expect(abs(glyph.tilt) <= abs(previous.tilt) + 1e-9)
            #expect(glyph.dispersion <= previous.dispersion + 1e-9)
            #expect(glyph.bloom <= previous.bloom + 1e-9)
            #expect(glyph.ember <= previous.ember + 1e-9)
            previous = glyph
        }
        #expect(previous == .settled)
    }

    /// A word must not land as one rigid block, and it must land the same way every time — a row
    /// scrolled away and back has to arrive where it was going to.
    @Test("A glyph's tilt is its own, and always the same")
    func wobbleIsSeededAndBounded() {
        var seen = Set<Double>()
        for seed in 0..<40 {
            let value = AuroraField.wobble(seed)
            #expect(value >= -1 && value <= 1)
            #expect(AuroraField.wobble(seed) == value)
            seen.insert(value)
        }
        #expect(seen.count > 20)
        for seed in 0..<40 {
            let tilt = AuroraField.glyph(distance: 0, seed: seed).tilt
            #expect(abs(tilt) <= AuroraField.tiltDepth + 1e-9)
        }
    }

    /// The margin is what the light is given to land in. Too small and every effect the shader
    /// draws outside a letterform has a straight edge cut through it.
    @Test("The quad's margin covers everything drawn outside a letterform")
    func marginCoversTheLight() {
        #expect(AuroraField.quadMargin > AuroraField.bloomRadius)
        #expect(AuroraField.quadMargin > AuroraField.emberDrift)
    }

    /// The nib is the one part of the effect that answers the pacer's speed rather than the
    /// reveal's position — and it rests rather than goes out, because an answer paused on a tool
    /// call has not finished.
    @Test("The nib burns with the rate and never goes out")
    func nibStrength() {
        let tuning = CadenceTuning.standard
        #expect(AuroraField.nibStrength(rate: 0) == AuroraField.nibRest)
        #expect(AuroraField.nibStrength(rate: tuning.minimumRate) == AuroraField.nibRest)
        #expect(AuroraField.nibStrength(rate: tuning.maximumRate) == 1)
        var previous = AuroraField.nibRest
        for step in stride(from: 0.0, through: tuning.maximumRate, by: 5) {
            let strength = AuroraField.nibStrength(rate: step)
            #expect(strength >= AuroraField.nibRest)
            #expect(strength <= 1)
            #expect(strength >= previous - 1e-9)
            previous = strength
        }
    }

    /// The light is on the ink, not on the paper after it.
    @Test("The nib sits on the character it has just written")
    func nibSitsOnTheInk() {
        #expect(AuroraField.nibPosition(progress: 10) < 10)
        #expect(AuroraField.nibPosition(progress: 0) == 0)
    }

    @Test("Classic is the stored absence")
    func settingDefaultsToClassic() {
        UserDefaults.standard.removeObject(forKey: StreamRendererSetting.defaultsKey)
        #expect(StreamRendererSetting.choice == .classic)
        #expect(!StreamRendererSetting.isAurora)
        StreamRendererSetting.set(.aurora)
        #expect(StreamRendererSetting.choice == .aurora)
        #expect(StreamRendererSetting.isAurora)
        StreamRendererSetting.set(.classic)
        #expect(UserDefaults.standard.string(forKey: StreamRendererSetting.defaultsKey) == nil)
        #expect(StreamRendererSetting.choice == .classic)
    }

    @Test("Only the alpha hand is marked alpha")
    func alphaMarking() {
        #expect(!StreamRenderer.classic.isAlpha)
        #expect(StreamRenderer.aurora.isAlpha)
        for choice in StreamRenderer.allCases {
            #expect(!choice.title.isEmpty)
            #expect(!choice.summary.isEmpty)
            #expect(!choice.detail.isEmpty)
            #expect(!choice.spoken.isEmpty)
        }
    }

    /// Both previews have to be comparable, which means the same characters at the same moments —
    /// and one of those moments has to be a stall, because the whole reason the transcript holds a
    /// buffer is what happens to the reveal when a turn stops to run something.
    @Test("The demo script only ever grows, and stalls once")
    func demoScript() {
        var previous = 0
        for step in stride(from: 0.0, through: StreamRendererDemo.loop, by: 0.01) {
            let arrived = StreamRendererDemo.arrived(at: step)
            #expect(arrived >= previous)
            #expect(arrived <= StreamRendererDemo.text.count)
            previous = arrived
        }
        #expect(previous == StreamRendererDemo.text.count)
        #expect(StreamRendererDemo.arrived(at: 0) == 0)

        let gaps = zip(
            StreamRendererDemo.beats.dropFirst().map(\.at), StreamRendererDemo.beats.map(\.at)
        ).map(-)
        #expect(gaps.max()! > gaps.min()! * 2.5)
    }

    /// The reveal is published sub-character because the alpha hand moves the edge itself, and a
    /// character that snapped from nothing to its entry floor would put a step back into the one
    /// effect whose entire purpose is to not have one.
    @Test("The edge is published between characters")
    func fractionalProgress() {
        var cadence = StreamCadence()
        cadence.observe(available: 400, sealed: false)
        cadence.advance(to: 0)
        var previous = cadence.progress
        var fractional = false
        for step in 1...200 {
            cadence.advance(to: Double(step) / 120)
            #expect(cadence.progress >= previous - 1e-9)
            #expect(cadence.progress >= Double(cadence.revealed))
            #expect(cadence.progress < Double(cadence.revealed) + 1.0001)
            if cadence.progress > Double(cadence.revealed) { fractional = true }
            previous = cadence.progress
        }
        #expect(fractional)
    }

    /// The wave is measured in characters behind the edge, which assumes the edge keeps moving. A
    /// reveal that has caught up breaks that assumption: the last character sits at distance zero
    /// for as long as the row lives, and every term that expresses *arriving* would stay pinned at
    /// full — a smear across the final word rather than a settled sentence.
    @Test("Arriving finishes when nothing is arriving")
    func arrivalRetires() {
        var arrival = AuroraArrival()
        #expect(arrival.level == 1)
        arrival.advance(to: 0, settled: false)
        #expect(arrival.level == 1)
        var time = 0.0
        for _ in 0..<600 {
            time += 1.0 / 120
            arrival.advance(to: time, settled: true)
        }
        #expect(arrival.level == 0)
    }

    /// Falling is eased so a glyph mid-landing is not snapped into place; rising is immediate,
    /// because the very next character has to land properly rather than fade up into landing.
    @Test("The next character lands at once")
    func arrivalRisesImmediately() {
        var arrival = AuroraArrival()
        var time = 0.0
        arrival.advance(to: time, settled: false)
        for _ in 0..<10 {
            time += 1.0 / 120
            arrival.advance(to: time, settled: true)
        }
        #expect(arrival.level < 1)
        #expect(arrival.level > 0)
        time += 1.0 / 120
        #expect(arrival.advance(to: time, settled: false) == 1)
    }

    @Test("A row that was over before it was watched never animates its arrival")
    func arrivalStartsSettled() {
        var arrival = AuroraArrival()
        #expect(arrival.advance(to: 12, settled: true) == 0)
    }

    /// What the transcript relies on when the agent stops writing a paragraph and goes off to run
    /// something: sealing a row must *finish* it, not hand it over. The pacer trails by design, so
    /// there are always characters owed at that moment, and dropping the row there put a paste in
    /// the middle of every answer that called a tool.
    @Test("Sealing a row part-written finishes it rather than dumping it")
    func sealedRowDrains() {
        var live = LiveCascade()
        var time = 0.0
        live.focus("row", length: 40, sealed: false, at: time)
        for _ in 0..<30 {
            time += 1.0 / 120
            live.advance(to: time)
            live.lands(live.revealed, at: time)
        }
        live.focus("row", length: 240, sealed: false, at: time)
        for _ in 0..<10 {
            time += 1.0 / 120
            live.advance(to: time)
            live.lands(live.revealed, at: time)
        }
        let owedAtSeal = 240 - live.revealed
        #expect(owedAtSeal > 40)

        live.focus("row", length: 240, sealed: true, at: time)
        var frames = 0
        while live.revealed < 240, frames < 600 {
            time += 1.0 / 120
            live.advance(to: time)
            live.lands(live.revealed, at: time)
            frames += 1
        }
        #expect(live.revealed == 240)
        #expect(frames > 8)
        #expect(!live.owes)
    }

    /// The same row, sealed, must never rewind: what has been shown has been shown.
    @Test("A sealed row only ever moves forward")
    func sealedRowNeverRewinds() {
        var live = LiveCascade()
        var time = 0.0
        live.focus("row", length: 200, sealed: false, at: time)
        var highest = 0
        for step in 0..<400 {
            time += 1.0 / 120
            if step == 120 { live.focus("row", length: 200, sealed: true, at: time) }
            live.advance(to: time)
            live.lands(live.revealed, at: time)
            #expect(live.revealed >= highest)
            highest = live.revealed
        }
        #expect(highest == 200)
    }

    @Test("A settled reveal owes nothing between characters either")
    func settledProgressIsWhole() {
        var cadence = StreamCadence()
        cadence.adopt(120)
        cadence.advance(to: 0)
        cadence.advance(to: 1)
        #expect(cadence.progress == 120)
    }
}

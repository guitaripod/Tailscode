import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural palette")
struct NeuralPaletteTests {
    private let dark = AppTheme.rosePine.dark
    private let dawn = AppTheme.rosePine.light
    private let face = NeuralFace(family: .opus)

    private func channels(_ hex: String) -> [Float] {
        let value = Contrast.channels(hex)!
        return [Float(value.red), Float(value.green), Float(value.blue)]
    }

    private func expected(_ hex: String, lift: Float) -> [Float] {
        channels(hex).map { powf($0 * (1 - lift) + lift, 2.2) }
    }

    private func matches(_ color: NeuralRGB, _ values: [Float]) -> Bool {
        abs(color.r - values[0]) < 1e-5 && abs(color.g - values[1]) < 1e-5
            && abs(color.b - values[2]) < 1e-5
    }

    @Test("on a dark palette a tone glows in its slot, in linear light, unlifted")
    func darkGlow() {
        #expect(matches(NeuralPalette.glow(.live, palette: dark, face: face), expected(dark.accent, lift: 0)))
        #expect(matches(NeuralPalette.glow(.attention, palette: dark, face: face), expected(dark.warn, lift: 0)))
        #expect(matches(NeuralPalette.glow(.danger, palette: dark, face: face), expected(dark.danger, lift: 0)))
        #expect(matches(NeuralPalette.glow(.quiet, palette: dark, face: face), expected(dark.textDim, lift: 0)))
    }

    @Test("identity glows in the family's authored hue")
    func identity() {
        let opus = NeuralPalette.glow(.identity, palette: dark, face: face)
        #expect(matches(opus, expected(ModelTint.authoredHex(.opus, isDark: true), lift: 0)))
        let bucketed = NeuralFace(bucket: 4)
        let other = NeuralPalette.glow(.identity, palette: dark, face: bucketed)
        #expect(matches(other, expected(ModelTint.bucketHex(4), lift: 0)))
    }

    @Test("on a light palette every glow lifts 45 percent toward white")
    func lightGlow() {
        #expect(!dawn.isDark)
        for (tone, hex) in [
            (NeuralTone.live, dawn.accent), (.attention, dawn.warn), (.danger, dawn.danger),
            (.quiet, dawn.textDim),
        ] {
            let glow = NeuralPalette.glow(tone, palette: dawn, face: face)
            #expect(matches(glow, expected(hex, lift: 0.45)), "\(tone)")
            let plain = expected(hex, lift: 0)
            #expect(glow.r >= plain[0] && glow.g >= plain[1] && glow.b >= plain[2])
        }
        let hue = NeuralPalette.glow(.identity, palette: dawn, face: face)
        #expect(matches(hue, expected(ModelTint.authoredHex(.opus, isDark: false), lift: 0.45)))
    }

    @Test("spill is for dark palettes only")
    func spill() {
        #expect(NeuralPalette.spill(palette: dark))
        #expect(!NeuralPalette.spill(palette: dawn))
        for theme in AppTheme.all {
            #expect(NeuralPalette.spill(palette: theme.dark))
            #expect(!NeuralPalette.spill(palette: theme.light))
        }
    }

    @Test("there are thirteen channel tones, each as the mock's tones() builds it")
    func channelTones() {
        let tones = NeuralPalette.channelTones(palette: dark, face: face)
        #expect(tones.count == NeuralChannel.count)
        #expect(matches(tones[NeuralChannel.think.rawValue], expected(dark.text, lift: 0)))
        #expect(matches(tones[NeuralChannel.sense.rawValue], expected(dark.info, lift: 0)))
        #expect(matches(tones[NeuralChannel.act.rawValue], expected(dark.accent, lift: 0)))
        #expect(matches(tones[NeuralChannel.shell.rawValue], expected(dark.special, lift: 0)))
        #expect(matches(tones[NeuralChannel.delegate.rawValue], expected(dark.textDim, lift: 0)))
        for channel in [NeuralChannel.seam, .eye, .rib, .ear, .visor] {
            #expect(matches(tones[channel.rawValue], expected(dark.accent, lift: 0)), "\(channel)")
        }
        let accent = channels(dark.accent)
        let info = channels(dark.info)
        let say = (0..<3).map { powf(accent[$0] * 0.55 + info[$0] * 0.45, 2.2) }
        #expect(matches(tones[NeuralChannel.say.rawValue], say))
        let link = (0..<3).map { powf(accent[$0] * 0.5 + info[$0] * 0.5, 2.2) }
        #expect(matches(tones[NeuralChannel.link.rawValue], link))
        let ink = channels(dark.text)
        let star = (0..<3).map { powf(ink[$0] * 0.7 + info[$0] * 0.3, 2.2) }
        #expect(matches(tones[NeuralChannel.star.rawValue], star))
    }

    @Test("a light palette lifts the channels and overrides take a tone's glow")
    func lightChannels() {
        let tones = NeuralPalette.channelTones(palette: dawn, face: face)
        #expect(matches(tones[NeuralChannel.think.rawValue], expected(dawn.text, lift: 0.45)))
        var overrides = [NeuralTone?](repeating: nil, count: NeuralChannel.count)
        overrides[NeuralChannel.eye.rawValue] = .danger
        overrides[NeuralChannel.shell.rawValue] = .identity
        let changed = NeuralPalette.channelTones(palette: dawn, face: face, overrides: overrides)
        #expect(changed[NeuralChannel.eye.rawValue] == NeuralPalette.glow(.danger, palette: dawn, face: face))
        #expect(changed[NeuralChannel.shell.rawValue] == NeuralPalette.glow(.identity, palette: dawn, face: face))
        #expect(changed[NeuralChannel.think.rawValue] == tones[NeuralChannel.think.rawValue])
        let short = NeuralPalette.channelTones(palette: dawn, face: face, overrides: [.live])
        #expect(short.count == NeuralChannel.count)
        #expect(short[0] == NeuralPalette.glow(.live, palette: dawn, face: face))
    }

    @Test("the canvas is the page in linear light")
    func canvas() {
        #expect(matches(NeuralPalette.canvas(palette: dark), expected(dark.canvas, lift: 0)))
    }
}

@Suite("Neural face and meters")
struct NeuralPaletteFaceTests {
    @Test("a tier lights its rank")
    func tiers() {
        let expected = ["low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 5]
        for (word, bars) in expected {
            let face = NeuralFace(model: "claude-opus-4", effort: word)
            #expect(face.effort == bars, "\(word)")
            #expect(!face.hollow && !face.rainbow && !face.ember)
        }
    }

    @Test("a power lights all five in the rainbow")
    func power() {
        let face = NeuralFace(model: "claude-fable-5", effort: "ultracode")
        #expect(face.effort == 5 && face.rainbow && !face.hollow)
    }

    @Test("the server's choice is hollow with none lit")
    func server() {
        for level in [nil, "", "auto"] {
            let face = NeuralFace(model: "claude-opus-4", effort: level)
            #expect(face.hollow && face.effort == 0 && !face.rainbow, "\(String(describing: level))")
        }
    }

    @Test("below low is one ember bar")
    func ember() {
        let face = NeuralFace(model: "gpt-5", effort: "minimal")
        #expect(face.ember && face.effort == 1 && !face.hollow)
    }

    @Test("the family comes from the model and an unknown model takes a bucket hue")
    func family() {
        #expect(NeuralFace(model: "claude-opus-4", effort: "low").family == .opus)
        #expect(NeuralFace(model: "gpt-5", effort: "low").family == .gpt)
        let unknown = NeuralFace(model: "hunyuan-large", effort: "low")
        #expect(unknown.family == nil)
        #expect(unknown.bucket == ModelTint.hueBucket("hunyuan-large"))
        #expect(unknown.hueHex(isDark: true) == ModelTint.bucketHex(unknown.bucket))
        #expect(NeuralFace(family: .haiku).hueHex(isDark: true) == "#3fc47c")
    }

    @Test("the dial's own face gives the same bars")
    func dial() {
        let options = ["low", "medium", "high"]
        let high = ModelDial.face(modelWord: "Opus", effort: "high", options: options)
        #expect(NeuralFace(model: "claude-opus-4", dial: high).effort == 3)
        let server = ModelDial.face(modelWord: "Opus", effort: nil, options: options)
        let hollow = NeuralFace(model: "claude-opus-4", dial: server)
        #expect(hollow.hollow && hollow.effort == 0)
        let none = ModelDial.face(modelWord: "Opus", effort: nil, options: [])
        let bare = NeuralFace(model: "claude-opus-4", dial: none)
        #expect(!bare.hollow && bare.effort == 0)
    }

    @Test("context tone turns attention at half and danger at four fifths")
    func contextTone() {
        #expect(NeuralMeters(contextFill: 0.49).contextTone == .quiet)
        #expect(NeuralMeters(contextFill: 0.5).contextTone == .attention)
        #expect(NeuralMeters(contextFill: 0.79).contextTone == .attention)
        #expect(NeuralMeters(contextFill: 0.8).contextTone == .danger)
        #expect(NeuralMeters(contextFill: 1.4).contextFill == 1)
        #expect(NeuralMeters(contextFill: 0.5).ribs == 3)
    }

    @Test("the meters read a context fill and mark an estimate")
    func fill() {
        let measured = ContextFill(used: 90_000, window: 100_000, model: "m", basis: .reported)
        let meters = NeuralMeters(fill: measured)
        #expect(abs(meters.contextFill - 0.9) < 1e-6 && meters.contextTone == .danger)
        #expect(!meters.isEstimate)
        let guessed = ContextFill(used: 60_000, window: 100_000, model: "m", basis: .estimated)
        #expect(NeuralMeters(fill: guessed).isEstimate)
        let compacted = ContextFill(used: 6_000, window: 100_000, model: "m", basis: .compacted)
        #expect(!NeuralMeters(fill: compacted).isEstimate)
        let unknownWindow = ContextFill(used: 6_000, window: nil, model: "m", basis: .reported)
        #expect(NeuralMeters(fill: unknownWindow).contextFill == 0)
        #expect(NeuralMeters(fill: nil) == NeuralMeters.none)
    }

    @Test("every call face maps to an ear")
    func ears() {
        #expect(NeuralMeters(fill: nil, call: .listening).call == .listening)
        #expect(NeuralMeters(fill: nil, call: .hearing).call == .hearing)
        #expect(NeuralMeters(fill: nil, call: .connecting).call == .connecting)
        #expect(NeuralMeters(fill: nil, call: .working).call == .working)
        #expect(NeuralMeters(fill: nil, call: .speaking).call == .working)
        #expect(NeuralMeters(fill: nil, call: .degraded(.engineError)).call == .degraded)
        #expect(NeuralMeters(fill: nil, call: .ended).call == .ended)
        #expect(NeuralMeters(fill: nil).call == nil)
        #expect(NeuralMeters.Ear.listening.motion == .breath && NeuralMeters.Ear.hearing.motion == .still)
        #expect(NeuralMeters.Ear.connecting.tone == .quiet && NeuralMeters.Ear.degraded.tone == .danger)
    }
}

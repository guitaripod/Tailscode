import CodingAgentKit
import Foundation

/// Who answered and how hard: the family's hue for a settled eye, and the visor's five bars.
/// Effort follows the dial's own heat rules, so "high" is three bars here as it is on the pill.
public struct NeuralFace: Sendable, Hashable {
    /// The authored family; nil for a model outside them, which wears `bucket`.
    public var family: ModelTint.Family?
    /// One of twelve evenly spaced hues for a model nobody authored an identity for.
    public var bucket: Int
    /// Bars lit out of five. A tier lights its rank, a power all five, the server's choice none.
    public var effort: Int
    /// The server decides: five hollow bars, none lit.
    public var hollow: Bool
    /// A power (ultracode): all five bars wear the rainbow.
    public var rainbow: Bool
    /// A level below low: one bar, an ember.
    public var ember: Bool

    public init(
        family: ModelTint.Family? = nil, bucket: Int = 0, effort: Int = 0, hollow: Bool = false,
        rainbow: Bool = false, ember: Bool = false
    ) {
        self.family = family
        self.bucket = bucket
        self.effort = max(0, min(EffortMeter.bars, effort))
        self.hollow = hollow
        self.rainbow = rainbow
        self.ember = ember
    }

    /// From the model that answered and the level the turn carried. `options` are the levels the
    /// model lists, which place a word the effort table has not met; empty is fine for a known one.
    public init(
        model: String?, providerID: String? = nil, effort level: String?, options: [String] = []
    ) {
        let name = model ?? ""
        let family = ModelTint.family(name, providerID: providerID)
        let bucket = ModelTint.hueBucket(name)
        guard let level, !level.isEmpty, !EffortVocabulary.isAutomatic(level) else {
            self.init(family: family, bucket: bucket, hollow: true)
            return
        }
        if ModelDial.isPower(level) {
            self.init(
                family: family, bucket: bucket, effort: EffortMeter.bars, rainbow: true)
        } else if ModelDial.isEmber(level) {
            self.init(
                family: family, bucket: bucket, effort: ModelDial.heat(level, options: options),
                ember: true)
        } else {
            self.init(
                family: family, bucket: bucket, effort: ModelDial.heat(level, options: options))
        }
    }

    /// From the composer's own dial, so the head and the pill cannot disagree.
    public init(model: String?, providerID: String? = nil, dial: DialFace) {
        let name = model ?? ""
        self.init(
            family: ModelTint.family(name, providerID: providerID),
            bucket: ModelTint.hueBucket(name),
            effort: dial.isServer ? 0 : dial.heat,
            hollow: dial.showsMeter && dial.isServer,
            rainbow: dial.isPower,
            ember: dial.isEmber)
    }

    /// A face for a head that has not met a model yet.
    public static let unknown = NeuralFace(hollow: true)

    /// The authored hue, before any palette has a say: additive light wants the family's own
    /// colour, not one walked for contrast against text.
    public func hueHex(isDark: Bool) -> String {
        if let family { return ModelTint.authoredHex(family, isDark: isDark) }
        return ModelTint.bucketHex(bucket)
    }
}

/// What the head carries besides the steps: how full the context window is, and a call's ear.
public struct NeuralMeters: Sendable, Hashable {
    /// The animation a call's ear wears, from the mock's `ct` table.
    public enum Ear: Sendable, Hashable {
        case listening
        case hearing
        case connecting
        case degraded
        case ended
        case working

        public init(_ face: VoiceCallFace) {
            switch face {
            case .connecting: self = .connecting
            case .listening: self = .listening
            case .hearing: self = .hearing
            case .speaking, .working: self = .working
            case .degraded: self = .degraded
            case .ended: self = .ended
            }
        }

        public var tone: NeuralTone {
            switch self {
            case .listening, .hearing, .working: return .live
            case .connecting, .ended: return .quiet
            case .degraded: return .danger
            }
        }

        public var motion: NeuralMotion {
            switch self {
            case .listening, .working: return .breath
            case .connecting: return .sweep
            case .hearing, .degraded, .ended: return .still
            }
        }
    }

    /// How full the window is, `0...1`; zero where the window is not known.
    public var contextFill: Float
    public var contextTone: NeuralTone
    /// A count made from the transcript's own characters rather than reported: drawn at half
    /// strength, because the head claims only what was measured.
    public var isEstimate: Bool
    public var call: Ear?

    public init(
        contextFill: Float = 0, contextTone: NeuralTone? = nil, isEstimate: Bool = false,
        call: Ear? = nil
    ) {
        let fill = min(max(contextFill, 0), 1)
        self.contextFill = fill
        self.contextTone = contextTone ?? Self.tone(forFill: fill)
        self.isEstimate = isEstimate
        self.call = call
    }

    public init(fill: ContextFill?, call: VoiceCallFace? = nil) {
        let ear = call.map(Ear.init)
        guard let fill else {
            self.init(call: ear)
            return
        }
        self.init(
            contextFill: Float(fill.fraction ?? 0), contextTone: Self.tone(of: fill.tone),
            isEstimate: fill.basis == .estimated, call: ear)
    }

    public static let none = NeuralMeters()

    /// Quiet below half, attention from half, danger from four fifths: `ContextFill`'s own marks.
    public static func tone(forFill fill: Float) -> NeuralTone {
        if Double(fill) >= ContextFill.dangerAt { return .danger }
        if Double(fill) >= ContextFill.attentionAt { return .attention }
        return .quiet
    }

    static func tone(of tone: ContextFill.Tone) -> NeuralTone {
        switch tone {
        case .quiet: return .quiet
        case .attention: return .attention
        case .danger: return .danger
        }
    }

    /// How many of the six ribs are lit, from the bottom, fractions allowed.
    public var ribs: Float { contextFill * 6 }
}

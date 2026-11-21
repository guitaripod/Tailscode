import Foundation

/// Who makes a model, read from the family its hue already names. A model no house claims has no
/// maker, which is a fact the wall draws too.
public enum ModelMaker: String, Sendable, CaseIterable {
    case anthropic, openAI, google, xAI, alibaba, deepSeek, meta, mistral
    case zhipu, moonshot, miniMax, microsoft, cohere

    public init(_ family: ModelTint.Family) {
        switch family {
        case .fable, .opus, .sonnet, .haiku: self = .anthropic
        case .gpt: self = .openAI
        case .gemini, .gemma: self = .google
        case .grok: self = .xAI
        case .qwen: self = .alibaba
        case .deepseek: self = .deepSeek
        case .llama: self = .meta
        case .mistral: self = .mistral
        case .glm: self = .zhipu
        case .kimi: self = .moonshot
        case .minimax: self = .miniMax
        case .phi: self = .microsoft
        case .command: self = .cohere
        }
    }
}

/// The figure a tile on the wall wears for the model driving it: a shape for who made the model, a
/// weight for which of that maker's models it is, and a heat for the effort it runs at. All three are
/// read from the tile's own chip, so the figure never says more than the words beside it do.
public struct WallEmblem: Sendable, Equatable {
    /// The shape a maker is told by, each drawn from motes and soft rings alone.
    public enum Form: String, Sendable, CaseIterable {
        /// Rays cut by hand around a hollow centre.
        case spark
        /// Six lobes woven into one blossom.
        case knot
        /// A four-pointed star with its sides drawn in.
        case star
        /// A ring crossed by one stroke.
        case slash
        /// One line that crosses itself and comes back.
        case loop
        /// Stepped rows leaning into a wind.
        case wind
        /// Three swells, one under the other.
        case wave
        /// Three arms turning about a centre.
        case swirl
        /// Satellites about a nucleus, as many as the name decides.
        case orbit
    }

    public static let topRank = 3
    public static let pips = 5

    public let form: Form
    public let maker: ModelMaker?
    /// How heavy the model is among its maker's, 0 the lightest to 3 the flagship.
    public let rank: Int
    /// The effort's tier, 0 cold to 5 hot; nil when the model decides or the word is not known.
    public let heat: Int?
    /// Whether the chat runs at ultracode, which is a power and not a level.
    public let power: Bool
    /// The model's own hue, before a theme or the night has a say.
    public let hue: WallInk
    /// The effort's own colour; nil when it has none.
    public let ember: WallInk?
    /// The model's name hashed, the same on every machine, for what tells two of a maker's models apart.
    public let seed: UInt32

    public init?(chip: ModelChip?) {
        guard let chip, !chip.name.isEmpty else { return nil }
        let maker = chip.family.map(ModelMaker.init)
        let seed = Self.hash(chip.name)
        self.maker = maker
        self.seed = seed
        form = Self.form(of: maker)
        rank = Self.rank(family: chip.family, name: chip.name)
        power = ModelDial.isPower(chip.effort)
        heat = chip.effort.flatMap(ModelDial.rank)
        hue = WallInk(
            hex: chip.family.map { ModelTint.authoredHex($0, isDark: true) }
                ?? ModelTint.bucketHex(ModelTint.hueBucket(chip.name)))
        ember = chip.effort.flatMap(ModelTint.authoredEffortHex).map(WallInk.init(hex:))
    }

    /// How many of the five pips are lit: the tier for a level, all of them for the power, and nil
    /// when the effort is not a thing the wall can count, which draws no pips at all.
    public var litPips: Int? {
        if power { return Self.pips }
        return heat.map { min(Self.pips, max(0, $0)) }
    }

    /// How fast the figure moves, as a multiple of its own pace: slow when the effort is cold, quick
    /// when it is hot, and quickest under the power.
    public var pace: Double {
        if power { return 1.5 }
        guard let heat else { return 0.6 }
        return [0.3, 0.42, 0.6, 0.8, 1.0, 1.25][min(5, max(0, heat))]
    }

    /// Which way the figure turns, decided by the name so a model always turns the same way.
    public var spin: Double { seed % 2 == 0 ? 1 : -1 }

    /// How many satellites an orbit carries: a maker's own number, or one the name decides.
    public var satellites: Int {
        switch maker {
        case .moonshot: return 1
        case .zhipu, .cohere: return 3
        case .miniMax, .microsoft: return 4
        default: return 2 + Int(seed % 5)
        }
    }

    static func form(of maker: ModelMaker?) -> Form {
        switch maker {
        case .anthropic: return .spark
        case .openAI: return .knot
        case .google: return .star
        case .xAI: return .slash
        case .meta: return .loop
        case .mistral: return .wind
        case .deepSeek: return .wave
        case .alibaba: return .swirl
        case .zhipu, .moonshot, .miniMax, .microsoft, .cohere, nil: return .orbit
        }
    }

    private static let lightWords: Set<String> = [
        "nano", "mini", "lite", "flash", "small", "tiny", "fast", "instant", "air", "micro", "haiku",
        "spark", "edge",
    ]
    private static let heavyWords: Set<String> = [
        "pro", "large", "plus", "opus", "codex", "heavy", "reasoner", "thinking", "big",
    ]
    private static let topWords: Set<String> = ["max", "ultra", "fable", "mythos", "ultimate"]

    /// Claude's members rank by name. Anyone else's model ranks by the word its name carries for
    /// its size, a light word winning over a heavy one because `codex-mini` is a mini, then by the
    /// parameter count a local build wears, and sits in the middle when the name says neither.
    static func rank(family: ModelTint.Family?, name: String) -> Int {
        switch family {
        case .fable: return 3
        case .opus: return 2
        case .sonnet: return 1
        case .haiku: return 0
        default: break
        }
        let words = name.lowercased().split { !($0.isLetter || $0.isNumber || $0 == ".") }.map(String.init)
        if words.contains(where: lightWords.contains) { return 0 }
        if words.contains(where: topWords.contains) { return 3 }
        if words.contains(where: heavyWords.contains) { return 2 }
        for word in words {
            guard word.hasSuffix("b"), let billions = Double(word.dropLast()) else { continue }
            if billions <= 9 { return 0 }
            if billions <= 40 { return 1 }
            return billions <= 130 ? 2 : 3
        }
        return 1
    }

    static func hash(_ name: String) -> UInt32 {
        var hash: UInt32 = 5381
        for byte in name.lowercased().utf8 { hash = hash &* 33 &+ UInt32(byte) }
        return hash
    }
}

extension WallTile {
    /// The figure this tile wears for its model; nil when the tile names none.
    public var emblem: WallEmblem? { WallEmblem(chip: chip) }
}

/// One drawn piece of a figure with the colour it is drawn in.
public struct WallEmblemPiece: Sendable, Equatable {
    public var shape: WallShape
    public var ink: WallInk

    public init(shape: WallShape, ink: WallInk) {
        self.shape = shape
        self.ink = ink
    }
}

/// What a wall knows when it draws a figure: where the tile stands, what state it is in, and what the
/// person chose for the wall's style.
public struct WallEmblemScene: Sendable {
    public var tile: WallRect
    public var unit: Double
    public var state: WallState
    public var t: TimeInterval
    /// Whether anything on the wall may move now: false for Still, Reduce Motion and a held frame.
    public var animated: Bool
    public var style: WallStyle
    public var night: Bool
    public var text: WallInk
    public var dim: WallInk
    /// The tile's own opacity, so a figure cools and arrives with its tile.
    public var opacity: Double

    public init(
        tile: WallRect, unit: Double, state: WallState, t: TimeInterval, animated: Bool, style: WallStyle,
        night: Bool, text: WallInk, dim: WallInk, opacity: Double = 1
    ) {
        self.tile = tile
        self.unit = unit
        self.state = state
        self.t = t
        self.animated = animated
        self.style = style
        self.night = night
        self.text = text
        self.dim = dim
        self.opacity = opacity
    }
}

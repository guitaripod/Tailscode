import Foundation

/// What a theme draws besides its colours.
///
/// A palette says what every meaning looks like; scenery says where the window is. It is the one
/// part of a theme allowed to mean nothing, and it pays for that by staying out of the way: the
/// sky sits behind the transcript and never on a surface that is read, it holds perfectly still,
/// and nothing in it wears a signal colour, because a star in the accent would be saying that
/// something is running. The two things that do take a signal's colour take it for the signal's
/// own meaning: a lit blade is the rule that was already the accent, and the scan lines lie on
/// the cards that were already the identity colour.
///
/// A theme with scenery is only whole where its scenery is drawn, so it joins `AppTheme.all` when
/// every client draws it and not before.
public struct Scenery: Equatable, Sendable {
    public enum Sky: Equatable, Sendable {
        case stars(StarField)
        case suns(TwinSuns)
    }

    public let sky: Sky
    /// How far, in points, a signal drawn as a bar spills its light: the rule beside a prompt, the
    /// edge of the chosen chat, the edge of the box being typed in. Zero keeps them ink, which is
    /// what a blade is in daylight.
    public let bladeGlow: Double
    /// The share of the identity colour laid as scan lines over what the agent delegated: a
    /// subagent's card is work happening somewhere else, projected here. Zero draws none.
    public let scanLines: Double
    /// The share of the text colour the chrome casts onto the canvas as a hard, unblurred shadow,
    /// which is what a wall does under a high sun. Zero casts none.
    public let castShadow: Double

    public init(sky: Sky, bladeGlow: Double, scanLines: Double, castShadow: Double) {
        self.sky = sky
        self.bladeGlow = bladeGlow
        self.scanLines = scanLines
        self.castShadow = castShadow
    }

    /// The most a single star may add to the canvas, and the most of a tile that may be lit at
    /// all. Scenery is behind words: a star brighter or a sky denser than this starts to read as
    /// punctuation, which is the one thing it must never be mistaken for.
    public static let starAlphaCeiling = 0.72
    public static let litShareCeiling = 0.0015
}

/// A night sky as data: a few layers of stars, each a seamless tile of its own size.
///
/// The tile sizes share no factor, so the layers drift out of step with each other and the eye
/// never finds the seam: three small pictures repeat as one sky that does not. Every star is
/// placed by a seeded generator rather than a clock or a random source, so the sky over a
/// conversation is the same sky tomorrow, on another machine, and in a test.
public struct StarField: Equatable, Sendable {
    public struct Layer: Equatable, Sendable {
        /// The side of the square tile, in points.
        public let tile: Int
        public let count: Int
        public let radius: ClosedRange<Double>
        public let alpha: ClosedRange<Double>
        /// The share of a star's own light it spills as a halo; zero is a hard point.
        public let halo: Double
        public let seed: UInt64

        public init(
            tile: Int, count: Int, radius: ClosedRange<Double>, alpha: ClosedRange<Double>,
            halo: Double, seed: UInt64
        ) {
            self.tile = tile
            self.count = count
            self.radius = radius
            self.alpha = alpha
            self.halo = halo
            self.seed = seed
        }
    }

    public struct Star: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let radius: Double
        public let alpha: Double
        public let tint: String
    }

    public let layers: [Layer]
    /// What colour a star may be. Most of a sky is the first one; the rest are the few that are
    /// not, drawn in proportion to how often they are listed.
    public let tints: [String]
    public let washes: [SkyWash]

    public init(layers: [Layer], tints: [String], washes: [SkyWash]) {
        self.layers = layers
        self.tints = tints
        self.washes = washes
    }

    /// The stars of one layer, in the order they are drawn. Faint ones are common and bright ones
    /// rare, which is the only thing that makes scattered points read as a sky.
    public func stars(in layer: Layer) -> [Star] {
        var generator = SceneryGenerator(seed: layer.seed)
        let side = Double(layer.tile)
        return (0..<layer.count).map { _ in
            let x = generator.unit() * side
            let y = generator.unit() * side
            let brightness = pow(generator.unit(), 2.2)
            let radius =
                layer.radius.lowerBound
                + (layer.radius.upperBound - layer.radius.lowerBound) * brightness
            let alpha =
                layer.alpha.lowerBound
                + (layer.alpha.upperBound - layer.alpha.lowerBound) * brightness
            let pick = Int(generator.unit() * Double(tints.count))
            let tint = tints.isEmpty ? "#ffffff" : tints[min(pick, tints.count - 1)]
            return Star(
                x: x, y: y, radius: radius, alpha: min(alpha, Scenery.starAlphaCeiling), tint: tint)
        }
    }

    /// One layer as a picture a client lays as a repeating background. A star that crosses the
    /// tile's edge is drawn again on the far side, so the tile meets itself without a seam. A
    /// client that draws for itself takes `stars(in:)` instead and lights each one as its own
    /// disc, which needs no picture kept and is sharp at any density.
    public func bitmap(_ layer: Layer) -> SceneryBitmap {
        var canvas = SceneryCanvas(side: layer.tile)
        for star in stars(in: layer) {
            canvas.light(star, halo: layer.halo)
        }
        return canvas.bitmap
    }
}

/// A wide, faint light on the canvas: where its centre sits as shares of the canvas, how far it
/// reaches as a share of the canvas's diagonal, and how much of its colour is there at most.
public struct SkyWash: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let reach: Double
    public let color: String
    public let alpha: Double

    public init(x: Double, y: Double, reach: Double, color: String, alpha: Double) {
        self.x = x
        self.y = y
        self.reach = reach
        self.color = color
        self.alpha = alpha
    }
}

/// Two suns standing on a horizon, and the light they throw on the canvas beneath it.
///
/// The horizon is the lower edge of the bar over the conversation, because that is the one line
/// in the window nothing is ever drawn across: a sun on the canvas itself is behind every card
/// and code block that scrolls past it, and a sun seen in slivers is a rendering fault to the
/// eye, not a sun. The canvas takes only their light, which has no edge to break.
public struct TwinSuns: Equatable, Sendable {
    public struct Sun: Equatable, Sendable {
        /// The centre: how many points in from the bar's leading edge, which is the one stretch
        /// of it that holds nothing (the title is centred and everything that comes and goes
        /// is packed at the trailing end), and how many points it stands above the horizon. A
        /// sun whose rise is less than its radius is setting.
        public let x: Double
        public let rise: Double
        public let radius: Double
        public let core: String
        public let corona: String
        public let alpha: Double

        public init(
            x: Double, rise: Double, radius: Double, core: String, corona: String, alpha: Double
        ) {
            self.x = x
            self.rise = rise
            self.radius = radius
            self.core = core
            self.corona = corona
            self.alpha = alpha
        }
    }

    /// A dune standing on the canvas's lower edge, seen as a silhouette a shade deeper than the
    /// sand: where its crest stands as a share of the canvas's width, how far its foot reaches to
    /// either side as a share of that width, and how many points it rises. Its fill is one flat
    /// tint, because a slope shaded by a gradient this faint shows its steps, and its crest
    /// takes a line of light from the suns.
    public struct Dune: Equatable, Sendable {
        public let x: Double
        public let reach: Double
        public let height: Double
        public let color: String
        public let alpha: Double
        public let crest: String

        public init(
            x: Double, reach: Double, height: Double, color: String, alpha: Double, crest: String
        ) {
            self.x = x
            self.reach = reach
            self.height = height
            self.color = color
            self.alpha = alpha
            self.crest = crest
        }
    }

    public let suns: [Sun]
    public let washes: [SkyWash]
    /// Farthest first, so a nearer dune is drawn over the one behind it.
    public let dunes: [Dune]

    public init(suns: [Sun], washes: [SkyWash], dunes: [Dune]) {
        self.suns = suns
        self.washes = washes
        self.dunes = dunes
    }

    /// The most a dune may deepen the sand under words set on it.
    public static let duneAlphaCeiling = 0.1
}

/// A square picture in straight (not premultiplied) RGBA, a row at a time.
public struct SceneryBitmap: Equatable, Sendable {
    public let side: Int
    public let rgba: [UInt8]

    /// How much of the picture is lit at all, which is what the sky's density is held to.
    public var litShare: Double {
        guard side > 0 else { return 0 }
        var lit = 0
        var index = 3
        while index < rgba.count {
            if rgba[index] > 24 { lit += 1 }
            index += 4
        }
        return Double(lit) / Double(side * side)
    }

    public var peakAlpha: Double {
        var peak: UInt8 = 0
        var index = 3
        while index < rgba.count {
            peak = max(peak, rgba[index])
            index += 4
        }
        return Double(peak) / 255
    }
}

/// SplitMix64: the same numbers on every machine, which a sky that must not move depends on.
struct SceneryGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

/// The tile a layer's stars are lit onto. A sky is almost all dark, so only the lit pixels are
/// kept while it is being painted, as premultiplied light, wrapped at the edges; the whole tile
/// exists once, as the straight RGBA it is handed back in. Where two stars share a pixel the
/// light they add up to is kept whole and only its opacity is held to the ceiling on the way
/// out, so the pixel stays the colour of its stars rather than burning toward white.
struct SceneryCanvas {
    private struct Light {
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var alpha = 0.0
    }

    private let side: Int
    private var lit: [Int: Light] = [:]

    init(side: Int) {
        self.side = side
    }

    mutating func light(_ star: StarField.Star, halo: Double) {
        guard let tint = Contrast.channels(star.tint), side > 0 else { return }
        let haloReach = halo > 0 ? star.radius * 3.2 : 0
        let reach = Int((max(star.radius + 1, haloReach)).rounded(.up))
        let centreX = Int(star.x.rounded(.down))
        let centreY = Int(star.y.rounded(.down))
        for row in (centreY - reach)...(centreY + reach) {
            for column in (centreX - reach)...(centreX + reach) {
                let dx = Double(column) + 0.5 - star.x
                let dy = Double(row) + 0.5 - star.y
                let distance = (dx * dx + dy * dy).squareRoot()
                let core = min(max(star.radius + 0.5 - distance, 0), 1)
                let spill =
                    halo > 0 ? halo * exp(-pow(distance / max(star.radius * 1.6, 0.5), 2)) : 0
                let alpha = star.alpha * max(core, spill)
                guard alpha > 0.004 else { continue }
                add(tint, alpha: alpha, column: wrapped(column), row: wrapped(row))
            }
        }
    }

    private func wrapped(_ value: Int) -> Int {
        ((value % side) + side) % side
    }

    private mutating func add(
        _ tint: (red: Double, green: Double, blue: Double), alpha: Double, column: Int, row: Int
    ) {
        let under = 1 - alpha
        var light = lit[row * side + column] ?? Light()
        light.red = tint.red * alpha + light.red * under
        light.green = tint.green * alpha + light.green * under
        light.blue = tint.blue * alpha + light.blue * under
        light.alpha = alpha + light.alpha * under
        lit[row * side + column] = light
    }

    var bitmap: SceneryBitmap {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for (pixel, light) in lit where light.alpha > 0 {
            let index = pixel * 4
            bytes[index] = Self.byte(light.red / light.alpha)
            bytes[index + 1] = Self.byte(light.green / light.alpha)
            bytes[index + 2] = Self.byte(light.blue / light.alpha)
            bytes[index + 3] = Self.byte(min(light.alpha, Scenery.starAlphaCeiling))
        }
        return SceneryBitmap(side: side, rgba: bytes)
    }

    private static func byte(_ value: Double) -> UInt8 {
        UInt8(min(max(value, 0), 1) * 255 + 0.5)
    }
}

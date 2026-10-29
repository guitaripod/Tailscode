import Foundation

/// A glass plate: the card of a tile or a worker, or a hatched stretch of the hour.
public struct WallPlate: Sendable, Equatable {
    public var rect: WallRect
    public var corner: Double
    public var ink: WallInk
    public var opacity: Double
    /// How strongly the state's colour washes the top of the glass.
    public var wash: Double
    /// A flat wash of the whole plate, for an ask.
    public var flat: Double
    public var borderAlpha: Double
    public var borderWidth: Double
    public var hatch: Bool
    public var sheen: Double

    public init(
        rect: WallRect, corner: Double, ink: WallInk, opacity: Double, wash: Double = 0, flat: Double = 0,
        borderAlpha: Double = 0.34, borderWidth: Double = 1, hatch: Bool = false, sheen: Double = 1
    ) {
        self.rect = rect
        self.corner = corner
        self.ink = ink
        self.opacity = opacity
        self.wash = wash
        self.flat = flat
        self.borderAlpha = borderAlpha
        self.borderWidth = borderWidth
        self.hatch = hatch
        self.sheen = sheen
    }
}

/// The marks a state is told by. Radii and widths in `p1` and `p2` are in glyph units, fractions of
/// the glyph's `size`.
public enum WallGlyphKind: Int, Sendable {
    case orb = 0, arc, dashes, hollow, check, cross, square, ring, bloom, hatched, flat
}

/// One mark. `extent` is how far the quad reaches from the centre in glyph units. The parameters mean:
/// orb `p1` radius, `p2` glow; arc `p1` radius, `p2` width, `p3` progress, `p4` track alpha; dashes
/// `p1` radius, `p2` width, `p3` phase in turns; hollow `p1` radius, `p2` width, `p3` angle, `p4` dot
/// radius; ring `p1` radius, `p2` width; bloom `p1` radius; hatched and flat `p1` radius.
public struct WallGlyph: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var size: Double
    public var extent: Double
    public var kind: WallGlyphKind
    public var ink: WallInk
    public var alpha: Double
    public var p1: Double
    public var p2: Double
    public var p3: Double
    public var p4: Double

    public init(
        x: Double, y: Double, size: Double, extent: Double, kind: WallGlyphKind, ink: WallInk,
        alpha: Double, p1: Double = 0, p2: Double = 0, p3: Double = 0, p4: Double = 0
    ) {
        self.x = x
        self.y = y
        self.size = size
        self.extent = extent
        self.kind = kind
        self.ink = ink
        self.alpha = alpha
        self.p1 = p1
        self.p2 = p2
        self.p3 = p3
        self.p4 = p4
    }
}

/// A mote of light: the ambient field, or a piece of an effect. `size` is its diameter and `core` how
/// much of it is sharp.
public struct WallDot: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var size: Double
    public var core: Double
    public var ink: WallInk
    public var alpha: Double

    public init(x: Double, y: Double, size: Double, core: Double, ink: WallInk, alpha: Double) {
        self.x = x
        self.y = y
        self.size = size
        self.core = core
        self.ink = ink
        self.alpha = alpha
    }
}

/// Light a tile spills onto the ground around it.
public struct WallLight: Sendable, Equatable {
    public var rect: WallRect
    public var ink: WallInk
    public var strength: Double

    public init(rect: WallRect, ink: WallInk, strength: Double) {
        self.rect = rect
        self.ink = ink
        self.strength = strength
    }
}

/// A band of light spreading from a plate's edge across the ground.
public struct WallRipple: Sendable, Equatable {
    public var rect: WallRect
    public var corner: Double
    public var grow: Double
    public var width: Double
    public var ink: WallInk
    public var alpha: Double

    public init(rect: WallRect, corner: Double, grow: Double, width: Double, ink: WallInk, alpha: Double) {
        self.rect = rect
        self.corner = corner
        self.grow = grow
        self.width = width
        self.ink = ink
        self.alpha = alpha
    }
}

/// A small flat bar without glass: a heartbeat bar or a stretch of the hour.
public struct WallBar: Sendable, Equatable {
    public var rect: WallRect
    public var corner: Double
    public var ink: WallInk
    public var alpha: Double

    public init(rect: WallRect, corner: Double, ink: WallInk, alpha: Double) {
        self.rect = rect
        self.corner = corner
        self.ink = ink
        self.alpha = alpha
    }
}

/// A press-and-hold on an ask: where the finger is and how far the ring has filled.
public struct WallHold: Sendable, Equatable {
    public var tile: String
    public var x: Double
    public var y: Double
    public var progress: Double

    public init(tile: String, x: Double, y: Double, progress: Double) {
        self.tile = tile
        self.x = x
        self.y = y
        self.progress = progress
    }
}

/// Everything one frame of the wall needs besides the clock's words.
public struct WallSceneInput: Sendable {
    public var wall: AgentWall
    public var layout: WallLayout
    public var palette: WallPalette
    public var style: WallStyle
    /// Seconds on the client's clock, the same clock the effects were started on.
    public var t: TimeInterval
    public var now: Date
    public var effects: [WallEffect]
    public var motes: WallMotes
    public var ribbon: WallRibbon?
    public var hold: WallHold?
    /// 0 lit to 1 dimmed.
    public var dim: Double
    public var peeking: Bool
    public var animated: Bool
    /// How far the heartbeat bars have slid toward their next slot, `0...1`.
    public var beatSlide: Double
    /// Where tiles that have just left the wall last stood, so their leaving still has a place to play.
    public var departed: [String: WallRect]

    public init(
        wall: AgentWall, layout: WallLayout, palette: WallPalette, style: WallStyle, t: TimeInterval,
        now: Date, effects: [WallEffect] = [], motes: WallMotes, ribbon: WallRibbon? = nil,
        hold: WallHold? = nil, dim: Double = 0, peeking: Bool = false, animated: Bool = true,
        beatSlide: Double = 0, departed: [String: WallRect] = [:]
    ) {
        self.wall = wall
        self.layout = layout
        self.palette = palette
        self.style = style
        self.t = t
        self.now = now
        self.effects = effects
        self.motes = motes
        self.ribbon = ribbon
        self.hold = hold
        self.dim = dim
        self.peeking = peeking
        self.animated = animated
        self.beatSlide = beatSlide
        self.departed = departed
    }
}

/// One frame of the wall as plain values in points of the layout, for a renderer to draw: the ground
/// (tint, vignette, grid, light, ripples), the glass plates, the glyphs, the added light and the
/// motes. Words are the client's.
public struct WallScene: Sendable, Equatable {
    public static let maxLights = 8
    public static let maxRipples = 12

    public var width: Double
    public var height: Double
    public var unit: Double
    public var palette: WallPalette
    public var tint: WallInk
    public var tintAlpha: Double
    public var vignette: Double
    public var vignetteInk: WallInk
    /// The brightness everything is drawn at: 1 lit, down to 0.4 dimmed, and lower while peeking.
    public var dim: Double
    public var driftX: Double
    public var driftY: Double
    public var aurora: Double
    public var gridAlpha: Double
    public var lights: [WallLight] = []
    public var ripples: [WallRipple] = []
    public var plates: [WallPlate] = []
    public var bars: [WallBar] = []
    public var glyphs: [WallGlyph] = []
    public var glows: [WallGlyph] = []
    public var dots: [WallDot] = []
    /// Whether an effect or a hold is playing, which asks for the faster frame rate.
    public var isAnimating = false

    public static func build(_ input: WallSceneInput) -> WallScene {
        var builder = Builder(input)
        builder.run()
        return builder.scene
    }
}

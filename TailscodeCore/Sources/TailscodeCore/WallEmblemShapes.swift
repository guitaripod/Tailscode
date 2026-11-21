import Foundation

/// The pieces of a tile's figure at a moment, the same on every client: the maker's shape in the
/// model's hue in the tile's lower right corner, five pips for the effort beside it, and embers that
/// rise from it while hot work runs. What the person chose for the wall decides how much of it there
/// is: with effects off or the wall held still the figure is a drawing that does not move, Subtle
/// lets it move, Lively adds a glow under it and more embers, and the night dims and warms it.
public enum WallEmblemShapes {
    /// How much of a mote's sprite is its sharp centre where a wall draws motes as sprites; a piece's
    /// `size` is the diameter of that centre.
    public static let dotCore = 0.55

    /// How far the gauge reaches above the figure's centre, in radii.
    static let gaugeReach = 1.3

    /// Where the figure stands in a tile and how large it is: the lower right corner, as large as the
    /// tile affords while its gauge stays clear of the row the glyph and the title stand in, and, in
    /// a tile narrow enough for its line of words to reach the corner, clear of that line too. Nil
    /// when the tile is too small for one.
    public static func place(in tile: WallRect, unit: Double) -> (x: Double, y: Double, radius: Double)? {
        let metrics = WallTileMetrics.tile(tile, unit: unit)
        let words = tile.width < narrow * unit ? wordsLine * unit : 0
        let room = tile.maxY - metrics.padding - metrics.body.y - words
        let radius = min(tile.width * 0.17, room / (1 + gaugeReach), 9 * unit)
        guard radius >= 12 else { return nil }
        return (tile.maxX - metrics.padding - radius, tile.maxY - metrics.padding - radius, radius)
    }

    /// The width, in units, under which a tile's words reach its corner, and the height their line takes.
    static let narrow = 42.0
    static let wordsLine = 3.4

    /// Whether the figure moves in this scene: the wall may move, the person left effects on, and the
    /// tile's work visibly goes on. Every settled tile holds its figure still.
    public static func isLive(_ scene: WallEmblemScene) -> Bool {
        scene.animated && scene.style.effects != .off && motion(of: scene.state) > 0
    }

    public static func pieces(for emblem: WallEmblem, in scene: WallEmblemScene) -> [WallEmblemPiece] {
        guard scene.style.showsEmblems, let place = place(in: scene.tile, unit: scene.unit) else { return [] }
        let live = isLive(scene)
        let lively = scene.style.effects == .lively
        let strength = (scene.style.effects == .off ? 0.34 : (lively ? 0.62 : 0.46))
            * presence(of: scene.state) * (scene.night ? 0.6 : 1) * WallMath.clamp(scene.opacity, 0, 1)
        guard strength > 0.01 else { return [] }
        var pen = Pen(
            x: place.x, y: place.y, radius: place.radius, strength: strength,
            ink: shade(emblem.hue.mixed(with: scene.text, 0.1), night: scene.night),
            tau: live ? scene.t * emblem.pace : 0, sway: live ? motion(of: scene.state) : 0,
            emblem: emblem, bounds: scene.tile)
        pen.pieces.reserveCapacity(96)
        if scene.style.light {
            let breath = live ? 0.5 + 0.5 * sin(pen.tau * 0.9) : 0.4
            let glow = (lively ? 0.16 : 0.1) * (0.7 + 0.5 * breath)
            pen.pieces.append(
                WallEmblemPiece(
                    shape: .bloom(x: place.x, y: place.y, radius: place.radius * 0.95, alpha: strength * glow),
                    ink: pen.ink))
        }
        pen.draw(emblem.form)
        addPips(of: emblem, to: &pen, scene: scene, live: live)
        if live { addEmbers(of: emblem, to: &pen, scene: scene, lively: lively) }
        return pen.pieces
    }

    /// How much a state lets the figure move, `0` held still to `1` free.
    static func motion(of state: WallState) -> Double {
        switch state {
        case .working: return 1
        case .thinking: return 0.55
        case .retrying: return 0.35
        case .background(let stuck): return stuck ? 0 : 0.6
        case .needsYou, .quiet, .finished, .away: return 0
        }
    }

    /// How brightly a state lets the figure show: full for work, lower for everything that waits or
    /// has ended, so the figure never competes with a tile that needs a person.
    static func presence(of state: WallState) -> Double {
        switch state {
        case .working: return 1
        case .thinking: return 0.85
        case .background(let stuck): return stuck ? 0.5 : 0.75
        case .retrying: return 0.65
        case .needsYou: return 0.55
        case .quiet: return 0.5
        case .finished: return 0.45
        case .away: return 0.32
        }
    }

    static func shade(_ ink: WallInk, night: Bool) -> WallInk {
        night ? ink.mixed(with: WallPalette.warmth, 0.22).sunk(0.2) : ink
    }

    /// A colour of the shared rainbow, `0...1` around it.
    static func rainbow(_ position: Double) -> WallInk {
        let stops = Ultracode.rainbowStops
        let wrapped = position - position.rounded(.down)
        let at = wrapped * Double(stops.count - 1)
        let lower = min(stops.count - 2, Int(at))
        let amount = at - Double(lower)
        let a = stops[lower]
        let b = stops[lower + 1]
        return WallInk(
            red: a.red + (b.red - a.red) * amount, green: a.green + (b.green - a.green) * amount,
            blue: a.blue + (b.blue - a.blue) * amount)
    }

    /// The effort as a gauge on the figure's inner side: five short strokes on an arc, the lit ones
    /// in the effort's own colour, or the rainbow under the power, and the rest as faint marks so
    /// the scale reads at a glance.
    private static func addPips(of emblem: WallEmblem, to pen: inout Pen, scene: WallEmblemScene, live: Bool) {
        guard let lit = emblem.litPips else { return }
        let heat = shade(emblem.ember ?? scene.dim, night: scene.night)
        let faint = shade(scene.dim, night: scene.night)
        let count = WallEmblem.pips
        for index in 0..<count {
            let centre = 225 + (Double(index) - Double(count - 1) / 2) * 15.5
            let isLit = index < lit
            let shimmer = live && isLit ? 0.8 + 0.2 * sin(pen.tau * 3 - Double(index) * 0.9) : 1
            let ink =
                !isLit
                ? faint
                : (emblem.power ? shade(rainbow(Double(index) / Double(count) + pen.tau * 0.08), night: scene.night) : heat)
            for step in -1...1 {
                let angle = (centre + Double(step) * 4.1) * .pi / 180
                pen.dot(
                    cos(angle) * gaugeReach, sin(angle) * gaugeReach, size: isLit ? 0.082 : 0.05,
                    alpha: isLit ? 2 * shimmer : 0.75, ink: ink)
            }
        }
    }

    /// Embers leaving the figure upward while hot work runs: none under medium, more for every tier
    /// above it, twice as many when the person chose Lively, each in the effort's own colour.
    private static func addEmbers(of emblem: WallEmblem, to pen: inout Pen, scene: WallEmblemScene, lively: Bool) {
        let tier = emblem.power ? 6 : (emblem.heat ?? 0)
        guard tier >= 2 else { return }
        let count = min(10, (tier - 1) * (lively ? 2 : 1))
        let heat = shade(emblem.ember ?? pen.ink, night: scene.night)
        let rate = 0.16 + 0.035 * Double(tier)
        for index in 0..<count {
            let start = pen.rnd(index, 7)
            let life = scene.t * rate * (0.8 + 0.4 * pen.rnd(index, 8)) + start
            let p = life - life.rounded(.down)
            let lap = Int(life.rounded(.down))
            let lane = pen.rnd(index + lap * 13, 9) - 0.5
            let x = lane * 1.3 + 0.12 * sin(p * 5 + Double(index))
            let y = -0.25 - p * (1.25 + 0.55 * pen.rnd(index, 10))
            let ink = emblem.power ? shade(rainbow(start + p * 0.3), night: scene.night) : heat
            pen.dot(x, y, size: 0.045 + 0.085 * (1 - p), alpha: 1.7 * sin(.pi * p) * pen.sway, ink: ink)
        }
    }
}

extension WallEmblemShapes {
    /// What a figure is drawn with: its centre and radius, the strength every piece is scaled by, the
    /// clock it moves on and how freely it may move. Positions are in figure units, `1` at its radius.
    struct Pen {
        let x: Double
        let y: Double
        let radius: Double
        let strength: Double
        let ink: WallInk
        let tau: Double
        let sway: Double
        let emblem: WallEmblem
        let bounds: WallRect
        var pieces: [WallEmblemPiece] = []

        var rank: Int { min(WallEmblem.topRank, max(0, emblem.rank)) }

        /// How many more motes a stroke takes on a large figure so it still reads as one line, `1...2`.
        var density: Double { WallMath.clamp(radius / 48, 1, 2) }

        /// A deterministic number in `0..<1` for the `i`-th piece and its `k`-th use, the same for the
        /// same model on every machine.
        func rnd(_ i: Int, _ k: Int) -> Double {
            let phase = Double(emblem.seed % 100_000) / 1000
            let value = sin(Double(i + 1) * 12.9898 + Double(k) * 78.233 + phase * 3.7) * 43758.5453
            return value - value.rounded(.down)
        }

        mutating func dot(_ ux: Double, _ uy: Double, size: Double, alpha: Double, ink other: WallInk? = nil) {
            let px = x + ux * radius
            let py = y + uy * radius
            let shown = WallMath.clamp(alpha * strength, 0, 1)
            guard shown > 0.012, px > bounds.x + 3, px < bounds.maxX - 3, py > bounds.y + 3, py < bounds.maxY - 3
            else { return }
            pieces.append(
                WallEmblemPiece(
                    shape: .dot(x: px, y: py, size: max(1.8, size * radius), alpha: shown), ink: other ?? ink))
        }

        mutating func ring(_ r: Double, width: Double, alpha: Double) {
            pieces.append(
                WallEmblemPiece(
                    shape: .ring(
                        x: x, y: y, radius: r * radius, width: max(0.6, width * radius),
                        alpha: WallMath.clamp(alpha * strength, 0, 1)),
                    ink: ink))
        }

        mutating func draw(_ form: WallEmblem.Form) {
            switch form {
            case .spark: spark()
            case .knot: knot()
            case .star: star()
            case .slash: slash()
            case .loop: loop()
            case .wind: wind()
            case .wave: wave()
            case .swirl: swirl()
            case .orbit: orbit()
            }
        }
    }
}

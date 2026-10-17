import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A painted poster: the cairo surface it was drawn on, and what can be read back from it. The
/// surface is freed with the value.
final class PosterSurface: @unchecked Sendable {
    let surface: OpaquePointer
    let width: Int
    let height: Int
    let scale: Double

    init(width: Int, height: Int, scale: Double) {
        self.width = width
        self.height = height
        self.scale = scale
        surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(width), Int32(height))
    }

    deinit { cairo_surface_destroy(surface) }

    var isUsable: Bool { cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS }

    var png: Data? {
        var length: gsize = 0
        guard let bytes = tailscode_surface_png(surface, &length), length > 0 else { return nil }
        defer { g_free(bytes) }
        return Data(bytes: bytes, count: Int(length))
    }

    /// The pixel at a point of the card in its own logical points, as 0...255 red, green, blue.
    func pixel(x: Double, y: Double) -> (red: Int, green: Int, blue: Int) {
        cairo_surface_flush(surface)
        guard let data = cairo_image_surface_get_data(surface) else { return (0, 0, 0) }
        let stride = Int(cairo_image_surface_get_stride(surface))
        let column = min(max(0, Int((x * scale).rounded())), width - 1)
        let row = min(max(0, Int((y * scale).rounded())), height - 1)
        let at = data + row * stride + column * 4
        return (Int(at[2]), Int(at[1]), Int(at[0]))
    }

    /// How many pixels of a rectangle (in logical points) are further from `ground` than a
    /// plain background is, which is how a hero with a head in it is told from an empty box.
    func pixels(in rect: NeuralShare.Rect, notNear ground: (red: Int, green: Int, blue: Int)) -> Int {
        cairo_surface_flush(surface)
        guard let data = cairo_image_surface_get_data(surface) else { return 0 }
        let rowBytes = Int(cairo_image_surface_get_stride(surface))
        let x0 = max(0, Int((rect.x * scale).rounded()))
        let x1 = min(width, Int((rect.maxX * scale).rounded()))
        let y0 = max(0, Int((rect.y * scale).rounded()))
        let y1 = min(height, Int((rect.maxY * scale).rounded()))
        var count = 0
        for row in stride(from: y0, to: y1, by: 2) {
            for column in stride(from: x0, to: x1, by: 2) {
                let at = data + row * rowBytes + column * 4
                let distance =
                    abs(Int(at[2]) - ground.red) + abs(Int(at[1]) - ground.green)
                    + abs(Int(at[0]) - ground.blue)
                if distance > 60 { count += 1 }
            }
        }
        return count
    }

    /// How many sampled pixels differ from another poster's by more than rounding.
    func differences(from other: PosterSurface) -> Int {
        cairo_surface_flush(surface)
        cairo_surface_flush(other.surface)
        guard width == other.width, height == other.height,
            let mine = cairo_image_surface_get_data(surface),
            let theirs = cairo_image_surface_get_data(other.surface)
        else { return -1 }
        let rowBytes = Int(cairo_image_surface_get_stride(surface))
        var count = 0
        for row in stride(from: 0, to: height, by: 3) {
            for column in stride(from: 0, to: width, by: 3) {
                let a = mine + row * rowBytes + column * 4
                let b = theirs + row * rowBytes + column * 4
                let distance =
                    abs(Int(a[0]) - Int(b[0])) + abs(Int(a[1]) - Int(b[1])) + abs(Int(a[2]) - Int(b[2]))
                if distance > 24 { count += 1 }
            }
        }
        return count
    }
}

extension BrainScene {
    /// What the nodes layer draws for a settled turn on a poster: every node and wire lit, nothing
    /// hovered, nothing moving.
    static func resting(model: NeuralBrainModel) -> BrainScene {
        var scene = BrainScene()
        scene.draws = NeuralNodes.draws(model: model, time: 0, reduceMotion: true)
        scene.wires = NeuralNodes.wires(model: model, time: 0, reduceMotion: true)
        scene.reduceMotion = true
        scene.usedZones = Set(model.steps.map(\.zone))
        scene.crowded = model.nodeCount > 60
        return scene
    }
}

/// A turn as a poster, painted with cairo and Pango from `NeuralShare.Card`. The geometry, the
/// words and the colours are Core's; the hero is the stage's own picture (the CPU compositor's full
/// frame with the nodes, wires and ties painted by `BrainPainter` between its interior and its
/// front), so the poster is the head the person was looking at, at the size of the poster.
enum BrainPoster {
    static let lookKey = "tailscode.brainShareLook"
    /// A narrower compositor for a harness that paints many posters and cares about their make, not
    /// their sharpness.
    nonisolated(unsafe) static var heroWidthOverride: Int?
    static let monospace = "Monospace"

    /// The model of a turn as a picture should show it: at rest, with nothing hovered, pinned,
    /// pointed at or replaying, and wearing none of the conversation's live facts (a state forced on
    /// the head, how full the context is, a call in progress), which are about now and not about
    /// the turn the poster is of.
    static func resting(_ model: NeuralBrainModel) -> NeuralBrainModel {
        var rested = model
        rested.stopReplay()
        rested.clearSelection()
        rested.setProvenance(token: nil)
        rested.setDiving(false)
        var facts = rested.context
        facts.activity = nil
        facts.fill = nil
        facts.call = nil
        rested.update(turn: rested.turn, context: facts)
        return rested
    }

    /// The compositor size every poster uses, whatever the scale it is painted at: the design's own
    /// aspect at the widest the layers hold, so the preview, a copy and a saved file share one.
    static var heroPixels: (width: Int, height: Int) {
        let width = heroWidthOverride ?? NeuralAssetName.fullWidth
        return (width, Int((Double(width) * NeuralDesign.height / NeuralDesign.width).rounded()))
    }

    static func savedLook() -> CardStyle {
        let id = UserDefaults.standard.string(forKey: lookKey)
        return NeuralShare.looks.first { $0.id == id } ?? .app
    }

    static func remember(_ look: CardStyle) {
        UserDefaults.standard.set(look.id, forKey: lookKey)
        SettingsFile.capture()
    }

    static func toneTable(palette: Palette, face: NeuralFace, card: NeuralShare.Card) -> NeuralToneTable {
        var table = NeuralToneTable(palette: palette, face: face)
        let ground = Contrast.blend(card.palette.canvas, card.palette.canvasEnd, 0.12) ?? card.palette.canvas
        table.background = linear(ground)
        return table
    }

    private static func linear(_ hex: String) -> NeuralRGB {
        guard let channels = Contrast.channels(hex) else { return NeuralRGB(0, 0, 0) }
        return NeuralRGB(
            powf(Float(channels.red), 2.2), powf(Float(channels.green), 2.2),
            powf(Float(channels.blue), 2.2))
    }

    /// Makes the poster. The compositor is the process's shared one for this look, built off the main
    /// loop, so `done` runs on the main loop a moment later; with no layers on the machine the hero
    /// is the glyph drawn large, so a poster is never empty.
    static func render(
        model: NeuralBrainModel, prompt: String?, style: CardStyle, dark: Bool, scale: Double,
        done: @escaping (PosterSurface?) -> Void
    ) {
        let rested = resting(model)
        let card = NeuralShare.Card.make(turn: rested.turn, prompt: prompt, style: style, dark: dark)
        let palette = NeuralShare.headPalette(style: style, dark: dark)
        guard NeuralAssetFiles.isAvailable else {
            done(paint(card, model: rested, palette: palette, compositor: nil, scale: scale))
            return
        }
        let table = toneTable(palette: palette, face: rested.face, card: card)
        let size = heroPixels
        BrainCompositors.acquire(width: size.width, height: size.height, table: table) { compositor in
            let poster = paint(card, model: rested, palette: palette, compositor: compositor, scale: scale)
            if let compositor { BrainCompositors.release(compositor) }
            done(poster)
        }
    }

    /// The suggested file name: the question's first words and the day the turn began.
    static func filename(prompt: String?, turn: NeuralTurn, now: Date = Date()) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let stamp = day.string(from: turn.startedAt ?? now)
        let words = (prompt ?? "").lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(6).joined(separator: "-")
        let slug = String(words.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "tailscode-turn-\(stamp).png" : "tailscode-turn-\(slug)-\(stamp).png"
    }

    static func paint(
        _ card: NeuralShare.Card, model: NeuralBrainModel, palette: Palette,
        compositor: NeuralCompositor?, scale: Double
    ) -> PosterSurface? {
        let width = Int((NeuralShare.Card.width * scale).rounded())
        let height = Int((NeuralShare.Card.height * scale).rounded())
        let poster = PosterSurface(width: width, height: height, scale: scale)
        guard poster.isUsable, let cr = cairo_create(poster.surface) else { return nil }
        defer { cairo_destroy(cr) }
        cairo_scale(cr, scale, scale)
        paintCanvas(cr, card.palette)
        paintHero(cr, card: card, model: model, palette: palette, compositor: compositor)
        text(cr, card.brand, card)
        text(cr, card.tag, card)
        text(cr, card.count, card)
        text(cr, card.caption, card)
        runs(cr, card)
        for meter in card.meters {
            text(cr, meter.label, card)
            fill(cr, meter.track, card.palette.rule)
            if meter.share > 0 { fill(cr, meter.bar, card.color(meter.slot)) }
            text(cr, meter.value, card)
        }
        if let quote = card.quote {
            fillSquare(cr, quote.rule, card.palette.accent)
            text(cr, quote.label, card)
        }
        text(cr, card.foot, card)
        text(cr, card.footTag, card)
        return poster
    }

    private static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double) {
        Contrast.channels(hex) ?? (0.5, 0.5, 0.5)
    }

    private static func setColor(_ cr: OpaquePointer, _ hex: String, alpha: Double = 1) {
        let color = rgb(hex)
        cairo_set_source_rgba(cr, color.red, color.green, color.blue, alpha)
    }

    /// The canvas falls from its top colour to its foot colour on a diagonal, with a faint pool of
    /// the accent in the upper right where the head's eye is.
    private static func paintCanvas(_ cr: OpaquePointer, _ palette: AnalyticsShare.Palette) {
        let width = NeuralShare.Card.width
        let height = NeuralShare.Card.height
        cairo_save(cr)
        setColor(cr, palette.canvas)
        cairo_paint(cr)
        if palette.canvasEnd != palette.canvas {
            let top = rgb(palette.canvas)
            let foot = rgb(palette.canvasEnd)
            if let fall = cairo_pattern_create_linear(width * 0.3, 0, width * 0.7, height) {
                cairo_pattern_add_color_stop_rgb(fall, 0, top.red, top.green, top.blue)
                cairo_pattern_add_color_stop_rgb(fall, 1, foot.red, foot.green, foot.blue)
                cairo_pattern_set_extend(fall, CAIRO_EXTEND_PAD)
                cairo_set_source(cr, fall)
                cairo_paint(cr)
                cairo_pattern_destroy(fall)
            }
        }
        cairo_translate(cr, width * 0.85, height * 0.12)
        cairo_scale(cr, 1, 520.0 / 900.0)
        let accent = rgb(palette.accent)
        if let glow = cairo_pattern_create_radial(0, 0, 0, 0, 0, 900) {
            cairo_pattern_add_color_stop_rgba(glow, 0, accent.red, accent.green, accent.blue, 0.10)
            cairo_pattern_add_color_stop_rgba(glow, 1, accent.red, accent.green, accent.blue, 0)
            cairo_set_source(cr, glow)
            cairo_new_path(cr)
            cairo_arc(cr, 0, 0, 900, 0, 2 * .pi)
            cairo_fill(cr)
            cairo_pattern_destroy(glow)
        }
        cairo_restore(cr)
    }

    /// The hero fits its box whole rather than being cropped to it, because a head with its top cut
    /// off is not the picture the poster promises; what is left at the sides is the picture's own
    /// ground, taken from its edge so there is no seam, and the picture sits on whole points so its
    /// edge is not blended with that ground into a faint line.
    private static func paintHero(
        _ cr: OpaquePointer, card: NeuralShare.Card, model: NeuralBrainModel, palette: Palette,
        compositor: NeuralCompositor?
    ) {
        let box = card.hero
        let aspect = NeuralDesign.width / NeuralDesign.height
        let fitWidth = min(box.width, box.height * aspect)
        let fitHeight = fitWidth / aspect
        let target = NeuralShare.Rect(
            (box.x + (box.width - fitWidth) / 2).rounded(),
            (box.y + (box.height - fitHeight) / 2).rounded(), fitWidth.rounded(.down),
            fitHeight.rounded(.down))
        let inks = BrainInks(palette: palette, face: model.face)
        cairo_save(cr)
        BrainPainter.round(cr, box.x, box.y, box.width, box.height, NeuralShare.Card.corner)
        cairo_clip(cr)
        let size = heroPixels
        guard let compositor else {
            glyphHero(cr, box: box, target: target, model: model, inks: inks, card: card)
            cairo_restore(cr)
            return
        }
        let frame = model.frame(time: 0, reduceMotion: true)
        var pair = compositor.renderFull(frame, dive: .none, time: 0)
        let ground = edgeColor(of: pair.interior)
        cairo_set_source_rgb(cr, ground.red, ground.green, ground.blue)
        cairo_new_path(cr)
        cairo_rectangle(cr, box.x, box.y, box.width, box.height)
        cairo_fill(cr)
        let factor = target.width / Double(size.width)
        draw(&pair.interior, into: cr, at: target, factor: factor)
        cairo_save(cr)
        cairo_translate(cr, target.x, target.y)
        cairo_scale(cr, factor, factor)
        BrainPainter.paint(
            cr, width: Int32(size.width), height: Int32(size.height),
            scene: BrainScene.resting(model: model), inks: inks)
        cairo_restore(cr)
        draw(&pair.front, into: cr, at: target, factor: factor)
        cairo_restore(cr)
    }

    private static func draw(
        _ picture: inout NeuralSurface, into cr: OpaquePointer, at target: NeuralShare.Rect,
        factor: Double
    ) {
        let width = Int32(picture.width)
        let height = Int32(picture.height)
        let stride = Int32(picture.bytesPerRow)
        picture.bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                let source = cairo_image_surface_create_for_data(
                    base.assumingMemoryBound(to: UInt8.self), CAIRO_FORMAT_ARGB32, width, height, stride)
            else { return }
            cairo_save(cr)
            cairo_translate(cr, target.x, target.y)
            cairo_scale(cr, factor, factor)
            cairo_set_source_surface(cr, source, 0, 0)
            cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_BEST)
            cairo_new_path(cr)
            cairo_rectangle(cr, 0, 0, Double(width), Double(height))
            cairo_fill(cr)
            cairo_restore(cr)
            cairo_surface_destroy(source)
        }
    }

    /// The colour at the middle of the picture's left edge.
    private static func edgeColor(of surface: NeuralSurface) -> (red: Double, green: Double, blue: Double) {
        guard surface.width > 0, surface.height > 0 else { return (0, 0, 0) }
        let at = (surface.height / 2) * surface.bytesPerRow
        return (
            Double(surface.bytes[at + 2]) / 255, Double(surface.bytes[at + 1]) / 255,
            Double(surface.bytes[at]) / 255
        )
    }

    /// The fallback for a machine with no layers: the glyph's silhouette large on the poster's own
    /// panel, with the nodes on it.
    private static func glyphHero(
        _ cr: OpaquePointer, box: NeuralShare.Rect, target: NeuralShare.Rect, model: NeuralBrainModel,
        inks: BrainInks, card: NeuralShare.Card
    ) {
        cairo_set_source_rgb(cr, inks.panel.red, inks.panel.green, inks.panel.blue)
        cairo_new_path(cr)
        cairo_rectangle(cr, box.x, box.y, box.width, box.height)
        cairo_fill(cr)
        let glyphWidth = target.width * 0.62
        let glyphHeight = NeuralGlyph.height(forWidth: glyphWidth)
        cairo_save(cr)
        cairo_translate(
            cr, target.x + (target.width - glyphWidth) / 2, target.y + (target.height - glyphHeight) / 2)
        BrainPainter.glyph(
            cr, glyph: model.glyph, width: glyphWidth, height: glyphHeight, inks: inks, time: 0,
            reduceMotion: true)
        cairo_restore(cr)
    }

    private static func fill(_ cr: OpaquePointer, _ rect: NeuralShare.Rect, _ hex: String) {
        let radius = min(rect.height / 2, 9)
        BrainPainter.round(cr, rect.x, rect.y, rect.width, rect.height, min(radius, rect.width / 2))
        setColor(cr, hex)
        cairo_fill(cr)
    }

    private static func fillSquare(_ cr: OpaquePointer, _ rect: NeuralShare.Rect, _ hex: String) {
        cairo_new_path(cr)
        cairo_rectangle(cr, rect.x, rect.y, rect.width, rect.height)
        setColor(cr, hex)
        cairo_fill(cr)
    }

    private static func font(_ role: NeuralShare.FontRole) -> String {
        "\(monospace)\(role.bold ? " Bold" : "") \(role.size)px"
    }

    /// One label in its box: a single line is let run two glyphs past its box rather than be cut
    /// short of its own words, a wrapped one keeps to the box and to the leading the geometry
    /// reserved.
    private static func text(_ cr: OpaquePointer, _ label: NeuralShare.Label, _ card: NeuralShare.Card) {
        var width = label.rect.width
        let single = label.maxLines == 1
        if single && label.alignment == .leading {
            width += label.font.size * NeuralShare.Card.glyphWidth * 2
        }
        let color = rgb(card.color(label.slot))
        _ = tailscode_poster_text(
            cr, label.text, font(label.font), label.rect.x, label.rect.y, width,
            label.alignment == .trailing ? 2 : 0, Int32(label.maxLines),
            single ? 0 : NeuralShare.Card.quoteLeading / 1.2, label.font.tracking * label.font.size,
            color.red, color.green, color.blue, 1)
    }

    /// The qualifying line is one line in two inks: what was written in the accent, and what else
    /// the turn did in the dim ink, the second starting where the first ends.
    private static func runs(_ cr: OpaquePointer, _ card: NeuralShare.Card) {
        guard let box = card.subRect else { return }
        let face = font(NeuralShare.FontRole(NeuralShare.Card.subSize))
        var x = box.x
        for run in card.sub {
            let color = rgb(card.color(run.slot))
            _ = tailscode_poster_text(
                cr, run.text, face, x, box.y, 0, 0, 1, 0, 0, color.red, color.green, color.blue, 1)
            var measured = 0.0
            var height = 0.0
            tailscode_text_measure(run.text, face, 0, 1, &measured, &height)
            x += measured
        }
    }
}

import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The head at rest, drawn once for a look and a size and shared by every card that wears it.
///
/// A conversation of three hundred turns is three hundred cards, and a compositor render per card
/// is what a card must never cost. The picture is the same head in the same palette for every turn
/// that ended the same way, so it is made once: the compositor draws the whole design space at the
/// picture's size, the two layers are kept as cairo surfaces, and each card paints them and lays
/// its own lights over them. The compositor is borrowed through `BrainCompositors` for the moment
/// the render takes and let go of again, so it leaves with the decoded layers a few seconds after
/// the last card has its picture.
final class BrainPicture: @unchecked Sendable {
    let width: Int
    let height: Int
    let scale: Int
    let interior: OpaquePointer
    let front: OpaquePointer
    let eyeTone: NeuralTone?

    init(
        width: Int, height: Int, scale: Int, interior: NeuralSurface, front: NeuralSurface,
        eyeTone: NeuralTone?
    ) {
        self.width = width
        self.height = height
        self.scale = scale
        self.eyeTone = eyeTone
        self.interior = Self.surface(from: interior, scale: scale)
        self.front = Self.surface(from: front, scale: scale)
    }

    deinit {
        cairo_surface_destroy(interior)
        cairo_surface_destroy(front)
    }

    /// The surface's size in logical pixels.
    var logicalWidth: Double { Double(width) / Double(scale) }
    var logicalHeight: Double { Double(height) / Double(scale) }

    var footprint: Int { width * height * 8 }

    private static func surface(from source: NeuralSurface, scale: Int) -> OpaquePointer {
        let made = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(source.width), Int32(source.height))!
        cairo_surface_flush(made)
        let stride = Int(cairo_image_surface_get_stride(made))
        if let destination = cairo_image_surface_get_data(made) {
            source.bytes.withUnsafeBufferPointer { bytes in
                guard let base = bytes.baseAddress else { return }
                let row = source.width * 4
                for line in 0..<source.height {
                    memcpy(destination + line * stride, base + line * row, row)
                }
            }
        }
        cairo_surface_mark_dirty(made)
        cairo_surface_set_device_scale(made, Double(scale), Double(scale))
        return made
    }
}

enum BrainPictures {
    struct Key: Equatable {
        let table: NeuralToneTable
        let frame: NeuralFrame
        let width: Int
        let height: Int
    }

    private final class Entry {
        let key: Key
        let picture: BrainPicture
        var used = 0
        init(key: Key, picture: BrainPicture) {
            self.key = key
            self.picture = picture
        }
    }

    private nonisolated(unsafe) static var entries: [Entry] = []
    private nonisolated(unsafe) static var waiting: [(Key, scale: Int, [(BrainPicture?) -> Void])] = []
    private nonisolated(unsafe) static var tick = 0
    private static let capacity = 12

    /// How many pictures are held and how big they are together, for the harness.
    static var resident: (count: Int, bytes: Int) {
        (entries.count, entries.reduce(0) { $0 + $1.picture.footprint })
    }

    /// How many renders the compositor has been asked for since launch: a card costs none.
    nonisolated(unsafe) static private(set) var renders = 0

    /// The picture for a head drawn `width` by `height` logical pixels over the whole design space
    /// (the card shows only the part of it the crop keeps), in this look. `done` runs on the main
    /// loop, at once when the picture is held.
    static func picture(
        frame: NeuralFrame, table: NeuralToneTable, width: Double, height: Double, scale: Int,
        done: @escaping (BrainPicture?) -> Void
    ) {
        let pixels = (width: max(1, Int((width * Double(scale)).rounded())),
                      height: max(1, Int((height * Double(scale)).rounded())))
        let key = Key(table: table, frame: frame, width: pixels.width, height: pixels.height)
        if let held = entries.first(where: { $0.key == key }) {
            tick += 1
            held.used = tick
            done(held.picture)
            return
        }
        if let index = waiting.firstIndex(where: { $0.0 == key }) {
            waiting[index].2.append(done)
            return
        }
        waiting.append((key, scale, [done]))
        BrainCompositors.acquire(width: pixels.width, height: pixels.height, table: table) { compositor in
            guard let index = waiting.firstIndex(where: { $0.0 == key }) else {
                if let compositor { BrainCompositors.release(compositor) }
                return
            }
            let callbacks = waiting.remove(at: index)
            guard let compositor else {
                for callback in callbacks.2 { callback(nil) }
                return
            }
            var pair = compositor.makeSurfacePair()
            renders += 1
            compositor.renderFull(frame, dive: .none, time: 0, into: &pair)
            let made = BrainPicture(
                width: pixels.width, height: pixels.height, scale: callbacks.scale,
                interior: pair.interior, front: pair.front, eyeTone: nil)
            BrainCompositors.release(compositor)
            tick += 1
            let entry = Entry(key: key, picture: made)
            entry.used = tick
            entries.append(entry)
            if entries.count > capacity {
                entries.sort { $0.used > $1.used }
                entries.removeLast(entries.count - capacity)
            }
            for callback in callbacks.2 { callback(made) }
        }
    }

    /// Lets go of every picture, for a harness that wants the memory back.
    static func dropAll() {
        entries.removeAll()
    }
}

/// How a card paints its picture: the head, the lights the turn lit in it, the rings where it
/// failed. The same drawing runs on the card at rest and, scaled with the traveller, while the
/// card opens into the stage.
enum BrainCardPainter {
    /// Where design space lands on a picture: the crop's left edge and the points per design unit.
    struct Mapping {
        var x: Double
        var y: Double
        var scale: Double

        func point(_ design: NeuralPoint) -> NeuralPoint {
            NeuralPoint(
                x + (design.x - NeuralStageMetrics.designCrop.x) * scale,
                y + design.y * scale)
        }
    }

    /// The head from a picture rendered over the whole design space, trimmed to its own bounds and
    /// laid at `rect`. A picture that is not there draws the glyph, which is also what a machine
    /// with no layers shows.
    static func head(
        _ cr: OpaquePointer, picture: BrainPicture?, rect: NeuralRect, alpha: Double = 1
    ) {
        guard let picture else { return }
        for surface in [picture.interior, picture.front] {
            layer(
                cr, surface: surface, logicalWidth: picture.logicalWidth,
                logicalHeight: picture.logicalHeight, rect: rect, alpha: alpha)
        }
    }

    /// One picture of the head, rendered over the whole design space at `logicalWidth` by
    /// `logicalHeight` points, laid trimmed to the head's own bounds into `rect`.
    static func layer(
        _ cr: OpaquePointer, surface: OpaquePointer, logicalWidth: Double, logicalHeight: Double,
        rect: NeuralRect, alpha: Double = 1
    ) {
        let crop = NeuralStageMetrics.designCrop
        let wholeWidth = rect.width * NeuralDesign.width / crop.width
        let scaleX = wholeWidth / logicalWidth
        let scaleY = rect.height / logicalHeight
        let offset = crop.x * wholeWidth / NeuralDesign.width
        cairo_save(cr)
        cairo_translate(cr, rect.x, rect.y)
        cairo_rectangle(cr, 0, 0, rect.width, rect.height)
        cairo_clip(cr)
        cairo_scale(cr, scaleX, scaleY)
        cairo_translate(cr, -offset / scaleX, 0)
        cairo_set_source_surface(cr, surface, 0, 0)
        cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD)
        cairo_pattern_set_extend(cairo_get_source(cr), CAIRO_EXTEND_PAD)
        if alpha < 1 { cairo_paint_with_alpha(cr, alpha) } else { cairo_paint(cr) }
        cairo_restore(cr)
    }

    /// One soft light per zone the turn used: a radial gradient at the zone's well, screened over
    /// the head. `lift` is how much of the card's own brightness is left, which is one on the
    /// card and falls to nothing as the card becomes the stage.
    static func lights(
        _ cr: OpaquePointer, card: NeuralBrainCard, mapping: Mapping, inks: BrainInks,
        hovered: Bool, lift: Double = 1
    ) {
        guard lift > 0.002 else { return }
        cairo_save(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_SCREEN)
        for light in card.lights {
            let center = mapping.point(light.center)
            let radius = light.radius * mapping.scale
            let strength = light.strength(hovered: hovered) * lift
            let tone = inks.zone(light.zone)
            let gradient = cairo_pattern_create_radial(center.x, center.y, 0, center.x, center.y, radius)
            cairo_pattern_add_color_stop_rgba(gradient, 0, tone.red, tone.green, tone.blue, strength)
            cairo_pattern_add_color_stop_rgba(
                gradient, 0.55, tone.red, tone.green, tone.blue, strength * 0.45)
            cairo_pattern_add_color_stop_rgba(gradient, 1, tone.red, tone.green, tone.blue, 0)
            cairo_set_source(cr, gradient)
            cairo_new_path(cr)
            cairo_arc(cr, center.x, center.y, radius, 0, 2 * .pi)
            cairo_fill(cr)
            cairo_pattern_destroy(gradient)
        }
        cairo_restore(cr)
    }

    /// The ring a failure leaves: solid where nobody repaired it, dashed where a later step did.
    static func rings(
        _ cr: OpaquePointer, card: NeuralBrainCard, mapping: Mapping, inks: BrainInks, alpha: Double = 1
    ) {
        guard alpha > 0.002 else { return }
        cairo_save(cr)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
        for light in card.lights {
            guard light.ringStyle != .none, let ring = light.ring else { continue }
            let center = mapping.point(light.center)
            let width = max(1.2, ring.strokeWidth * mapping.scale)
            cairo_new_path(cr)
            cairo_arc(cr, center.x, center.y, ring.radius * mapping.scale, 0, 2 * .pi)
            cairo_set_source_rgba(cr, inks.danger.red, inks.danger.green, inks.danger.blue, alpha)
            cairo_set_line_width(cr, width)
            if light.ringStyle == .repairedDashed {
                let pattern = [26 * mapping.scale, 18 * mapping.scale]
                pattern.withUnsafeBufferPointer { cairo_set_dash(cr, $0.baseAddress, 2, 0) }
                cairo_set_source_rgba(cr, inks.danger.red, inks.danger.green, inks.danger.blue, alpha * 0.9)
            } else {
                cairo_set_dash(cr, nil, 0, 0)
            }
            cairo_stroke(cr)
        }
        cairo_restore(cr)
    }
}

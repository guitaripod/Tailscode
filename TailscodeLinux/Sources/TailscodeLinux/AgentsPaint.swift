import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The palette's own tone slots as cairo takes them, read at draw time so a theme change reaches
/// a strip or a lane on its next draw rather than at the next launch.
struct AgentsInks {
    let live: PartyInk
    let attention: PartyInk
    let danger: PartyInk
    let quiet: PartyInk
    let text: PartyInk
    let canvas: PartyInk
    let raised: PartyInk
    let rule: PartyInk

    init(palette: Palette = MatrixTheme.palette) {
        live = PartyInk(hex: palette.accent)
        attention = PartyInk(hex: palette.warn)
        danger = PartyInk(hex: palette.danger)
        quiet = PartyInk(hex: palette.textDim)
        text = PartyInk(hex: palette.text)
        canvas = PartyInk(hex: palette.canvas)
        raised = PartyInk(hex: palette.canvasRaised)
        rule = PartyInk(hex: palette.rule)
    }

    func ink(_ tone: ActivityTone) -> PartyInk {
        switch tone {
        case .live: return live
        case .attention: return attention
        case .danger: return danger
        case .quiet: return quiet
        }
    }
}

extension PartyInk {
    func set(_ cr: OpaquePointer, alpha: Double = 1) {
        cairo_set_source_rgba(cr, red, green, blue, alpha)
    }
}

/// A picture that paints only when it is told something changed. It owns nothing but its closure
/// and the one paint it is asked for, so a strip of bars or a field of lanes costs a line at rest:
/// no timer, no frame clock, nothing between a state change and the paint that shows it. What it
/// paints is kept as a texture the GPU draws for as long as nothing changes, so a canvas that sits
/// beside something moving every frame is never painted again because of it. Its widget keeps it
/// alive, as a drawing area kept its closure, so a maker may let go of it once it is placed.
final class AgentsCanvas: @unchecked Sendable {
    let layer = WallLayer()
    var paint: ((OpaquePointer, Double, Double) -> Void)?
    private let picture = WallPicture()
    private var generation = 0
    private(set) var draws = 0
    /// Every canvas's draws and the logical pixels they covered, for a bench of the wall's cost.
    nonisolated(unsafe) static var drawsEverywhere = 0
    nonisolated(unsafe) static var pixelsEverywhere = 0.0

    var widget: UnsafeMutablePointer<GtkWidget> { layer.widget }

    private final class Weak {
        weak var canvas: AgentsCanvas?
        init(_ canvas: AgentsCanvas) { self.canvas = canvas }
    }

    /// Every canvas alive, so a theme change can paint each of them again: their closures read the
    /// palette when they paint, and a kept picture would otherwise wear the old one until the next
    /// thing it shows changed.
    nonisolated(unsafe) private static var live: [ObjectIdentifier: Weak] = [:]

    init(width: Int32, height: Int32) {
        gtk_widget_set_size_request(layer.widget, width, height)
        layer.draw = { snapshot, width, height in self.snap(snapshot, width, height) }
        Self.live[ObjectIdentifier(self)] = Weak(self)
    }

    deinit {
        Self.live[ObjectIdentifier(self)] = nil
    }

    /// The theme changed: every canvas paints itself again in it.
    static func repaintAll() {
        for entry in live.values { entry.canvas?.redraw() }
    }

    func redraw() {
        generation &+= 1
        layer.redraw()
    }

    private func snap(_ snapshot: WallSnapshot, _ width: Double, _ height: Double) {
        guard let paint else { return }
        picture.ensure(String(generation), width: width, height: height, in: snapshot) { cr, width, height in
            draws += 1
            AgentsCanvas.drawsEverywhere += 1
            AgentsCanvas.pixelsEverywhere += width * height
            paint(cr, width, height)
        }
        snapshot.picture(picture, WatchRect(x: 0, y: 0, width: width, height: height))
    }
}

/// Text inside a drawing, set by Pango from the widget's own font so it follows the desk's size
/// and the person's type scale like every label beside it.
enum AgentsText {
    struct Style {
        var scale = 1.0
        var bold = false
        var lines = 1
        var width: Double?
        var rightAligned = false
    }

    static func layout(
        _ widget: UnsafeMutablePointer<GtkWidget>, _ text: String, style: Style
    ) -> OpaquePointer? {
        guard let layout = gtk_widget_create_pango_layout(widget, text) else { return nil }
        if let context = pango_layout_get_context(layout),
            let base = pango_context_get_font_description(context),
            let font = pango_font_description_copy(base)
        {
            let size = pango_font_description_get_size(font)
            if size > 0 {
                let scaled = Int32((Double(size) * style.scale).rounded())
                if pango_font_description_get_size_is_absolute(font) != 0 {
                    pango_font_description_set_absolute_size(font, Double(scaled))
                } else {
                    pango_font_description_set_size(font, scaled)
                }
            }
            if style.bold { pango_font_description_set_weight(font, PANGO_WEIGHT_SEMIBOLD) }
            pango_layout_set_font_description(layout, font)
            pango_font_description_free(font)
        }
        if let width = style.width {
            pango_layout_set_width(layout, Int32(width * Double(PANGO_SCALE)))
            pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END)
            pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR)
            if style.lines > 1 { pango_layout_set_height(layout, -Int32(style.lines)) }
        }
        if style.rightAligned { pango_layout_set_alignment(layout, PANGO_ALIGN_RIGHT) }
        return layout
    }

    /// The pixel size the text takes in this style.
    static func size(
        _ widget: UnsafeMutablePointer<GtkWidget>, _ text: String, style: Style
    ) -> (width: Double, height: Double) {
        guard let layout = layout(widget, text, style: style) else { return (0, 0) }
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        var width: Int32 = 0
        var height: Int32 = 0
        pango_layout_get_pixel_size(layout, &width, &height)
        return (Double(width), Double(height))
    }

    @discardableResult
    static func draw(
        _ cr: OpaquePointer, _ widget: UnsafeMutablePointer<GtkWidget>, _ text: String, x: Double,
        y: Double, ink: PartyInk, alpha: Double = 1, style: Style
    ) -> (width: Double, height: Double) {
        guard let layout = layout(widget, text, style: style) else { return (0, 0) }
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        var width: Int32 = 0
        var height: Int32 = 0
        pango_layout_get_pixel_size(layout, &width, &height)
        ink.set(cr, alpha: alpha)
        cairo_move_to(cr, x, y)
        pango_cairo_show_layout(cr, layout)
        return (Double(width), Double(height))
    }
}

/// A rounded rectangle as a path.
func agentsRoundedRect(
    _ cr: OpaquePointer, x: Double, y: Double, width: Double, height: Double, radius: Double
) {
    let r = min(radius, width / 2, height / 2)
    cairo_new_sub_path(cr)
    cairo_arc(cr, x + width - r, y + r, r, -.pi / 2, 0)
    cairo_arc(cr, x + width - r, y + height - r, r, 0, .pi / 2)
    cairo_arc(cr, x + r, y + height - r, r, .pi / 2, .pi)
    cairo_arc(cr, x + r, y + r, r, .pi, 3 * .pi / 2)
    cairo_close_path(cr)
}

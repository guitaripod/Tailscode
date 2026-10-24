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

/// A drawing area that paints only when it is told something changed. It owns nothing but its
/// closure and the one draw it is asked for, so a strip of bars or a field of lanes costs a line at
/// rest: no timer, no frame clock, nothing between a state change and the draw that shows it.
final class AgentsCanvas: @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget>
    var paint: ((OpaquePointer, Double, Double) -> Void)?
    private(set) var draws = 0

    init(width: Int32, height: Int32) {
        widget = gtk_drawing_area_new()!
        gtk_widget_set_size_request(widget, width, height)
        _ = Gtk.releaseInstalled
        let held = Unmanaged.passRetained(self).toOpaque()
        gtk_drawing_area_set_draw_func(
            ptr(widget),
            { _, cr, width, height, raw in
                guard let cr, let raw else { return }
                let canvas = Unmanaged<AgentsCanvas>.fromOpaque(raw).takeUnretainedValue()
                canvas.draws += 1
                canvas.paint?(cr, Double(width), Double(height))
            }, held,
            { raw in
                guard let raw else { return }
                Unmanaged<AgentsCanvas>.fromOpaque(raw).release()
            })
    }

    func redraw() { gtk_widget_queue_draw(widget) }
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

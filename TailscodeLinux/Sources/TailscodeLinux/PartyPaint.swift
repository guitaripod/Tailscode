import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A colour as cairo takes it, read from the same hex the stylesheet is written from, so a ball
/// drawn here and a ring drawn by CSS are one hue.
struct PartyInk: Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hex: String) {
        let channels = Contrast.channels(hex)
        self.init(
            red: channels?.red ?? 0.5, green: channels?.green ?? 0.5, blue: channels?.blue ?? 0.5)
    }

    func mixed(with other: PartyInk, _ amount: Double) -> PartyInk {
        PartyInk(
            red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount)
    }

    static let white = PartyInk(red: 1, green: 1, blue: 1)
    static let black = PartyInk(red: 0, green: 0, blue: 0)
}

/// One of the six balls: the model's house as a glass sphere, lit from the upper left, with the
/// button at its heart that a person presses to step the level in edit mode. Drawn with cairo into
/// a 40 point area, and drawn again only when what it shows changes.
final class PartyBall: @unchecked Sendable {
    static let size: Int32 = 40
    let widget: UnsafeMutablePointer<GtkWidget>
    private(set) var ink = PartyInk(hex: "#888888")
    private(set) var inUse = false

    init() {
        widget = gtk_drawing_area_new()!
        gtk_widget_set_size_request(widget, Self.size, Self.size)
        gtk_widget_set_halign(widget, GTK_ALIGN_START)
        gtk_widget_set_valign(widget, GTK_ALIGN_START)
        gtk_widget_set_can_target(widget, 0)
        gtk_widget_set_can_focus(widget, 0)
        tailscode_set_accessible_hidden(widget, 1)
        _ = Gtk.releaseInstalled
        let held = Unmanaged.passRetained(self).toOpaque()
        gtk_drawing_area_set_draw_func(
            ptr(widget),
            { _, cr, width, height, raw in
                guard let cr, let raw else { return }
                Unmanaged<PartyBall>.fromOpaque(raw).takeUnretainedValue()
                    .paint(cr, width: Double(width), height: Double(height))
            }, held,
            { raw in
                guard let raw else { return }
                Unmanaged<PartyBall>.fromOpaque(raw).release()
            })
    }

    func show(hex: String, inUse: Bool) {
        let next = PartyInk(hex: hex)
        guard next != ink || inUse != self.inUse else { return }
        ink = next
        self.inUse = inUse
        gtk_widget_queue_draw(widget)
    }

    private func circle(_ cr: OpaquePointer, _ x: Double, _ y: Double, _ radius: Double) {
        cairo_new_path(cr)
        cairo_arc(cr, x, y, radius, 0, 2 * .pi)
    }

    private func fillRadial(
        _ cr: OpaquePointer, center: (Double, Double), focus: (Double, Double), inner: Double,
        outer: Double, stops: [(Double, PartyInk, Double)]
    ) {
        guard
            let gradient = cairo_pattern_create_radial(
                focus.0, focus.1, inner, center.0, center.1, outer)
        else { return }
        for (offset, ink, alpha) in stops {
            cairo_pattern_add_color_stop_rgba(gradient, offset, ink.red, ink.green, ink.blue, alpha)
        }
        cairo_set_source(cr, gradient)
        cairo_fill_preserve(cr)
        cairo_pattern_destroy(gradient)
        cairo_new_path(cr)
    }

    /// The sphere: a soft glow behind it, the body shaded from a highlight at the upper left to
    /// the house's own dark, a one and a half point white rim at half strength, and the button.
    private func paint(_ cr: OpaquePointer, width: Double, height: Double) {
        let cx = width / 2
        let cy = height / 2
        let radius = min(width, height) / 2 - 3
        let hue = ink
        let glow = inUse ? 0.5 : 0.22
        circle(cr, cx, cy, radius + 3)
        fillRadial(
            cr, center: (cx, cy), focus: (cx, cy), inner: radius - 2, outer: radius + 3,
            stops: [(0, hue, glow), (1, hue, 0)])
        circle(cr, cx, cy, radius)
        fillRadial(
            cr, center: (cx, cy), focus: (cx - radius * 0.38, cy - radius * 0.42), inner: 1,
            outer: radius * 1.15,
            stops: [
                (0, hue.mixed(with: .white, 0.55), 1), (0.45, hue, 1),
                (1, hue.mixed(with: .black, 0.5), 1),
            ])
        circle(cr, cx, cy, radius - 0.75)
        cairo_set_source_rgba(cr, 1, 1, 1, 0.5)
        cairo_set_line_width(cr, 1.5)
        cairo_stroke(cr)
        circle(cr, cx, cy, 7 + 4)
        fillRadial(
            cr, center: (cx, cy), focus: (cx, cy), inner: 5, outer: 11,
            stops: [(0, .white, 0.35), (1, .white, 0)])
        circle(cr, cx, cy, 6)
        fillRadial(
            cr, center: (cx, cy), focus: (cx - 1.5, cy - 2), inner: 0.5, outer: 7,
            stops: [(0, .white, 0.95), (0.6, hue.mixed(with: .white, 0.6), 0.9), (1, hue, 0.9)])
        circle(cr, cx, cy, 6)
        cairo_set_source_rgba(cr, 1, 1, 1, 0.8)
        cairo_set_line_width(cr, 2)
        cairo_stroke(cr)
    }
}

/// The five bars of a level, 3 points wide and 5 to 13 tall, the first `lit` of them in the
/// house's hue and the rest in the dim register.
final class PartyBars: @unchecked Sendable {
    static let heights: [Double] = [5, 7, 9, 11, 13]
    static let width: Int32 = 23
    static let height: Int32 = 13
    let widget: UnsafeMutablePointer<GtkWidget>
    private(set) var lit = 0
    private(set) var ink = PartyInk(hex: "#888888")

    init() {
        widget = gtk_drawing_area_new()!
        gtk_widget_set_size_request(widget, Self.width, Self.height)
        gtk_widget_set_halign(widget, GTK_ALIGN_END)
        gtk_widget_set_valign(widget, GTK_ALIGN_END)
        gtk_widget_set_can_target(widget, 0)
        gtk_widget_set_can_focus(widget, 0)
        tailscode_set_accessible_hidden(widget, 1)
        _ = Gtk.releaseInstalled
        let held = Unmanaged.passRetained(self).toOpaque()
        gtk_drawing_area_set_draw_func(
            ptr(widget),
            { _, cr, _, height, raw in
                guard let cr, let raw else { return }
                Unmanaged<PartyBars>.fromOpaque(raw).takeUnretainedValue()
                    .paint(cr, height: Double(height))
            }, held,
            { raw in
                guard let raw else { return }
                Unmanaged<PartyBars>.fromOpaque(raw).release()
            })
    }

    func show(lit: Int, hex: String) {
        let next = PartyInk(hex: hex)
        guard lit != self.lit || next != ink else { return }
        self.lit = lit
        ink = next
        gtk_widget_queue_draw(widget)
    }

    private func paint(_ cr: OpaquePointer, height: Double) {
        let quiet = PartyInk(hex: MatrixTheme.palette.textDim)
        for (index, bar) in Self.heights.enumerated() {
            let x = Double(index) * 5
            let on = index < lit
            let colour = on ? ink : quiet
            cairo_set_source_rgba(cr, colour.red, colour.green, colour.blue, on ? 1 : 0.28)
            cairo_new_path(cr)
            cairo_rectangle(cr, x, height - bar, 3, bar)
            cairo_fill(cr)
        }
    }
}

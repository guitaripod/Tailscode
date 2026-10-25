import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The top of the wall: the situation in one sentence in the largest type on the screen, what is
/// being watched under it, and the time and date at the right.
final class WatchTopBand: @unchecked Sendable {
    static let headlineSizes = [7.0, 6.0, 5.2, 4.4, 3.6]

    let headline = WatchLabel()
    let watchLine = WatchLabel()
    let clock = WatchLabel(wrap: false)
    let date = WatchLabel(wrap: false)
    private let context: WatchContext
    private let timeFormat = DateFormatter()
    private let dateFormat = DateFormatter()
    private var shownMinute = ""

    init(context: WatchContext) {
        self.context = context
        timeFormat.timeStyle = .short
        timeFormat.dateStyle = .none
        dateFormat.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        clock.set(align: 1)
        date.set(align: 1)
        for label in [clock, date] { gtk_label_set_ellipsize(op(label.widget), PANGO_ELLIPSIZE_NONE) }
        gtk_label_set_ellipsize(op(headline.widget), PANGO_ELLIPSIZE_NONE)
        headline.set(lines: 2)
        watchLine.set(lines: 1)
    }

    var widgets: [UnsafeMutablePointer<GtkWidget>] {
        [headline.widget, watchLine.widget, clock.widget, date.widget]
    }

    func apply(_ wall: AgentWall, now: Date) {
        let palette = context.palette
        headline.set(text: wall.headline)
        watchLine.set(text: wall.watchLine)
        let tone = palette.mood(wall.mood, hasFailure: wall.hasFailure)
        headlineInk = tone
        watchLine.set(style: context.label(2.4, ink: palette.dim))
        clock.set(style: context.label(7.0, bold: true, ink: palette.text))
        date.set(style: context.label(2.4, ink: palette.dim))
        tick(now: now)
    }

    var headlineInk = PartyInk.white

    func tick(now: Date) {
        let time = timeFormat.string(from: now)
        guard time != shownMinute || date.text.isEmpty else { return }
        shownMinute = time
        clock.set(text: time)
        date.set(text: dateFormat.string(from: now))
    }

    /// The largest size the sentence can be set at in its rectangle, one line where it fits.
    func fit(in rect: WatchRect, portrait: Bool) {
        headline.set(lines: 2)
        let start = portrait ? 1 : 0
        for units in Self.headlineSizes.dropFirst(start) {
            headline.set(style: context.label(units, bold: true, ink: headlineInk))
            if headline.height(forWidth: rect.width) <= rect.height + 1 { return }
        }
    }
}

/// What the wall shows when nothing runs: a large slow orb, drawn in the centre of the grid, and
/// the last hour in one line under it.
final class WatchCalmView: @unchecked Sendable {
    let orb = AgentsCanvas(width: 1, height: 1)
    let line = WatchLabel()
    private let context: WatchContext

    init(context: WatchContext) {
        self.context = context
        gtk_widget_set_can_target(orb.widget, 0)
        tailscode_set_accessible_hidden(orb.widget, 1)
        gtk_label_set_ellipsize(op(line.widget), PANGO_ELLIPSIZE_NONE)
        gtk_label_set_xalign(op(line.widget), 0.5)
        gtk_label_set_justify(op(line.widget), GTK_JUSTIFY_CENTER)
        orb.paint = { [weak self] cr, width, _ in self?.paintOrb(cr, width) }
    }

    func apply(_ wall: AgentWall) {
        let words = wall.calm.map { $0.line + " · " + Localized.text("seen by this device") } ?? ""
        line.set(text: words)
        line.set(style: context.label(2.8, ink: context.palette.dim))
        orb.redraw()
    }

    func paintOrb(_ cr: OpaquePointer, _ size: Double) {
        Self.paint(cr, size: size, palette: context.palette, t: context.seconds, animated: context.animated)
    }

    static func paint(
        _ cr: OpaquePointer, size: Double, palette: WatchPalette, t: Double, animated: Bool
    ) {
        let centre = size / 2
        let ink = palette.working.mixed(with: palette.text, 0.25)
        let swell = WatchGlyph.breath(t, period: 9, animated: animated)
        let core = size * (0.17 + 0.012 * swell)
        if let halo = cairo_pattern_create_radial(centre, centre, core * 0.4, centre, centre, size * 0.5) {
            cairo_pattern_add_color_stop_rgba(halo, 0, ink.red, ink.green, ink.blue, 0.2 + 0.1 * swell)
            cairo_pattern_add_color_stop_rgba(halo, 1, ink.red, ink.green, ink.blue, 0)
            cairo_set_source(cr, halo)
            cairo_new_path(cr)
            cairo_arc(cr, centre, centre, size * 0.5, 0, 2 * .pi)
            cairo_fill(cr)
            cairo_pattern_destroy(halo)
        }
        for ring in 0..<3 {
            let radius = size * (0.27 + 0.085 * Double(ring))
            let drift = animated ? 0.5 + 0.5 * sin(2 * .pi * (t / 14 - Double(ring) * 0.14)) : 0.6
            cairo_new_path(cr)
            cairo_arc(cr, centre, centre, radius, 0, 2 * .pi)
            ink.set(cr, alpha: (0.18 - 0.04 * Double(ring)) * (0.55 + 0.45 * drift))
            cairo_set_line_width(cr, max(1, size * 0.004))
            cairo_stroke(cr)
        }
        if let body = cairo_pattern_create_radial(centre - core * 0.3, centre - core * 0.35, core * 0.1, centre, centre, core) {
            let bright = ink.lifted(0.5)
            let deep = ink.sunk(0.35)
            cairo_pattern_add_color_stop_rgba(body, 0, bright.red, bright.green, bright.blue, 0.95)
            cairo_pattern_add_color_stop_rgba(body, 0.6, ink.red, ink.green, ink.blue, 0.9)
            cairo_pattern_add_color_stop_rgba(body, 1, deep.red, deep.green, deep.blue, 0.9)
            cairo_set_source(cr, body)
            cairo_new_path(cr)
            cairo_arc(cr, centre, centre, core, 0, 2 * .pi)
            cairo_fill(cr)
            cairo_pattern_destroy(body)
        }
    }
}

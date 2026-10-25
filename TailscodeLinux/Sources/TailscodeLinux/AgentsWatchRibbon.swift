import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The last hour as one thin ribbon: every lane's working, waiting and background stretches laid
/// on a single track, the endings as dots, a now line at the right edge, and the stretches this
/// device never saw hatched so a quiet hour and a blind one never look alike.
final class WatchRibbon: @unchecked Sendable {
    let canvas = AgentsCanvas(width: 1, height: 1)
    private let context: WatchContext
    private(set) var hour: AgentHour?
    private var isCalm = false
    private var unit = 10.8

    init(context: WatchContext) {
        self.context = context
        gtk_widget_set_can_target(canvas.widget, 0)
        canvas.paint = { [weak self] cr, width, height in self?.paint(cr, width, height, now: self?.context.clock.now ?? Date()) }
    }

    func apply(hour next: AgentHour?, calm: Bool, unit: Double) {
        hour = next
        isCalm = calm
        self.unit = unit
        tailscode_set_accessible_label(
            canvas.widget, Localized.text("The last hour") + ", " + Localized.text("seen by this device"))
        canvas.redraw()
    }

    private func text(
        _ cr: OpaquePointer, _ words: String, size: Double, bold: Bool = false, x: Double, y: Double,
        width: Double, align: PangoAlignment, ink: PartyInk, alpha: Double
    ) {
        guard let layout = pango_cairo_create_layout(cr),
            let description = pango_font_description_new()
        else { return }
        pango_font_description_set_family(description, "Sans")
        pango_font_description_set_weight(description, bold ? PANGO_WEIGHT_BOLD : PANGO_WEIGHT_NORMAL)
        pango_font_description_set_absolute_size(description, size * Double(PANGO_SCALE))
        pango_layout_set_font_description(layout, description)
        pango_layout_set_width(layout, Int32(width * Double(PANGO_SCALE)))
        pango_layout_set_alignment(layout, align)
        pango_layout_set_text(layout, words, -1)
        ink.set(cr, alpha: alpha)
        cairo_move_to(cr, x, y)
        pango_cairo_show_layout(cr, layout)
        pango_font_description_free(description)
        g_object_unref(UnsafeMutableRawPointer(layout))
    }

    func paint(_ cr: OpaquePointer, _ width: Double, _ height: Double, now: Date) {
        let palette = context.palette
        let u = unit
        let small = max(WatchGeometry.minimumText * u, 9)
        let caption = Localized.text("The last hour") + " · " + Localized.text("seen by this device")
        text(
            cr, caption.uppercased(), size: small, bold: true, x: 0, y: 0, width: width,
            align: PANGO_ALIGN_LEFT, ink: palette.dim, alpha: 0.9)
        let trackHeight = (isCalm ? 4.2 : 2.0) * u
        let trackY = small * 1.4 + 0.4 * u
        agentsRoundedRect(cr, x: 0, y: trackY, width: width, height: trackHeight, radius: trackHeight / 2)
        palette.text.set(cr, alpha: 0.07)
        cairo_fill_preserve(cr)
        palette.text.set(cr, alpha: 0.12)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        cairo_save(cr)
        agentsRoundedRect(cr, x: 0, y: trackY, width: width, height: trackHeight, radius: trackHeight / 2)
        cairo_clip(cr)
        if let hour {
            hatch(cr, hour, width: width, y: trackY, height: trackHeight, now: now, palette: palette)
            spans(cr, hour, width: width, y: trackY, height: trackHeight, now: now, palette: palette)
        }
        cairo_restore(cr)
        if let hour { marks(cr, hour, width: width, y: trackY, height: trackHeight, now: now, palette: palette) }
        nowLine(cr, width: width, y: trackY, height: trackHeight, palette: palette)
        ticks(cr, width: width, y: trackY + trackHeight, small: small, palette: palette)
    }

    private func x(_ date: Date, _ width: Double, _ now: Date) -> Double {
        width * min(max(1 - now.timeIntervalSince(date) / AgentHour.span, 0), 1)
    }

    private func hatch(
        _ cr: OpaquePointer, _ hour: AgentHour, width: Double, y: Double, height: Double, now: Date,
        palette: WatchPalette
    ) {
        for gap in hour.unseen {
            let left = x(gap.start, width, now)
            let right = x(gap.end, width, now)
            guard right - left > 1 else { continue }
            cairo_save(cr)
            cairo_rectangle(cr, left, y, right - left, height)
            cairo_clip(cr)
            palette.dim.set(cr, alpha: 0.5)
            cairo_set_line_width(cr, 1)
            var stripe = left - height
            while stripe < right {
                cairo_move_to(cr, stripe, y + height)
                cairo_line_to(cr, stripe + height, y)
                stripe += max(4, unit * 0.55)
            }
            cairo_stroke(cr)
            cairo_restore(cr)
        }
    }

    private func spans(
        _ cr: OpaquePointer, _ hour: AgentHour, width: Double, y: Double, height: Double, now: Date,
        palette: WatchPalette
    ) {
        let bar = height * 0.56
        for lane in hour.lanes where lane.parentID == nil {
            for span in lane.spans {
                let left = x(span.start, width, now)
                let right = x(span.end, width, now)
                guard right >= left else { continue }
                switch span.phase {
                case .working: palette.working.set(cr, alpha: 0.7)
                case .needsYou: palette.needs.set(cr, alpha: 0.95)
                case .background: palette.working.set(cr, alpha: 0.32)
                }
                cairo_rectangle(cr, left, y + (height - bar) / 2, max(2, right - left), bar)
                cairo_fill(cr)
            }
        }
    }

    private func marks(
        _ cr: OpaquePointer, _ hour: AgentHour, width: Double, y: Double, height: Double, now: Date,
        palette: WatchPalette
    ) {
        let radius = min(height * 0.42, unit * 0.9)
        for lane in hour.lanes where lane.parentID == nil {
            for mark in lane.marks {
                let at = x(mark.at, width, now)
                let ink: PartyInk
                switch mark.outcome {
                case .done: ink = palette.finished
                case .failed: ink = palette.failed
                case .stopped, .unknown: ink = palette.dim
                }
                cairo_new_path(cr)
                cairo_arc(cr, min(max(at, radius), width - radius), y + height / 2, radius, 0, 2 * .pi)
                palette.ground.set(cr)
                cairo_fill_preserve(cr)
                ink.set(cr)
                cairo_set_line_width(cr, max(1.2, unit * 0.2))
                cairo_stroke(cr)
            }
        }
    }

    private func nowLine(
        _ cr: OpaquePointer, width: Double, y: Double, height: Double, palette: WatchPalette
    ) {
        palette.working.set(cr, alpha: 0.3)
        cairo_rectangle(cr, width - 4, y - unit * 0.4, 4, height + unit * 0.8)
        cairo_fill(cr)
        palette.working.set(cr)
        cairo_rectangle(cr, width - 2, y - unit * 0.4, 2, height + unit * 0.8)
        cairo_fill(cr)
    }

    private func ticks(
        _ cr: OpaquePointer, width: Double, y: Double, small: Double, palette: WatchPalette
    ) {
        for minutes in stride(from: 60, through: 0, by: -15) {
            let at = width * (1 - Double(minutes) / 60)
            palette.text.set(cr, alpha: 0.25)
            cairo_rectangle(cr, min(max(at, 0), width - 1), y, 1, unit * 0.5)
            cairo_fill(cr)
            let words = minutes == 0 ? Localized.text("now") : Localized.text("%dm", minutes)
            let align = minutes == 0 ? PANGO_ALIGN_RIGHT : (minutes == 60 ? PANGO_ALIGN_LEFT : PANGO_ALIGN_CENTER)
            let box = 12 * unit
            let left = minutes == 0 ? width - box : (minutes == 60 ? 0 : at - box / 2)
            text(
                cr, words, size: small, x: left, y: y + unit * 0.7, width: box, align: align,
                ink: palette.dim, alpha: 0.85)
        }
    }
}

import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The quota strip at the foot of the chat list, drawn from ``QuotaGlance``. One row per line, and
/// every row is the same three columns so a reader's eye runs down them rather than across each
/// line: a tone dot, the words, and the number the words are about — right-aligned, tabular, and
/// always the same distance from the edge whether it reads `9%` or `Used up`.
///
/// The bar between the words and the number is the only part that is conditional. It carries
/// magnitude, which is worth a fixed 44 points where there is room for it and worth nothing at all
/// where taking them would start eating the provider's name — a sidebar dragged narrow keeps the
/// sentence and drops the picture.
enum UsageStrip {
    /// Below this the strip is words and numbers only.
    static let barsNeed: Int32 = 260
    private static let trackWidth = 44
    private static let trackHeight: Int32 = 4
    /// The number column is as wide as its widest word rather than as wide as each row's own
    /// number, so the bars beside it start at one x and the strip reads down instead of across.
    private static let valueWidth: Int32 = 62
    /// A sentence about the reading wears no dot, so it starts where the words start rather than
    /// where the dots do — one left edge down the strip instead of two.
    private static let noticeIndent: Int32 = 14

    static func render(
        _ glance: QuotaGlance, into box: UnsafeMutablePointer<GtkWidget>, bars: Bool
    ) {
        Gtk.removeChildren(of: box)
        gtk_widget_set_visible(box, glance.isEmpty ? 0 : 1)
        gtk_widget_set_tooltip_text(
            box,
            glance.tooltip.isEmpty ? Localized.text("The full quota picture") : glance.tooltip)
        for line in glance.lines {
            gtk_box_append(ptr(box), row(line, bars: bars))
        }
    }

    private static func row(_ line: QuotaGlance.Line, bars: Bool)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        Gtk.addClass(row, "glance-row")

        if line.kind == .notice {
            let text = Gtk.label(line.text, css: "glance-notice", selectable: false)
            Gtk.addClass(text, tone(line.tone))
            gtk_widget_set_hexpand(text, 1)
            gtk_label_set_ellipsize(op(text), PANGO_ELLIPSIZE_END)
            Gtk.margins(text, leading: noticeIndent)
            gtk_box_append(ptr(row), text)
            return row
        }

        let dot = Gtk.label("●", css: "glance-dot", selectable: false)
        Gtk.addClass(dot, dotTone(line))
        gtk_widget_set_valign(dot, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(row), dot)

        let text = Gtk.label(line.text, css: "glance-label", selectable: false)
        gtk_widget_set_hexpand(text, 1)
        gtk_label_set_xalign(op(text), 0)
        gtk_label_set_ellipsize(op(text), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(row), text)

        if bars, let fraction = line.fraction {
            gtk_box_append(ptr(row), track(fraction, line: line))
        }

        if !line.trailing.isEmpty {
            let value = Gtk.label(line.trailing, css: "glance-value", selectable: false)
            Gtk.addClass(value, tone(line.tone))
            gtk_label_set_xalign(op(value), 1)
            gtk_label_set_ellipsize(op(value), PANGO_ELLIPSIZE_NONE)
            gtk_widget_set_halign(value, GTK_ALIGN_END)
            gtk_widget_set_size_request(value, valueWidth, -1)
            gtk_box_append(ptr(row), value)
        }
        return row
    }

    /// The bar reads as one length rather than two: the track keeps its whole width whatever the
    /// fill does, so a row at 9% and a row at 91% are the same object at two readings instead of
    /// two differently sized marks.
    private static func track(_ fraction: Double, line: QuotaGlance.Line)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let track = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(track, "gauge-track")
        gtk_widget_set_size_request(track, Int32(trackWidth), trackHeight)
        gtk_widget_set_valign(track, GTK_ALIGN_CENTER)
        let fill = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(
            fill,
            ProviderBrand.fillClass(severity: severity(line), slug: line.slug))
        let width = Int32((min(max(fraction, 0), 1) * Double(trackWidth)).rounded())
        gtk_widget_set_size_request(fill, max(width, fraction > 0 ? 2 : 0), trackHeight)
        gtk_widget_set_halign(fill, GTK_ALIGN_START)
        gtk_box_append(ptr(track), fill)
        return track
    }

    /// A healthy bar wears its provider's colour and a hot one wears the alarm — the same rule the
    /// panel's gauges follow, so one window never reads as two different states on two surfaces.
    private static func severity(_ line: QuotaGlance.Line) -> String {
        switch line.tone {
        case .danger: return "danger"
        case .warn: return "warn"
        default: return "ok"
        }
    }

    private static func tone(_ tone: QuotaGlance.Tone) -> String {
        switch tone {
        case .danger: return "glance-danger"
        case .warn: return "glance-warn"
        case .ok: return "glance-ok"
        case .balance: return "glance-balance"
        case .quiet: return "glance-quiet"
        }
    }

    /// A balance's dot is its provider's own colour rather than a severity — money that is there is
    /// not a state anybody has to act on.
    private static func dotTone(_ line: QuotaGlance.Line) -> String {
        guard line.tone == .balance, let slug = line.slug else { return tone(line.tone) }
        return "brand-\(slug)"
    }
}

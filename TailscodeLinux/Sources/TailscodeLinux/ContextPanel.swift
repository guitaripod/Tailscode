import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The whole window behind the band's one ring: how much of it the conversation holds, what kind
/// of tokens hold it, what is left, where the number came from, and the one thing to do about it.
///
/// Every number and every word is `ContextFill`'s; this file decides only how round the ring is and
/// how wide a band of the bar each slice gets.
enum ContextPanel {
    private static let heroSize: Int32 = 112
    private static let trackWidth = 380

    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?, fill: ContextFill, title: String,
        compact: (@Sendable () -> Void)?
    ) {
        let (window, content) = Dialogs.window(title: fill.title, parent: parent, width: 460)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 12)
        gtk_box_append(ptr(column), hero(fill, title: title))
        if !fill.slices.isEmpty { gtk_box_append(ptr(column), bands(fill)) }
        gtk_box_append(ptr(column), facts(fill))
        gtk_box_append(ptr(column), Gtk.label(fill.source, css: "usage-source", selectable: false))
        gtk_box_append(ptr(content), column)

        let actions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(actions, GTK_ALIGN_END)
        Gtk.margins(actions, top: 4)
        let windowBits = UInt(bitPattern: window)
        if let compact {
            let button = Gtk.button(Localized.text("Compact…"), css: ["suggested-action"]) {
                if let raw = UnsafeMutableRawPointer(bitPattern: windowBits) {
                    gtk_window_destroy(ptr(raw))
                }
                compact()
            }
            gtk_box_append(ptr(actions), button)
        }
        let dismiss = Gtk.button(Localized.text("Close"), css: compact == nil ? ["suggested-action"] : []) {
            guard let raw = UnsafeMutableRawPointer(bitPattern: windowBits) else { return }
            gtk_window_destroy(ptr(raw))
        }
        gtk_box_append(ptr(actions), dismiss)
        gtk_box_append(ptr(content), actions)
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(dismiss)
    }

    /// The ring with the share inside it, the headline beside it, the sentence under both, and the
    /// advice — when there is any — in the register the fill is in.
    private static func hero(_ fill: ContextFill, title: String) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Gtk.addClass(card, "usage-card")
        if fill.tone == .danger { Gtk.addClass(card, "usage-hero") }

        let name = Gtk.label(title, css: "usage-plan", selectable: false)
        gtk_label_set_ellipsize(op(name), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(op(name), 0)
        gtk_box_append(ptr(card), name)

        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 16)
        gtk_box_append(ptr(row), ring(fill))
        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        gtk_widget_set_valign(words, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(words, 1)
        let headline = Gtk.label(fill.headline, css: "context-headline", selectable: false)
        gtk_label_set_xalign(op(headline), 0)
        gtk_label_set_ellipsize(op(headline), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(words), headline)
        let summary = Gtk.label(fill.summary, css: "context-summary", wrap: true, selectable: false)
        gtk_label_set_xalign(op(summary), 0)
        gtk_box_append(ptr(words), summary)
        gtk_box_append(ptr(row), words)
        gtk_box_append(ptr(card), row)

        if let advice = fill.advice {
            let css = fill.tone == .danger ? "context-advice-danger" : "context-advice"
            let label = Gtk.label(advice, css: css, wrap: true, selectable: false)
            gtk_label_set_xalign(op(label), 0)
            gtk_box_append(ptr(card), label)
        }
        return card
    }

    /// The hero ring: the same painter the band uses, larger, with the percentage laid over it.
    private static func ring(_ fill: ContextFill) -> UnsafeMutablePointer<GtkWidget> {
        let overlay = gtk_overlay_new()!
        let area = tailscode_ring_new()!
        gtk_widget_set_size_request(area, heroSize, heroSize)
        gtk_overlay_set_child(op(overlay), area)
        let palette = MatrixTheme.palette
        let hex: String
        switch fill.tone {
        case .quiet: hex = palette.accent
        case .attention: hex = palette.warn
        case .danger: hex = palette.danger
        }
        let rgb = PresenceRGB(hex: hex) ?? PresenceRGB(red: 0.5, green: 0.5, blue: 0.5)
        [rgb.red, rgb.green, rgb.blue].withUnsafeBufferPointer {
            tailscode_ring_set(area, fill.fraction ?? 0, $0.baseAddress, 9.0, 0.16)
        }
        let centre = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_halign(centre, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(centre, GTK_ALIGN_CENTER)
        let share = Gtk.label(
            fill.percent.map { "\($0)%" } ?? StatusFacts.tokens(fill.used),
            css: "spend-total", selectable: false)
        gtk_label_set_ellipsize(op(share), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(centre), share)
        let caption = Gtk.label(
            fill.percent == nil ? Localized.text("tokens") : Localized.text("in use"),
            css: "spend-caption", selectable: false)
        gtk_label_set_ellipsize(op(caption), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(centre), caption)
        gtk_overlay_add_overlay(op(overlay), centre)
        gtk_widget_set_halign(overlay, GTK_ALIGN_START)
        gtk_widget_set_valign(overlay, GTK_ALIGN_CENTER)
        return overlay
    }

    /// The window as one bar, banded by what kind of tokens fill it, with a legend row per band.
    private static func bands(_ fill: ContextFill) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Gtk.addClass(card, "usage-card")
        gtk_box_append(
            ptr(card),
            heading(
                Localized.text("What fills it"),
                trailing: fill.window.map { Localized.text("of %@", StatusFacts.tokens($0)) }))

        let track = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 1)
        Gtk.addClass(track, "context-track")
        gtk_widget_set_size_request(track, Int32(trackWidth), 10)
        gtk_widget_set_halign(track, GTK_ALIGN_START)
        gtk_widget_set_overflow(track, GTK_OVERFLOW_HIDDEN)
        for slice in fill.slices {
            let band = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            Gtk.addClass(band, "context-band-\(slice.id)")
            let width = max(2, Int(Double(trackWidth) * min(max(slice.share, 0), 1)))
            gtk_widget_set_size_request(band, Int32(width), 10)
            gtk_widget_set_tooltip_text(
                band, "\(slice.label) · \(StatusFacts.tokens(slice.tokens))")
            gtk_box_append(ptr(track), band)
        }
        gtk_box_append(ptr(card), track)

        for slice in fill.slices {
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            let swatch = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            Gtk.addClass(swatch, "context-swatch")
            Gtk.addClass(swatch, "context-band-\(slice.id)")
            gtk_widget_set_size_request(swatch, 10, 10)
            gtk_widget_set_valign(swatch, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(row), swatch)
            let name = Gtk.label(slice.label, css: "usage-gauge-label", selectable: false)
            gtk_label_set_xalign(op(name), 0)
            gtk_widget_set_hexpand(name, 1)
            gtk_box_append(ptr(row), name)
            let share = Gtk.label(
                "\(Int((slice.share * 100).rounded()))%", css: "spend-caption", selectable: false)
            gtk_label_set_ellipsize(op(share), PANGO_ELLIPSIZE_NONE)
            gtk_box_append(ptr(row), share)
            let count = Gtk.label(
                StatusFacts.tokens(slice.tokens), css: "usage-detail-value", selectable: false)
            gtk_label_set_ellipsize(op(count), PANGO_ELLIPSIZE_NONE)
            gtk_box_append(ptr(row), count)
            gtk_box_append(ptr(card), row)
        }
        return card
    }

    private static func facts(_ fill: ContextFill) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "usage-card")
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        for fact in fill.facts {
            let cell = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
            let value = Gtk.label(fact.value, css: "usage-detail-value", selectable: false)
            gtk_label_set_xalign(op(value), 0)
            gtk_label_set_ellipsize(op(value), PANGO_ELLIPSIZE_END)
            gtk_box_append(ptr(cell), value)
            let caption = Gtk.label(fact.label.uppercased(), css: "spend-caption", selectable: false)
            gtk_label_set_ellipsize(op(caption), PANGO_ELLIPSIZE_NONE)
            gtk_label_set_xalign(op(caption), 0)
            gtk_box_append(ptr(cell), caption)
            gtk_box_append(ptr(row), cell)
        }
        gtk_box_append(ptr(card), row)
        return card
    }

    private static func heading(_ text: String, trailing: String?)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let title = Gtk.label(text, css: "usage-provider", selectable: false)
        gtk_label_set_xalign(op(title), 0)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(row), title)
        if let trailing {
            let caption = Gtk.label(trailing, css: "spend-caption", selectable: false)
            gtk_label_set_ellipsize(op(caption), PANGO_ELLIPSIZE_NONE)
            gtk_box_append(ptr(row), caption)
        }
        return row
    }
}

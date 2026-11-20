import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The pieces every expert surface on this desk is drawn from: the mark, a line in its tone, the
/// chips a task starts with.
enum ExpertMarks {
    enum Size: String {
        case tiny, normal, row, large
    }

    /// The expert's glyph on its own hue.
    static func mark(_ glyph: String, hue: ExpertHue, size: Size = .normal) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(glyph, css: "expert-mark", selectable: false)
        Gtk.addClass(label, "expert-hue-\(hue.rawValue)")
        if size != .normal { Gtk.addClass(label, "expert-mark-\(size.rawValue)") }
        gtk_label_set_xalign(op(label), 0.5)
        gtk_label_set_yalign(op(label), 0.5)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(label, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(label, glyph)
        return label
    }

    static func mark(_ expert: MachineExpert, size: Size = .normal) -> UnsafeMutablePointer<GtkWidget> {
        mark(expert.glyph, hue: ExpertHue(expert.hue), size: size)
    }

    static func toneClass(_ tone: ExpertTone) -> String { "expert-tone-\(tone.rawValue)" }

    /// The class an Adwaita row wears so its subtitle carries the tone; nil for a quiet line.
    static func lineClass(_ tone: ExpertTone) -> String? {
        tone == .quiet ? nil : "expert-line-\(tone.rawValue)"
    }

    static func line(_ line: ExpertLine, css: String = "row-detail", wrap: Bool = true) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(line.text, css: css, wrap: wrap, selectable: false)
        Gtk.addClass(label, toneClass(line.tone))
        gtk_label_set_xalign(op(label), 0)
        return label
    }

    /// A row of chips that wraps onto further lines rather than asking for width.
    static func chips(_ lines: [ExpertLine]) -> UnsafeMutablePointer<GtkWidget> {
        let widgets = lines.map { chip -> UnsafeMutablePointer<GtkWidget> in
            let label = Gtk.label(chip.text, css: "expert-chip", selectable: false)
            if chip.tone != .quiet { Gtk.addClass(label, toneClass(chip.tone)) }
            return label
        }
        return Gtk.wrapRow(widgets, spacing: 6)
    }

    /// An Adwaita row for a reading: its title, its tone-coloured detail, its trailing words.
    static func row(_ reading: ExpertRowReading, prefix: UnsafeMutablePointer<GtkWidget>? = nil) -> UnsafeMutablePointer<GtkWidget> {
        let row = MachineRows.row(reading.title, subtitle: reading.detail.text, subtitleCSS: lineClass(reading.detail.tone))
        if let prefix { adw_action_row_add_prefix(ptr(row), prefix) }
        if let tag = reading.tag {
            let label = Gtk.label(tag.text, css: "expert-stale", selectable: false)
            gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_NONE)
            gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
            adw_action_row_add_suffix(ptr(row), label)
        }
        if let trailing = reading.trailing, !trailing.isEmpty {
            let label = Gtk.label(trailing, css: "row-meta", selectable: false)
            gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_END)
            let widest = trailing.split(separator: "\n").map(\.count).max() ?? trailing.count
            gtk_label_set_width_chars(op(label), Int32(min(widest, 10)))
            gtk_label_set_max_width_chars(op(label), 24)
            gtk_widget_set_tooltip_text(label, trailing)
            gtk_label_set_justify(op(label), GTK_JUSTIFY_RIGHT)
            gtk_label_set_xalign(op(label), 1)
            gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
            adw_action_row_add_suffix(ptr(row), label)
        }
        tailscode_set_accessible_label(row, reading.accessibilityLabel)
        return row
    }

    /// A small lamp in a tone, for a bench row.
    static func lamp(_ tone: ExpertTone) -> UnsafeMutablePointer<GtkWidget> {
        let glyph: String
        switch tone {
        case .good: glyph = "●"
        case .active: glyph = "●"
        case .attention: glyph = "●"
        case .failing: glyph = "●"
        case .quiet: glyph = "○"
        }
        let label = Gtk.label(glyph, css: toneClass(tone), selectable: false)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(label, 18, -1)
        return label
    }
}

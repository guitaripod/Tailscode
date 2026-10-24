import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension TranscriptRow {
    /// Where the answering model changed: the new model's dot in its own tint, its word bold, and
    /// the old one's after it, quiet. One flat line that wraps rather than truncates.
    static func modelSeam(_ seam: ModelSwitch) -> UnsafeMutablePointer<GtkWidget> {
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        Gtk.addClass(line, "model-seam")
        gtk_widget_set_halign(line, GTK_ALIGN_START)
        gtk_widget_set_size_request(line, -1, Int32(TranscriptGaps.metrics.seamRowHeight))
        let dot = Gtk.label("●", css: "dial-dot", selectable: false)
        gtk_widget_set_valign(dot, GTK_ALIGN_CENTER)
        DialPill.swapClass(
            on: dot, among: DialPill.modelTintClasses, chosen: seamTint(seam))
        let label = Gtk.label("", css: "model-seam-text", wrap: true, selectable: false)
        gtk_label_set_markup(op(label), seamMarkup(seam))
        gtk_label_set_max_width_chars(op(label), 90)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(line), dot)
        gtk_box_append(ptr(line), label)
        tailscode_set_accessible_label(line, seam.line)
        return line
    }

    /// What the person typed in a message that may carry a brief: the words before the tag, or the
    /// whole text when nothing rode along.
    static func typedWords(_ text: String) -> String {
        CarryMark.split(text)?.rest ?? text
    }

    static func seamTint(_ seam: ModelSwitch) -> String {
        ModelTint.identityClass(
            family: ModelTint.family(seam.selection.modelID, providerID: seam.selection.providerID),
            name: seam.to)
    }

    static func seamMarkup(_ seam: ModelSwitch) -> String {
        let quiet = MatrixTheme.palette.textDim
        return "<b>" + PangoMarkdown.escape(seam.to) + "</b> <span foreground=\"\(quiet)\">"
            + PangoMarkdown.escape(seam.fromText) + "</span>"
    }

    /// The first row of a carried chat: where the conversation came from, the source in bold, and
    /// the chevron that says the line opens the brief it rode in.
    static func carriedLine(
        _ reading: CarryReading, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let glyph = Gtk.label("↩", css: "carried-glyph", selectable: false)
        gtk_widget_set_valign(glyph, GTK_ALIGN_CENTER)
        let label = Gtk.label("", css: "carried-text", wrap: true, selectable: false)
        gtk_label_set_markup(op(label), carriedMarkup(reading))
        gtk_label_set_max_width_chars(op(label), 90)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        let chevron = Gtk.label("›", css: "carried-glyph", selectable: false)
        gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER)
        let content = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_box_append(ptr(content), glyph)
        gtk_box_append(ptr(content), label)
        gtk_box_append(ptr(content), chevron)
        let press = gtk_button_new()!
        Gtk.addClass(press, "flat")
        Gtk.addClass(press, "carried-line")
        gtk_button_set_child(ptr(press), content)
        gtk_widget_set_halign(press, GTK_ALIGN_START)
        gtk_widget_set_size_request(press, -1, Int32(TranscriptGaps.metrics.seamRowHeight))
        gtk_widget_set_cursor_from_name(press, "pointer")
        tailscode_set_accessible_label(press, reading.line)
        let present = context.presentText
        let title = Localized.text("Carried conversation")
        let summary = reading.summary
        let brief = reading.brief
        Gtk.connect(UnsafeMutableRawPointer(press), "clicked") {
            present?(title, summary, brief, false)
        }
        return press
    }

    static func carriedMarkup(_ reading: CarryReading) -> String {
        let line = PangoMarkdown.escape(reading.line)
        let source = PangoMarkdown.escape(reading.source)
        let lead = PangoMarkdown.escape(Localized.text("Continued from %@", reading.source))
        guard !source.isEmpty, line.hasPrefix(lead),
            let found = lead.range(of: source, options: .backwards)
        else { return line }
        let start = line.index(line.startIndex, offsetBy: lead.distance(from: lead.startIndex, to: found.lowerBound))
        let end = line.index(start, offsetBy: source.count)
        return line.replacingCharacters(in: start..<end, with: "<b>" + source + "</b>")
    }
}

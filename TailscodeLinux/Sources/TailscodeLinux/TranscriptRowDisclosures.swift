import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension TranscriptRow {
    final class FoldState: @unchecked Sendable {
        var opened: Bool
        init(opened: Bool) { self.opened = opened }
    }

    /// The copy button of a block: the bytes go to the clipboard exactly, and the button says
    /// so for a moment where the pointer already is, beside the toast.
    static func copyButton(_ bytes: String, toast: (@Sendable (String) -> Void)?)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let slot = Gtk.Slot()
        let button = Gtk.button(Localized.text("copy"), css: ["flat", "code-copy"]) {
            Gtk.copyToClipboard(bytes)
            toast?(Localized.text("Code copied"))
            guard let button = UnsafeMutablePointer<GtkWidget>(bitPattern: slot.bits) else { return }
            gtk_button_set_label(ptr(button), Localized.text("copied"))
            Gtk.after(1500) {
                guard let button = UnsafeMutablePointer<GtkWidget>(bitPattern: slot.bits) else { return }
                gtk_button_set_label(ptr(button), Localized.text("copy"))
            }
        }
        slot.bits = UInt(bitPattern: button)
        return button
    }

    static func reasoning(_ text: String, key: String, context: TranscriptContext)
        -> UnsafeMutablePointer<GtkWidget>
    {
        context.liveReasoning[key] = text
        let header = Gtk.label(Self.thoughtHeader(text), css: "reasoning-label", selectable: false)
        let toggle = context.onToggle
        let reveal = context.revealRow
        return Gtk.disclosure(
            header: header, expanded: context.isExpanded(key),
            onToggle: { open, bits in
                toggle?(key, open)
                if open { reveal?(bits) }
            }
        ) { [weak context] in
            let body = Gtk.label(
                context?.liveReasoning[key] ?? text, css: "reasoning-body", wrap: true)
            Gtk.margins(body, leading: 14)
            return body
        }
    }

    static func thoughtHeader(_ text: String) -> String {
        Localized.text("Thought · %@ words", "\(text.split(whereSeparator: \.isWhitespace).count)")
    }

    /// A thought growing under its own disclosure, written into the widget it already has. The
    /// header counts words, so it changes with every arrival; tearing the row down and building it
    /// again twenty times a second is the flicker, not the counting.
    static func restateReasoning(
        _ widget: UnsafeMutablePointer<GtkWidget>, text: String, key: String,
        context: TranscriptContext
    ) -> Bool {
        func isLabel(_ candidate: UnsafeMutablePointer<GtkWidget>) -> Bool {
            let instance = UnsafeMutableRawPointer(candidate).assumingMemoryBound(
                to: GTypeInstance.self)
            return g_type_check_instance_is_a(instance, gtk_label_get_type()) != 0
        }
        guard let button = gtk_widget_get_first_child(widget),
            let header = Gtk.disclosureHeader(button), isLabel(header)
        else { return false }
        context.liveReasoning[key] = text
        gtk_label_set_text(op(header), thoughtHeader(text))
        if let body = gtk_widget_get_next_sibling(button), isLabel(body) {
            gtk_label_set_text(op(body), text)
        }
        return true
    }

    /// A thumbnail, not a poster: the transcript is for reading, and a picture in it is a
    /// reference — small, scaled to fit, one click from the full-window viewer. Until the bytes
    /// arrive, the placeholder holds a thumbnail-sized space so the arrival replaces it instead
    /// of shoving everything below it down — the difference between a photo developing and a
    /// transcript twitching.
    static func filePart(
        _ reference: FileReference, mine: Bool, key: String, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let name = reference.filename ?? reference.path.map {
            URL(fileURLWithPath: $0).lastPathComponent
        } ?? "file"
        let isImage = (reference.mime ?? "").hasPrefix("image/")
        guard isImage else {
            return Gtk.label("📎 \(name)", css: "attachment")
        }
        let thumbWidth = Int32(ImagePreview.deskBound(ImagePreview.deskWidth, mine: mine))
        let thumbHeight = Int32(ImagePreview.deskBound(ImagePreview.deskHeight, mine: mine))
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        let bits = context.texture(forKey: key)
        if bits != 0 {
            let texture = OpaquePointer(bitPattern: Int(bitPattern: bits))
            let width = tailscode_texture_width(texture)
            let height = tailscode_texture_height(texture)
            let scale = min(
                Double(thumbWidth) / Double(max(1, width)),
                Double(thumbHeight) / Double(max(1, height)), 1)
            let fitted = (
                Int32(Double(width) * scale), Int32(Double(height) * scale))
            let picture = tailscode_picture_for_texture_sized(
                texture, fitted.0, fitted.1)!
            gtk_picture_set_content_fit(op(picture), GTK_CONTENT_FIT_CONTAIN)
            gtk_widget_set_size_request(picture, fitted.0, fitted.1)
            Gtk.addClass(picture, "image-part")
            let opener = gtk_button_new()!
            Gtk.addClass(opener, "flat")
            gtk_widget_set_halign(opener, GTK_ALIGN_START)
            gtk_button_set_child(ptr(opener), picture)
            let open = context.openImage
            Gtk.connect(UnsafeMutableRawPointer(opener), "clicked") {
                open?(key, name)
            }
            gtk_box_append(ptr(column), opener)
            let dims = context.dimensions(forKey: key) ?? (width, height)
            gtk_box_append(
                ptr(column),
                Gtk.label("\(name) · \(dims.0)×\(dims.1)", css: "row-detail", selectable: false))
        } else {
            let frame = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            Gtk.addClass(frame, "image-part")
            gtk_widget_set_size_request(frame, thumbWidth, thumbHeight)
            gtk_widget_set_halign(frame, GTK_ALIGN_START)
            let label = Gtk.label(
                Localized.text("🖼 %@ — loading…", name), css: "dim", selectable: false)
            gtk_widget_set_halign(label, GTK_ALIGN_CENTER)
            gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
            gtk_widget_set_vexpand(label, 1)
            gtk_box_append(ptr(frame), label)
            gtk_box_append(ptr(column), frame)
            context.requestImage?(reference, key)
        }
        return column
    }

    /// A compaction is a seam, not a message: one divider line saying what was traded for what —
    /// `── Context compacted · 311.6k → 16.4k tokens · 1m 54s ›` — where a card with a bar and a
    /// sentence used to stand. The bar and the sentence moved to the reader the line opens, which
    /// is also where the CLI's machine-facing summary, tens of thousands of words, has always
    /// been read rather than cramped into the flow. A seam with no summary behind it is not
    /// pressable and wears no chevron.
    static func seam(
        _ compaction: Compaction, key: String, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let story = CompactionStory.done(compaction)
        let readable = story.isReadable
        let words =
            [story.title, story.detail].joined(separator: " · ") + (readable ? " ›" : "") + "\u{2002}"
        let label = Gtk.label(words, css: "seam-text", selectable: false)
        gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_END)
        gtk_label_set_single_line_mode(op(label), 1)
        gtk_label_set_max_width_chars(op(label), 120)
        guard let summary = story.summary, readable else {
            return dividerLine(around: label)
        }
        let present = context.presentText
        let header = [CompactionStory.summaryHeader(compaction), story.footnote]
            .compactMap { $0 }.joined(separator: "\n")
        let press = gtk_button_new()!
        Gtk.addClass(press, "flat")
        Gtk.addClass(press, "seam-line-press")
        gtk_button_set_child(ptr(press), label)
        gtk_widget_set_tooltip_text(press, Localized.text("Read the summary"))
        gtk_widget_set_cursor_from_name(press, "pointer")
        Gtk.connect(UnsafeMutableRawPointer(press), "clicked") {
            present?(Localized.text("Compaction summary"), header, summary, false)
        }
        return dividerLine(around: press)
    }

    /// A line the transcript restarts on: a hairline either side of whatever the line says, at
    /// the flat line's own height.
    static func dividerLine(around middle: UnsafeMutablePointer<GtkWidget>)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(line, "seam-line")
        gtk_widget_set_size_request(line, -1, Int32(TranscriptGaps.metrics.seamRowHeight))
        let before = Gtk.hairline()
        let after = Gtk.hairline()
        gtk_widget_set_valign(before, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(after, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(middle, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(line), before)
        gtk_box_append(ptr(line), middle)
        gtk_box_append(ptr(line), after)
        return line
    }
}

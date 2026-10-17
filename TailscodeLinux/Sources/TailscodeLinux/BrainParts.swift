import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The words only the brain's own surfaces say on this desk, beside Core's, so the card, the
/// readout and the footer never spell a sentence of their own.
enum BrainWords {
    static var settled: String { Localized.text("Settled") }
    static var turn: String { Localized.text("TURN") }
    static var needsYou: String { Localized.text("NEEDS YOU") }
    static var replaying: String { Localized.text("REPLAY") }
    static var relations: String { Localized.text("RELATIONS") }
    static var output: String { Localized.text("OUTPUT") }
    static var diff: String { Localized.text("DIFF") }
    static var matches: String { Localized.text("MATCHES") }
    static var result: String { Localized.text("RESULT") }
    static var readLabel: String { Localized.text("READ") }
    static var whereTheWorkWent: String { Localized.text("WHERE THE WORK WENT") }
    static var failures: String { Localized.text("FAILURES") }
    static var changed: String { Localized.text("CHANGED") }
    static var answer: String { Localized.text("ANSWER") }
    static var soFar: String { Localized.text("SO FAR") }
    static var log: String { Localized.text("EARLIER") }
    static var copied: String { Localized.text("Copied") }
    static var hoverHint: String { Localized.text("hover a step to read it") }
    static var zoneHint: String { Localized.text("click a row to pin it on the stage") }
    static var surfaceHint: String { Localized.text("esc surfaces") }
    static var pinned: String { Localized.text("pinned") }
    static var inTheAnswer: String { Localized.text("In the answer") }
    static var close: String { Localized.text("Close") }
    static var share: String { Localized.text("Share") }
    static var readoutLabel: String { Localized.text("What the head is saying") }
    static var live: String { Localized.text("live") }

    static func steps(_ count: Int) -> String {
        count == 1 ? Localized.text("1 step") : Localized.text("%lld steps", count)
    }

    static func lines(_ count: Int) -> String {
        count == 1 ? Localized.text("1 line") : Localized.text("%lld lines", count)
    }

    static func lastLines(_ count: Int) -> String { Localized.text("live · last %lld lines", count) }

    static func zoneSteps(_ label: String) -> String { Localized.text("%@ · steps in order", label) }

    static func stepsOf(_ count: Int, _ total: Int) -> String {
        Localized.text("%1$lld of %2$lld steps", count, total)
    }

    static func waitingSince(_ clock: String) -> String {
        Localized.text("waiting since %@ · the approval itself is in the transcript", clock)
    }

    static func asked(_ clock: String) -> String { Localized.text("asked %@", clock) }

    static func earlier(_ count: Int) -> String { Localized.text("%lld earlier steps not shown", count) }

    static func count(_ count: Int, steps: String, duration: String?) -> String {
        guard let duration else { return steps }
        return Localized.text("%1$@ · %2$@", steps, duration)
    }
}

/// Small widgets every part of the brain's chrome is made of. Colours come from the style sheet by
/// class, and a word that needs two colours is Pango markup written from the palette's own hex.
enum BrainUI {
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.append(character)
            }
        }
        return out
    }

    static func label(
        _ text: String, _ classes: String..., wrap: Bool = false, selectable: Bool = false,
        lines: Int = 0, ellipsize: Bool = false
    ) -> UnsafeMutablePointer<GtkWidget> {
        let widget = Gtk.label(text, css: nil, wrap: wrap, selectable: selectable)
        for name in classes { Gtk.addClass(widget, name) }
        if !wrap && !ellipsize { gtk_label_set_ellipsize(op(widget), PANGO_ELLIPSIZE_NONE) }
        if wrap {
            gtk_label_set_width_chars(op(widget), 1)
            gtk_label_set_max_width_chars(op(widget), 1)
            gtk_widget_set_hexpand(widget, 1)
            if lines > 0 {
                gtk_label_set_lines(op(widget), Int32(lines))
                gtk_label_set_ellipsize(op(widget), PANGO_ELLIPSIZE_END)
            }
        }
        return widget
    }

    static func markup(
        _ markup: String, _ classes: String..., wrap: Bool = true, selectable: Bool = false
    ) -> UnsafeMutablePointer<GtkWidget> {
        let widget = Gtk.label("", css: nil, wrap: wrap, selectable: selectable)
        gtk_label_set_markup(op(widget), markup)
        for name in classes { Gtk.addClass(widget, name) }
        if wrap {
            gtk_label_set_width_chars(op(widget), 1)
            gtk_label_set_max_width_chars(op(widget), 1)
            gtk_widget_set_hexpand(widget, 1)
        }
        return widget
    }

    static func box(
        _ orientation: GtkOrientation, spacing: Int32 = 0, _ classes: String...
    ) -> UnsafeMutablePointer<GtkWidget> {
        let widget = Gtk.box(orientation, spacing: spacing)
        for name in classes { Gtk.addClass(widget, name) }
        return widget
    }

    static func add(_ parent: UnsafeMutablePointer<GtkWidget>, _ children: UnsafeMutablePointer<GtkWidget>...) {
        for child in children { gtk_box_append(ptr(parent), child) }
    }

    static func spacer() -> UnsafeMutablePointer<GtkWidget> {
        let widget = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(widget, 1)
        return widget
    }

    /// A small button that reads as a link: the dim ink, underlined, no border.
    static func link(_ title: String, action: @escaping @Sendable () -> Void) -> UnsafeMutablePointer<GtkWidget> {
        let button = Gtk.button(title, css: ["bn-link", "flat"]) {
            Gtk.onMain { action() }
        }
        gtk_widget_set_halign(button, GTK_ALIGN_START)
        gtk_widget_set_cursor_from_name(button, "pointer")
        return button
    }

    /// A pill button, which says "Copied" for a moment once it has copied.
    static func copyButton(_ title: String, text: @escaping @Sendable () -> String?) -> UnsafeMutablePointer<GtkWidget> {
        let holder = Unmanaged.passRetained(CopyState(title: title)).toOpaque()
        let button = Gtk.button(title, css: ["brain-pill", "bn-copy"]) {}
        _ = Gtk.releaseInstalled
        g_object_set_data_full(
            ptr(button), "bn-copy-state", holder,
            { raw in
                guard let raw else { return }
                Unmanaged<CopyState>.fromOpaque(raw).release()
            })
        let hold = Gtk.WeakWidget(button)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") {
            Gtk.onMain {
                guard let button = hold.widget, let value = text(), !value.isEmpty else { return }
                Gtk.copyToClipboard(value)
                guard let state = g_object_get_data(ptr(button), "bn-copy-state") else { return }
                let held = Unmanaged<CopyState>.fromOpaque(state).takeUnretainedValue()
                held.ticket += 1
                let ticket = held.ticket
                gtk_button_set_label(ptr(button), BrainWords.copied)
                Gtk.after(1400) {
                    Gtk.onMain {
                        guard let raw = hold.widget,
                            let state = g_object_get_data(ptr(raw), "bn-copy-state")
                        else { return }
                        let held = Unmanaged<CopyState>.fromOpaque(state).takeUnretainedValue()
                        guard held.ticket == ticket else { return }
                        gtk_button_set_label(ptr(raw), held.title)
                    }
                }
            }
        }
        gtk_widget_set_valign(button, GTK_ALIGN_START)
        gtk_widget_set_cursor_from_name(button, "pointer")
        return button
    }

    private final class CopyState: @unchecked Sendable {
        let title: String
        var ticket = 0
        init(title: String) { self.title = title }
    }

    /// A zone's shape, outlined in its colour at `size` points.
    static func shapeGlyph(
        _ zone: NeuralZone, size: Double, color: @escaping @Sendable () -> BrainInks.RGB
    ) -> UnsafeMutablePointer<GtkWidget> {
        let holder = GlyphBox(zone: zone, color: color)
        _ = Gtk.releaseInstalled
        let widget = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                let box = Unmanaged<GlyphBox>.fromOpaque(raw).takeUnretainedValue()
                let tone = box.color()
                cairo_save(cr)
                cairo_translate(cr, Double(width) / 2, Double(height) / 2)
                let radius = Double(min(width, height)) * 0.34
                BrainPainter.shape(cr, box.zone.shape, radius: radius)
                cairo_set_source_rgba(cr, tone.red, tone.green, tone.blue, 1)
                cairo_set_line_width(cr, 1.5)
                cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
                cairo_stroke(cr)
                cairo_restore(cr)
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<GlyphBox>.fromOpaque(raw).release()
            })!
        gtk_widget_set_size_request(widget, Int32(size), Int32(size))
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(widget, 0)
        tailscode_set_accessible_hidden(widget, 1)
        return widget
    }

    private final class GlyphBox: @unchecked Sendable {
        let zone: NeuralZone
        let color: @Sendable () -> BrainInks.RGB
        init(zone: NeuralZone, color: @escaping @Sendable () -> BrainInks.RGB) {
            self.zone = zone
            self.color = color
        }
    }

    /// Whether a widget is of the class a click on a row would also reach.
    static func clickable(_ widget: UnsafeMutablePointer<GtkWidget>, action: @escaping @Sendable () -> Void) {
        gtk_widget_set_cursor_from_name(widget, "pointer")
        Gtk.onPrimaryRelease(widget) { Gtk.onMain { action() } }
    }

    static func clear(_ box: UnsafeMutablePointer<GtkWidget>) { Gtk.removeChildren(of: box) }

    static func font(of widget: UnsafeMutablePointer<GtkWidget>) -> String {
        guard let raw = tailscode_widget_font(widget) else { return "Sans 10" }
        defer { g_free(raw) }
        return String(cString: raw)
    }
}

extension BrainUI {
    /// The chip a zone wears on the card and in the readout's "so far": its shape in its colour,
    /// its name, the number of steps it holds. A chip that opens something is a button.
    static func zoneChip(
        _ chip: NeuralBrainCard.ZoneChip, inks: BrainInks, compact: Bool = false,
        action: (@Sendable () -> Void)? = nil
    ) -> UnsafeMutablePointer<GtkWidget> {
        let toneZone = chip.zone
        let tone = chip.tone
        let content = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: compact ? 5 : 6)
        let glyph = shapeGlyph(chip.zone, size: compact ? 14 : 16) {
            switch tone {
            case .danger: return inks.cDanger
            case .attention: return inks.warn
            default: return inks.corrected(toneZone)
            }
        }
        let name = label(chip.label, "bn-zchip-name", "bn-z-\(zoneName(chip.zone))")
        if tone == .danger { Gtk.addClass(name, "bn-tone-danger") }
        if tone == .attention { Gtk.addClass(name, "bn-tone-attention") }
        let count = label(String(chip.count), "bn-zchip-count")
        add(content, glyph, name, count)
        if let action {
            let button = gtk_button_new()!
            gtk_button_set_child(ptr(button), content)
            Gtk.addClass(button, "bn-zchip")
            if compact { Gtk.addClass(button, "bn-zchip-compact") }
            Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { Gtk.onMain { action() } }
            gtk_widget_set_cursor_from_name(button, "pointer")
            tailscode_set_accessible_label(
                button, Localized.text("%1$@, %2$lld steps. Open the head diving into it.", chip.label, chip.count))
            return button
        }
        let frame = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(frame, "bn-zchip")
        Gtk.addClass(frame, "bn-zchip-still")
        if compact { Gtk.addClass(frame, "bn-zchip-compact") }
        gtk_box_append(ptr(frame), content)
        return frame
    }

    static func zoneName(_ zone: NeuralZone) -> String {
        switch zone {
        case .think: return "think"
        case .sense: return "sense"
        case .act: return "act"
        case .shell: return "shell"
        case .delegate: return "delegate"
        case .say: return "say"
        }
    }
}

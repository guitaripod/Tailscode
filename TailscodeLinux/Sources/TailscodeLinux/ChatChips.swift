import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The one chip a chat wears, whatever it does: a glyph at twelve pixels, a word, and nothing
/// else. The size, the shape and the fill live in the stylesheet (`chip-ctl`) from `ChatChrome`;
/// this builds what goes inside and says what it is to a screen reader.
enum ChatChips {
    struct Parts {
        let box: UnsafeMutablePointer<GtkWidget>
        let glyph: UnsafeMutablePointer<GtkWidget>?
        let word: UnsafeMutablePointer<GtkWidget>?
    }

    static let toneClasses = ["chip-tone-live", "chip-tone-attention", "chip-tone-danger", "chip-tone-quiet"]

    static func toneClass(_ tone: ActivityTone?) -> String? {
        switch tone {
        case .live?: return "chip-tone-live"
        case .attention?: return "chip-tone-attention"
        case .danger?: return "chip-tone-danger"
        case .quiet?: return "chip-tone-quiet"
        case nil: return nil
        }
    }

    /// A glyph and a word in one row. `wordChars` fixes the word's width in characters, so a chip
    /// whose word flips between two lengths — send and queue — keeps the width it had.
    static func content(
        glyph: String?, word: String?, tone: ActivityTone? = nil, wordChars: Int32? = nil,
        wraps: Bool = false
    ) -> Parts {
        let box = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_valign(box, GTK_ALIGN_CENTER)
        var glyphLabel: UnsafeMutablePointer<GtkWidget>?
        var wordLabel: UnsafeMutablePointer<GtkWidget>?
        if let glyph {
            let label = Gtk.label(glyph, css: "chip-glyph", selectable: false)
            gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_NONE)
            gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
            if let cls = toneClass(tone) { Gtk.addClass(label, cls) }
            gtk_box_append(ptr(box), label)
            glyphLabel = label
        }
        if let word {
            let label = Gtk.label(word, selectable: false)
            gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_NONE)
            gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
            if glyph != nil { Gtk.addClass(label, "chip-gap") }
            if wraps {
                gtk_label_set_wrap(op(label), 1)
                gtk_label_set_wrap_mode(op(label), PANGO_WRAP_WORD_CHAR)
            }
            if let wordChars {
                gtk_label_set_width_chars(op(label), wordChars)
                gtk_label_set_xalign(op(label), 0.5)
            }
            gtk_box_append(ptr(box), label)
            wordLabel = label
        }
        return Parts(box: box, glyph: glyphLabel, word: wordLabel)
    }

    static func setTone(_ glyph: UnsafeMutablePointer<GtkWidget>?, _ tone: ActivityTone?) {
        guard let glyph else { return }
        Gtk.setTone(glyph, toneClass(tone), from: toneClasses)
    }

    /// A control: outlined, opaque, a chip's height.
    static func control(
        glyph: String?, word: String?, tone: ActivityTone? = nil, wordChars: Int32? = nil,
        wraps: Bool = false, label spoken: String, onClick: @escaping @Sendable () -> Void
    ) -> (button: UnsafeMutablePointer<GtkWidget>, parts: Parts) {
        let parts = content(
            glyph: glyph, word: word, tone: tone, wordChars: wordChars, wraps: wraps)
        let button = gtk_button_new()!
        Gtk.addClass(button, "chip-ctl")
        gtk_button_set_child(ptr(button), parts.box)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(button, spoken)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onClick)
        return (button, parts)
    }

    /// A word on a plain control, for the places where a chip holds text and no glyph.
    static func plain(
        _ title: String, label spoken: String? = nil, css: [String] = ["chip-ctl"],
        onClick: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = Gtk.button(title, css: css, onClick: onClick)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(button, spoken ?? title)
        return button
    }

    /// The longest word a chip flips between, in characters, so its width never moves.
    static func widest(_ words: [String]) -> Int32 {
        Int32(words.map(\.count).max() ?? 0)
    }
}

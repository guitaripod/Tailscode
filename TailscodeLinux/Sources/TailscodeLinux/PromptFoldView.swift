import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A prompt's words and, under a long one, the fold line that shows the rest (`PromptFold`).
///
/// Whether a prompt is long is a question about the width it is drawn at, so the column asks
/// again whenever that width changes: the prompt's own type is measured for how many characters
/// fit a line and Core decides. A label's own line limit counts each paragraph apart, which would
/// let a listed prompt through whole, so a folded label is handed the words Core cut for that
/// width instead. Nothing is rebuilt: the same label is given other words.
enum PromptFoldView {
    /// The label in a column that folds it. `key` is where the reader's choice is kept, and
    /// `markup` is how the prompt's words become the label's.
    static func make(
        _ label: UnsafeMutablePointer<GtkWidget>, text: String, key: String, context: TranscriptContext,
        markup: @escaping @Sendable (String) -> String
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(column, 1)
        let stack = gtk_overlay_new()!
        gtk_overlay_set_child(op(stack), label)
        let watch = Gtk.widthWatch()
        gtk_overlay_add_overlay(op(stack), watch)
        gtk_box_append(ptr(column), stack)

        let fold = Fold(text: text, key: key, opened: context.isExpanded(key), markup: markup)
        let labelBits = UInt(bitPattern: label)
        let slot = Gtk.Slot()
        let onToggle = context.onToggle
        let toggle = Gtk.button("", css: ["flat", "code-fold", "prompt-fold"]) {
            fold.opened.toggle()
            onToggle?(key, fold.opened)
            fold.apply(labelBits: labelBits, toggleBits: slot.bits)
        }
        slot.bits = UInt(bitPattern: toggle)
        gtk_widget_set_halign(toggle, GTK_ALIGN_START)
        gtk_widget_set_visible(toggle, 0)
        gtk_box_append(ptr(column), toggle)

        Gtk.onAreaResize(watch) { width, _ in
            fold.width = Double(width)
            fold.apply(labelBits: labelBits, toggleBits: slot.bits)
        }
        return column
    }

    /// One prompt's fold between redraws: its words, the width it was last given and whether the
    /// reader has opened it.
    private final class Fold: @unchecked Sendable {
        let text: String
        let key: String
        var opened: Bool
        var width: Double = 0
        private let markup: @Sendable (String) -> String
        private var columns = 0
        private var drawn: PromptFold.Reading?

        init(text: String, key: String, opened: Bool, markup: @escaping @Sendable (String) -> String) {
            self.text = text
            self.key = key
            self.opened = opened
            self.markup = markup
        }

        func apply(labelBits: UInt, toggleBits: UInt) {
            guard width > 1, let label = UnsafeMutablePointer<GtkWidget>(bitPattern: labelBits),
                let toggle = UnsafeMutablePointer<GtkWidget>(bitPattern: toggleBits)
            else { return }
            let fits = max(1, Int(width / Self.characterWidth(in: label)))
            let reading = PromptFold.read(text, columns: fits, expanded: opened)
            guard reading != drawn || fits != columns else { return }
            let wasFolded = drawn?.folded ?? false
            let refolds = reading.folded && fits != columns
            columns = fits
            drawn = reading
            if reading.folded != wasFolded || refolds {
                gtk_label_set_markup(
                    op(label), markup(reading.folded ? PromptFold.cut(text, columns: fits) : text))
            }
            gtk_widget_set_visible(toggle, reading.foldable ? 1 : 0)
            if let words = reading.toggleLabel {
                gtk_button_set_label(ptr(toggle), (reading.folded ? "⌄ " : "⌃ ") + words)
            }
        }

        /// How wide one character of the label's own type is: a prompt is set in a face where
        /// every character is, so the width over this is exactly what fits a line.
        private static func characterWidth(in label: UnsafeMutablePointer<GtkWidget>) -> Double {
            guard let layout = gtk_widget_create_pango_layout(label, "0000000000") else { return 8 }
            defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
            var width: Int32 = 0
            pango_layout_get_pixel_size(layout, &width, nil)
            return max(1, Double(width) / 10)
        }
    }
}

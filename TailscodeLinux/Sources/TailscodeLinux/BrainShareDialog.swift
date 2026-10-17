import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The poster as it will leave, before it leaves. Sharing a picture nobody has seen is a guess, so
/// the clipboard and the file dialog are reached through this window: the poster drawn in the chosen
/// look and appearance, two drop-downs that redraw it the moment either changes, and Copy and Save
/// beside it. The look is remembered; nothing in the transcript behind changes, because the look
/// dresses the poster only.
final class BrainShareDialog: @unchecked Sendable {
    private static let previewScale = 0.6

    private let model: NeuralBrainModel
    private let prompt: String?
    private let slot: UnsafeMutablePointer<GtkWidget>
    private let appearance: UnsafeMutablePointer<GtkWidget>
    private var window: UnsafeMutablePointer<GtkWidget>?
    private var style: CardStyle
    private var dark: Bool
    private var generation = 0
    private var closed = false

    @discardableResult
    static func present(
        model: NeuralBrainModel, prompt: String?, parent: UnsafeMutablePointer<GtkWidget>?
    ) -> BrainShareDialog {
        let dialog = BrainShareDialog(model: model, prompt: prompt)
        dialog.build(parent: parent)
        return dialog
    }

    /// Whether a poster is on the sheet, for the harness.
    var hasPreview: Bool { gtk_widget_get_first_child(slot) != nil }

    /// The labels of the buttons the sheet offers, for the harness.
    private(set) var offers: [String] = []

    func close() {
        guard let window, !closed else { return }
        gtk_window_destroy(ptr(window))
    }

    private init(model: NeuralBrainModel, prompt: String?) {
        self.model = BrainPoster.resting(model)
        self.prompt = prompt
        style = BrainPoster.savedLook()
        dark = MatrixTheme.palette.isDark
        slot = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        let choices = gtk_string_list_new(nil)!
        gtk_string_list_append(choices, Localized.text("Dark"))
        gtk_string_list_append(choices, Localized.text("Light"))
        appearance = gtk_drop_down_new(OpaquePointer(UnsafeMutableRawPointer(choices)), nil)!
    }

    private func build(parent: UnsafeMutablePointer<GtkWidget>?) {
        let (made, content, actions) = Dialogs.windowWithActions(
            title: Localized.text("Share this turn"), parent: parent, width: 620)
        window = made
        gtk_window_set_default_size(ptr(made), 620, 900)

        let pickers = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(pickers), Gtk.label(Localized.text("Poster look"), css: "dim-label"))
        gtk_box_append(ptr(pickers), lookPicker())
        gtk_drop_down_set_selected(op(appearance), dark ? 0 : 1)
        gtk_widget_set_tooltip_text(appearance, Localized.text("Appearance"))
        tailscode_set_accessible_label(appearance, Localized.text("Appearance"))
        gtk_widget_set_sensitive(appearance, style.authored == nil ? 1 : 0)
        gtk_box_append(ptr(pickers), appearance)
        gtk_box_append(ptr(content), pickers)
        watchAppearance()

        gtk_widget_set_hexpand(slot, 1)
        gtk_box_append(ptr(content), slot)
        let retained = Unmanaged.passRetained(self).toOpaque()
        g_object_set_data_full(
            ptr(made), "tailscode-brain-share", retained,
            { raw in
                guard let raw else { return }
                let dialog = Unmanaged<BrainShareDialog>.fromOpaque(raw).takeRetainedValue()
                dialog.closed = true
            })
        renderPreview()

        let copy = Gtk.button(Localized.text("Copy")) { [weak self] in
            Gtk.onMain { [weak self] in self?.copyPoster() }
        }
        let save = Gtk.button(Localized.text("Save…")) { [weak self] in
            Gtk.onMain { [weak self] in self?.savePoster() }
        }
        let windowHold = Gtk.WeakWidget(made)
        let close = Gtk.button(Localized.text("Close"), css: ["suggested-action"]) {
            guard let raw = windowHold.widget else { return }
            gtk_window_destroy(ptr(raw))
        }
        gtk_box_append(ptr(actions), copy)
        gtk_box_append(ptr(actions), save)
        gtk_box_append(ptr(actions), close)
        offers = [Localized.text("Copy"), Localized.text("Save…"), Localized.text("Close")]
        Gtk.onKey(made) { keyval, _ in
            guard keyval == Keymap.escape else { return false }
            guard let raw = windowHold.widget else { return true }
            gtk_window_destroy(ptr(raw))
            return true
        }
        gtk_window_present(ptr(made))
    }

    private func lookPicker() -> UnsafeMutablePointer<GtkWidget> {
        let model = gtk_string_list_new(nil)!
        for candidate in NeuralShare.looks { gtk_string_list_append(model, candidate.name) }
        let picker = gtk_drop_down_new(OpaquePointer(UnsafeMutableRawPointer(model)), nil)!
        let index = NeuralShare.looks.firstIndex { $0.id == style.id } ?? 0
        gtk_drop_down_set_selected(op(picker), guint(index))
        gtk_widget_set_tooltip_text(picker, Localized.text("Poster look"))
        tailscode_set_accessible_label(picker, Localized.text("Poster look"))
        let hold = Gtk.WeakWidget(picker)
        Gtk.onNotify(UnsafeMutableRawPointer(picker), property: "selected") { [weak self] in
            guard let self, let raw = hold.widget else { return }
            let selected = Int(gtk_drop_down_get_selected(op(raw)))
            guard NeuralShare.looks.indices.contains(selected) else { return }
            let picked = NeuralShare.looks[selected]
            guard picked.id != self.style.id else { return }
            self.style = picked
            BrainPoster.remember(picked)
            gtk_widget_set_sensitive(self.appearance, picked.authored == nil ? 1 : 0)
            self.renderPreview()
        }
        return picker
    }

    private func watchAppearance() {
        let hold = Gtk.WeakWidget(appearance)
        Gtk.onNotify(UnsafeMutableRawPointer(appearance), property: "selected") { [weak self] in
            guard let self, let raw = hold.widget else { return }
            let isDark = gtk_drop_down_get_selected(op(raw)) == 0
            guard isDark != self.dark else { return }
            self.dark = isDark
            self.renderPreview()
        }
    }

    /// The preview is drawn at a little over half the poster's size, every word on it, so a look is
    /// judged in a beat; the copy and the file are drawn at twice the card's points.
    private func renderPreview() {
        generation += 1
        let mine = generation
        BrainPoster.render(
            model: model, prompt: prompt, style: style, dark: dark, scale: Self.previewScale
        ) { [weak self] poster in
            guard let self, !self.closed, mine == self.generation, let poster, let png = poster.png
            else { return }
            self.show(png)
        }
    }

    private func show(_ png: Data) {
        Gtk.removeChildren(of: slot)
        let picture: UnsafeMutablePointer<GtkWidget>? = png.withUnsafeBytes { raw in
            guard let base = raw.baseAddress,
                let texture = tailscode_texture_from_bytes(base, gsize(png.count))
            else { return nil }
            defer { g_object_unref(UnsafeMutableRawPointer(texture)) }
            return tailscode_picture_for_texture(texture)
        }
        guard let picture else { return }
        gtk_widget_set_hexpand(picture, 1)
        Gtk.addClass(picture, "share-card-preview")
        tailscode_set_accessible_label(picture, Localized.text("Poster preview"))
        gtk_box_append(ptr(slot), picture)
    }

    private func withPoster(_ use: @escaping (Data) -> Void) {
        BrainPoster.render(model: model, prompt: prompt, style: style, dark: dark, scale: 2) {
            poster in
            guard let png = poster?.png else { return }
            use(png)
        }
    }

    private func copyPoster() {
        let words = model.spoken
        withPoster { png in
            png.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                tailscode_clipboard_set_text_and_image_png(words, base, gsize(png.count))
            }
        }
    }

    private func savePoster() {
        guard let made = window else { return }
        let name = BrainPoster.filename(prompt: prompt, turn: model.turn)
        let windowHold = Gtk.WeakWidget(made)
        withPoster { png in
            guard let raw = windowHold.widget else { return }
            Gtk.saveFile(parent: ptr(raw), suggestedName: name, data: png) { _ in }
        }
    }
}

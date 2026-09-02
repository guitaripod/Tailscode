import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The card as it will leave, before it leaves. Sharing a picture nobody has seen is a guess,
/// so the clipboard and the file dialog are reached through this window: the card drawn at
/// the chosen look, a drop-down that redraws it the moment another look is picked, and Copy
/// and Save beside it. The choice is remembered; nothing in the panel behind changes, because
/// the look dresses the card only.
enum ShareCardDialog {
    private nonisolated(unsafe) static var previewSlot: UInt = 0
    private nonisolated(unsafe) static var style = CardStyleSelection.current
    private nonisolated(unsafe) static var generation = 0

    static func present(_ analytics: UsageAnalytics, parent: UnsafeMutablePointer<GtkWidget>?) {
        let package = AnalyticsShare(analytics)
        style = CardStyleSelection.current
        let (window, content, actions) = Dialogs.windowWithActions(
            title: Localized.text("Share card"), parent: parent, width: 620)
        gtk_window_set_default_size(ptr(window), 620, 760)
        let windowBits = UInt(bitPattern: window)

        let pickerRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(pickerRow), Gtk.label(Localized.text("Card style"), css: "dim-label"))
        gtk_box_append(ptr(pickerRow), stylePicker(package))
        gtk_box_append(ptr(content), pickerRow)

        let slot = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(slot, 1)
        gtk_box_append(ptr(content), slot)
        previewSlot = UInt(bitPattern: slot)
        renderPreview(package)

        let copy = Gtk.button(Localized.text("Copy card")) {
            if let png = AnalyticsCardRenderer.png(package, style: style) {
                png.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    tailscode_clipboard_set_text_and_image_png(
                        package.plainText, base, gsize(png.count))
                }
            } else {
                Gtk.copyToClipboard(package.plainText)
            }
        }
        let save = Gtk.button(Localized.text("Save image…")) {
            guard let png = AnalyticsCardRenderer.png(package, style: style),
                let windowRaw = UnsafeMutableRawPointer(bitPattern: windowBits)
            else { return }
            Gtk.saveFile(
                parent: ptr(windowRaw), suggestedName: package.filename, data: png
            ) { _ in }
        }
        let close = Gtk.button(Localized.text("Close"), css: ["suggested-action"]) {
            guard let raw = UnsafeMutableRawPointer(bitPattern: windowBits) else { return }
            gtk_window_destroy(ptr(raw))
        }
        gtk_box_append(ptr(actions), copy)
        gtk_box_append(ptr(actions), save)
        gtk_box_append(ptr(actions), close)
        Gtk.onKey(window) { keyval, _ in
            guard keyval == Keymap.escape else { return false }
            guard let raw = UnsafeMutableRawPointer(bitPattern: windowBits) else { return true }
            gtk_window_destroy(ptr(raw))
            return true
        }
        gtk_window_present(ptr(window))
    }

    private static func stylePicker(_ package: AnalyticsShare) -> UnsafeMutablePointer<GtkWidget> {
        let model = gtk_string_list_new(nil)!
        for candidate in CardStyle.all { gtk_string_list_append(model, candidate.name) }
        let picker = gtk_drop_down_new(OpaquePointer(UnsafeMutableRawPointer(model)), nil)!
        let index = CardStyle.all.firstIndex { $0.id == style.id } ?? 0
        gtk_drop_down_set_selected(op(picker), guint(index))
        gtk_widget_set_tooltip_text(picker, Localized.text("Card style"))
        let bits = UInt(bitPattern: picker)
        Gtk.onNotify(UnsafeMutableRawPointer(picker), property: "selected") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            let selected = Int(gtk_drop_down_get_selected(op(raw)))
            guard CardStyle.all.indices.contains(selected) else { return }
            let picked = CardStyle.all[selected]
            guard picked.id != style.id else { return }
            style = picked
            CardStyleSelection.set(picked)
            SettingsFile.capture()
            renderPreview(package)
        }
        return picker
    }

    /// The preview is drawn at the card's own logical size — every word, a quarter of the
    /// pixels the copy will carry — so a look is judged in a beat.
    private static func renderPreview(_ package: AnalyticsShare) {
        guard let slotRaw = UnsafeMutableRawPointer(bitPattern: previewSlot) else { return }
        let slot: UnsafeMutablePointer<GtkWidget> = ptr(slotRaw)
        Gtk.removeChildren(of: slot)
        generation += 1
        guard let png = AnalyticsCardRenderer.png(package, scale: 1, style: style) else { return }
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
        gtk_box_append(ptr(slot), picture)
    }
}

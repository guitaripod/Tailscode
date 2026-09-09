import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// One finished picture, full size, with its making named beside it: the words, the engine, the
/// aspect, the seconds, the seed. A draw slot's own viewer rather than the transcript's gallery,
/// because the caption is the prompt that made the picture and the seed is the reroll.
final class DrawViewer: @unchecked Sendable {
    private let picture: ImageGenPicture
    private let textureBits: UInt
    private var window: UnsafeMutablePointer<GtkWidget>?

    static func present(
        picture: ImageGenPicture, textureBits: UInt, parent: UnsafeMutablePointer<GtkWidget>?
    ) {
        let viewer = DrawViewer(picture: picture, textureBits: textureBits)
        viewer.presentWindow(parent: parent)
    }

    private init(picture: ImageGenPicture, textureBits: UInt) {
        self.picture = picture
        self.textureBits = textureBits
    }

    /// A picture is not a decision, so this is a window rather than a dialog.
    ///
    /// It used to be `Dialogs.window`, which is modal — and opened from the image studio, which is
    /// itself modal, that is a modal transient for a modal: X11 hands input to a window the window
    /// manager will not focus, and the pointer stops working for the whole session rather than for
    /// this app. Nothing here may be modal, and the content is not wrapped in the dialog's own
    /// scroller either — a picture inside two nested scrollers is measured against a natural size
    /// neither of them has, which is why it came up small and squashed.
    private func presentWindow(parent: UnsafeMutablePointer<GtkWidget>?) {
        let window = gtk_window_new()!
        gtk_window_set_title(ptr(window), picture.name)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }
        let size = Self.size(near: parent, aspect: picture.aspect)
        gtk_window_set_default_size(ptr(window), size.width, size.height)
        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(
            op(UnsafeMutableRawPointer(header)),
            adw_window_title_new(picture.prompt.ellipsized(to: 60), ImageGenFacts.line(for: picture))
        )
        gtk_window_set_titlebar(ptr(window), header)
        let content = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 12)
        Gtk.margins(content, 18)
        gtk_window_set_child(ptr(window), content)
        self.window = window

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_hexpand(scroller, 1)
        gtk_widget_set_vexpand(scroller, 1)
        if textureBits != 0,
            let raw = UnsafeMutableRawPointer(bitPattern: textureBits),
            let texture = OpaquePointer(bitPattern: Int(bitPattern: raw))
        {
            let image = tailscode_picture_for_texture(texture)!
            gtk_picture_set_content_fit(op(image), GTK_CONTENT_FIT_CONTAIN)
            gtk_widget_set_hexpand(image, 1)
            gtk_widget_set_vexpand(image, 1)
            gtk_scrolled_window_set_child(op(scroller), image)
        }
        gtk_box_append(ptr(content), scroller)

        let bar = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let folder = picture.path
        gtk_box_append(
            ptr(bar),
            Gtk.button(Localized.text("Open Folder"), css: ["flat"]) { [weak self] in
                let path = folder
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.openFolder(path)
                }
            })
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(bar), spacer)
        gtk_box_append(
            ptr(bar),
            Gtk.button(Localized.text("Copy Prompt"), css: ["flat"]) { [weak self] in
                let words = self?.picture.prompt ?? ""
                Gtk.onMain { Gtk.copyToClipboard(words) }
            })
        let seed = picture.seed
        gtk_box_append(
            ptr(bar),
            Gtk.button(Localized.text("Copy Seed"), css: ["flat"]) {
                Gtk.onMain { Gtk.copyToClipboard("\(seed)") }
            })
        gtk_box_append(ptr(content), bar)

        Gtk.onKey(window) { [weak self] keyval, _ in
            guard let self else { return false }
            if keyval == Keymap.escape {
                Gtk.onMain {
                    if let window = self.window { gtk_window_destroy(ptr(window)) }
                }
                return true
            }
            return false
        }
        gtk_window_present(ptr(window))
    }

    /// A window shaped like the picture in it, inside what the screen actually has — a portrait
    /// render in a landscape window is letterboxed twice over and reads as small.
    private static func size(
        near widget: UnsafeMutablePointer<GtkWidget>?, aspect: ImageGenAspect
    ) -> (width: Int32, height: Int32) {
        let available = Double(tailscode_monitor_workarea_height(widget))
        let ceiling = available > 0 ? available * 0.9 : 900
        let pixels = aspect.pixels
        let ratio = Double(pixels.width) / Double(pixels.height)
        var height = min(ceiling, Double(pixels.height) + 140)
        var width = (height - 140) * ratio
        if width > 1600 {
            width = 1600
            height = width / ratio + 140
        }
        return (Int32(max(520, width)), Int32(max(420, height)))
    }

    private func openFolder(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
        let handle = Process()
        handle.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        handle.arguments = ["sh", "-c", "xdg-open '\(url.path)'"]
        try? handle.run()
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
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
    private let titleLabel = Gtk.label("", css: "row-title", selectable: false)
    private let detailLabel = Gtk.label("", css: "row-detail", selectable: false)

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

    private func presentWindow(parent: UnsafeMutablePointer<GtkWidget>?) {
        let hostWidth = parent.map { gtk_widget_get_width($0) } ?? 0
        let width = max(900, hostWidth - 120)
        let (window, content) = Dialogs.window(
            title: picture.name, parent: parent, width: width)
        self.window = window

        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        let titles = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_box_append(ptr(titles), titleLabel)
        gtk_box_append(ptr(titles), detailLabel)
        gtk_box_append(ptr(header), titles)
        gtk_box_append(ptr(content), header)

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
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

        refresh()
        Gtk.onKey(window) { [weak self] keyval, _ in
            guard let self else { return false }
            if keyval == Keymap.escape {
                Gtk.onMain {
                    if let window = self.window { Dialogs.close(window) }
                }
                return true
            }
            return false
        }
        gtk_window_present(ptr(window))
    }

    private func refresh() {
        gtk_label_set_text(op(titleLabel), picture.prompt.ellipsized(to: 72))
        let when = Self.formatter.string(from: picture.madeAt)
        gtk_label_set_text(
            op(detailLabel),
            [
                picture.engine.label,
                picture.mode.label,
                picture.aspect.label,
                String(format: "%.1fs", picture.seconds),
                "seed \(picture.seed)",
                when,
            ].joined(separator: "  ·  "))
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
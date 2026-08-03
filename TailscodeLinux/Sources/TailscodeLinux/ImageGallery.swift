import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A gallery over every picture in the conversation rather than a single-image window: paged
/// with ‹ › or the arrow keys, zoomable between fit and 1:1 pixels with a click or `z`, and a
/// save that hands over the exact bytes the server sent under their sniffed extension. Pages
/// whose texture is still being fetched paint the moment it lands, via the context's ear.
final class ImageGallery: @unchecked Sendable {
    struct Item {
        let key: String
        let name: String
        let reference: FileReference
    }

    private let items: [Item]
    private var index: Int
    private let context: TranscriptContext
    private let fetch: @Sendable (FileReference, String) -> Void
    private let notice: @Sendable (String) -> Void
    private let previousEar: (@Sendable (String) -> Void)?

    private var window: UnsafeMutablePointer<GtkWidget>?
    private let titleLabel = Gtk.label("", css: "row-title", selectable: false)
    private let dimsLabel = Gtk.label("", css: "row-detail", selectable: false)
    private let pictureHolder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let scroller = gtk_scrolled_window_new()!
    private let zoomButton = gtk_button_new_with_label("")!
    private var oneToOne = false

    static func present(
        items: [Item], startKey: String, parent: UnsafeMutablePointer<GtkWidget>?,
        context: TranscriptContext,
        fetch: @escaping @Sendable (FileReference, String) -> Void,
        notice: @escaping @Sendable (String) -> Void
    ) {
        guard !items.isEmpty else { return }
        let gallery = ImageGallery(
            items: items, startKey: startKey, context: context, fetch: fetch, notice: notice)
        gallery.presentWindow(parent: parent)
    }

    private init(
        items: [Item], startKey: String, context: TranscriptContext,
        fetch: @escaping @Sendable (FileReference, String) -> Void,
        notice: @escaping @Sendable (String) -> Void
    ) {
        self.items = items
        self.index = items.firstIndex { $0.key == startKey } ?? 0
        self.context = context
        self.fetch = fetch
        self.notice = notice
        self.previousEar = context.onImageStored
    }

    private func presentWindow(parent: UnsafeMutablePointer<GtkWidget>?) {
        let hostWidth = parent.map { gtk_widget_get_width($0) } ?? 0
        let hostHeight = parent.map { gtk_widget_get_height($0) } ?? 0
        let width = max(960, hostWidth - 120)
        let height = max(700, hostHeight - 100)
        let (window, content) = Dialogs.window(title: "", parent: parent, width: width)
        gtk_window_set_default_size(ptr(window), width, height)
        self.window = window

        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        gtk_box_append(ptr(header), titleLabel)
        let headSpacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(headSpacer, 1)
        gtk_box_append(ptr(header), headSpacer)
        gtk_box_append(ptr(header), dimsLabel)
        gtk_box_append(ptr(content), header)

        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_NEVER)
        gtk_widget_set_hexpand(scroller, 1)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_scrolled_window_set_child(op(scroller), pictureHolder)
        gtk_box_append(ptr(content), scroller)

        let bar = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        if items.count > 1 {
            gtk_box_append(
                ptr(bar),
                Gtk.button("‹", css: ["flat"]) { [self] in Gtk.onMain { self.step(-1) } })
            gtk_box_append(
                ptr(bar),
                Gtk.button("›", css: ["flat"]) { [self] in Gtk.onMain { self.step(1) } })
        }
        gtk_button_set_label(ptr(zoomButton), Localized.text("1:1"))
        Gtk.addClass(zoomButton, "flat")
        Gtk.connect(UnsafeMutableRawPointer(zoomButton), "clicked") { [self] in
            Gtk.onMain { self.toggleZoom() }
        }
        gtk_box_append(ptr(bar), zoomButton)
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(bar), spacer)
        gtk_box_append(
            ptr(bar),
            Gtk.button(Localized.text("Save to Downloads"), css: ["suggested-action"]) { [self] in
                Gtk.onMain { self.save() }
            })
        gtk_box_append(ptr(content), bar)

        Gtk.onKey(window) { [self] keyval, _ in
            switch keyval {
            case 0xFF51: Gtk.onMain { self.step(-1) }
            case 0xFF53: Gtk.onMain { self.step(1) }
            case UInt32(UnicodeScalar("z").value): Gtk.onMain { self.toggleZoom() }
            case UInt32(UnicodeScalar("s").value): Gtk.onMain { self.save() }
            case Keymap.escape:
                Gtk.onMain { [self] in if let window = self.window { Dialogs.close(window) } }
            default: return false
            }
            return true
        }
        context.onImageStored = { [self] key in
            Gtk.onMain {
                guard key == self.items[self.index].key else { return }
                self.render()
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") { [self] in
            Gtk.onMain { self.context.onImageStored = self.previousEar }
        }
        render()
        gtk_window_present(ptr(window))
    }

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        index = (index + delta + items.count) % items.count
        oneToOne = false
        render()
    }

    private func toggleZoom() {
        oneToOne.toggle()
        render()
    }

    private func render() {
        let item = items[index]
        let counter = items.count > 1 ? "  ·  \(index + 1)/\(items.count)" : ""
        gtk_label_set_text(op(titleLabel), item.name + counter)
        if let window { gtk_window_set_title(ptr(window), item.name) }
        Gtk.removeChildren(of: pictureHolder)

        guard let bits = context.textures[item.key], bits != 0,
            let texture = OpaquePointer(bitPattern: Int(bitPattern: bits))
        else {
            gtk_label_set_text(op(dimsLabel), "")
            let loading = Gtk.label(Localized.text("Loading…"), css: "dim", selectable: false)
            gtk_widget_set_hexpand(loading, 1)
            gtk_widget_set_vexpand(loading, 1)
            gtk_label_set_xalign(op(loading), Float(0.5))
            gtk_box_append(ptr(pictureHolder), loading)
            fetch(item.reference, item.key)
            return
        }

        let width = tailscode_texture_width(texture)
        let height = tailscode_texture_height(texture)
        gtk_label_set_text(
            op(dimsLabel), "\(width)×\(height)" + (oneToOne ? "  ·  1:1" : ""))
        gtk_button_set_label(
            ptr(zoomButton), oneToOne ? Localized.text("Fit") : Localized.text("1:1"))

        let picture = tailscode_picture_for_texture(texture)!
        if oneToOne {
            gtk_picture_set_content_fit(op(picture), GTK_CONTENT_FIT_FILL)
            gtk_widget_set_size_request(picture, width, height)
            gtk_widget_set_halign(picture, GTK_ALIGN_CENTER)
            gtk_widget_set_valign(picture, GTK_ALIGN_CENTER)
            gtk_scrolled_window_set_policy(
                op(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC)
        } else {
            gtk_picture_set_content_fit(op(picture), GTK_CONTENT_FIT_CONTAIN)
            gtk_widget_set_hexpand(picture, 1)
            gtk_widget_set_vexpand(picture, 1)
            gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_NEVER)
        }
        Gtk.onRelease(picture) { [self] in Gtk.onMain { self.toggleZoom() } }
        gtk_box_append(ptr(pictureHolder), picture)
    }

    private func save() {
        let item = items[index]
        guard let data = context.imageData[item.key] else {
            notice(Localized.text("Still loading — try again in a moment."))
            return
        }
        let filename = ImageBytes.exportFilename(item.name, data: data)
        let target = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(filename)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wrote = (try? data.write(to: target)) != nil
        notice(
            wrote
                ? Localized.text("Saved %@", target.path)
                : Localized.text("Could not write %@", target.path))
    }
}

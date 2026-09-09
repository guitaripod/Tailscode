import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The image studio, opened over the work rather than beside it.
///
/// Making a picture is a task you start, watch and collect — not a place you work — so it does not
/// earn half of a window the way a second conversation does. Taking a pane spent the transcript's
/// width on a surface nobody types into while it runs, and left the pane behind afterwards. This
/// is the same studio as a modal transient for the main window, so the conversation is untouched
/// behind it and comes back whole the moment it closes.
///
/// Closing may never stop a render. The job, its runner and the pictures live in ``ImageStudio``,
/// so this window is only the view: it says so while one is out (`ImageGenSurface.dismissNote`)
/// and reopening finds the same picture exactly where it was.
final class ImageWindow: @unchecked Sendable {
    nonisolated(unsafe) private static var open: ImageWindow?

    /// The one that is up, for the headless driver and for anything that wants to know whether
    /// the surface is on screen at all.
    static var current: ImageWindow? { open }

    @discardableResult
    static func present(parent: UnsafeMutablePointer<GtkWidget>?) -> ImageWindow {
        if let open {
            open.pane.studio.adoptDoor()
            gtk_window_present(ptr(open.window))
            open.pane.focusPrompt()
            return open
        }
        ImageStudio.shared.adoptDoor()
        let made = ImageWindow(parent: parent)
        open = made
        return made
    }

    private let window: UnsafeMutablePointer<GtkWidget>
    private let pane: DrawPane
    private let dismissNote: UnsafeMutablePointer<GtkWidget>
    private var studioObserver: NSObjectProtocol?

    private init(parent: UnsafeMutablePointer<GtkWidget>?) {
        window = gtk_window_new()!
        gtk_window_set_title(ptr(window), ImageGenSurface.title)
        gtk_window_set_modal(ptr(window), 1)
        gtk_window_set_default_size(
            ptr(window), Int32(ImageGenSurface.preferredWidth), Self.height(near: parent))
        gtk_widget_set_size_request(
            window, Int32(ImageGenSurface.minimumWidth), Int32(ImageGenSurface.minimumHeight))
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }

        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(
            op(UnsafeMutableRawPointer(header)),
            adw_window_title_new(ImageGenSurface.title, Self.subtitle))
        gtk_window_set_titlebar(ptr(window), header)

        pane = DrawPane(studio: .shared, fills: true)
        pane.wireChips()
        dismissNote = Gtk.label("", css: "row-detail", wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(dismissNote), 58)
        gtk_widget_set_hexpand(dismissNote, 1)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_box_append(ptr(column), pane.root)
        gtk_box_append(ptr(column), footer())
        gtk_window_set_child(ptr(window), column)

        pane.onNotice = { [weak self] text in
            Gtk.onMain { [weak self] in self?.say(text) }
        }
        studioObserver = NotificationCenter.default.addObserver(
            forName: ImageStudio.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            Gtk.onMain { [weak self] in self?.drawFooter() }
        }
        Gtk.onKey(window) { [weak self] keyval, state in
            guard let self else { return false }
            return self.key(keyval: keyval, state: state)
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") { [weak self] in
            guard let self else { return }
            Self.destroyed(self)
        }
        drawFooter()
        gtk_window_present(ptr(window))
        pane.focusPrompt()
    }

    /// The machine under the title, so the surface names where the work happens before anybody
    /// asks — and says the door's own sentence when there is something to say about it.
    private static var subtitle: String {
        let door = ImageGenDoor.current()
        return door.line ?? ImageGenSurface.subtitle
    }

    /// The way out, and the one sentence that has to sit beside it: closing over a render leaves
    /// the render running. The window's own close button says the same thing by doing it, so the
    /// note is what makes the promise legible before the press rather than after it.
    private func footer() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.margins(row, top: 4, bottom: 12, leading: 14, trailing: 14)
        gtk_widget_set_valign(dismissNote, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(row), dismissNote)
        let done = Gtk.button(ImageGenSurface.dismissTitle, css: ["suggested-action", "pill"]) {
            [weak self] in
            Gtk.onMain { [weak self] in self?.close() }
        }
        gtk_widget_set_valign(done, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(row), done)
        return row
    }

    /// A file written or a picture copied is worth one line, said where the work happened rather
    /// than as a dialog somebody has to dismiss. It clears itself, because a notice that outstays
    /// its news becomes chrome.
    private func say(_ text: String) {
        gtk_label_set_text(op(dismissNote), text)
        gtk_widget_set_visible(dismissNote, 1)
        Gtk.after(4000) { [weak self] in
            Gtk.onMain { [weak self] in self?.drawFooter() }
        }
    }

    private func drawFooter() {
        let note = ImageGenSurface.dismissNote(painting: ImageStudio.shared.isPainting)
        gtk_label_set_text(op(dismissNote), note ?? "")
        gtk_widget_set_visible(dismissNote, note == nil ? 0 : 1)
    }

    /// The studio's keys first, then the window's one key. A prompt being typed keeps everything
    /// but Return, and Escape closes the surface rather than the words in it.
    private func key(keyval: UInt32, state: UInt32) -> Bool {
        guard let chord = KeyChord.canonical(keyval: keyval, state: state) else { return false }
        if Gtk.focusTakesText(window) {
            if let command = ImageGenCommand.command(for: chord), command == .submit {
                pane.handle(command)
                return true
            }
        } else if let command = ImageGenCommand.command(for: chord) {
            pane.handle(command)
            return true
        }
        guard keyval == Keymap.escape else { return false }
        close()
        return true
    }

    private func close() {
        gtk_window_destroy(ptr(window))
    }

    /// This window is gone — and it is the one that was destroyed that lets go, never whatever the
    /// static happens to hold: destroy is emitted while the window is torn down, so by the time
    /// deferred work runs the static can already carry a window opened in its place.
    ///
    /// The render is left exactly where it is, in the studio, still arriving.
    private static func destroyed(_ window: ImageWindow) {
        if open === window { open = nil }
        if let observer = window.studioObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        window.studioObserver = nil
        Gtk.onMain { window.pane.shutdown() }
    }

    var summary: String { pane.summary }

    func driverType(_ text: String) { pane.driverType(text) }

    func driverSubmit() { pane.driverSubmit() }

    private static func height(near widget: UnsafeMutablePointer<GtkWidget>?) -> Int32 {
        let asked = Int32(ImageGenSurface.preferredHeight)
        let available = Int32(tailscode_monitor_workarea_height(widget))
        guard available > 0 else { return asked }
        return max(
            Int32(ImageGenSurface.minimumHeight), min(asked, Int32(Double(available) * 0.9)))
    }
}

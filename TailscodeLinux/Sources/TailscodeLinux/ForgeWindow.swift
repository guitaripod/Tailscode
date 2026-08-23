import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The forge, opened over the work rather than beside it.
///
/// A render is a task you start, watch and collect — not a place you work — so it does not earn
/// half of a window the way a second conversation does. It used to take a pane: the transcript lost
/// its width to a surface nobody types into for four minutes, and the pane stayed behind afterwards.
/// This is the same board as a modal transient for the main window, so the conversation is untouched
/// behind it and comes back whole the moment it closes.
///
/// Closing may never stop a render. The job, its socket and the board live in ``ForgeRunner``, so
/// this window is only the view: it says so while a render is out (`ForgeSurface.dismissNote`) and
/// reopening finds the same render exactly where it was.
final class ForgeWindow: @unchecked Sendable {
    nonisolated(unsafe) private static var open: ForgeWindow?

    /// The one that is up, for the headless driver and for anything that wants to know whether the
    /// surface is on screen at all.
    static var current: ForgeWindow? { open }

    @discardableResult
    static func present(parent: UnsafeMutablePointer<GtkWidget>?) -> ForgeWindow {
        if let open {
            gtk_window_present(ptr(open.window))
            open.pane.focusPrompt()
            return open
        }
        let made = ForgeWindow(parent: parent)
        open = made
        return made
    }

    private let window: UnsafeMutablePointer<GtkWidget>
    private let pane: ForgePane
    private let dismissNote: UnsafeMutablePointer<GtkWidget>

    private init(parent: UnsafeMutablePointer<GtkWidget>?) {
        window = gtk_window_new()!
        gtk_window_set_title(ptr(window), ForgeSurface.title)
        gtk_window_set_modal(ptr(window), 1)
        gtk_window_set_default_size(
            ptr(window), Int32(ForgeSurface.preferredWidth),
            Self.height(near: parent))
        gtk_widget_set_size_request(
            window, Int32(ForgeSurface.minimumWidth), Int32(ForgeSurface.minimumHeight))
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }

        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(
            op(UnsafeMutableRawPointer(header)),
            adw_window_title_new(ForgeSurface.title, ForgeSurface.subtitle))
        gtk_window_set_titlebar(ptr(window), header)

        pane = ForgePane(parent: window)
        dismissNote = Gtk.label("", css: "row-detail", wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(dismissNote), 58)
        gtk_widget_set_hexpand(dismissNote, 1)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_box_append(ptr(column), pane.root)
        gtk_box_append(ptr(column), footer())
        gtk_window_set_child(ptr(window), column)

        pane.onChange = { [weak self] in
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

    /// The way out, and the one sentence that has to sit beside it: closing over a render leaves
    /// the render running. The window's own close button says the same thing by doing it, so the
    /// note is what makes the promise legible before the press rather than after it.
    private func footer() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.margins(row, top: 4, bottom: 12, leading: 14, trailing: 14)
        gtk_widget_set_valign(dismissNote, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(row), dismissNote)
        let done = Gtk.button(ForgeSurface.dismissTitle, css: ["suggested-action", "pill"]) {
            [weak self] in
            Gtk.onMain { [weak self] in self?.close() }
        }
        gtk_widget_set_valign(done, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(row), done)
        return row
    }

    private func drawFooter() {
        let note = ForgeSurface.dismissNote(rendering: ForgeRunner.shared.isRendering)
        gtk_label_set_text(op(dismissNote), note ?? "")
        gtk_widget_set_visible(dismissNote, note == nil ? 0 : 1)
    }

    /// The board's keys first, then the window's one key. Escape closes only what the board did not
    /// already close — an expanded section takes it first — so a person who opened the history
    /// closes the history rather than the whole surface.
    private func key(keyval: UInt32, state: UInt32) -> Bool {
        guard let chord = KeyChord.canonical(keyval: keyval, state: state) else { return false }
        if pane.handleChord(chord) { return true }
        guard keyval == Keymap.escape else { return false }
        close()
        return true
    }

    private func close() {
        gtk_window_destroy(ptr(window))
    }

    /// This window is gone — and it is the one that was destroyed that lets go, never whatever the
    /// static happens to hold. Destroy is emitted while the window is torn down, so by the time any
    /// deferred work runs the static can already carry a window opened in its place: releasing that
    /// one would leave a modal on screen that no longer watches the render and a `current` of nil
    /// under it. The reference is dropped now, so nothing can be handed a finalized window, and the
    /// pane stops drawing in the same breath; freeing its player waits for the next turn of the
    /// main loop rather than happening inside GTK's own teardown of the widgets it holds.
    ///
    /// The render is left exactly where it is, in the runner, still arriving.
    private static func destroyed(_ window: ForgeWindow) {
        if open === window { open = nil }
        window.pane.stopDrawing()
        Gtk.onMain { window.pane.shutdown() }
    }

    var summary: String { pane.summary }

    func describe(_ text: String) {
        pane.describe(text)
    }

    func demonstrate(_ name: String) {
        pane.demonstrate(name)
    }

    func handleChord(_ chord: KeyChord) -> Bool {
        pane.handleChord(chord)
    }

    /// As tall as the surface asks for, and never taller than the display it opens on. The modal
    /// carries the renderer, the render, seven settings and the first clips, which is a tall window
    /// by design — and a tall window whose bottom falls off a laptop screen is one whose way out is
    /// somewhere below the fold.
    private static func height(near widget: UnsafeMutablePointer<GtkWidget>?) -> Int32 {
        let asked = Int32(ForgeSurface.preferredHeight)
        let available = Int32(tailscode_monitor_workarea_height(widget))
        guard available > 0 else { return asked }
        return max(Int32(ForgeSurface.minimumHeight), min(asked, Int32(Double(available) * 0.9)))
    }
}

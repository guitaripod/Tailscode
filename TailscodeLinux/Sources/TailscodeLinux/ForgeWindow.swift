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
    /// The header's own title widget: the subtitle is where the closing-keeps-rendering promise
    /// is made while a render is out. A bar under the studio for one label and a Done button that
    /// only repeated the window's own close was a row of chrome the stage paid for.
    private let title: UnsafeMutablePointer<GtkWidget>

    private init(parent: UnsafeMutablePointer<GtkWidget>?) {
        window = gtk_window_new()!
        gtk_window_set_title(ptr(window), ForgeSurface.title)
        gtk_window_set_modal(ptr(window), 1)
        FeatureWindow.fill(
            window, near: parent, minimumWidth: Int32(ForgeSurface.minimumWidth),
            minimumHeight: Int32(ForgeSurface.minimumHeight))
        gtk_widget_set_size_request(
            window, Int32(ForgeSurface.minimumWidth), Int32(ForgeSurface.minimumHeight))
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }

        let header = adw_header_bar_new()!
        title = adw_window_title_new(ForgeSurface.title, ForgeSurface.subtitle)!
        adw_header_bar_set_title_widget(op(UnsafeMutableRawPointer(header)), title)
        gtk_window_set_titlebar(ptr(window), header)

        pane = ForgePane(parent: window)
        gtk_window_set_child(ptr(window), pane.root)

        pane.onChange = { [weak self] in
            Gtk.onMain { [weak self] in self?.drawSubtitle() }
        }
        Gtk.onKey(window) { [weak self] keyval, state in
            guard let self else { return false }
            return self.key(keyval: keyval, state: state)
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") { [weak self] in
            guard let self else { return }
            Self.destroyed(self)
        }

        drawSubtitle()
        gtk_window_present(ptr(window))
        pane.focusPrompt()
    }

    /// The one sentence that has to be legible before the close is pressed: closing over a render
    /// leaves the render running. It rides the header's subtitle while a render is out and gives
    /// the line back when none is.
    private func drawSubtitle() {
        let note = ForgeSurface.dismissNote(rendering: ForgeRunner.shared.isRendering)
        adw_window_title_set_subtitle(op(UnsafeMutableRawPointer(title)), note ?? ForgeSurface.subtitle)
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

    func drive(_ verb: String, _ argument: String) {
        switch verb {
        case "fenhance": pane.driveEnhance()
        case "fuse": pane.driveUseRewrite()
        case "fframe": pane.driveFrame(argument)
        case "fextend": pane.driveExtendNewest()
        case "fsound": pane.driveSound(argument)
        default: break
        }
    }
}

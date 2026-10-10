import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The sheets of one window: the Studio's and the media viewer's, one standing on the other, in
/// the main window's overlay.
///
/// The two layers are made once, in order, so the viewer is always drawn and picked above the
/// Studio whichever was opened first. The Studio's layer is the bottom one. The viewer's sits above
/// it: at depth 1 over the Studio, pushed in so the Studio's edge shows, and at depth 0 over a
/// conversation with nothing beneath it. The Studio never goes under a viewer — asking for it
/// closes the viewer — so a layer's hooks and contents are never taken over by the other.
///
/// Every key goes to the topmost sheet that owns the keyboard, which is how Esc, Ctrl+W, Done and
/// a press on the scrim close the top sheet only and how the Studio's own chords stay out of reach
/// while a viewer sits on it. The conversation's chords are bypassed while any sheet is up.
final class SheetStack: @unchecked Sendable {
    nonisolated(unsafe) private static var installed: SheetStack?

    /// The stack of this window's overlay, or nil before the window has made one.
    static var shared: SheetStack? { installed }

    let layers: [SheetLayer]
    private let probe = gtk_drawing_area_new()!

    /// - Parameters:
    ///   - overlay: the overlay that spans the whole window, sidebar, conversation and composer.
    ///   - content: what the overlay's child is — everything the bottom sheet covers.
    ///   - window: the one main window every dialog a sheet opens is a transient of.
    ///   - titlebar: how far down the window's own bar clears, so a sheet stays below it.
    init(
        overlay: UnsafeMutablePointer<GtkWidget>, content: UnsafeMutablePointer<GtkWidget>,
        window: UnsafeMutablePointer<GtkWidget>, titlebar: @escaping @Sendable () -> Double
    ) {
        let studio = SheetLayer(
            stackedOn: nil, overlay: overlay, content: content, window: window, titlebar: titlebar)
        let viewer = SheetLayer(
            stackedOn: studio, overlay: overlay, content: content, window: window,
            titlebar: titlebar)
        layers = [studio, viewer]

        gtk_widget_set_hexpand(probe, 1)
        gtk_widget_set_vexpand(probe, 1)
        gtk_widget_set_can_target(probe, 0)
        gtk_widget_set_can_focus(probe, 0)
        Gtk.setHidden(probe, true)
        gtk_overlay_add_overlay(op(overlay), probe)
        gtk_overlay_set_measure_overlay(op(overlay), probe, 0)
        Gtk.onResize(probe) { [weak self] in
            Gtk.onMain { [weak self] in self?.relayout() }
        }
        Self.installed = self
    }

    /// Lets go of the claim to be the window's stack, for a harness that built its own.
    func retire() {
        if Self.installed === self { Self.installed = nil }
        for layer in layers { layer.stopClock() }
    }

    /// A window resize or a maximise re-lays every sheet that is up.
    func relayout() {
        for layer in layers { layer.relayout() }
    }

    /// The appearance changed: every scrim re-resolves to the other face's alpha.
    func rethemed() {
        for layer in layers { layer.rethemed() }
    }

    /// Whether any sheet is on screen, rising, at rest or leaving.
    var isUp: Bool { layers.contains { $0.isUp } }

    /// Whether the conversation's chords may run: no sheet owns the keyboard.
    var conversationChordsEnabled: Bool { layers.allSatisfy { $0.state.conversationChordsEnabled } }

    /// How many sheets are standing on one another right now.
    var depth: Int { layers.filter { $0.isUp }.count }

    /// The sheet that owns the keyboard: the topmost that is rising or at rest.
    var top: SheetLayer? { layers.last { $0.capturesKeys } }

    /// A key while any sheet owns the keyboard: whether the top one took it. Nil when no sheet owns
    /// the keyboard, which is the conversation's cue to go on.
    func handleKey(keyval: UInt32, state: UInt32) -> Bool? {
        guard let top, let keys = top.keys else { return nil }
        return keys(keyval, state)
    }

    /// The Studio's layer, the bottom one.
    var studioLayer: SheetLayer { layers[0] }

    /// The viewer's layer, above the Studio's.
    var viewerLayer: SheetLayer { layers[1] }

    /// Takes the viewer down at once, with no motion, for a Studio that is about to rise or leave
    /// and must not have a viewer standing over it.
    func closeViewer() {
        viewerLayer.closeNow()
    }
}

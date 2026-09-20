import CGtkShim
import Foundation

/// How a feature surface — the image studio, the forge, a design board, the gallery, the delegate
/// desk — is sized when it opens: the whole display less a margin on every side.
///
/// Each of these is a room a person walks into to do one thing and then leaves, not a dialog to
/// glance at, and a room drawn at a preferred size on a large monitor sat in the middle of the
/// screen with the conversation showing round it, so every one of them was dragged bigger before
/// it was used. The size is taken from the monitor the opener's window is on, never from the
/// opener's own width: a main window half the screen is no reason for the studio to be.
enum FeatureWindow {
    /// The margin left on every side, so the surface reads as a window over the work rather than
    /// as the app having gone full screen.
    static let inset: Int32 = 40

    /// The size to open at, on the screen the widget is on, and never below the floor a surface
    /// names for itself — a monitor smaller than the floor gets the floor and the window manager
    /// deals with it the way it deals with any window that does not fit.
    static func size(
        near widget: UnsafeMutablePointer<GtkWidget>?, minimumWidth: Int32, minimumHeight: Int32
    ) -> (width: Int32, height: Int32) {
        var width: Int32 = 0
        var height: Int32 = 0
        tailscode_monitor_size(widget, &width, &height)
        guard width > 0, height > 0 else { return (minimumWidth, minimumHeight) }
        return (
            max(minimumWidth, width - inset * 2),
            max(minimumHeight, height - inset * 2)
        )
    }

    /// Applies the size to a window that is about to be presented.
    static func fill(
        _ window: UnsafeMutablePointer<GtkWidget>, near widget: UnsafeMutablePointer<GtkWidget>?,
        minimumWidth: Int32, minimumHeight: Int32
    ) {
        let size = size(near: widget, minimumWidth: minimumWidth, minimumHeight: minimumHeight)
        gtk_window_set_default_size(ptr(window), size.width, size.height)
    }
}

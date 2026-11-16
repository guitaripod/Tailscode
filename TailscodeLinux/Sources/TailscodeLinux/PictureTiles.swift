import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The tiles one transcript is drawing its pictures in, by picture, so the viewer can open a
/// picture out of the tile it stands in and put it back there.
///
/// A transcript rebuilds its rows under an open viewer, so nothing here is kept longer than a
/// widget lives: a tile is forgotten the moment its widget is destroyed, and whoever asks is told
/// where the picture is now or that it is nowhere.
final class PictureTiles: @unchecked Sendable {
    struct Tile {
        let widget: UnsafeMutablePointer<GtkWidget>
        /// Whether the picture is fitted whole inside the widget rather than cropped to it.
        let fitted: Bool
    }

    private var standing: [String: (bits: UInt, fitted: Bool)] = [:]

    /// Says that `widget` is where the picture `key` is drawn, until the widget goes.
    func stand(_ widget: UnsafeMutablePointer<GtkWidget>, for key: String, fitted: Bool) {
        let bits = UInt(bitPattern: widget)
        standing[key] = (bits, fitted)
        Gtk.connect(UnsafeMutableRawPointer(widget), "destroy") { [weak self] in
            guard let self, self.standing[key]?.bits == bits else { return }
            self.standing[key] = nil
        }
    }

    /// The widget the picture is drawn in right now, when it is on screen.
    func tile(for key: String) -> Tile? {
        guard let held = standing[key], let widget = UnsafeMutablePointer<GtkWidget>(bitPattern: held.bits),
            gtk_widget_get_mapped(widget) != 0
        else { return nil }
        return Tile(widget: widget, fitted: held.fitted)
    }

    /// Draws a picture's tile again, or stops drawing it while the picture is in the viewer.
    func setOut(_ key: String, _ out: Bool) {
        guard let tile = tile(for: key) else { return }
        gtk_widget_set_opacity(tile.widget, out ? 0 : 1)
    }
}

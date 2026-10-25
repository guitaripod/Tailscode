import CGtkShim
import Foundation

/// How big the agents window opens: the size of the window it came from, never less than the
/// floor, never more than the monitor can hold — or the size the person left it at, held to the
/// same limits. The old size came from the whole monitor less a margin, which is taller than the
/// window it belongs to whenever that window is short.
enum AgentsWindowSize {
    static let floor = (width: Int32(640), height: Int32(420))
    static let margin: Int32 = 24
    static let usableHeight = 0.94

    static func initial(parent: UnsafeMutablePointer<GtkWidget>?) -> (width: Int32, height: Int32) {
        let reference = parentSize(parent)
        let wanted =
            Preferences.agentsWindowSize
            ?? (max(reference.width, floor.width), max(reference.height, floor.height))
        return clamp(wanted, near: parent)
    }

    static func parentSize(_ parent: UnsafeMutablePointer<GtkWidget>?) -> (width: Int32, height: Int32) {
        if let parent {
            let width = gtk_widget_get_width(parent)
            let height = gtk_widget_get_height(parent)
            if width > 0 && height > 0 { return (width, height) }
        }
        return Preferences.windowSize
    }

    /// The monitor's room for a window: the whole width less a margin each side, and the height
    /// the main window is already held to, which leaves what a panel takes.
    static func workArea(near widget: UnsafeMutablePointer<GtkWidget>?) -> (width: Int32, height: Int32) {
        var width: Int32 = 0
        var height: Int32 = 0
        tailscode_monitor_size(widget, &width, &height)
        guard width > 0, height > 0 else { return (Int32.max, Int32.max) }
        return (width - 2 * margin, Int32(Double(height) * usableHeight) - margin)
    }

    static func clamp(
        _ size: (width: Int32, height: Int32), near widget: UnsafeMutablePointer<GtkWidget>?
    ) -> (width: Int32, height: Int32) {
        let room = workArea(near: widget)
        return (min(size.width, max(room.width, floor.width)), min(size.height, max(room.height, floor.height)))
    }

    static func ceiling(near widget: UnsafeMutablePointer<GtkWidget>?) -> Int32 {
        workArea(near: widget).height
    }
}

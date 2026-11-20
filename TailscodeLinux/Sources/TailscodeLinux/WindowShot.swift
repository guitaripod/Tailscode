import CAdw
import CGtkShim
import Foundation

/// A toplevel drawn into a PNG by GTK's own renderer, for the harness: a window on a display with
/// no window manager is mapped but not always painted, so reading the screen shows what lies
/// under it, while its own render node is always what it would draw.
enum WindowShot {
    static func render(titled title: String, to path: String) -> Bool {
        guard let window = toplevel(titled: title) else { return false }
        return render(window, to: path)
    }

    /// Any widget with a surface of its own, a popover as much as a window.
    static func render(_ window: UnsafeMutablePointer<GtkWidget>, to path: String) -> Bool {
        let width = gtk_widget_get_width(window)
        let height = gtk_widget_get_height(window)
        guard width > 0, height > 0, let paintable = gtk_widget_paintable_new(window),
            let snapshot = gtk_snapshot_new()
        else { return false }
        defer { g_object_unref(UnsafeMutableRawPointer(paintable)) }
        gdk_paintable_snapshot(paintable, snapshot, Double(width), Double(height))
        guard let node = gtk_snapshot_free_to_node(snapshot) else { return false }
        defer { gsk_render_node_unref(node) }
        guard let native = gtk_widget_get_native(window), let renderer = gtk_native_get_renderer(native),
            let texture = gsk_renderer_render_texture(renderer, node, nil)
        else { return false }
        defer { g_object_unref(UnsafeMutableRawPointer(texture)) }
        return gdk_texture_save_to_png(texture, path) != 0
    }

    private static func toplevel(titled title: String) -> UnsafeMutablePointer<GtkWidget>? {
        guard let list = gtk_window_list_toplevels() else { return nil }
        defer { g_list_free(list) }
        var cursor: UnsafeMutablePointer<GList>? = list
        while let node = cursor {
            if let data = node.pointee.data {
                let widget: UnsafeMutablePointer<GtkWidget> = data.assumingMemoryBound(to: GtkWidget.self)
                if gtk_widget_get_visible(widget) != 0, let raw = gtk_window_get_title(ptr(UnsafeMutableRawPointer(widget))),
                    String(cString: raw).contains(title)
                {
                    return widget
                }
            }
            cursor = node.pointee.next
        }
        return nil
    }
}

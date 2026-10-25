import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The peek that comes over the wall: what one agent is doing, its steps, its agents, its meters
/// and the verbs toward it. It is the same view the board's inspector is, in a sheet of its own,
/// and it goes back to the wall by itself when nobody has touched anything for a while.
final class WatchPeekLayer: @unchecked Sendable {
    static let returnsAfter: TimeInterval = 20

    let backdrop = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
    let sheet = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
    let peek: AgentPeekView
    private let context: WatchContext
    private(set) var isShown = false
    private(set) var lastInput = Date.distantPast
    var onDismiss: () -> Void = {}

    init(peek: AgentPeekView, context: WatchContext) {
        self.peek = peek
        self.context = context
        Gtk.addClass(backdrop, "agents-wall-backdrop")
        Gtk.addClass(sheet, "agents-wall-sheet")
        gtk_box_append(ptr(sheet), peek.widget)
        gtk_widget_set_vexpand(peek.widget, 1)
        gtk_widget_set_overflow(sheet, GTK_OVERFLOW_HIDDEN)
        Gtk.onPrimaryRelease(backdrop) { [weak self] in Gtk.onMain { [weak self] in self?.onDismiss() } }
        Gtk.onPointer(
            sheet, move: { [weak self] _, _ in Gtk.onMain { [weak self] in self?.touch() } }, leave: {})
        Gtk.onKey(sheet) { [weak self] _, _ in
            Gtk.onMain { [weak self] in self?.touch() }
            return false
        }
    }

    var widgets: [UnsafeMutablePointer<GtkWidget>] { [backdrop, sheet] }

    func show() {
        isShown = true
        touch()
    }

    func hide() {
        isShown = false
    }

    func touch() {
        lastInput = context.clock.now
    }

    func isExpired(at now: Date) -> Bool {
        isShown && now.timeIntervalSince(lastInput) >= Self.returnsAfter
    }

    func place(width: Double, height: Double, unit: Double, sink: TileSink) {
        guard isShown else { return }
        sink.place(backdrop, TileRect(x: 0, y: 0, width: Int32(width), height: Int32(height)))
        let wide = width >= height
        let sheetWidth = min(width * 0.94, wide ? max(width * 0.46, 54 * unit) : width * 0.92)
        let sheetHeight = height * 0.9
        sink.place(
            sheet,
            TileRect(
                x: Int32(((width - sheetWidth) / 2).rounded()), y: Int32(((height - sheetHeight) / 2).rounded()),
                width: Int32(sheetWidth.rounded()), height: Int32(sheetHeight.rounded())))
    }
}

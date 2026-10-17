import CAdw
import CGtkShim
import Foundation

/// Keeps what the reader is looking at where it is while something above it changes height.
///
/// A scrolled window holds an offset, not a row, so a stage that opens or closes above the top of
/// the viewport moves everything under it by the stage's own height and the reader's place is
/// lost. The anchor is the row at the top of the viewport and how far from the top it sits: it is
/// taken just before the change, and re-asserted on every height the scroller reports for a short
/// settle window, because the change does not land in one allocation (a stage is built, then laid
/// out, then given its picture). The row is found again by its key each time, never by a widget
/// that a rebuild may have replaced.
final class ScrollAnchor: @unchecked Sendable {
    typealias Row = (key: String, widget: UInt)

    /// How long after the change heights are still being held. A stage is allocated within a frame
    /// or two; this is long enough for a slow machine and short enough that no wheel turn of the
    /// reader's can be fought.
    static let settle: UInt32 = 450

    private let adjustment: UnsafeMutablePointer<GtkAdjustment>
    private let canvas: UnsafeMutablePointer<GtkWidget>
    private let rows: () -> [Row]
    private let place: (Double) -> Void
    private var held: (key: String, offset: Double)?
    private var generation = 0

    init(
        adjustment: UnsafeMutablePointer<GtkAdjustment>, canvas: UnsafeMutablePointer<GtkWidget>,
        rows: @escaping () -> [Row], place: @escaping (Double) -> Void
    ) {
        self.adjustment = adjustment
        self.canvas = canvas
        self.rows = rows
        self.place = place
    }

    var isHolding: Bool { held != nil }

    var holdsKey: String? { held?.key }

    /// Notes the row at the top of the viewport and holds it there until the heights settle. A hold
    /// already running keeps its row and only has its window extended: the row is the same one.
    func capture() {
        if held == nil {
            let value = gtk_adjustment_get_value(adjustment)
            for row in rows() {
                guard let frame = frame(of: row.widget) else { continue }
                if frame.y + frame.height > value + 1 {
                    held = (row.key, frame.y - value)
                    break
                }
            }
        }
        guard held != nil else { return }
        generation += 1
        let mine = generation
        Gtk.after(Self.settle) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.generation == mine else { return }
                self.held = nil
            }
        }
    }

    /// Puts the held row back at its offset. Runs when the scroller reports a new height, at once
    /// and again once layout has finished, because a value written in the middle of an allocation is
    /// taken and never drawn.
    func reassert() {
        guard held != nil else { return }
        apply()
        Gtk.onMain { [weak self] in self?.apply() }
    }

    private func apply() {
        guard let held, let row = rows().first(where: { $0.key == held.key }),
            let frame = frame(of: row.widget)
        else { return }
        let page = gtk_adjustment_get_page_size(adjustment)
        let ceiling = max(gtk_adjustment_get_lower(adjustment), gtk_adjustment_get_upper(adjustment) - page)
        let target = min(max(gtk_adjustment_get_lower(adjustment), frame.y - held.offset), ceiling)
        guard abs(gtk_adjustment_get_value(adjustment) - target) > 0.5 else { return }
        place(target)
    }

    private func frame(of widget: UInt) -> (y: Double, height: Double)? {
        guard let raw = UnsafeMutableRawPointer(bitPattern: widget) else { return nil }
        var x = 0.0
        var y = 0.0
        var width = 0.0
        var height = 0.0
        guard tailscode_widget_bounds_in(ptr(raw), canvas, &x, &y, &width, &height) != 0 else { return nil }
        return (y, height)
    }
}

import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension Gtk {
    /// Every key let go of inside `widget`, in the capture phase, with the modifiers still held.
    static func onKeyRelease(
        _ widget: UnsafeMutablePointer<GtkWidget>, _ handler: @escaping @Sendable (UInt32, UInt32) -> Void
    ) {
        _ = releaseInstalled
        let box = Unmanaged.passRetained(KeyReleaseBox(handler)).toOpaque()
        let callback: @convention(c) (guint, guint, UnsafeMutableRawPointer?) -> Void = { keyval, state, raw in
            guard let raw else { return }
            Unmanaged<KeyReleaseBox>.fromOpaque(raw).takeUnretainedValue().handler(UInt32(keyval), UInt32(state))
        }
        tailscode_connect_key_release(widget, callback, box)
    }

    /// A primary press on `widget` that may travel, claimed so the widget never also clicks.
    static func onPressDrag(
        _ widget: UnsafeMutablePointer<GtkWidget>, begin: @escaping @Sendable (Double, Double) -> Void,
        update: @escaping @Sendable (Double, Double) -> Void, end: @escaping @Sendable (Double, Double) -> Void,
        cancel: @escaping @Sendable () -> Void
    ) {
        _ = releaseInstalled
        let box = Unmanaged.passRetained(PressDragBox(begin: begin, update: update, end: end, cancel: cancel)).toOpaque()
        tailscode_on_press_drag(
            widget,
            { x, y, raw in
                guard let raw else { return }
                Unmanaged<PressDragBox>.fromOpaque(raw).takeUnretainedValue().begin(x, y)
            },
            { dx, dy, raw in
                guard let raw else { return }
                Unmanaged<PressDragBox>.fromOpaque(raw).takeUnretainedValue().update(dx, dy)
            },
            { dx, dy, raw in
                guard let raw else { return }
                Unmanaged<PressDragBox>.fromOpaque(raw).takeUnretainedValue().end(dx, dy)
            },
            { raw in
                guard let raw else { return }
                Unmanaged<PressDragBox>.fromOpaque(raw).takeUnretainedValue().cancel()
            }, box)
    }

    final class KeyReleaseBox: @unchecked Sendable {
        let handler: @Sendable (UInt32, UInt32) -> Void
        init(_ handler: @escaping @Sendable (UInt32, UInt32) -> Void) { self.handler = handler }
    }

    final class PressDragBox: @unchecked Sendable {
        let begin: @Sendable (Double, Double) -> Void
        let update: @Sendable (Double, Double) -> Void
        let end: @Sendable (Double, Double) -> Void
        let cancel: @Sendable () -> Void

        init(
            begin: @escaping @Sendable (Double, Double) -> Void, update: @escaping @Sendable (Double, Double) -> Void,
            end: @escaping @Sendable (Double, Double) -> Void, cancel: @escaping @Sendable () -> Void
        ) {
            self.begin = begin
            self.update = update
            self.end = end
            self.cancel = cancel
        }
    }
}

/// The lit edge of the prompt box while the microphone is open: the aura's drawing, in one colour,
/// its glow following the voice. Accent while listening, danger while a held take is armed to be
/// thrown away. It never takes input.
final class ListeningEdge: @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget>
    private(set) var isLit = false
    private var tone: ActivityTone = .live

    init() {
        widget = tailscode_aura_new()
        gtk_widget_set_visible(widget, 0)
    }

    func set(lit: Bool, tone: ActivityTone, glow: Double) {
        if lit != isLit {
            isLit = lit
            gtk_widget_set_visible(widget, lit ? 1 : 0)
        }
        guard lit else { return }
        self.tone = tone
        let palette = MatrixTheme.palette
        let ink = PartyInk(hex: tone == .danger ? palette.danger : palette.accent)
        let stops = [ink.red, ink.green, ink.blue, ink.red, ink.green, ink.blue]
        stops.withUnsafeBufferPointer { buffer in
            tailscode_aura_set(widget, 0, min(1, max(0, glow)), buffer.baseAddress, 2)
        }
    }
}

/// The five level bars the mic chip turns into while it listens, drawn in the chip's own ink.
final class DictationBarsView: @unchecked Sendable {
    let widget = gtk_drawing_area_new()!
    private var heights = [Double](repeating: DictationBars.floor, count: DictationBars.count)
    private var ink = PartyInk(red: 1, green: 1, blue: 1)

    private final class Holder: @unchecked Sendable {
        weak var view: DictationBarsView?
        init(_ view: DictationBarsView) { self.view = view }
    }

    init() {
        gtk_drawing_area_set_content_width(ptr(widget), 27)
        gtk_drawing_area_set_content_height(ptr(widget), 16)
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        _ = Gtk.releaseInstalled
        let box = Unmanaged.passRetained(Holder(self)).toOpaque()
        gtk_drawing_area_set_draw_func(
            ptr(widget),
            { _, cr, width, height, raw in
                guard let cr, let raw, let view = Unmanaged<Holder>.fromOpaque(raw).takeUnretainedValue().view else {
                    return
                }
                view.paint(cr, width: Double(width), height: Double(height))
            }, box,
            { raw in
                guard let raw else { return }
                Unmanaged<Holder>.fromOpaque(raw).release()
            })
    }

    func set(heights: [Double], ink: PartyInk) {
        guard heights != self.heights || ink != self.ink else { return }
        self.heights = heights
        self.ink = ink
        gtk_widget_queue_draw(widget)
    }

    private func paint(_ cr: OpaquePointer, width: Double, height: Double) {
        let count = Double(heights.count)
        let bar = 3.0
        let gap = (width - bar * count) / max(1, count - 1)
        cairo_set_source_rgba(cr, ink.red, ink.green, ink.blue, 1)
        for (index, fraction) in heights.enumerated() {
            let barHeight = max(bar, height * fraction)
            let x = Double(index) * (bar + gap)
            let y = (height - barHeight) / 2
            BrainPainter.round(cr, x, y, bar, barHeight, bar / 2)
            cairo_fill(cr)
        }
    }
}

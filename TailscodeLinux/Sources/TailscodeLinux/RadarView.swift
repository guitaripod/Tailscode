import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The tailnet dial, rasterised.
///
/// `TailnetRadar` is the whole of the arithmetic — where the sweep is, and how brightly each found
/// machine sits on it — and this only paints that through the shim's cairo painter, on frames from
/// the display's own clock. Two surfaces ask the same question of the same tailnet — which machines
/// run an agent, and which one runs the renderer — so they draw one dial rather than two that could
/// drift apart in speed, ink or geometry.
///
/// The inks are painted rather than styled, so a theme change that restyles every other widget by
/// CSS would leave them where they were; they are re-read whenever the palette's accent differs
/// from the one they were mixed from, which costs four colours on a frame that was going to be
/// drawn anyway. When the scan ends the clock stops: a finished picture repainted sixty times a
/// second is a fan spinning for nothing.
final class RadarView: @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget>
    var blips: [RadarBlip] = []
    var scanning = false

    private var tick: guint = 0
    private var inkedFrom = ""

    static var motionAllowed: Bool { tailscode_animations_enabled() != 0 }
    static var now: Double { Double(g_get_monotonic_time()) / 1_000_000 }

    init(size: Int32 = 168) {
        widget = tailscode_radar_new()!
        gtk_widget_set_size_request(widget, size, size)
        gtk_widget_set_halign(widget, GTK_ALIGN_CENTER)
    }

    /// A widget handed to `adw_preferences_group_add` that is not a row lands in a box *after* the
    /// group's list, which would put the dial under every result it drew. Wrapping it in a bare
    /// preferences row puts it in the list, in the order it was added — and it activates nothing,
    /// because it is a picture rather than a control.
    func preferencesRow() -> UnsafeMutablePointer<GtkWidget> {
        let holder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.margins(holder, top: 14, bottom: 10)
        gtk_box_append(ptr(holder), widget)
        let row = adw_preferences_row_new()!
        gtk_list_box_row_set_child(ptr(row), holder)
        gtk_list_box_row_set_activatable(ptr(row), 0)
        gtk_list_box_row_set_selectable(ptr(row), 0)
        return row
    }

    func startClock() {
        guard tick == 0, Self.motionAllowed else {
            draw()
            return
        }
        let box = Unmanaged.passRetained(TickBox(self)).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
            guard let raw else { return }
            Unmanaged<TickBox>.fromOpaque(raw).takeUnretainedValue().radar?.draw()
        }
        tick = tailscode_add_tick(widget, callback, box)
    }

    func stopClock() {
        guard tick != 0 else { return }
        tailscode_remove_tick(widget, tick)
        tick = 0
    }

    func draw() {
        applyInk()
        let frame = TailnetRadar.frame(
            at: Self.now, blips: blips, scanning: scanning, reducedMotion: !Self.motionAllowed)
        var sparks: [Double] = []
        sparks.reserveCapacity(frame.sparks.count * 5)
        for spark in frame.sparks {
            sparks.append(contentsOf: [
                spark.angle, spark.radius, spark.light, spark.scale, Double(Self.tone(spark.tone)),
            ])
        }
        let count = Int32(frame.sparks.count)
        TailnetRadar.rings.withUnsafeBufferPointer { rings in
            sparks.withUnsafeBufferPointer { blips in
                tailscode_radar_set(
                    widget, frame.sweep, frame.sweepLight, frame.ping, frame.pingLight,
                    rings.baseAddress, Int32(TailnetRadar.rings.count), blips.baseAddress, count)
            }
        }
        if frame.settled { stopClock() }
    }

    private func applyInk() {
        let palette = MatrixTheme.palette
        guard palette.accent != inkedFrom else { return }
        inkedFrom = palette.accent
        var ink: [Double] = []
        for hex in [palette.textDim, palette.accent, palette.warn, palette.info] {
            let rgb = PresenceRGB(hex: hex) ?? PresenceRGB(red: 0.5, green: 0.5, blue: 0.5)
            ink.append(contentsOf: [rgb.red, rgb.green, rgb.blue])
        }
        ink.withUnsafeBufferPointer { tailscode_radar_ink(widget, $0.baseAddress, 4) }
    }

    private static func tone(_ tone: RadarTone) -> Int32 {
        switch tone {
        case .ready: return 0
        case .locked: return 1
        case .pending: return 2
        }
    }
}

/// The tick callback's payload. The shim takes a raw pointer and gives it back every frame, so the
/// reference has to be one this side owns; it holds the dial weakly, because a clock that kept a
/// closed window's dial alive would repaint a picture nobody can see.
private final class TickBox {
    weak var radar: RadarView?

    init(_ radar: RadarView) {
        self.radar = radar
    }
}

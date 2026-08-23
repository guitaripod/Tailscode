import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The presence orb: the aggregate of everything this window watches, worn as one small creature
/// at the foot of the sidebar. The whole behaviour is Core's `PresenceField` — this end only
/// resolves the palette's inks, reads the frame clock, and hands each frame to the GL shader —
/// and the clock stops the moment a frame reports itself settled, because stillness rendered
/// sixty times a second is a fan spinning for a picture that is finished.
final class OrbPainter: @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget>
    private let area: UnsafeMutablePointer<GtkWidget>
    private var field: PresenceField
    private var tick: UInt = 0
    private var lastPainted = 0.0
    private let stops: [Float]
    private(set) var signal = PresenceSignal()
    private(set) var lastFrameSettled = false

    init() {
        field = PresenceField(colors: Self.inks())
        stops = Ultracode.rainbowStops.flatMap {
            [Float($0.red), Float($0.green), Float($0.blue)]
        }
        area = tailscode_orb_new()
        gtk_widget_set_size_request(area, 88, 88)
        gtk_widget_set_halign(area, GTK_ALIGN_CENTER)
        widget = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(widget, "presence-orb")
        Gtk.margins(widget, top: 0, bottom: 6, leading: 10, trailing: 10)
        gtk_widget_set_cursor_from_name(widget, "pointer")
        gtk_box_append(ptr(widget), area)
        gtk_widget_set_visible(widget, 0)
        applyEnabled()
        RepeatingMotion.watch(area) { [weak self] in self?.motionPreferenceChanged() }
    }

    /// Whether the creature's clock is running, for a harness that has to prove it rather than
    /// watch it — a body breathing and a body that stopped are the same picture in any one frame,
    /// and a clock left turning over a settled body is the whole cost the pausing exists to avoid.
    var isDrawing: Bool { tick != 0 }

    /// Takes the still-or-moving decision again when the desk changes its mind.
    ///
    /// Every frame already asks — a creature told to stop moving settles, and a settled frame stops
    /// the clock — which is exactly why the change has to be answered: a stopped clock asks nothing
    /// more, so a desk that allowed movement back would be left with a body frozen mid-breath for
    /// as long as the sidebar stood. Waking is the whole of the answer. The next frame reads the
    /// preference again and settles straight back if nothing changed, and a creature the setting
    /// itself switched off is not woken at all.
    private func motionPreferenceChanged() {
        wake()
    }

    private static var now: Double { Double(g_get_monotonic_time()) / 1_000_000 }

    /// The palette's own tone slots, and nothing private: live is the accent, attention is warn,
    /// failure is danger, rest is the dim register. The area itself is transparent — the creature
    /// floats on the sidebar's own background rather than sitting in a box of canvas colour.
    private static func inks() -> PresenceColors {
        let palette = MatrixTheme.palette
        func rgb(_ hex: String) -> PresenceRGB {
            PresenceRGB(hex: hex) ?? PresenceRGB(red: 0.5, green: 0.5, blue: 0.5)
        }
        return PresenceColors(
            live: rgb(palette.accent), attention: rgb(palette.warn),
            danger: rgb(palette.danger), quiet: rgb(palette.textDim))
    }

    func applyEnabled() {
        let enabled = Preferences.presenceOrb
        gtk_widget_set_visible(widget, enabled ? 1 : 0)
        guard enabled else {
            stop()
            return
        }
        wake()
    }

    func applyTheme() {
        field.set(colors: Self.inks())
        wake()
    }

    func update(signal: PresenceSignal) {
        guard signal != self.signal else { return }
        self.signal = signal
        field.set(signal: signal)
        gtk_widget_set_tooltip_text(widget, signal.spoken)
        wake()
    }

    /// One line for the harness: what the orb is saying, without a screenshot.
    var stateLine: String {
        let ready = tailscode_orb_ready(area) != 0
        return "enabled=\(Preferences.presenceOrb ? 1 : 0) ready=\(ready ? 1 : 0) "
            + "satellites=\(signal.satellites) tone=\(signal.tone?.rawValue ?? "idle") "
            + "settled=\(lastFrameSettled ? 1 : 0)"
    }

    private func wake() {
        guard Preferences.presenceOrb else { return }
        lastFrameSettled = false
        paint(at: Self.now)
        start()
    }

    private func start() {
        guard tick == 0 else { return }
        g_object_ref(UnsafeMutableRawPointer(area))
        tick = UInt(
            tailscode_add_tick(
                area,
                { raw in
                    guard let raw else { return }
                    let painter = Unmanaged<OrbPainter>.fromOpaque(raw).takeUnretainedValue()
                    painter.step()
                }, Unmanaged.passUnretained(self).toOpaque()))
    }

    private func stop() {
        guard tick != 0 else { return }
        tailscode_remove_tick(area, guint(tick))
        tick = 0
        g_object_unref(UnsafeMutableRawPointer(area))
    }

    /// One frame of the body, at the tempo everything in this app that moves runs at, and the last
    /// one when the frame reports itself settled.
    ///
    /// It breathes on a swell measured in seconds, and drawing that a hundred and sixty-five times
    /// a second because the display can is a fan spinning for motion no eye can tell from the
    /// tempo. Which tick the tempo owes is ``ActivityTuning/wantsFrame(at:lastDrawn:)``'s answer
    /// rather than a comparison of its own, which on a 60Hz or 120Hz panel lands on the tick
    /// boundary and quietly runs the creature slow. The arithmetic still reads absolute time, so a
    /// skipped frame costs a frame and never the phase.
    private func step() {
        let time = Self.now
        guard ActivityTuning.wantsFrame(at: time, lastDrawn: lastPainted) else { return }
        lastPainted = time
        paint(at: time)
        if lastFrameSettled { stop() }
    }

    private func paint(at time: Double) {
        let frame = field.frame(at: time, reduceMotion: !RepeatingMotion.allowed)
        lastFrameSettled = frame.settled
        var blobs: [Float] = []
        blobs.reserveCapacity(frame.blobs.count * 4)
        for blob in frame.blobs {
            blobs.append(contentsOf: [
                Float(blob.x), Float(blob.y), Float(blob.radius), Float(blob.weight),
            ])
        }
        let color = [Float(frame.color.red), Float(frame.color.green), Float(frame.color.blue)]
        blobs.withUnsafeBufferPointer { blobBuffer in
            color.withUnsafeBufferPointer { colorBuffer in
                stops.withUnsafeBufferPointer { stopBuffer in
                    tailscode_orb_set(
                        area, blobBuffer.baseAddress, Int32(frame.blobs.count),
                        colorBuffer.baseAddress, Float(frame.energy),
                        Float(frame.intensity), Float(frame.rainbow),
                        Float(frame.rainbowPhase), Float(frame.rainbowGlow),
                        stopBuffer.baseAddress, Int32(Ultracode.rainbowStops.count))
                }
            }
        }
    }

    deinit { stop() }
}

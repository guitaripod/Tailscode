import CAdw
import CGtkShim
import TailscodeCore

/// What makes a busy row look busy: the glyph a state owns, moving the way that state moves.
///
/// Frames come from the widget's own frame clock, and the time is the monotonic clock every other
/// moving thing in this app reads — so five live rows breathe as one hand rather than five, which
/// is the difference between a list that is alive and a list that is glitching. What a frame is
/// allowed to change is deliberately narrow: opacity always, and the glyph only for a state that
/// sweeps, whose four frames are one column wide apiece. Nothing here re-measures a label, because
/// a row that re-wraps under the reader is worse than a row that does not move at all.
///
/// The state lives on the widget (`g_object_set_data_full`), so a row torn down mid-swell releases
/// it without anyone remembering to — the sidebar rebuilds hundreds of rows a session and a
/// registry someone has to keep swept is a leak with extra steps.
final class ActivityPulse {
    private static let key = "tailscode-activity-pulse"

    private let widget: UnsafeMutablePointer<GtkWidget>
    private let icon: ActivityIcon
    private let motion: ActivityMotion
    private var text: String?
    private let write: ((String) -> Void)?
    private var tick: UInt = 0
    private var lastOpacity = -1.0
    private var lastFrame = ""
    private var lastStepped = 0.0
    /// A swell measured in seconds needs no more than thirty frames of it a second; stepped at a
    /// fast panel's own rate, every breathing badge redraws the window that often for light no
    /// eye can tell apart. The arithmetic reads absolute time, so a skipped frame skips nothing.
    private static let frameInterval = 1.0 / ActivityTuning.frameRate

    private init(
        widget: UnsafeMutablePointer<GtkWidget>, icon: ActivityIcon, motion: ActivityMotion,
        text: String?, write: ((String) -> Void)?
    ) {
        self.widget = widget
        self.icon = icon
        self.motion = motion
        self.text = text
        self.write = write
    }

    /// Whether the desk wants motion at all. Read once per attach rather than per frame: a state
    /// that cannot move still says everything it has to say in its glyph, its word and its colour.
    static var motionAllowed: Bool { tailscode_animations_enabled() != 0 }

    private static var now: Double { Double(g_get_monotonic_time()) / 1_000_000 }

    /// Points a widget at a state, or lets go of it. A widget already moving to the same state is
    /// left exactly as it is — re-attaching every render would restart the swell on every keystroke
    /// and the list would flicker instead of breathe.
    ///
    /// - Parameter text: the line the widget shows, whose first character is the glyph. Only a
    ///   sweeping state needs it; a breathing one moves without touching the text at all.
    /// - Parameter write: how this widget takes new text — a label, a button and a menu button all
    ///   spell it differently, and the band holds all three.
    static func apply(
        _ icon: ActivityIcon?, to widget: UnsafeMutablePointer<GtkWidget>, text: String? = nil,
        write: ((String) -> Void)? = nil
    ) {
        let existing = current(of: widget)
        guard let icon else {
            existing?.stop()
            clear(widget)
            gtk_widget_set_opacity(widget, 1)
            return
        }
        let motion = icon.motion.honoring(reduceMotion: !motionAllowed)
        if let existing, existing.icon == icon {
            existing.text = text
            return
        }
        existing?.stop()
        clear(widget)
        guard motion.isAnimated else {
            gtk_widget_set_opacity(widget, 1)
            return
        }
        let pulse = ActivityPulse(
            widget: widget, icon: icon, motion: motion, text: text, write: write)
        let box = Unmanaged.passRetained(pulse).toOpaque()
        g_object_set_data_full(
            ptr(widget), Self.key, box,
            { raw in
                guard let raw else { return }
                Unmanaged<ActivityPulse>.fromOpaque(raw).release()
            })
        pulse.start()
    }

    /// Puts a widget back the way it was found. A turn merely ending changes no widget property a
    /// diff would notice, so the swell has to be taken off by hand or the row keeps breathing after
    /// the agent has stopped.
    static func stop(_ widget: UnsafeMutablePointer<GtkWidget>) {
        current(of: widget)?.stop()
        clear(widget)
        gtk_widget_set_opacity(widget, 1)
    }

    private static func current(of widget: UnsafeMutablePointer<GtkWidget>) -> ActivityPulse? {
        guard let raw = g_object_get_data(ptr(widget), Self.key) else { return nil }
        return Unmanaged<ActivityPulse>.fromOpaque(raw).takeUnretainedValue()
    }

    private static func clear(_ widget: UnsafeMutablePointer<GtkWidget>) {
        g_object_set_data_full(ptr(widget), Self.key, nil, nil)
    }

    private func start() {
        guard tick == 0 else { return }
        step()
        let box = Unmanaged.passUnretained(self).toOpaque()
        tick = UInt(
            tailscode_add_tick(
                widget,
                { raw in
                    guard let raw else { return }
                    Unmanaged<ActivityPulse>.fromOpaque(raw).takeUnretainedValue().step()
                }, box))
    }

    private func stop() {
        guard tick != 0 else { return }
        tailscode_remove_tick(widget, guint(tick))
        tick = 0
        gtk_widget_set_opacity(widget, 1)
    }

    /// One frame: light, and — for a state that sweeps — the frame of the ring. Both are written
    /// only when they actually changed, so a breathing badge costs one property set per frame and
    /// a sweeping one costs four text writes a second.
    private func step() {
        let time = Self.now
        guard time - lastStepped >= Self.frameInterval else { return }
        lastStepped = time
        let opacity = motion.intensity(at: time)
        if abs(opacity - lastOpacity) > 0.004 {
            lastOpacity = opacity
            gtk_widget_set_opacity(widget, opacity)
        }
        guard let frame = motion.frame(at: time, of: icon.cycle), frame != lastFrame else { return }
        lastFrame = frame
        guard let text, let write else {
            gtk_label_set_text(op(widget), frame)
            return
        }
        write(frame + text.dropFirst())
    }
}

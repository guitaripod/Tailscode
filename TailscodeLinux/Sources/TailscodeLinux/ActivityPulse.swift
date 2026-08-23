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
/// The swell is laid through ``RepeatingMotion``, which is where the desk is asked, and every mark
/// with a motion to it watches the same preference — a mark stands for as long as the state it
/// names, and a turn is minutes, so a reader who changes their mind inside that window has to be
/// answered rather than remembered.
///
/// The state lives on the widget (`g_object_set_data_full`), so a row torn down mid-swell releases
/// it without anyone remembering to — the sidebar rebuilds hundreds of rows a session and a
/// registry someone has to keep swept is a leak with extra steps.
final class ActivityPulse: @unchecked Sendable {
    private static let key = "tailscode-activity-pulse"

    private let widget: UnsafeMutablePointer<GtkWidget>
    private let icon: ActivityIcon
    private var motion: ActivityMotion = .still
    private var text: String?
    private let write: ((String) -> Void)?
    private var lastOpacity = -1.0
    private var lastFrame = ""
    private var lastStepped = 0.0
    private var startedAt = 0.0
    private var offered = 0
    private var drawn = 0
    /// The lap holds no reference on the widget: this object is released by that widget's own data,
    /// so a reference the other way round is a row nothing can ever finalize.
    private lazy var lap = RepeatingMotion(holding: false) { [weak self] in self?.step() }

    private init(
        widget: UnsafeMutablePointer<GtkWidget>, icon: ActivityIcon, text: String?,
        write: ((String) -> Void)?
    ) {
        self.widget = widget
        self.icon = icon
        self.text = text
        self.write = write
    }

    private static var now: Double { Double(g_get_monotonic_time()) / 1_000_000 }

    /// Points a widget at a state, or lets go of it. A widget already moving to the same state is
    /// left exactly as it is — re-attaching every render would restart the swell on every keystroke
    /// and the list would flicker instead of breathe.
    ///
    /// A state the vocabulary calls still keeps nothing: it cannot start moving whatever the desk
    /// says, so it needs no clock, no watcher and no object on the widget.
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
        if let existing, existing.icon == icon {
            existing.text = text
            return
        }
        existing?.stop()
        clear(widget)
        guard icon.motion.isAnimated else {
            gtk_widget_set_opacity(widget, 1)
            return
        }
        let pulse = ActivityPulse(widget: widget, icon: icon, text: text, write: write)
        let box = Unmanaged.passRetained(pulse).toOpaque()
        g_object_set_data_full(
            ptr(widget), Self.key, box,
            { raw in
                guard let raw else { return }
                Unmanaged<ActivityPulse>.fromOpaque(raw).release()
            })
        RepeatingMotion.watch(widget) { [weak pulse] in pulse?.relay() }
        pulse.relay()
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

    /// What this mark is actually doing, for a harness that has to prove a claim about it rather
    /// than look at it: whether it is moving at all, how many ticks the panel offered, how many of
    /// them the tempo took, and the rate that really came out. A screenshot cannot tell thirty
    /// frames a second from twenty, and the two numbers have to be read side by side — a mark
    /// drawing twenty on a panel offering twenty is keeping every frame it was given, while one
    /// drawing twenty on a panel offering sixty is the boundary bug this gate exists to answer.
    static func reading(of widget: UnsafeMutablePointer<GtkWidget>) -> String {
        guard let pulse = current(of: widget), pulse.lap.isTurning else { return "moving=0" }
        let seconds = max(Self.now - pulse.startedAt, 0.001)
        return "moving=1 offered=\(pulse.offered) frames=\(pulse.drawn)"
            + " panel=" + String(format: "%.1f", Double(pulse.offered) / seconds)
            + " fps=" + String(format: "%.1f", Double(pulse.drawn) / seconds)
    }

    /// Takes the moving-or-still decision again, from scratch, and does whichever it decided.
    ///
    /// The desk is asked here rather than where the mark was attached, because a mark stands for as
    /// long as the state it names: a turn is minutes and a workflow can be an hour, so a reader who
    /// changes their mind inside that window would otherwise be answered by whatever the desk said
    /// when the row first appeared. The lap's own answer is the only one taken — asking twice in
    /// two places is how two marks in one window end up disagreeing.
    private func relay() {
        let moving = lap.lay(on: widget, meaning: icon.motion)
        motion = moving ? icon.motion : .still
        lastOpacity = -1
        lastFrame = ""
        guard moving else {
            settle()
            return
        }
        startedAt = Self.now
        lastStepped = 0
        offered = 0
        drawn = 0
        step()
    }

    private func stop() {
        lap.lift()
        gtk_widget_set_opacity(widget, 1)
    }

    /// What a mark that is not moving shows: full light and the state's own glyph, written back by
    /// hand. A sweep stopped mid-lap would otherwise keep whichever of its four frames it happened
    /// to be on, which is a moving record of a state that has stopped moving — and reduced motion
    /// drops the movement and nothing else, so the glyph the vocabulary gave the state is exactly
    /// what is left.
    private func settle() {
        gtk_widget_set_opacity(widget, 1)
        guard let text, let write else {
            guard tailscode_is_label(widget) != 0 else { return }
            gtk_label_set_text(op(widget), icon.glyph)
            return
        }
        write(icon.glyph + text.dropFirst())
    }

    /// One frame: light, and — for a state that sweeps — the frame of the ring. Both are written
    /// only when they actually changed, so a breathing badge costs one property set per frame and
    /// a sweeping one costs four text writes a second.
    ///
    /// A swell measured in seconds needs no more than the vocabulary's tempo of it a second, and
    /// the panel's clock is the only one on offer — so which of its ticks the tempo owes is
    /// ``ActivityTuning/wantsFrame(at:lastDrawn:)``'s to answer, never a bare comparison here: on a
    /// 60Hz or 120Hz desk one frame of the tempo lands exactly on a tick boundary, where a clock
    /// quantised to microseconds measures the tick short and the mark falls to two thirds of the
    /// rate it was owed. The arithmetic reads absolute time, so a skipped frame skips nothing.
    private func step() {
        let time = Self.now
        offered += 1
        guard ActivityTuning.wantsFrame(at: time, lastDrawn: lastStepped) else { return }
        lastStepped = time
        drawn += 1
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

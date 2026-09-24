import CAdw
import CGtkShim
import TailscodeCore

/// The one road a never-ending lap takes in this client, and the only place the desk is asked
/// whether it wants one.
///
/// A motion that never ends on its own is up for exactly as long as the thing it stands for — a
/// step with no progress to report, a power that is switched on, a scan still out on the tailnet —
/// which makes it the moving thing a reader ends up watching longest, and so the last place
/// movement may go on running under a setting that asks for none. A guard read where the clock is
/// installed cannot answer that question, because the question stays open for as long as the lap
/// does: a desk that asks for less motion halfway through a conversation keeps the ring it just
/// switched off, and one that allows movement back is never given it. So the decision is one call,
/// taken every time a lap is laid and again whenever ``watch(_:_:)`` says the answer may have
/// changed — every surface that lays one pairs the two, and the pairing is what makes the answer
/// current rather than remembered.
///
/// What the movement means is the vocabulary's to say rather than this client's: `meaning` is the
/// `ActivityMotion` the lap stands for, and `honoring(reduceMotion:)` is where reduced motion is
/// already decided for every mark in the window, so nothing here can end up disagreeing with the
/// badge in the row beside it. Reduced motion drops the movement and nothing else: what the lap was
/// drawing stays exactly where it is, fully lit, still saying what it was saying.
final class RepeatingMotion {
    private let step: () -> Void
    private let holding: Bool
    private var widget: UnsafeMutablePointer<GtkWidget>?
    private var tick: UInt = 0
    /// What the frame clock holds in place of the lap: a clock outlives whatever let go of it, so
    /// it must never hold the lap itself. A lap released while it turns leaves the link empty, and
    /// the clock's next frame takes the clock off instead of calling into freed memory. The clock
    /// owns the link and lets it go when it ends, which is how an empty `link` here says the clock
    /// is gone — lifted, ended, or torn down with a widget that no longer exists to be asked.
    private weak var link: Link?

    private final class Link {
        weak var motion: RepeatingMotion?
        init(_ motion: RepeatingMotion) { self.motion = motion }
    }

    /// - Parameter holding: whether the lap keeps a reference on the widget it runs on. A surface
    ///   that owns its own drawing area does, because a pane can be torn down between frames and
    ///   removing a callback from a freed widget is a crash rather than a dropped frame. A mark
    ///   that lives *on* its widget does not: it is released by that widget's own data, so a
    ///   reference held back the other way is a row nothing can ever finalize.
    init(holding: Bool = true, _ step: @escaping () -> Void) {
        self.holding = holding
        self.step = step
    }

    /// Whether the desk wants motion at all — GTK's `gtk-enable-animations`, which is what every
    /// desktop's "reduce animation" switch actually writes. One reading for the whole client, so a
    /// badge, an aura and a dial in the same window can never answer it differently.
    static var allowed: Bool { tailscode_animations_enabled() != 0 }

    /// Whether a lap is turning right now, for a harness that has to prove a claim about it rather
    /// than watch it — a still frame and a moving one are the same picture in any screenshot.
    var isTurning: Bool { tick != 0 && link != nil }

    /// Lays the lap on the widget's own frame clock, or leaves the widget perfectly still because
    /// the desk asked for that, and says which it did.
    ///
    /// The previous lap always comes off first, so a surface handed the motion twice — a pane
    /// returning to a window, a desk changing its mind mid-wait — ends up with one clock rather
    /// than a second stacked on the first.
    @discardableResult
    func lay(
        on widget: UnsafeMutablePointer<GtkWidget>, meaning: ActivityMotion = .working
    ) -> Bool {
        lift()
        guard meaning.honoring(reduceMotion: !Self.allowed).isAnimated else { return false }
        _ = Gtk.releaseInstalled
        if holding { g_object_ref(UnsafeMutableRawPointer(widget)) }
        self.widget = widget
        let link = Link(self)
        self.link = link
        tick = UInt(
            tailscode_add_owned_tick(
                widget,
                { raw in
                    guard let raw,
                        let motion = Unmanaged<Link>.fromOpaque(raw).takeUnretainedValue().motion
                    else { return 0 }
                    motion.step()
                    return 1
                }, Unmanaged.passRetained(link).toOpaque()))
        return true
    }

    /// Takes the lap off the widget it was laid on, which is not always the widget a surface would
    /// name today — a pane re-parents, and the callback belongs to whatever held the clock. A clock
    /// that has already gone is not asked for again: a mark's widget can be torn down under it, and
    /// reaching into a widget that no longer exists is a crash rather than a tidy-up.
    func lift() {
        guard let widget else { return }
        if tick != 0, link != nil { tailscode_remove_tick(widget, guint(tick)) }
        tick = 0
        link = nil
        self.widget = nil
        if holding { g_object_unref(UnsafeMutableRawPointer(widget)) }
    }

    /// Calls `handler` whenever the desk changes its mind about movement, for as long as `widget`
    /// is alive. This is the other half of the road: `lay` makes the decision current at the moment
    /// it is asked, and this is what asks again.
    static func watch(
        _ widget: UnsafeMutablePointer<GtkWidget>, _ handler: @escaping @Sendable () -> Void
    ) {
        _ = Gtk.releaseInstalled
        let box = Unmanaged.passRetained(Gtk.Box(handler)).toOpaque()
        tailscode_watch_animations(
            widget,
            { raw in
                guard let raw else { return }
                Unmanaged<Gtk.Box>.fromOpaque(raw).takeUnretainedValue().work()
            }, box)
    }

    /// A lap let go of takes its clock with it, whichever way it was laid. One that lives on its
    /// widget is usually outlived by nothing — that widget's own teardown ends every clock on it,
    /// and `lift` then finds nothing left to ask for — but a surface that replaces its lap while
    /// the widget stays up is the other case, and a clock left behind there would keep asking the
    /// compositor for frames on the lap's behalf.
    deinit {
        lift()
    }
}

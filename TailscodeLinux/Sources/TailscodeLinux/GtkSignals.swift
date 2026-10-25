import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension Gtk {
    /// Connects a signal to a Swift closure, which lives exactly as long as the connection does.
    static func connect(_ instance: UnsafeMutableRawPointer, _ signal: String, _ handler: @escaping @Sendable () -> Void) {
        _ = releaseInstalled
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = {
            _, raw in
            guard let raw else { return }
            Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue().work()
        }
        tailscode_connect(
            instance, signal, unsafeBitCast(callback, to: GCallback.self), box)
    }

    /// A signal GTK asks a question of rather than merely announces — `close-request` being the
    /// one that matters here. The handler answers "carry on", so watching a window close never
    /// changes whether it closes; a void closure would leave the answer to whatever happened to
    /// be in the return register.
    static func observe(
        _ instance: UnsafeMutableRawPointer, _ signal: String,
        _ handler: @escaping @Sendable () -> Void
    ) {
        _ = releaseInstalled
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        let callback:
            @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> gboolean = {
                _, raw in
                guard let raw else { return 0 }
                Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue().work()
                return 0
            }
        tailscode_connect(
            instance, signal, unsafeBitCast(callback, to: GCallback.self), box)
    }

    /// A plain click (release with nothing selected) on any widget. The shim owns the gesture;
    /// the box leaks by design, like every other signal closure here — rows live as long as the
    /// transcript does.
    static func onRelease(
        _ widget: UnsafeMutablePointer<GtkWidget>, _ handler: @escaping @Sendable () -> Void
    ) {
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
            guard let raw else { return }
            Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue().work()
        }
        tailscode_on_release(widget, unsafeBitCast(callback, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self), box)
    }

    /// A click that is this widget's alone: the press is claimed in the capture phase, so a button
    /// the widget sits inside never hears it and a chip in a row does not also open the row.
    static func onClaimedClick(
        _ widget: UnsafeMutablePointer<GtkWidget>, _ handler: @escaping @Sendable () -> Void
    ) {
        _ = releaseInstalled
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
            guard let raw else { return }
            Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue().work()
        }
        tailscode_on_claimed_click(widget, unsafeBitCast(callback, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self), box)
    }

    /// A plain click of the primary button only. A right press on the same widget is somebody
    /// else's — a context menu — and must not also count as the click that opens something.
    static func onPrimaryRelease(
        _ widget: UnsafeMutablePointer<GtkWidget>, _ handler: @escaping @Sendable () -> Void
    ) {
        _ = releaseInstalled
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
            guard let raw else { return }
            Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue().work()
        }
        tailscode_on_primary_release(widget, unsafeBitCast(callback, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self), box)
    }

    /// Any button pressed anywhere inside `widget`, children included, with where it landed —
    /// before the widget under the pointer acts on it. The event itself is untouched, which is how
    /// a window learns what was pressed without taking the press away from it.
    static func onPressCapture(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ handler: @escaping @Sendable (Double, Double) -> Void
    ) {
        let box = Unmanaged.passRetained(PointBox(handler)).toOpaque()
        let callback: @convention(c) (Double, Double, UnsafeMutableRawPointer?) -> Void = {
            x, y, raw in
            guard let raw else { return }
            Unmanaged<PointBox>.fromOpaque(raw).takeUnretainedValue().handler(x, y)
        }
        tailscode_on_press_capture(widget, callback, box)
    }

    /// Whether a pointer button is held anywhere inside `widget`. Watched from the capture phase
    /// and never claimed, so the press keeps its ordinary meaning.
    static func onPressHold(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        down: @escaping @Sendable () -> Void,
        up: @escaping @Sendable () -> Void
    ) {
        let box = Unmanaged.passRetained(HoldBox(down: down, up: up)).toOpaque()
        let downCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
            guard let raw else { return }
            Unmanaged<HoldBox>.fromOpaque(raw).takeUnretainedValue().down()
        }
        let upCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
            guard let raw else { return }
            Unmanaged<HoldBox>.fromOpaque(raw).takeUnretainedValue().up()
        }
        tailscode_on_press_hold(widget, downCallback, upCallback, box)
    }

    /// Where the pointer is inside `widget` — every move, and its leaving — watched once for
    /// everything beneath it and never claimed, so a list of rows costs one controller rather
    /// than one per row.
    static func onPointer(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        move: @escaping @Sendable (Double, Double) -> Void,
        leave: @escaping @Sendable () -> Void
    ) {
        let box = Unmanaged.passRetained(PointerBox(move: move, leave: leave)).toOpaque()
        let moveCallback: @convention(c) (Double, Double, UnsafeMutableRawPointer?) -> Void = {
            x, y, raw in
            guard let raw else { return }
            Unmanaged<PointerBox>.fromOpaque(raw).takeUnretainedValue().move(x, y)
        }
        let leaveCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
            guard let raw else { return }
            Unmanaged<PointerBox>.fromOpaque(raw).takeUnretainedValue().leave()
        }
        tailscode_on_pointer(widget, moveCallback, leaveCallback, box)
    }

    final class PointerBox: @unchecked Sendable {
        let move: @Sendable (Double, Double) -> Void
        let leave: @Sendable () -> Void
        init(
            move: @escaping @Sendable (Double, Double) -> Void,
            leave: @escaping @Sendable () -> Void
        ) {
            self.move = move
            self.leave = leave
        }
    }

    /// A double click on a paned's handle — the divider itself, never its children. Single
    /// clicks and drags pass through untouched, so the handle keeps its ordinary meaning.
    static func onPanedHandleDoubleClick(
        _ paned: UnsafeMutablePointer<GtkWidget>, _ handler: @escaping @Sendable () -> Void
    ) {
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
            guard let raw else { return }
            Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue().work()
        }
        tailscode_on_paned_handle_double_click(paned, callback, box)
    }

    /// What a key pressed on a focused divider asks for, in Core's words.
    static func dividerKey(_ key: Int32, large: Bool) -> DividerKey? {
        switch key {
        case 0: return .back(large: large)
        case 1: return .forward(large: large)
        case 2: return .lowest
        case 3: return .highest
        default: return nil
        }
    }

    final class DividerKeyBox: @unchecked Sendable {
        let handler: @Sendable (DividerKey) -> Bool

        init(_ handler: @escaping @Sendable (DividerKey) -> Bool) {
            self.handler = handler
        }
    }

    /// A focused divider answers the arrow keys, Home and End, and says whether it used the key.
    static func onDividerKey(
        _ paned: UnsafeMutablePointer<GtkWidget>,
        _ handler: @escaping @Sendable (DividerKey) -> Bool
    ) {
        _ = releaseInstalled
        let box = Unmanaged.passRetained(DividerKeyBox(handler)).toOpaque()
        let callback: @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> gboolean = {
            key, large, raw in
            guard let raw, let divider = Gtk.dividerKey(key, large: large != 0) else { return 0 }
            let box = Unmanaged<DividerKeyBox>.fromOpaque(raw).takeUnretainedValue()
            return box.handler(divider) ? 1 : 0
        }
        tailscode_paned_handle_keys(paned, callback, box)
    }

    /// Whether `keyval` is a key a focused divider answers — an arrow, Home or End with no
    /// control, alt or super — while focus sits on one, so the window's own keys, which would hand
    /// it to whatever pane is active, step aside.
    static func dividerOwnsKey(
        _ keyval: UInt32, state: UInt32, in window: UnsafeMutablePointer<GtkWidget>
    ) -> Bool {
        let keys: Set<UInt32> = [
            Keymap.up, Keymap.down, 0xFF51, 0xFF53, 0xFF50, 0xFF57,
        ]
        guard keys.contains(keyval), state & (KeyChord.controlMask | KeyChord.altMask) == 0
        else { return false }
        return tailscode_focus_on_divider(window) != 0
    }

    /// The divider introduces itself: the two panes it divides, and where it stands.
    static func describeDivider(
        _ paned: UnsafeMutablePointer<GtkWidget>, label: String, minimum: Double, maximum: Double,
        now: Double, text: String
    ) {
        tailscode_paned_describe(paned, label, minimum, maximum, now, text)
    }

    static func focusDivider(_ paned: UnsafeMutablePointer<GtkWidget>) -> Bool {
        tailscode_paned_focus_handle(paned) != 0
    }

    /// What the toolkit's accessibility layer holds for a divider, against what was meant.
    static func dividerReading(
        _ paned: UnsafeMutablePointer<GtkWidget>, label: String, minimum: Double, maximum: Double,
        now: Double
    ) -> String {
        guard let raw = tailscode_paned_reading(paned, label, minimum, maximum, now) else {
            return "-"
        }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    /// A right click (or long-press equivalent the desktop maps to it) on any widget, with where
    /// it landed, so a context menu can open under the pointer rather than at a corner.
    static func onRightClick(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ handler: @escaping @Sendable (Double, Double) -> Void
    ) {
        let box = Unmanaged.passRetained(PointBox(handler)).toOpaque()
        let callback: @convention(c) (Double, Double, UnsafeMutableRawPointer?) -> Void = {
            x, y, raw in
            guard let raw else { return }
            Unmanaged<PointBox>.fromOpaque(raw).takeUnretainedValue().handler(x, y)
        }
        tailscode_on_right_click(widget, callback, box)
    }

    /// The row-menu right click for a widget whose own child is selectable text: claimed on the
    /// way down, before a `GtkLabel`'s own copy-menu gesture ever sees the press and keeps this
    /// one from arriving at all.
    static func onRightClickCapture(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ handler: @escaping @Sendable (Double, Double) -> Void
    ) {
        let box = Unmanaged.passRetained(PointBox(handler)).toOpaque()
        let callback: @convention(c) (Double, Double, UnsafeMutableRawPointer?) -> Void = {
            x, y, raw in
            guard let raw else { return }
            Unmanaged<PointBox>.fromOpaque(raw).takeUnretainedValue().handler(x, y)
        }
        tailscode_on_right_click_capture(widget, callback, box)
    }

    final class PointBox: @unchecked Sendable {
        let handler: @Sendable (Double, Double) -> Void
        init(_ handler: @escaping @Sendable (Double, Double) -> Void) { self.handler = handler }
    }

    final class HoldBox: @unchecked Sendable {
        let down: @Sendable () -> Void
        let up: @Sendable () -> Void
        init(down: @escaping @Sendable () -> Void, up: @escaping @Sendable () -> Void) {
            self.down = down
            self.up = up
        }
    }

    /// A `Duration` as the millisecond count ``after(_:_:)`` wants.
    static func milliseconds(_ duration: Duration) -> UInt32 {
        let components = duration.components
        let whole = components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
        return UInt32(clamping: whole)
    }

    final class AreaBox: @unchecked Sendable {
        let handler: @Sendable (Int32, Int32) -> Void
        init(_ handler: @escaping @Sendable (Int32, Int32) -> Void) { self.handler = handler }
    }

    /// A drawing area's own size, every time it changes. `GtkDrawingArea` is the one widget that
    /// announces its allocation, so a row that has to place things by hand for its width puts an
    /// area of no height at its top and hears the row's width from it — never from a guess made
    /// when the row was built, which is the width the pane had at the time.
    static func onAreaResize(
        _ area: UnsafeMutablePointer<GtkWidget>, _ handler: @escaping @Sendable (Int32, Int32) -> Void
    ) {
        _ = releaseInstalled
        let box = Unmanaged.passRetained(AreaBox(handler)).toOpaque()
        let callback:
            @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, UnsafeMutableRawPointer?) -> Void =
            { _, width, height, raw in
                guard let raw else { return }
                Unmanaged<AreaBox>.fromOpaque(raw).takeUnretainedValue().handler(width, height)
            }
        tailscode_connect(
            UnsafeMutableRawPointer(area), "resize",
            unsafeBitCast(callback, to: GCallback.self), box)
    }

    /// The area an ``onAreaResize(_:_:)`` watches: it paints nothing and takes no pointer, and it
    /// is laid over the row so the space it measures is the space the row has.
    static func widthWatch() -> UnsafeMutablePointer<GtkWidget> {
        let area = gtk_drawing_area_new()!
        gtk_widget_set_can_target(area, 0)
        gtk_widget_set_can_focus(area, 0)
        return area
    }

    /// Runs `work` on the GLib main context after a delay — the timed cousin of ``onMain(_:)``.
    static func after(_ milliseconds: UInt32, _ work: @escaping @Sendable () -> Void) {
        let box = Unmanaged.passRetained(Box(work)).toOpaque()
        tailscode_after(
            guint(milliseconds),
            { raw in
                guard let raw else { return }
                Unmanaged<Box>.fromOpaque(raw).takeRetainedValue().work()
            }, box)
    }

    /// Lets a wrapping label ask for the width of its own words rather than its ceiling. GTK hands
    /// a wrapping label its `max-width-chars` as its natural width, so a short name in a label
    /// allowed to wrap at forty characters reserved room for forty; held to the words' own length,
    /// with slack for letters wider than the average, it asks for one line and wraps only when
    /// the space is genuinely short.
    static func fitWrap(_ label: UnsafeMutablePointer<GtkWidget>, to text: String, ceiling: Int) {
        let chars = min(ceiling, text.count + text.count / 4 + 2)
        gtk_label_set_max_width_chars(op(label), Int32(chars))
    }

    /// A drawing area's `resize`, which carries the new width and height before the user data —
    /// the plain trampoline would read the width as its closure.
    static func onResize(
        _ area: UnsafeMutablePointer<GtkWidget>, _ handler: @escaping @Sendable () -> Void
    ) {
        _ = releaseInstalled
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        let callback:
            @convention(c) (UnsafeMutableRawPointer?, gint, gint, UnsafeMutableRawPointer?) -> Void = {
                _, _, _, raw in
                guard let raw else { return }
                Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue().work()
            }
        tailscode_connect(
            UnsafeMutableRawPointer(area), "resize", unsafeBitCast(callback, to: GCallback.self),
            box)
    }

    /// Watches a GObject property — `notify::` carries a GParamSpec the plain trampoline cannot
    /// marshal, so it goes through its own. The handler runs on the GLib main context.
    static func onNotify(
        _ instance: UnsafeMutableRawPointer, property: String,
        _ handler: @escaping @Sendable () -> Void
    ) {
        _ = releaseInstalled
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        tailscode_connect_notify(
            instance, property,
            { raw in
                guard let raw else { return }
                Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue().work()
            }, box)
    }

    /// Key presses on a widget, in the capture phase, so normal-mode letters never reach a text
    /// view that would otherwise swallow them.
    static func onKey(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ handler: @escaping @Sendable (UInt32, UInt32) -> Bool
    ) {
        _ = releaseInstalled
        let box = Unmanaged.passRetained(KeyBox(handler)).toOpaque()
        let callback: @convention(c) (guint, guint, UnsafeMutableRawPointer?) -> gboolean = {
            keyval, state, raw in
            guard let raw else { return 0 }
            let box = Unmanaged<KeyBox>.fromOpaque(raw).takeUnretainedValue()
            return box.handler(UInt32(keyval), UInt32(state)) ? 1 : 0
        }
        tailscode_connect_key(widget, callback, box)
    }

    /// Wheel notches on a widget: the sign of each notch, in the capture phase. Returning true
    /// keeps the notch from scrolling whatever the widget sits in.
    static func onScroll(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ handler: @escaping @Sendable (Double) -> Bool
    ) {
        _ = releaseInstalled
        let box = Unmanaged.passRetained(ScrollBox(handler)).toOpaque()
        let callback: @convention(c) (Double, UnsafeMutableRawPointer?) -> gboolean = {
            dy, raw in
            guard let raw else { return 0 }
            let box = Unmanaged<ScrollBox>.fromOpaque(raw).takeUnretainedValue()
            return box.handler(dy) ? 1 : 0
        }
        tailscode_connect_scroll(widget, callback, box)
    }

    final class ScrollBox: @unchecked Sendable {
        let handler: @Sendable (Double) -> Bool
        init(_ handler: @escaping @Sendable (Double) -> Bool) { self.handler = handler }
    }

    final class KeyBox: @unchecked Sendable {
        let handler: @Sendable (UInt32, UInt32) -> Bool
        init(_ handler: @escaping @Sendable (UInt32, UInt32) -> Bool) { self.handler = handler }
    }

    /// Whether what has focus right now takes text. Insert mode is implied by focus rather than
    /// declared, so clicking into the composer and typing behaves the way a pointer user expects.
    static func focusTakesText(_ widget: UnsafeMutablePointer<GtkWidget>) -> Bool {
        tailscode_focus_is_editable(widget) != 0
    }
}

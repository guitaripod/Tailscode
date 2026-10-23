import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The thin layer between Swift and GTK: signal connection, marshalling back onto the GLib main
/// context, and the casts every call needs. Everything above this file talks in Swift terms.
/// GTK's C types import as distinct pointer types, so every call up or down the widget hierarchy
/// needs a cast. One helper rather than a `unsafeBitCast` at each call site.
/// GTK declares most of its classes as incomplete C types, which Swift imports as
/// `OpaquePointer`, and a handful as complete structs, which it imports as typed pointers. Every
/// call up or down the hierarchy therefore needs one cast or the other.
@inline(__always)
func op(_ pointer: UnsafeMutableRawPointer) -> OpaquePointer {
    OpaquePointer(pointer)
}

@inline(__always)
func ptr<T>(_ pointer: UnsafeMutableRawPointer) -> UnsafeMutablePointer<T> {
    pointer.assumingMemoryBound(to: T.self)
}

enum Gtk {
    /// Whether the shift modifier is held, read from the widget's display's keyboard at signal
    /// time — a "clicked" handler receives no event, so the state is asked for rather than handed
    /// over. Range marks ride on this.
    static func shiftHeld(_ widget: UnsafeMutablePointer<GtkWidget>) -> Bool {
        tailscode_shift_held(widget)
    }

    /// Whether control is held, read the same way as ``shiftHeld``: a link row's "clicked" carries
    /// no event, and control-click copies where a plain click opens.
    static func ctrlHeld(_ widget: UnsafeMutablePointer<GtkWidget>) -> Bool {
        tailscode_ctrl_held(widget)
    }

    /// Runs `work` on the GLib main context. GTK is not thread-safe and the agent engine runs on
    /// cooperative threads, so every UI touch that starts in a `Task` comes back through here.
    static func onMain(_ work: @escaping @Sendable () -> Void) {
        let box = Unmanaged.passRetained(Box(work)).toOpaque()
        tailscode_on_main(
            { raw in
                guard let raw else { return }
                let box = Unmanaged<Box>.fromOpaque(raw).takeRetainedValue()
                box.work()
            }, box)
    }

    /// Runs `work` once after `widget`'s next frame has been laid out and painted, never before —
    /// for work done in hops that each must be drawn before the next is added.
    static func betweenFrames(
        of widget: UnsafeMutablePointer<GtkWidget>?, _ work: @escaping @Sendable () -> Void
    ) {
        let box = Unmanaged.passRetained(Box(work)).toOpaque()
        tailscode_between_frames(
            widget,
            { raw in
                guard let raw else { return }
                Unmanaged<Box>.fromOpaque(raw).takeRetainedValue().work()
            }, box)
    }

    final class Box: @unchecked Sendable {
        let work: @Sendable () -> Void
        init(_ work: @escaping @Sendable () -> Void) { self.work = work }
    }

    /// Tells the shim the process is ending: every posted, timed, between-frames, clock and drain
    /// callback it owns is dropped from here on without calling into Swift. Set on the paths that
    /// really end the process, never on a window closing while something else keeps the
    /// application alive.
    static func markQuitting() {
        tailscode_set_quitting(1)
    }

    /// Lifts the gate again, for a selftest that has to keep running after proving it.
    static func markNotQuitting() {
        tailscode_set_quitting(0)
    }

    /// Whether ``markQuitting()`` has been called.
    static var isQuitting: Bool {
        tailscode_is_quitting() != 0
    }

    /// A widget a long-lived property, timer or hop needs to find again without keeping it alive
    /// or trusting it to still exist. GObject clears the record when the widget is disposed, so
    /// `widget` is nil from then on rather than a pointer into freed memory.
    final class WeakWidget: @unchecked Sendable {
        private let lock = NSLock()
        private var raw: UnsafeMutablePointer<GtkWidget>?

        init(_ widget: UnsafeMutablePointer<GtkWidget>) {
            raw = widget
            g_object_weak_ref(
                UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GObject.self),
                Self.notify, Unmanaged.passUnretained(self).toOpaque())
        }

        /// One function for both `g_object_weak_ref` and `g_object_weak_unref`, which match a
        /// registration by the notify's address.
        private static let notify: GWeakNotify = { data, _ in
            guard let data else { return }
            Unmanaged<WeakWidget>.fromOpaque(data).takeUnretainedValue().cleared()
        }

        deinit {
            if let raw {
                g_object_weak_unref(
                    UnsafeMutableRawPointer(raw).assumingMemoryBound(to: GObject.self),
                    Self.notify, Unmanaged.passUnretained(self).toOpaque())
            }
        }

        /// The widget, or nil once it has been disposed.
        var widget: UnsafeMutablePointer<GtkWidget>? {
            lock.lock()
            defer { lock.unlock() }
            return raw
        }

        private func cleared() {
            lock.lock()
            raw = nil
            lock.unlock()
        }
    }

    /// How a connected closure is let go of: GObject hands it back when the handler is
    /// disconnected or the object it was on is finalized, and that is the one moment at which the
    /// handler can never run again. Installed once, before the first connection.
    ///
    /// The closures used to be kept for the life of the process, which is the right lifetime for a
    /// window's own controls and the wrong one for everything the app builds and rebuilds — a
    /// transcript row, a sidebar row, the rows a popover makes fresh on every open. Those are made
    /// in their thousands over a session and each one kept a closure nobody could ever call again.
    static let releaseInstalled: Bool = {
        tailscode_set_box_release { raw in
            guard let raw else { return }
            Unmanaged<AnyObject>.fromOpaque(raw).release()
        }
        return true
    }()

    /// The app's own style. Chrome is left to libadwaita; this only sets the transcript's rhythm
    /// and the two type registers the design calls for.
    static func installStyle() {
        let css = """
            .transcript { background-color: @view_bg_color; }
            .prompt-rule { background-color: @accent_bg_color; min-width: 2px; }
            .agent-text { font-size: 1.0rem; }
            .tool-line { font-family: monospace; font-size: 0.9rem; }
            .dim { opacity: 0.55; }
            .status-line { font-family: monospace; font-size: 0.85rem; opacity: 0.7; }
            .sidebar-title { font-weight: 600; }
            .sidebar-detail { font-size: 0.85rem; opacity: 0.6; }
            """
        let provider = gtk_css_provider_new()
        gtk_css_provider_load_from_string(provider, css)
        if let display = gdk_display_get_default() {
            gtk_style_context_add_provider_for_display(
                display, op(provider!),
                guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
        }
    }
}

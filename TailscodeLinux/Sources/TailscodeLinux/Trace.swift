import CGtkShim
import CAdw
import Foundation

/// `TAILSCODE_TRACE=1` prints millisecond-stamped marks for the paths worth watching — the same
/// stdout a `TAILSCODE_DRIVE` run records, so a headless timing session reads as one log.
enum Trace {
    static let enabled = ProcessInfo.processInfo.environment["TAILSCODE_TRACE"] != nil
    private static let epoch = ContinuousClock.now

    static func mark(_ label: @autoclosure () -> String) {
        guard enabled else { return }
        let elapsed = (ContinuousClock.now - epoch).components
        let ms = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
        FileHandle.standardOutput.write(Data("TRACE +\(ms)ms \(label())\n".utf8))
    }
}

extension Trace {
    /// A mark stamped with absolute `CLOCK_MONOTONIC` nanoseconds rather than with time since the
    /// first mark, which is the only form a launch can be measured in: the clock the shell reads
    /// before `exec` and the clock the process reads after it are the same clock, so the two
    /// subtract. `+ms` marks say what the process did to itself; this says when it happened.
    static func stamp(_ label: @autoclosure () -> String) {
        guard enabled else { return }
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC, &now)
        let ns = Int64(now.tv_sec) * 1_000_000_000 + Int64(now.tv_nsec)
        FileHandle.standardOutput.write(Data("TRACE @\(ns) \(label())\n".utf8))
    }

    /// Stamps `label` on the first frame the toolkit actually draws for `widget`, then takes the
    /// clock straight back off. A window is "up" when the compositor has been handed a frame with
    /// it in — `gtk_window_present` returns long before that, so a launch measured to the call
    /// reports a window nobody could yet type into.
    static func stampFirstFrame(
        of widget: UnsafeMutablePointer<GtkWidget>, _ label: @autoclosure () -> String
    ) {
        guard enabled else { return }
        let box = FirstFrame(widget: widget, label: label())
        box.id = UInt(
            tailscode_add_tick(
                widget,
                { raw in
                    guard let raw else { return }
                    Unmanaged<FirstFrame>.fromOpaque(raw).takeRetainedValue().fired()
                }, Unmanaged.passRetained(box).toOpaque()))
    }

    private final class FirstFrame {
        let widget: UnsafeMutablePointer<GtkWidget>
        let label: String
        var id: UInt = 0

        init(widget: UnsafeMutablePointer<GtkWidget>, label: String) {
            self.widget = widget
            self.label = label
        }

        func fired() {
            Trace.stamp(label)
            if id != 0 { tailscode_remove_tick(widget, guint(id)) }
        }
    }
}

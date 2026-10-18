import CGtkShim
import Foundation

/// What a chat switch costs, in the pane's own clock: milliseconds from the press to the first
/// rows, to the frame that drew them and to the last row of the backfill. Written only under
/// `TAILSCODE_TRACE`, so a change to the switch is measured rather than argued.
struct OpenTimer {
    private var begun: ContinuousClock.Instant?
    private var sawRows = false
    private var sawFill = false

    mutating func begin() {
        guard Trace.enabled else { return }
        begun = .now
        sawRows = false
        sawFill = false
    }

    mutating func rows(_ count: Int, drawnIn widget: UnsafeMutablePointer<GtkWidget>) {
        guard let begun, !sawRows, count > 0 else { return }
        sawRows = true
        Trace.mark("open+\(Self.milliseconds(since: begun))ms first rows \(count)")
        Trace.markAfterFrames(of: widget, 2) {
            "open+\(Self.milliseconds(since: begun))ms first frame"
        }
    }

    mutating func filled(_ count: Int) {
        guard let begun, sawRows, !sawFill else { return }
        sawFill = true
        Trace.mark("open+\(Self.milliseconds(since: begun))ms filled \(count)")
    }

    func note(_ what: String) {
        guard let begun else { return }
        Trace.mark("open+\(Self.milliseconds(since: begun))ms \(what)")
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = (ContinuousClock.now - start).components
        return Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }
}

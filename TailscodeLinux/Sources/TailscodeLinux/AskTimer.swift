import CGtkShim
import Foundation

/// What the quick ask costs, in microseconds: from the chord to the frame that shows the card, and
/// for the box to answer one edit. Written only under `TAILSCODE_TRACE`, so a change
/// to the quick ask is measured rather than argued.
enum AskTimer {
    nonisolated(unsafe) private static var begun: ContinuousClock.Instant?

    static func begin() {
        guard Trace.enabled else { return }
        begun = .now
        Trace.mark("ask+0us summoned")
    }

    static func note(_ what: @autoclosure () -> String) {
        guard let begun else { return }
        Trace.mark("ask+\(microseconds(since: begun))us \(what())")
    }

    /// Marks the frame after the one that drew the card, which is when the person can see it.
    static func shown(in widget: UnsafeMutablePointer<GtkWidget>) {
        guard let begun else { return }
        self.begun = nil
        Trace.markAfterFrames(of: widget, 2) { "ask+\(microseconds(since: begun))us shown" }
    }

    /// Runs the box's reactions to one edit, and says what they cost and when the frame showing
    /// them was over.
    static func edit(in widget: UnsafeMutablePointer<GtkWidget>, _ body: () -> Void) {
        guard Trace.enabled else {
            body()
            return
        }
        let start = ContinuousClock.now
        body()
        Trace.mark("ask edit handled \(microseconds(since: start))us")
        Trace.markAfterFrames(of: widget, 2) { "ask edit drawn \(microseconds(since: start))us" }
    }

    static func microseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = (ContinuousClock.now - start).components
        return Int(elapsed.seconds * 1_000_000 + elapsed.attoseconds / 1_000_000_000_000)
    }
}

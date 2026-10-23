import Foundation

enum RunLoopTurn {
    /// Runs `work` after the turn that asks has finished and the run loop has had its moment: the
    /// timer is set from a block queued behind everything this turn still has to do, so it cannot
    /// have fired by the time that work ends, and a slice of work that follows another is never
    /// glued to it the way two blocks on the main queue would be.
    static func next(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) {
                MainActor.assumeIsolated { work() }
            }
        }
    }
}

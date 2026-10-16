import Foundation

extension SetupDesk {
    /// Keeps one surface's checklist fresh for as long as `lifetime` lives: the desk is asked to
    /// watch the target (so it polls), the surface is handed the latest snapshot and then every
    /// change, and when the lifetime ends the watch is given back and the desk stops polling. The
    /// snapshots arrive on a cooperative thread; a toolkit hops to its own before drawing.
    public nonisolated func follow(
        _ target: SetupTarget, lifetime: PaneLifetime, deliver: @escaping @Sendable (SetupSnapshot) -> Void
    ) {
        let stream = changes()
        let desk = self
        let task = Task {
            await desk.watch(target)
            deliver(await desk.snapshot(for: target))
            for await change in stream where change.target == target { deliver(change.snapshot) }
            await desk.unwatch(target)
        }
        lifetime.add { task.cancel() }
    }
}

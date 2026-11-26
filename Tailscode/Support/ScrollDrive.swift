#if DEBUG
    import Foundation

    /// A scroll a harness is driving, in the shape the chat holds its own live updates for a
    /// finger. `ChatOpenBench` raises it while it moves its transcript, so a headless run measures
    /// the same still page a person's drag gets.
    @MainActor
    enum ScrollDrive {
        static var isDriving = false
    }
#endif

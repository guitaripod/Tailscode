import Foundation
import MidgarCore
import Synchronization
import UIKit

/// The app's ``UsageLockSuspensionGuard``: a UIKit background task, begun before the usage
/// providers lock is asked for and ended once it is let go, so a write that lands while the app is
/// heading into the background finishes before the app is suspended.
final class BackgroundTaskLockGuard: UsageLockSuspensionGuard {
    nonisolated(unsafe) private let application: UIApplication

    init(application: UIApplication) {
        self.application = application
    }

    func holdAwake(reason: String) -> (any UsageLockHold)? {
        let hold = BackgroundTaskHold { [self] identifier in
            application.endBackgroundTask(identifier)
        }
        let identifier = application.beginBackgroundTask(withName: reason) { hold.expire() }
        guard identifier != .invalid, hold.adopt(identifier) else { return nil }
        return hold
    }

    #if DEBUG
        /// `TAILSCODE_HOLD_USAGE_LOCK=<seconds>` holds the providers lock that long from launch, so
        /// a device test can send the app to the background mid-hold: under this guard the app
        /// stays up until the lock is let go. `<seconds>:unguarded` holds it the way the app did
        /// before the guard existed, which iOS answers with a 0xDEAD10CC kill.
        func holdProvidersLockIfAsked() {
            guard let spec = ProcessInfo.processInfo.environment["TAILSCODE_HOLD_USAGE_LOCK"]
            else { return }
            let parts = spec.split(separator: ":")
            guard let seconds = parts.first.flatMap({ Double($0) }) else { return }
            let unguarded = parts.dropFirst().first == "unguarded"
            let keeper: (any UsageLockSuspensionGuard)? = unguarded ? nil : self
            let lockFile = UsageWidgetStore.providersLockFile
            Thread.detachNewThread {
                UsageWidgetStore.withProvidersLock(lockFile: lockFile, keeper: keeper) {
                    MidgarLog.info(
                        "usage lock held for \(seconds)s (\(unguarded ? "unguarded" : "guarded"))",
                        category: .session)
                    Thread.sleep(forTimeInterval: seconds)
                }
                MidgarLog.info("usage lock released", category: .session)
            }
        }
    #endif
}

/// One background task as the providers lock sees it, ended exactly once. The system's expiration
/// ends it at once unless the flock is held, and then the release ends it the moment the flock is
/// let go, a few milliseconds later, so the app is never suspended holding the flock.
final class BackgroundTaskHold: UsageLockHold {
    private enum Phase {
        case starting
        case holding(UIBackgroundTaskIdentifier)
        case locked(UIBackgroundTaskIdentifier)
        case expiredWhileLocked(UIBackgroundTaskIdentifier)
        case ended
    }

    private let phase = Mutex<Phase>(.starting)
    private let endTask: @Sendable (UIBackgroundTaskIdentifier) -> Void

    init(endTask: @escaping @Sendable (UIBackgroundTaskIdentifier) -> Void) {
        self.endTask = endTask
    }

    /// Records the task the system began; false when its expiration came first, and the task is
    /// then ended at once.
    func adopt(_ identifier: UIBackgroundTaskIdentifier) -> Bool {
        let expiredFirst = phase.withLock { phase -> Bool in
            guard case .starting = phase else { return true }
            phase = .holding(identifier)
            return false
        }
        if expiredFirst { endTask(identifier) }
        return !expiredFirst
    }

    var isHolding: Bool {
        phase.withLock { phase in
            switch phase {
            case .holding, .locked: true
            case .starting, .expiredWhileLocked, .ended: false
            }
        }
    }

    func flockTaken() -> Bool {
        phase.withLock { phase in
            guard case .holding(let identifier) = phase else { return false }
            phase = .locked(identifier)
            return true
        }
    }

    /// The system's expiration handler.
    func expire() {
        let finished = phase.withLock { phase -> UIBackgroundTaskIdentifier? in
            switch phase {
            case .starting:
                phase = .ended
                return nil
            case .holding(let identifier):
                phase = .ended
                return identifier
            case .locked(let identifier):
                phase = .expiredWhileLocked(identifier)
                return nil
            case .expiredWhileLocked, .ended:
                return nil
            }
        }
        if let finished { endTask(finished) }
    }

    func release() {
        let finished = phase.withLock { phase -> UIBackgroundTaskIdentifier? in
            defer { phase = .ended }
            switch phase {
            case .holding(let identifier), .locked(let identifier),
                .expiredWhileLocked(let identifier):
                return identifier
            case .starting, .ended:
                return nil
            }
        }
        if let finished { endTask(finished) }
    }
}

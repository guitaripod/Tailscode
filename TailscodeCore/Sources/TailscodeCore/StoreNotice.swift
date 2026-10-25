import Foundation

/// How a store tells the clients it changed.
///
/// A store's setters run wherever the caller happens to be: a refresh task, a background session
/// callback, a detached read. An observer that is a method on a main-actor view controller is
/// called on the posting thread, and Swift 6 checks its isolation on entry and traps off the main
/// actor. So a store never posts from where it is: off the main thread the notice is handed to the
/// main queue first, and on it the post stays synchronous. Linux has no main queue to hand to
/// (`g_application_run` never drains it) and its clients do not observe, so it posts in place.
public enum StoreNotice {
    public static func post(_ name: Notification.Name, object: (AnyObject & Sendable)? = nil) {
        #if canImport(Darwin)
            guard !Thread.isMainThread else {
                NotificationCenter.default.post(name: name, object: object)
                return
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: name, object: object)
            }
        #else
            NotificationCenter.default.post(name: name, object: object)
        #endif
    }
}

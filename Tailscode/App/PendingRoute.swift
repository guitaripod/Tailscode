import TailscodeCore
import UIKit

/// Where a notification tap goes when there is nothing yet to send it to.
///
/// Tapping a notification for an app that is not running delivers the response to
/// `UNUserNotificationCenterDelegate` as soon as the delegate is set — which is inside
/// `didFinishLaunching`, before any scene has connected and long before the scene's coordinator
/// exists. Handing the URL to whatever scene happens to be listed at that moment either finds
/// nothing or finds a `SceneDelegate` still holding a nil coordinator, and the tap is lost: the
/// app opens on Home instead of the chat that pinged you, which is the whole reason it was tapped.
/// So a route that cannot be delivered is parked here, and the coordinator drains it once its
/// window is on screen. Stale by 30 seconds it is dropped rather than hijacking navigation long
/// after the tap.
@MainActor
enum PendingRoute {
    private static let horizon: TimeInterval = 30
    private static var parked: (url: URL, at: Date)?

    static func deliver(_ url: URL) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0.delegate as? SceneDelegate }.first
        if scene?.routeDeepLink(url) == true { return }
        AppLogger.lifecycle.info("route parked until the window exists: \(url.absoluteString)")
        parked = (url, Date())
    }

    static func take() -> URL? {
        guard let pending = parked else { return nil }
        parked = nil
        guard Date().timeIntervalSince(pending.at) < horizon else { return nil }
        return pending.url
    }
}

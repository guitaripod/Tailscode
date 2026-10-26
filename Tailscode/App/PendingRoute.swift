import MidgarCore
import TailscodeCore
import UIKit

/// Where a notification tap or a spoken question goes when there is nothing yet to send it to.
///
/// Tapping a notification for an app that is not running delivers the response to
/// `UNUserNotificationCenterDelegate` as soon as the delegate is set — which is inside
/// `didFinishLaunching`, before any scene has connected and long before the scene's coordinator
/// exists. Handing the URL to whatever scene happens to be listed at that moment either finds
/// nothing or finds a `SceneDelegate` still holding a nil coordinator, and the tap is lost: the
/// app opens on Home instead of the chat that pinged you, which is the whole reason it was tapped.
/// An App Intent that opens the app runs on the same cold launch with the same race. So a route
/// that cannot be delivered is parked here, and the coordinator drains it once its window is on
/// screen. Stale by 30 seconds it is dropped rather than hijacking navigation long after the tap.
@MainActor
enum PendingRoute {
    /// A question that was spoken is delivered in process rather than as a link, and words a
    /// `tailscode://ask?text=` link carries only ever reach the box unsent (`PromptLink`), because
    /// anything on the phone can open a `tailscode://` URL.
    enum Route {
        case link(URL)
        case question(String)
        case partySlot(Int)
    }

    private static let horizon: TimeInterval = 30
    private static var parked: (route: Route, at: Date)?

    private static func priority(_ state: UIScene.ActivationState) -> Int {
        switch state {
        case .foregroundActive: return 0
        case .foregroundInactive: return 1
        case .background: return 2
        default: return 3
        }
    }

    static func deliver(_ url: URL) { deliver(.link(url)) }

    static func deliver(question: String) { deliver(.question(question)) }

    static func deliver(partySlot number: Int) { deliver(.partySlot(number)) }

    private static func deliver(_ route: Route) {
        let scenes = UIApplication.shared.connectedScenes
            .sorted { priority($0.activationState) < priority($1.activationState) }
        let delegates = scenes.compactMap { $0.delegate as? SceneDelegate }
        for delegate in delegates where delegate.route(route) { return }
        MidgarLog.info("route parked until the window exists: \(described(route))", category: .lifecycle)
        parked = (route, Date())
    }

    static func take() -> Route? {
        guard let pending = parked else { return nil }
        parked = nil
        guard Date().timeIntervalSince(pending.at) < horizon else { return nil }
        return pending.route
    }

    /// A spoken question is the person's own words, so the log names only that one arrived.
    private static func described(_ route: Route) -> String {
        switch route {
        case .link(let url): return url.absoluteString
        case .question(let text): return "a spoken question of \(text.count) characters"
        case .partySlot(let number): return "party slot \(number)"
        }
    }
}

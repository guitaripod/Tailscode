import MidgarCore
import UIKit

/// The wall in a window of its own, for a Stage Manager desk or a monitor: a scene that connects with
/// this activity builds a wall as its root and nothing else, and its Done closes the scene.
@MainActor
enum WatchScene {
    static let activityType = "com.guitaripod.tailscode.watch"

    static func activity() -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType)
        activity.title = String(localized: "Watch")
        return activity
    }

    static func wants(_ options: UIScene.ConnectionOptions, session: UISceneSession) -> Bool {
        options.userActivities.contains { $0.activityType == activityType }
            || session.stateRestorationActivity?.activityType == activityType
    }

    static func openWindow() {
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity(), options: nil) { error in
            MidgarLog.error("agents wall window failed: \(error.localizedDescription)", category: .lifecycle)
        }
    }
}

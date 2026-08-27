import UIKit

/// Opening a chat in its own window is the iPad's version of a split: the request rides an
/// `NSUserActivity` carrying the same `tailscode://` URL every other entry point already
/// speaks, and the new scene's coordinator delivers it once its window exists.
@MainActor
enum SceneRouting {
    static let activityType = "com.guitaripod.tailscode.route"
    private static let urlKey = "url"

    static var supportsMultipleWindows: Bool {
        UIApplication.shared.supportsMultipleScenes
    }

    static func openInNewWindow(_ url: URL) {
        let activity = NSUserActivity(activityType: activityType)
        activity.userInfo = [urlKey: url.absoluteString]
        let request = UISceneSessionActivationRequest(userActivity: activity)
        UIApplication.shared.activateSceneSession(for: request) { error in
            AppLogger.lifecycle.error("new window refused: \(error.localizedDescription)")
        }
    }

    static func url(from activity: NSUserActivity) -> URL? {
        guard activity.activityType == activityType,
            let raw = activity.userInfo?[urlKey] as? String
        else { return nil }
        return URL(string: raw)
    }

    nonisolated static func sessionURL(_ sessionID: String) -> URL? {
        guard !sessionID.isEmpty else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: allowed) ?? sessionID
        return URL(string: "tailscode://session/\(encoded)")
    }
}

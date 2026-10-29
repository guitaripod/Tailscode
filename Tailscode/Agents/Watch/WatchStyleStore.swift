import Foundation
import TailscodeCore

/// Where the wall's style lives on this device: one JSON text in `UserDefaults`, never in iCloud,
/// so each screen keeps the wall the way it is watched. A change is posted for the walls that are
/// open, and they redraw underneath whoever is editing it.
@MainActor
enum WatchStyleStore {
    static let key = "agentsWatchStyle"
    static let didChange = Notification.Name("tailscode.agentsWatchStyle.didChange")

    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    static var current: WallStyle { WallStyle.decoded(defaults.string(forKey: key)) }

    static func save(_ style: WallStyle) {
        guard style != current else { return }
        defaults.set(style.encoded(), forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

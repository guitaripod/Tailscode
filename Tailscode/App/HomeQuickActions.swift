import TailscodeCore
import UIKit

/// The Home-screen long-press jump list. The static items live in the Info.plist
/// (`UIApplicationShortcutItems` in project.yml); this type names them for the
/// coordinator and owns the one dynamic item — Resume — which tracks the most
/// recent session, so the first press after picking up the phone goes straight
/// back into the conversation that was last touched.
enum HomeQuickActions {
    static let newChat = "com.guitaripod.tailscode.compose"
    static let saved = "com.guitaripod.tailscode.saved"
    static let usage = "com.guitaripod.tailscode.usage"
    static let addServer = "com.guitaripod.tailscode.connect"
    static let resume = "com.guitaripod.tailscode.resume"

    /// Keeps the dynamic Resume item pointed at the session list's most recent
    /// entry. The list is ordered by `updatedAt`, so `first` is the chat the
    /// user was last in. Clearing to an empty array leaves the static items in
    /// the menu — dynamic items only ever sit on top of them.
    static func refresh(entries: [SessionEntry]) {
        guard let latest = entries.first else {
            if UIApplication.shared.shortcutItems?.contains(where: { $0.type == resume }) == true {
                UIApplication.shared.shortcutItems = []
            }
            return
        }
        let item = UIApplicationShortcutItem(
            type: resume,
            localizedTitle: String(localized: "Resume"),
            localizedSubtitle: latest.session.title,
            icon: UIApplicationShortcutIcon(systemImageName: "arrow.uturn.backward.circle"),
            userInfo: ["sessionID": latest.session.id as NSString])
        UIApplication.shared.shortcutItems = [item]
    }
}

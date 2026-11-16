import Foundation

/// Which chats the app icon's number counts, kept where the app and its notification service can
/// both read it.
///
/// The number is chats, never notices: a chat that finished and then asked something is one thing
/// to go back to, and so is a turn this device noted and the bridge then pushed as well. The app
/// writes the chats it is showing as news whenever that changes; the service, which cannot see
/// them, adds the chat a push is about and badges the push with how many that makes, so a second
/// push about the same chat never counts it twice.
enum NoticeBadge {
    private static let chatsKey = "tailscode.notice.badge.chats"
    private static let retiredCountKey = "tailscode.notice.badge"

    private static var store: UserDefaults {
        UserDefaults(suiteName: NoticeSlots.groupSuite) ?? .standard
    }

    static func set(chats: Set<String>) {
        store.set(chats.sorted(), forKey: chatsKey)
        store.removeObject(forKey: retiredCountKey)
    }

    /// The count a push about `sessionID` should wear, with that chat now counted. Nil when the
    /// app has never said what it counts — before its first launch, or while a phone that has not
    /// been unlocked since it started keeps the shared container shut — and the icon is better
    /// left as it is than set from nothing.
    static func counting(sessionID: String) -> Int? {
        guard var chats = (store.array(forKey: chatsKey) as? [String]).map(Set.init) else {
            return nil
        }
        if chats.insert(sessionID).inserted { store.set(chats.sorted(), forKey: chatsKey) }
        return chats.count
    }
}

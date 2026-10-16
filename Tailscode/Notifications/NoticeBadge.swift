import Foundation

/// How many notices are waiting, kept where the app and its notification service can both read it.
///
/// The app sets it to what the Missed list holds whenever that changes; the service, which cannot
/// see the list, counts up from it when it badges a push, and the app's next look puts it right.
enum NoticeBadge {
    private static let key = "tailscode.notice.badge"

    private static var store: UserDefaults {
        UserDefaults(suiteName: NoticeSlots.groupSuite) ?? .standard
    }

    static var count: Int { store.integer(forKey: key) }

    static func set(_ count: Int) { store.set(max(0, count), forKey: key) }

    static func bumped() -> Int {
        let next = count + 1
        set(next)
        return next
    }
}

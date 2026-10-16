import UserNotifications

#if !NOTICE_EXTENSION
    import TailscodeCore
#endif

/// What the notification service does to a push, separate from the extension that hosts it so the
/// app can run the same thing over a payload and show the result.
enum NoticePushDresser {
    /// Writes the words, category, thread, face and badge a bridge's notice calls for. Returns the
    /// kind it dressed, or nil when the push carries no notice and keeps the bridge's own words.
    @discardableResult
    static func dress(_ content: UNMutableNotificationContent, identifier: String) -> NoticeWire.Kind? {
        guard let wire = NoticeWire(userInfo: content.userInfo) else { return nil }
        let sessionID = content.userInfo["sessionID"] as? String
        var category: String?
        if wire.kind == .question,
            let claim = NoticeCategories.claimSlot(
                identifier: identifier, reading: NoticeWords.reading(wire))
        {
            category = claim.category
            if let evicted = claim.evicted {
                UNUserNotificationCenter.current().removeDeliveredNotifications(
                    withIdentifiers: [evicted])
            }
        }
        NoticeContent.dress(content, as: wire, sessionID: sessionID, category: category)
        content.badge = NSNumber(value: NoticeBadge.bumped())
        return wire.kind
    }
}

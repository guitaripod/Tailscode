import UserNotifications

#if !NOTICE_EXTENSION
    import TailscodeCore
#endif

/// Dresses a notification for a notice: its words, where it files, how loudly it may interrupt,
/// how much it matters beside the others, and the face on it.
///
/// One function, used by the app for the notices it raises itself and by the notification service
/// for the ones a bridge pushes, so a turn ending reads the same whichever machine noticed it
/// first. Everything here is a property of the content; nothing talks to the network.
enum NoticeContent {
    /// - Parameters:
    ///   - title: the chat's name, or nil to keep the title the content already has.
    ///   - category: a category other than the kind's own, for a question whose options are
    ///     buttons.
    static func dress(
        _ content: UNMutableNotificationContent, as wire: NoticeWire, title: String? = nil,
        sessionID: String? = nil, profileID: String? = nil, category: String? = nil,
        withFace: Bool = true
    ) {
        let reading = NoticeWords.reading(wire)
        let presentation = NoticePresentation.of(wire.kind)
        if let title, !title.isEmpty { content.title = title }
        let rest = reading.rest.joined(separator: "\n")
        if rest.isEmpty {
            content.subtitle = ""
            content.body = reading.lead.isEmpty ? presentation.hiddenBody : reading.lead
        } else {
            content.subtitle = reading.lead
            content.body = rest
        }
        content.categoryIdentifier = category ?? presentation.category
        content.relevanceScore = presentation.relevance
        content.interruptionLevel = level(presentation.interruption)
        if content.sound == nil { content.sound = .default }
        var userInfo = content.userInfo
        if let sessionID, !sessionID.isEmpty {
            content.threadIdentifier = sessionID
            userInfo["sessionID"] = sessionID
        }
        if let profileID { userInfo["profileID"] = profileID }
        if let value = wire.userInfoValue() { userInfo[NoticeWire.key] = value }
        content.userInfo = userInfo
        if withFace, content.attachments.isEmpty,
            let face = NoticeFace.attachment(for: presentation)
        {
            content.attachments = [face]
        }
    }

    private static func level(_ interruption: NoticePresentation.Interruption)
        -> UNNotificationInterruptionLevel
    {
        switch interruption {
        case .passive: return .passive
        case .active: return .active
        case .timeSensitive: return .timeSensitive
        }
    }
}

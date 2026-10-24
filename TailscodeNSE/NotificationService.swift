import MidgarCore
import UserNotifications

/// Dresses a push the bridge sent, on the phone, in the phone's language.
///
/// A bridge writes the facts of a turn and the first of what it answered, in numbers and quotes;
/// the sentences around them, the face, the buttons the notice wears, how loudly it may interrupt
/// and the count on the app's icon are made here from the same code the app uses for the notices
/// it raises itself. A push the extension never gets to, or one it cannot read, is still the
/// bridge's own English alert, which is why that stays complete.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override init() {
        super.init()
        TailscodeLogging.configure()
    }

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent
        let applied = UsagePushPayload.apply(userInfo: request.content.userInfo)
        MidgarLog.info("nse: applied \(applied) usage snapshot(s)", category: .session)
        if let content = bestAttemptContent { dress(content, for: request) }
        contentHandler(bestAttemptContent ?? request.content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    private func dress(_ content: UNMutableNotificationContent, for request: UNNotificationRequest) {
        if let kind = NoticePushDresser.dress(content, identifier: request.identifier) {
            MidgarLog.info("nse: dressed a \(kind.rawValue) notice", category: .session)
        } else {
            MidgarLog.info(
                "nse: no notice in the push, leaving the bridge's own words", category: .session)
        }
    }
}

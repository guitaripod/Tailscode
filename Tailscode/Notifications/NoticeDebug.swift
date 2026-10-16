#if DEBUG
    import TailscodeCore
    import UIKit
    import UserNotifications

    /// Drivers for looking at notifications without a person at the phone, for a simulator that
    /// has nobody to tap Allow: `--notice-auth` asks for provisional authorization, which the
    /// system grants silently; `--notice-sample <name>` raises one of the Settings samples;
    /// `--notice-dump` writes everything Notification Center holds, as the app reads it, to
    /// `Documents/notice-dump.json`. Nothing here exists in a release build.
    @MainActor
    enum NoticeDebug {
        static func runIfRequested() {
            let arguments = CommandLine.arguments
            if arguments.contains("--notice-auth") {
                Task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(
                        options: [.alert, .sound, .badge, .provisional])
                }
            }
            if let flag = arguments.firstIndex(of: "--notice-sample"),
                arguments.indices.contains(flag + 1),
                let sample = NoticeSample(rawValue: arguments[flag + 1])
            {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    NotificationManager.sendTest(sample)
                }
            }
            if let flag = arguments.firstIndex(of: "--notice-push"),
                arguments.indices.contains(flag + 1)
            {
                let path = arguments[flag + 1]
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    deliverAsService(payloadPath: path)
                }
            }
            if arguments.contains("--notice-dump") {
                Task {
                    try? await Task.sleep(for: .seconds(8))
                    await dump()
                }
            }
        }

        /// A push payload run through the notification service's own code and raised as a local
        /// notification, for a simulator whose `simctl push` never reaches the extension.
        private static func deliverAsService(payloadPath: String) {
            guard let data = FileManager.default.contents(atPath: payloadPath),
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let aps = payload["aps"] as? [String: Any]
            else { return }
            let content = UNMutableNotificationContent()
            if let alert = aps["alert"] as? [String: Any] {
                content.title = alert["title"] as? String ?? ""
                content.body = alert["body"] as? String ?? ""
            }
            content.sound = .default
            var userInfo = payload
            userInfo["aps"] = nil
            content.userInfo = userInfo
            let identifier = "done:\(userInfo["sessionID"] as? String ?? UUID().uuidString)"
            NoticePushDresser.dress(content, identifier: identifier)
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }

        private static func dump() async {
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            let rows: [[String: Any]] = delivered.map { notice in
                let content = notice.request.content
                var row: [String: Any] = [
                    "identifier": notice.request.identifier,
                    "title": content.title, "subtitle": content.subtitle, "body": content.body,
                    "category": content.categoryIdentifier, "thread": content.threadIdentifier,
                    "relevance": content.relevanceScore,
                    "interruption": content.interruptionLevel.rawValue,
                    "attachments": content.attachments.map(\.identifier),
                ]
                if let badge = content.badge { row["badge"] = badge }
                if let wire = NoticeWire(userInfo: content.userInfo) { row["notice"] = wire.kind.rawValue }
                return row
            }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let categories = await UNUserNotificationCenter.current().notificationCategories()
            let report: [String: Any] = [
                "authorization": settings.authorizationStatus.rawValue,
                "delivered": rows,
                "categories": categories.map { category in
                    [
                        "id": category.identifier,
                        "actions": category.actions.map {
                            "\($0.identifier)|\($0.title)|\($0 is UNTextInputNotificationAction ? "text" : "button")"
                        },
                        "summaryFormat": category.categorySummaryFormat,
                        "hidden": category.hiddenPreviewsBodyPlaceholder,
                    ] as [String: Any]
                }.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") },
            ]
            guard let data = try? JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                let documents = FileManager.default.urls(
                    for: .documentDirectory, in: .userDomainMask
                ).first
            else { return }
            try? data.write(to: documents.appendingPathComponent("notice-dump.json"))
        }
    }
#endif

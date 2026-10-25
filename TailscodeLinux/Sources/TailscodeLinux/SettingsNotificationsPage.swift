import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// Notifications: what may raise one, and a way to prove the path works.
enum SettingsNotificationsPage {
    static func fill(_ page: UnsafeMutablePointer<GtkWidget>, _ context: SettingsContext) {
        let alerts = SettingsRows.group(
            Localized.text("Notifications"), on: page,
            description: Localized.text(
                "Raised only while the window is not focused, and withdrawn once a request is answered."))
        SettingsRows.add(
            SettingsRows.switchRow(
                title: Localized.text("A turn finishes"),
                subtitle: Localized.text("Any chat, not only the open one"),
                value: Notifier.notifyTurnComplete
            ) { value in
                Notifier.setNotifyTurnComplete(value)
            }, to: alerts)
        SettingsRows.add(
            SettingsRows.switchRow(
                title: Localized.text("An agent needs you"),
                subtitle: Localized.text("An approval to give or a question to answer"),
                value: Notifier.notifyNeedsYou
            ) { value in
                Notifier.setNotifyNeedsYou(value)
            }, to: alerts)
        SettingsRows.add(
            SettingsRows.switchRow(
                title: Localized.text("Running low"),
                subtitle: Localized.text(
                    "Tell me when a usage window is on course to run out before it resets. Account-wide windows only; once per window"),
                value: Notifier.notifyRunningLow
            ) { value in
                Notifier.setNotifyRunningLow(value)
            }, to: alerts)
        SettingsRows.add(
            SettingsRows.buttonRow(
                Localized.text("Prove the path"),
                subtitle: Localized.text("Sends one notification right now"),
                label: Localized.text("Test")
            ) {
                Notifier.shared.sendTest()
            }, to: alerts)
    }
}

import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// Notifications: what may raise one, and a way to prove the path works.
enum SettingsNotificationsPage {
    static func fill(_ page: UnsafeMutablePointer<GtkWidget>, _ context: SettingsContext) {
        let alerts = SettingsRows.group(
            Localized.text("Notifications"), on: page,
            description: NoticeRulesWords.groupDescription)
        let rules = Notifier.rules
        let finishes = NoticeRules.Finish.allCases
        SettingsRows.add(
            SettingsRows.comboRow(
                title: NoticeRulesWords.finishTitle, subtitle: NoticeRulesWords.finishSubtitle,
                options: finishes.map(NoticeRulesWords.title),
                selected: finishes.firstIndex(of: rules.finish) ?? 0
            ) { index in
                var next = Notifier.rules
                next.finish = finishes[index]
                Notifier.setRules(next)
            }, to: alerts)
        let minimums = NoticeRules.minimumChoices
        SettingsRows.add(
            SettingsRows.comboRow(
                title: NoticeRulesWords.minimumTitle, subtitle: NoticeRulesWords.minimumSubtitle,
                options: minimums.map(NoticeRulesWords.minimum),
                selected: minimums.firstIndex(of: rules.minimumWork) ?? 0
            ) { index in
                var next = Notifier.rules
                next.minimumWork = minimums[index]
                Notifier.setRules(next)
            }, to: alerts)
        SettingsRows.add(
            SettingsRows.switchRow(
                title: NoticeRulesWords.needsYouTitle, subtitle: NoticeRulesWords.needsYouSubtitle,
                value: rules.needsYou
            ) { value in
                Notifier.setNotifyNeedsYou(value)
            }, to: alerts)
        if !rules.muted.isEmpty {
            SettingsRows.add(
                SettingsRows.buttonRow(
                    NoticeRulesWords.mutedTitle,
                    subtitle: NoticeRulesWords.mutedCount(rules.muted.count),
                    label: NoticeRulesWords.unmuteAll
                ) {
                    var next = Notifier.rules
                    next.muted = []
                    Notifier.setRules(next)
                }, to: alerts)
        }
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

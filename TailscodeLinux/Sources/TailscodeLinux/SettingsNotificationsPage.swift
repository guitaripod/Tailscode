import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// Notifications, in the order every client asks: what is news, what this computer tells the
/// phone, which chats are muted, and a way to prove the path works. The first group's description
/// says what the choices add up to and follows them as they change.
enum SettingsNotificationsPage {
    static func fill(_ page: UnsafeMutablePointer<GtkWidget>, _ context: SettingsContext) {
        let rules = Notifier.rules
        let alerts = SettingsRows.group(
            Localized.text("Notifications"), on: page,
            description: NoticeRulesWords.summary(rules, desk: false))
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
        SettingsRows.add(
            SettingsRows.switchRow(
                title: Localized.text("Running low"),
                subtitle: Localized.text(
                    "Tell me when a usage window is on course to run out before it resets. Account-wide windows only; once per window"),
                value: Notifier.notifyRunningLow
            ) { value in
                Notifier.setNotifyRunningLow(value)
            }, to: alerts)

        let phone = SettingsRows.group(
            Localized.text("Your phone"), on: page, description: NoticeRulesWords.deskReportsSubtitle)
        let desk = SettingsRows.switchRow(
            title: NoticeRulesWords.deskReportsTitle,
            subtitle: DeskSense.isSilenced
                ? Localized.text("Off in a development build") : Localized.text("Starting…"),
            value: DeskSense.enabled
        ) { value in
            DeskSense.setEnabled(value)
        }
        adw_action_row_set_subtitle_lines(ptr(desk), 0)
        if DeskSense.isSilenced { gtk_widget_set_sensitive(desk, 0) }
        SettingsRows.add(desk, to: phone)

        let muted = SettingsRows.group(
            NoticeRulesWords.mutedTitle, on: page,
            description: NoticeRulesWords.mutedFooter)
        let list = gtk_list_box_new()!
        Gtk.addClass(list, "boxed-list")
        gtk_list_box_set_selection_mode(op(list), GTK_SELECTION_NONE)
        gtk_widget_set_margin_top(list, 6)
        SettingsRows.add(list, to: muted)

        let proof = SettingsRows.group(nil, on: page)
        SettingsRows.add(
            SettingsRows.buttonRow(
                Localized.text("Prove the path"),
                subtitle: Localized.text("Sends one notification right now"),
                label: Localized.text("Test")
            ) {
                Notifier.shared.sendTest()
            }, to: proof)

        let live = NotificationsPageLive(alerts: alerts, desk: desk, muted: list)
        SettingsRows.keep(live, alive: page)
        live.renderMuted()
        live.refreshDesk()
    }
}

/// What on the page follows the world while it is open: the summary and the muted list follow the
/// rules wherever they change (a chat's own menu, another page), and the desk's line follows its
/// reports.
final class NotificationsPageLive: @unchecked Sendable {
    private let alerts: Gtk.WeakWidget
    private let desk: Gtk.WeakWidget
    private let muted: Gtk.WeakWidget
    private var observers: [NSObjectProtocol] = []

    init(
        alerts: UnsafeMutablePointer<GtkWidget>, desk: UnsafeMutablePointer<GtkWidget>,
        muted: UnsafeMutablePointer<GtkWidget>
    ) {
        self.alerts = Gtk.WeakWidget(alerts)
        self.desk = Gtk.WeakWidget(desk)
        self.muted = Gtk.WeakWidget(muted)
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: NoticeRulesKeys.didChange, object: nil, queue: nil) {
                [weak self] _ in
                Gtk.onMain { [weak self] in
                    self?.renderMuted()
                }
            })
        observers.append(
            center.addObserver(forName: DeskBeat.didChange, object: nil, queue: nil) {
                [weak self] _ in
                self?.refreshDesk()
            })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func refreshDesk() {
        guard !DeskSense.isSilenced else { return }
        Task { [weak self] in
            let status = await DeskSense.status() ?? DeskBeat.Status(enabled: DeskSense.enabled)
            Gtk.onMain { [weak self] in
                guard let widget = self?.desk.widget else { return }
                adw_action_row_set_subtitle(ptr(widget), NoticeRulesWords.deskReportStatus(status))
            }
        }
    }

    func renderMuted() {
        let rules = Notifier.rules
        if let alerts = alerts.widget {
            adw_preferences_group_set_description(
                ptr(alerts), NoticeRulesWords.summary(rules, desk: false))
        }
        guard let list = muted.widget else { return }
        while let child = gtk_widget_get_first_child(list) {
            gtk_list_box_remove(op(list), child)
        }
        let chats = rules.mutedChats
        guard !chats.isEmpty else {
            let empty = adw_action_row_new()!
            adw_preferences_row_set_title(ptr(empty), Localized.text("No muted chats"))
            gtk_widget_add_css_class(empty, "dim-label")
            gtk_list_box_append(op(list), empty)
            return
        }
        for chat in chats {
            let id = chat.id
            gtk_list_box_append(
                op(list),
                SettingsRows.buttonRow(
                    chat.name ?? NoticeRulesWords.unnamedChat,
                    label: NoticeRulesWords.mutedRowAction
                ) {
                    Gtk.onMain { Notifier.unmute(id) }
                })
        }
        guard chats.count > 1 else { return }
        gtk_list_box_append(
            op(list),
            SettingsRows.buttonRow(
                NoticeRulesWords.mutedCount(chats.count), label: NoticeRulesWords.unmuteAll
            ) {
                Gtk.onMain {
                    var next = Notifier.rules
                    next.muted = []
                    next.mutedNames = [:]
                    Notifier.setRules(next)
                }
            })
    }
}

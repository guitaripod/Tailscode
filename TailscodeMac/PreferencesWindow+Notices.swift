import AppKit
import TailscodeCore

/// The parts of the Notifications page that follow the world while it is open: the summary and
/// the muted chats follow the rules wherever they change (a chat's own menu, another Mac window),
/// and the desk's line follows its reports.
extension PreferencesWindow {
    func renderNotices() {
        let rules = MacNotifier.rules
        noticeSummary.stringValue = NoticeRulesWords.summary(rules, desk: false)
        for view in mutedChats.arrangedSubviews {
            mutedChats.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let chats = rules.mutedChats
        guard !chats.isEmpty else {
            let empty = MacDialogs.detailLabel(Localized.text("No muted chats"), wraps: false)
            mutedChats.addArrangedSubview(empty)
            return
        }
        for chat in chats {
            let button = NSButton(
                title: NoticeRulesWords.mutedRowAction, target: self, action: #selector(unmuteChat))
            button.identifier = NSUserInterfaceItemIdentifier(chat.id)
            button.setAccessibilityLabel(
                "\(NoticeRulesWords.mutedRowAction) \(chat.name ?? NoticeRulesWords.unnamedChat)")
            mutedChats.addArrangedSubview(
                mutedRow(chat.name ?? NoticeRulesWords.unnamedChat, button: button))
        }
        guard chats.count > 1 else { return }
        let all = NSButton(
            title: NoticeRulesWords.unmuteAll, target: self, action: #selector(unmuteAllChats))
        mutedChats.addArrangedSubview(mutedRow(NoticeRulesWords.mutedCount(chats.count), button: all))
    }

    func renderDeskState() {
        Task { @MainActor [weak self] in
            let status =
                await MacDeskSense.status() ?? DeskBeat.Status(enabled: MacDeskSense.enabled)
            self?.deskState.stringValue =
                MacDeskSense.isStaged
                ? Localized.text("Off while the app is being checked")
                : NoticeRulesWords.deskReportStatus(status)
        }
    }

    private func mutedRow(_ title: String, button: NSButton) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Ramp.font(.panelLabel)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [label, filler, button])
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        return row
    }

    @objc func unmuteChat(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        MacNotifier.unmute(id)
    }

    @objc func deskReportsChanged(_ sender: NSButton) {
        MacDeskSense.setEnabled(sender.state == .on)
        renderDeskState()
    }
}

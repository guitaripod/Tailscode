import CodingAgentKitApple
import TailscodeCore
import UIKit

extension SettingsViewController {
    func permissionDetail() -> (String, UIColor) {
        switch notificationStatus {
        case .some(.authorized), .some(.provisional), .some(.ephemeral):
            return (String(localized: "Allowed"), Theme.Color.secondaryLabel)
        case .some(.denied):
            return (String(localized: "Turned off — tap to open iOS Settings"), Theme.Color.danger)
        case .some(.notDetermined):
            return (String(localized: "Not requested — tap to allow"), Theme.Color.warning)
        case .none:
            return (String(localized: "Checking…"), Theme.Color.secondaryLabel)
        default:
            return (String(localized: "Unknown"), Theme.Color.secondaryLabel)
        }
    }

    /// Whether this is a fact or a fault: on and available reads as plain status, denied or
    /// restricted is the one thing standing between a person and a wake this app cannot promise
    /// any other way, so it wears the warning tone and the tap that fixes it.
    func backgroundRefreshDetail() -> (String, UIColor, actionable: Bool) {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:
            return (String(localized: "On"), Theme.Color.secondaryLabel, false)
        case .denied, .restricted:
            return (String(localized: "Off — tap to open iOS Settings"), Theme.Color.warning, true)
        @unknown default:
            return (String(localized: "Unknown"), Theme.Color.secondaryLabel, false)
        }
    }

    func pushDetail(_ state: PushRegistrar.State) -> String {
        switch state {
        case .registered: return String(localized: "Registered")
        case .unsupported: return String(localized: "Bridge too old")
        case .notOffered: return String(localized: "Sends no pushes")
        case .failed: return String(localized: "Failed — tap to retry")
        case .unknown:
            if !AppPreferences.pushAlertsEnabled { return String(localized: "Turned off") }
            return PushRegistrar.hasToken
                ? String(localized: "Not registered — tap to retry")
                : String(localized: "Waiting for token")
        }
    }

    func healthDot(for id: String) -> UICellAccessory {
        let symbol: String
        let color: UIColor
        let label: String
        switch ServerHealthMonitor.entry(for: id)?.reachable {
        case .some(true):
            (symbol, color, label) = (
                "circle.fill", Theme.Color.success, String(localized: "Reachable")
            )
        case .some(false):
            (symbol, color, label) = (
                "exclamationmark.circle.fill", Theme.Color.danger, String(localized: "Unreachable")
            )
        case .none:
            (symbol, color, label) = (
                "circle.dotted", Theme.Color.separator, String(localized: "Checking")
            )
        }
        let dot = UIImageView(
            image: UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)))
        dot.tintColor = color
        dot.isAccessibilityElement = true
        dot.accessibilityLabel = label
        return .customView(configuration: .init(customView: dot, placement: .trailing()))
    }

    /// The same standing mark the Home chrome wears, per machine. Absent — rather than grey —
    /// when this server is not a reason for it: a dot that is always there is a dot nobody reads,
    /// and reachability already owns the slot beside it.
    func updateDot(for id: String) -> UICellAccessory? {
        let rollup = facts.updates
        let component = UpdateComponent.server(profileID: id)
        guard let reading = rollup.readings.first(where: { $0.component == component }),
            reading.stands(acknowledged: rollup.isAcknowledged(reading)) || reading.verdict.isBusy
        else { return nil }
        let badge = ActivityBadgeView(pointSize: 11)
        badge.show(reading.icon, spoken: UpdateCard(reading).headline)
        return .customView(configuration: .init(customView: badge, placement: .trailing()))
    }

    /// A toggle that changes what other rows mean repaints them: turning server
    /// pushes off makes every per-bridge row read "Turned off" immediately rather
    /// than after the next visit.
    func toggleDidChange(_ toggle: Toggle) {
        guard toggle == .serverPush else { return }
        applySnapshot()
    }

    /// The mark the writing hand wears while it is still being proven, carried on the row rather
    /// than only on the screen behind it, so a setting that is alpha says so where it is switched
    /// on from.
    func alphaMark() -> [UICellAccessory] {
        guard StreamRendererSetting.choice.isAlpha else { return [] }
        return [.customView(configuration: .init(customView: AlphaBadge(), placement: .trailing()))]
    }

    /// The two densities as a page of their own, each with the sentence that says what it means.
    func chooseDensity() {
        Theme.Haptics.tap()
        let densities = ChatDensity.allCases
        push(
            SettingsChoiceViewController(
                title: ChatDensitySetting.title,
                options: densities.map { .init(title: $0.title, detail: $0.explanation) },
                selected: densities.firstIndex(of: ChatDensitySetting.current) ?? 0,
                footer: ChatDensitySetting.explanation
            ) { ChatDensitySetting.set(densities[$0]) })
    }

    /// When finished work taps the shoulder: four short answers, each with the sentence that says
    /// what it means.
    func chooseNoticeFinish() {
        Theme.Haptics.tap()
        let choices = NoticeRules.Finish.allCases
        push(
            SettingsChoiceViewController(
                title: NoticeRulesWords.finishTitle,
                options: choices.map {
                    .init(title: NoticeRulesWords.title($0), detail: NoticeRulesWords.detail($0))
                },
                selected: choices.firstIndex(of: AppPreferences.noticeRules.finish) ?? 0,
                footer: NoticeRulesWords.groupDescription
            ) { index in
                var rules = AppPreferences.noticeRules
                rules.finish = choices[index]
                AppPreferences.noticeRules = rules
            })
    }

    func chooseNoticeMinimum() {
        Theme.Haptics.tap()
        let choices = NoticeRules.minimumChoices
        push(
            SettingsChoiceViewController(
                title: NoticeRulesWords.minimumTitle,
                options: choices.map { .init(title: NoticeRulesWords.minimum($0), detail: nil) },
                selected: choices.firstIndex(of: AppPreferences.noticeRules.minimumWork) ?? 0,
                footer: NoticeRulesWords.minimumSubtitle
            ) { index in
                var rules = AppPreferences.noticeRules
                rules.minimumWork = choices[index]
                AppPreferences.noticeRules = rules
            })
    }

    /// Unmuting every chat cannot be taken back in one tap, so it is asked once, from the row.
    func confirmUnmuteAll(from indexPath: IndexPath) {
        Theme.Haptics.tap()
        let sheet = UIAlertController(
            title: NoticeRulesWords.mutedTitle,
            message: NoticeRulesWords.mutedCount(AppPreferences.noticeRules.muted.count),
            preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: NoticeRulesWords.unmuteAll, style: .default) { [weak self] _ in
                Theme.Haptics.selection()
                var rules = AppPreferences.noticeRules
                rules.muted = []
                AppPreferences.noticeRules = rules
                self?.applySnapshot()
            })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = collectionView
        sheet.popoverPresentationController?.sourceRect =
            collectionView.cellForItem(at: indexPath)?.frame ?? .zero
        present(sheet, animated: true)
    }

    /// How a turn's work is drawn, as a page for the same reason the density is. A chat left open
    /// behind this screen answers it at once.
    func chooseActivityStyle() {
        Theme.Haptics.tap()
        let styles = ActivityStyle.allCases
        push(
            SettingsChoiceViewController(
                title: ActivityStyleSetting.title,
                options: styles.map { .init(title: $0.title, detail: $0.explanation) },
                selected: styles.firstIndex(of: ActivityStyleSetting.current) ?? 0,
                footer: ActivityStyleSetting.explanation
            ) { ActivityStyleSetting.set(styles[$0]) })
    }

    private func push(_ choice: SettingsChoiceViewController) {
        navigationController?.pushViewController(choice, animated: true)
    }

    /// The row states the choice rather than offering it: which identity, and which of its two
    /// faces. Both are one screen away, where they can be seen instead of read.
    static var themeSummary: String {
        let identity = ThemeSelection.usesSystemPalette
            ? String(localized: "System") : ThemeSelection.theme.name
        guard ThemeSelection.appearance != .system else { return identity }
        return "\(identity) · \(ThemeSelection.appearance.title)"
    }

    /// The inline trailing menu button shared by every value row.
    var pushCapableProfiles: [ConnectionProfile] {
        var seen = Set<URL>()
        return facts.profiles.filter {
            $0.backend == .claudeCode && !$0.id.hasPrefix(DemoWorld.profilePrefix)
                && seen.insert($0.baseURL).inserted
        }
    }
}

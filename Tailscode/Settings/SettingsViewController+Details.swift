import CodingAgentKitApple
import TailscodeCore
import UIKit

extension SettingsViewController {
    func permissionDetail() -> (String, UIColor, String) {
        switch notificationStatus {
        case .some(.authorized), .some(.provisional), .some(.ephemeral):
            return (String(localized: "Allowed"), Theme.Color.secondaryLabel, "bell.badge.fill")
        case .some(.denied):
            return (
                String(localized: "Turned off — tap to open iOS Settings"), Theme.Color.danger,
                "bell.slash.fill"
            )
        case .some(.notDetermined):
            return (
                String(localized: "Not requested — tap to allow"), Theme.Color.warning, "bell.badge"
            )
        case .none:
            return (String(localized: "Checking…"), Theme.Color.secondaryLabel, "bell.badge")
        default:
            return (String(localized: "Unknown"), Theme.Color.secondaryLabel, "bell.badge")
        }
    }

    /// Whether this is a fact or a fault: on and available reads as plain status, denied or
    /// restricted is the one thing standing between a person and a wake this app cannot promise
    /// any other way, so it wears the warning tone and the tap that fixes it.
    func backgroundRefreshDetail() -> (String, UIColor, String, actionable: Bool) {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:
            return (
                String(localized: "On"), Theme.Color.secondaryLabel,
                "arrow.triangle.2.circlepath", false
            )
        case .denied, .restricted:
            return (
                String(localized: "Off — tap to open iOS Settings"), Theme.Color.warning,
                "arrow.triangle.2.circlepath.circle.fill", true
            )
        @unknown default:
            return (String(localized: "Unknown"), Theme.Color.secondaryLabel, "questionmark.circle", false)
        }
    }

    func pushDetail(_ state: PushRegistrar.State) -> String {
        switch state {
        case .registered: return String(localized: "Registered")
        case .unsupported: return String(localized: "Bridge too old")
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
        let rollup = UpdateLedger.rollup()
        let component = UpdateComponent.server(profileID: id)
        guard let reading = rollup.readings.first(where: { $0.component == component }),
            reading.stands(acknowledged: rollup.isAcknowledged(reading)) || reading.verdict.isBusy
        else { return nil }
        let badge = ActivityBadgeView(pointSize: 11)
        badge.show(reading.icon, spoken: UpdateCard(reading).headline)
        return .customView(configuration: .init(customView: badge, placement: .trailing()))
    }

    func switchAccessory(_ toggle: Toggle) -> UICellAccessory.CustomViewConfiguration {
        let toggleView = UISwitch()
        toggleView.isOn = toggle.isOn
        toggleView.accessibilityLabel = toggle.title
        toggleView.addAction(
            UIAction { [weak self] action in
                guard let sender = action.sender as? UISwitch else { return }
                toggle.set(sender.isOn)
                Theme.Haptics.tap()
                self?.toggleDidChange(toggle)
            }, for: .valueChanged)
        return .init(customView: toggleView, placement: .trailing())
    }

    /// A toggle that changes what other rows mean repaints them: turning server
    /// pushes off makes every per-bridge row read "Turned off" immediately rather
    /// than after the next visit.
    private func toggleDidChange(_ toggle: Toggle) {
        guard toggle == .serverPush else { return }
        applySnapshot()
    }

    /// The row states the strength it is set to, so the one number worth knowing does not
    /// require opening the screen that owns it.
    func strengthBadge() -> UICellAccessory {
        let label = UILabel()
        label.font = Theme.Ramp.font(.panelLabel)
        label.textColor = Theme.Color.secondaryLabel
        label.text =
            AppPreferences.hapticsEnabled ? HapticStrength.label(AppPreferences.hapticIntensity) : ""
        return .customView(configuration: .init(customView: label, placement: .trailing()))
    }

    /// Which hand is writing, and the mark it wears while it is still being proven — carried on
    /// the row rather than only on the screen behind it, so a setting that is alpha says so where
    /// it is switched on from.
    func rendererBadge() -> UICellAccessory {
        let choice = StreamRendererSetting.choice
        let name = UILabel()
        name.font = Theme.Ramp.font(.panelLabel)
        name.textColor = Theme.Color.secondaryLabel
        name.text = choice.title
        guard choice.isAlpha else {
            return .customView(configuration: .init(customView: name, placement: .trailing()))
        }
        let row = UIStackView(arrangedSubviews: [name, AlphaBadge()])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.xs
        return .customView(configuration: .init(customView: row, placement: .trailing()))
    }

    /// The two densities as a sheet over the row, the current one ticked: the choice is two
    /// words, so it is made from the row that reads it rather than on a screen of its own.
    func chooseDensity(from indexPath: IndexPath) {
        Theme.Haptics.tap()
        let sheet = UIAlertController(
            title: ChatDensitySetting.title, message: ChatDensitySetting.explanation,
            preferredStyle: .actionSheet)
        for density in ChatDensity.allCases {
            let current = density == ChatDensitySetting.current
            let action = UIAlertAction(
                title: current ? density.title + " ✓" : density.title, style: .default
            ) { [weak self] _ in
                Theme.Haptics.selection()
                ChatDensitySetting.set(density)
                self?.reconfigure([.chatDensity])
            }
            sheet.addAction(action)
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = collectionView
        sheet.popoverPresentationController?.sourceRect =
            collectionView.cellForItem(at: indexPath)?.frame ?? .zero
        present(sheet, animated: true)
    }

    /// How a turn's work is drawn, as a sheet over the row for the same reason the density is: the
    /// choice is two words. A chat left open behind this screen answers it at once.
    func chooseActivityStyle(from indexPath: IndexPath) {
        Theme.Haptics.tap()
        let sheet = UIAlertController(
            title: ActivityStyleSetting.title, message: ActivityStyleSetting.explanation,
            preferredStyle: .actionSheet)
        for style in ActivityStyle.allCases {
            let current = style == ActivityStyleSetting.current
            sheet.addAction(
                UIAlertAction(title: current ? style.title + " ✓" : style.title, style: .default) {
                    [weak self] _ in
                    Theme.Haptics.selection()
                    ActivityStyleSetting.set(style)
                    self?.reconfigure([.activityStyle])
                })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = collectionView
        sheet.popoverPresentationController?.sourceRect =
            collectionView.cellForItem(at: indexPath)?.frame ?? .zero
        present(sheet, animated: true)
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
        return ConnectionController.shared.profiles.filter {
            $0.backend == .claudeCode && !$0.id.hasPrefix(DemoWorld.profilePrefix)
                && seen.insert($0.baseURL).inserted
        }
    }
}

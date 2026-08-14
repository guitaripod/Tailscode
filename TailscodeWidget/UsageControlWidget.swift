import AppIntents
import SwiftUI
import TailscodeCore
import WidgetKit

/// Which quota the Control Center button watches. A control is one line on a screen somebody swipes
/// to in a hurry, so the choice of *what* it watches belongs to them: the account's tightest window
/// by default, or one provider they are actually waiting on.
struct TopUsageConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Agent usage"
    static let description = IntentDescription("Pick the quota this control watches.")

    @Parameter(
        title: "Provider",
        description: "Leave empty for whichever quota is tightest right now.")
    var provider: QuotaProviderEntity?

    init() {}
}

struct TopUsageValue {
    var label: String
    var symbol: String
    var isEmpty: Bool
}

struct TopUsageValueProvider: AppIntentControlValueProvider {
    func previewValue(configuration: TopUsageConfiguration) -> TopUsageValue {
        TopUsageValue(label: "Claude 47%", symbol: "gauge.with.needle", isEmpty: false)
    }

    func currentValue(configuration: TopUsageConfiguration) async throws -> TopUsageValue {
        let filter = configuration.provider.map { Set([$0.id]) }
        guard let stored = UsageWidgetStore.read() else { return empty }
        let glance = stored.glance(providerFilter: filter)
        guard let hero = glance.hero else { return empty }
        return TopUsageValue(
            label: "\(hero.providerShort) \(hero.value)",
            symbol: hero.tone == .danger
                ? "exclamationmark.triangle.fill"
                : (hero.kind == .balance ? "creditcard" : "gauge.with.needle"),
            isEmpty: false)
    }

    private var empty: TopUsageValue {
        TopUsageValue(
            label: String(localized: "Usage"), symbol: "gauge.with.dots.needle", isEmpty: true)
    }
}

struct TopUsageControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: "com.guitaripod.tailscode.TopUsageControl",
            provider: TopUsageValueProvider()
        ) { value in
            ControlWidgetButton(action: OpenUsageIntent()) {
                Label {
                    Text(value.label)
                } icon: {
                    Image(systemName: value.symbol)
                }
            }
        }
        .displayName(LocalizedStringResource("Top Agent Usage"))
        .description(
            LocalizedStringResource("Your hottest agent quota, one tap from the dashboard."))
    }
}

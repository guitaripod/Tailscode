import AppIntents
import SwiftUI
import WidgetKit

struct TopUsageValue {
    var percentText: String
    var symbol: String
    var providerName: String
    var isEmpty: Bool
}

struct TopUsageValueProvider: ControlValueProvider {
    var previewValue: TopUsageValue {
        TopUsageValue(percentText: "47%", symbol: "gauge.with.needle", providerName: "Claude Code", isEmpty: false)
    }

    func currentValue() async throws -> TopUsageValue {
        guard let entry = UsageWidgetStore.read(),
            let top = entry.providers
                .flatMap({ provider in provider.gauges.map { (provider, $0) } })
                .max(by: { $0.1.fraction < $1.1.fraction })
        else {
            return TopUsageValue(percentText: "—", symbol: "gauge.with.dots.needle", providerName: "Usage", isEmpty: true)
        }
        let gauge = top.1
        return TopUsageValue(
            percentText: gauge.percentText,
            symbol: gauge.fraction > 0.85 ? "exclamationmark.triangle.fill" : "gauge.with.needle",
            providerName: top.0.providerName,
            isEmpty: false)
    }
}

struct TopUsageControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.guitaripod.tailscode.TopUsageControl", provider: TopUsageValueProvider()) { value in
            ControlWidgetButton(action: OpenUsageIntent()) {
                Label {
                    Text(value.isEmpty ? "Usage" : "\(value.providerName) \(value.percentText)")
                } icon: {
                    Image(systemName: value.symbol)
                }
            }
        }
        .displayName("Top Agent Usage")
        .description("Your hottest agent quota, one tap from the dashboard.")
    }
}

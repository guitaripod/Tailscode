import AppIntents
import Foundation

/// Tapping the Top Usage control launches the app and drops a one-shot route flag in the shared
/// App Group. `AppCoordinator` reads and clears it on the next foreground and pushes the Usage
/// screen. A custom-scheme `OpenURLIntent` is deliberately avoided — it is unreliable from a
/// Control without an associated domain.
struct OpenUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Usage"
    static let description = IntentDescription("Open Tailscode to the Usage dashboard.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        UsageWidgetStore.setPendingControlRoute("usage")
        return .result()
    }
}

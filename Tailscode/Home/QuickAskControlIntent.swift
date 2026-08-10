import AppIntents
import Foundation

/// Tapping the Quick Ask control launches the app and drops a one-shot route flag in the shared
/// App Group. `AppCoordinator` reads and clears it on the next foreground and summons the quick
/// ask composer. A custom-scheme `OpenURLIntent` is deliberately avoided — it is unreliable from
/// a Control without an associated domain.
struct QuickAskIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Ask"
    static let description = IntentDescription("Open Tailscode with a question ready to type.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        UsageWidgetStore.setPendingControlRoute("ask")
        return .result()
    }
}

import AppIntents
import Foundation

/// Tapping the Agents control, or asking Siri or a Shortcut for the board, launches the app and
/// drops a one-shot route flag in the shared App Group. `AppCoordinator` reads and clears it on the
/// next foreground and opens the Agents board over whatever is on screen. A custom-scheme
/// `OpenURLIntent` is deliberately avoided — it is unreliable from a Control without an associated
/// domain.
struct OpenAgentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Agents"
    static let description = IntentDescription("Open Tailscode to the Agents board.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        UsageWidgetStore.setPendingControlRoute("agents")
        return .result()
    }
}

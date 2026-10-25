import AppIntents

/// What Siri, Spotlight, the Shortcuts app and Vocal Shortcuts offer before the person builds
/// anything: a question asked out loud, and the quick ask box opened to type in.
struct TailscodeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskQuestionIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
                "Ask my agent in \(.applicationName)",
            ],
            shortTitle: "Ask a Question",
            systemImageName: "questionmark.bubble")
        AppShortcut(
            intent: QuickAskIntent(),
            phrases: [
                "Quick ask in \(.applicationName)",
                "Open quick ask in \(.applicationName)",
            ],
            shortTitle: "Quick Ask",
            systemImageName: "sparkle")
    }
}

import Foundation

/// A way to begin a conversation that has not begun, offered by the empty chat on every client.
///
/// The phone has always drawn four starters under "What should your agent do?"; the desktops drew
/// a caption and a blank page, so the first minute with a new chat was a good deal better on the
/// small screen. The words live here once, with the symbol each client draws beside them (an SF
/// Symbol, or the glyph for a toolkit that has none).
public struct ChatSuggestion: Sendable, Hashable, Identifiable {
    public let id: String
    public let symbol: String
    public let glyph: String
    public let title: String
    public let prompt: String

    public static var all: [ChatSuggestion] {
        [
            ChatSuggestion(
                id: "tests", symbol: "checkmark.diamond", glyph: "✓",
                title: Localized.text("Fix the failing tests"),
                prompt: Localized.text("Run the test suite, find the failures, and fix them.")),
            ChatSuggestion(
                id: "review", symbol: "sparkle.magnifyingglass", glyph: "◎",
                title: Localized.text("Review recent changes"),
                prompt: Localized.text("Review the latest commits and point out anything risky.")),
            ChatSuggestion(
                id: "bug", symbol: "ladybug", glyph: "✱",
                title: Localized.text("Hunt a bug"),
                prompt: Localized.text(
                    "Look through the codebase for likely bugs and fix the most severe one.")),
            ChatSuggestion(
                id: "coverage", symbol: "text.badge.plus", glyph: "+",
                title: Localized.text("Add test coverage"),
                prompt: Localized.text(
                    "Find the least-tested important module and write tests for it.")),
        ]
    }

    public static var headline: String { Localized.text("What should your agent do?") }
}

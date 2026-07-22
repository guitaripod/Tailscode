import Foundation

/// One on-device rewrite of the user's draft: a short `label` naming the angle
/// it takes plus the refined `text`. A plain value type so the Foundation
/// Models types stay behind `PromptEnhancer` and never reach the UI layer.
struct EnhancedPrompt: Sendable, Hashable, Identifiable {
    let id: Int
    let label: String
    let text: String
}

/// Tuning for the throttle and the on-device generation. Kept in one place so
/// the thresholds are easy to reason about and adjust.
enum PromptEnhancement {
    /// Below this many trimmed characters a draft is too thin to be worth
    /// refining — the throttle stays idle.
    static let minCharacters = 12
    /// …and it must be at least this many words, so a long run of one token
    /// ("aaaaaaa…") never trips the threshold.
    static let minWords = 3
    /// Idle time after the last keystroke before a background refine kicks off.
    static let debounce: Duration = .milliseconds(750)
    /// Only the leading slice of a long draft is handed to the small model —
    /// enough for intent, short enough to stay fast.
    static let maxInputCharacters = 1200
    /// How many distinct rewrites to ask for.
    static let suggestionCount = 3
}

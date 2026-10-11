import Foundation
import TailscodeCore

/// The words of the window's one quiet line about density: how many chats are whole out of how
/// many are open — `Live 2 of 5` — and, when the machine is shedding, why. Pressed, it explains
/// itself and offers `Keep all live`, which asks every open chat to stay whole; at strained and
/// above safety outranks that preference, and the popover says so rather than leaving a switch
/// that silently does nothing.
enum LiveChipReading {
    static func title(live: Int, chats: Int, decision: GovernorDecision?) -> String {
        let count = Localized.text("Live %@ of %@", "\(live)", "\(chats)")
        guard let decision, decision.level > .calm, let reason = decision.reasons.first else {
            return count
        }
        return "\(count) · \(reason.chipWord)"
    }

    static func explanation(decision: GovernorDecision?) -> String {
        var lines = [
            Localized.text(
                "The focused chat and a few others stay whole; the rest show as glance tiles, so many panes never slow this computer down.")
        ]
        if let decision, decision.level > .calm, let reason = decision.reasons.first {
            lines.append(
                Localized.text("Fewer chats stay whole right now (%@).", reason.chipWord))
        }
        return lines.joined(separator: " ")
    }

    static let ignoredNote = Localized.text(
        "Ignored while this computer is strained: keeping it responsive comes first.")
}

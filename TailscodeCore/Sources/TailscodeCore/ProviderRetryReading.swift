import CodingAgentKit
import Foundation

/// A turn waiting on its provider, read into the card every client docks under the transcript.
///
/// From the outside the wait is a model thinking very hard: the turn is open and nothing streams.
/// The provider's own reason is the whole explanation (a rate limit that lifts in a minute, a plan
/// used up for the week), so the card leads with it, says which attempt failed and when the next
/// one goes, and offers the remedy the provider named where it named one. Nobody here has to do
/// anything for the server to try again, so the card never asks; stopping the turn stays where it
/// always is.
public struct ProviderRetryCard: Sendable, Hashable {
    /// What the provider says would end the wait, and where to go to do it.
    public struct Remedy: Sendable, Hashable {
        public let title: String
        public let message: String
        public let label: String
        public let link: URL?
    }

    public let title: String
    /// The provider's own words, or a plain sentence when it gave none.
    public let reason: String
    /// Which attempt failed and when the next one goes: the line that moves as the clock does.
    public let attemptLine: String
    public let remedy: Remedy?
    public let spoken: String

    public static let symbol = ActivityKind.retrying(attempt: 1).icon.symbol
    public static let glyph = ActivityKind.retrying(attempt: 1).icon.glyph
    public static let tone = ActivityTone.attention
}

public enum ProviderRetryReading {
    public static func read(_ retry: TurnRetry?, now: Date = Date()) -> ProviderRetryCard? {
        guard let retry else { return nil }
        let reason = retry.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = Localized.text("Waiting on the provider")
        let words = reason.isEmpty
            ? Localized.text("The provider did not answer the last attempt.") : reason
        let line = attemptLine(retry, now: now)
        let remedy = retry.remedy.map {
            ProviderRetryCard.Remedy(
                title: $0.title, message: $0.message, label: $0.label,
                link: $0.link.flatMap(URL.init(string:)))
        }
        return ProviderRetryCard(
            title: title, reason: words, attemptLine: line, remedy: remedy,
            spoken: [title, words, line].joined(separator: ". "))
    }

    /// When the card's words next change on their own, so a client wakes its clock for that moment
    /// rather than ticking under a card that has nothing new to say. The countdown moves once a
    /// second until the next attempt is due, and then not at all.
    public static func nextChange(_ retry: TurnRetry, now: Date = Date()) -> Date? {
        guard let next = retry.nextAttemptAt, next > now else { return nil }
        let wholeSecondsAfterChange = ceil(next.timeIntervalSince(now)) - 1
        return next.addingTimeInterval(-wholeSecondsAfterChange)
    }

    static func attemptLine(_ retry: TurnRetry, now: Date) -> String {
        guard let next = retry.nextAttemptAt else {
            return Localized.text("Attempt %@ failed, the server will try again", "\(retry.attempt)")
        }
        let seconds = Int(ceil(next.timeIntervalSince(now)))
        guard seconds > 0 else {
            return Localized.text("Attempt %@ failed, trying again now", "\(retry.attempt)")
        }
        return Localized.text(
            "Attempt %1$@ failed, trying again in %2$@", "\(retry.attempt)", countdown(seconds))
    }

    /// A wait of seconds, minutes or hours in the fewest words that still say it exactly enough.
    static func countdown(_ seconds: Int) -> String {
        if seconds < 60 { return Localized.text("%@ s", "\(seconds)") }
        let minutes = seconds / 60
        if minutes < 60 {
            let rest = seconds % 60
            return rest == 0
                ? Localized.text("%@ min", "\(minutes)")
                : Localized.text("%1$@ min %2$@ s", "\(minutes)", "\(rest)")
        }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0
            ? Localized.text("%@ h", "\(hours)")
            : Localized.text("%1$@ h %2$@ min", "\(hours)", "\(rest)")
    }
}

import CodingAgentKit
import Foundation

/// Everything a compaction card says, in every state it can be in — finished seam, the minutes-long
/// summarize still running, or the attempt that was refused. The words, the tone and the bar's
/// proportion are decided here once; a client decides only how tall the bar is and which widget
/// draws each line.
public struct CompactionStory: Sendable, Hashable {
    public enum Tone: Sendable, Hashable {
        case accent
        case warn
    }

    /// SF Symbol name for the clients that have them; text clients pick their own glyph by tone.
    public let symbol: String
    public let tone: Tone
    public let title: String
    public let detail: String
    public let footnote: String?
    /// The sliver of context the summary still occupies, `0...1`. Rendering what is *kept* rather
    /// than what was freed is the honest read: a nearly empty bar is the point of compacting.
    /// `nil` hides the bar.
    public let keptFraction: Double?
    /// The bar sweeps instead of measuring: compaction reports no progress, and a bar that
    /// pretended to know would be lying about a step that can run for minutes.
    public let sweeps: Bool
    /// The machine-facing summary behind the card, when there is one to open.
    public let summary: String?

    public var isReadable: Bool { summary?.isEmpty == false }

    public static func done(_ compaction: Compaction) -> CompactionStory {
        CompactionStory(
            symbol: "arrow.down.right.and.arrow.up.left",
            tone: .accent,
            title: compaction.trigger == .auto
                ? Localized.text("Context compacted automatically")
                : Localized.text("Context compacted"),
            detail: doneDetail(compaction),
            footnote: doneFootnote(compaction),
            keptFraction: keptFraction(compaction),
            sweeps: false,
            summary: compaction.summary)
    }

    /// `waiting` is a prompt this device has already handed over while the summarize runs. The
    /// send button says a message goes into a queue rather than out, so the card owes the reader
    /// the other half of that sentence: the wait is the compaction's, and the message is not lost
    /// in it.
    public static func running(startedAt: Date, waiting: Bool = false, now: Date = Date())
        -> CompactionStory
    {
        CompactionStory(
            symbol: "arrow.down.right.and.arrow.up.left",
            tone: .accent,
            title: Localized.text("Compacting…"),
            detail: waiting
                ? Localized.text(
                    "Re-reading the conversation to summarize it. Your message is queued behind it.")
                : Localized.text(
                    "Re-reading the conversation to summarize it. This can take a minute or two."),
            footnote: elapsedLine(startedAt: startedAt, now: now),
            keptFraction: nil,
            sweeps: true,
            summary: nil)
    }

    public static func failed(_ reason: String) -> CompactionStory {
        CompactionStory(
            symbol: "exclamationmark.triangle.fill",
            tone: .warn,
            title: Localized.text("Couldn't compact"),
            detail: reason,
            footnote: Localized.text("The conversation is unchanged."),
            keptFraction: nil,
            sweeps: false,
            summary: nil)
    }

    /// The ticking line under a running card, regenerated each second by the client's own clock.
    public static func elapsedLine(startedAt: Date, now: Date = Date()) -> String {
        Localized.text("Running for %@", StatusFacts.clock(max(0, now.timeIntervalSince(startedAt))))
    }

    /// The line above the summary in its reader: the trade restated where the prose begins.
    public static func summaryHeader(_ compaction: Compaction) -> String {
        var parts: [String] = []
        if let before = compaction.tokensBefore, let after = compaction.tokensAfter {
            parts.append(
                Localized.text(
                    "%@ → %@ tokens", StatusFacts.tokens(before), StatusFacts.tokens(after)))
        }
        if let reduction = compaction.reduction {
            parts.append(Localized.text("%@%% freed", "\(Int((reduction * 100).rounded()))"))
        }
        if let duration = compaction.duration, duration >= 1 {
            parts.append(StatusFacts.clock(duration))
        }
        guard !parts.isEmpty else {
            return Localized.text("What the agent carries forward from here.")
        }
        return parts.joined(separator: " · ") + " — "
            + Localized.text("this is what the agent carries forward.")
    }

    private static func doneDetail(_ compaction: Compaction) -> String {
        var parts: [String] = []
        if let before = compaction.tokensBefore, let after = compaction.tokensAfter {
            parts.append(
                Localized.text(
                    "%@ → %@ tokens", StatusFacts.tokens(before), StatusFacts.tokens(after)))
        } else if let after = compaction.tokensAfter {
            parts.append(Localized.text("%@ tokens in context", StatusFacts.tokens(after)))
        }
        if let duration = compaction.duration, duration >= 1 {
            parts.append(StatusFacts.clock(duration))
        }
        guard !parts.isEmpty else {
            return Localized.text("The conversation so far was replaced by a summary of it.")
        }
        return parts.joined(separator: " · ")
    }

    private static func doneFootnote(_ compaction: Compaction) -> String {
        var sentence =
            compaction.reduction.map {
                Localized.text(
                    "%@%% of the context was replaced by a summary",
                    "\(Int(($0 * 100).rounded()))")
            } ?? Localized.text("Earlier messages were replaced by a summary")
        if let preserved = compaction.preservedMessageCount, preserved > 0 {
            sentence += "; " + Localized.text("the last %@ messages carried over", "\(preserved)")
        }
        return sentence + "."
    }

    private static func keptFraction(_ compaction: Compaction) -> Double? {
        guard let before = compaction.tokensBefore, before > 0,
            let after = compaction.tokensAfter
        else { return nil }
        return min(max(Double(after) / Double(before), 0.02), 1)
    }
}

/// The decision screen `/compact` opens instead of firing bare. Compaction is destructive to the
/// agent's memory and takes minutes, so the screen makes the argument in full: what it does, what
/// stays, what it costs, and a place to say what the summary must not lose — every word decided
/// here so three clients cannot drift into three explanations.
public struct CompactPreflight: Sendable, Hashable {
    public let headline: String
    public let subtitle: String
    public let paragraphs: [String]
    public let fieldCaption: String
    public let fieldPlaceholder: String
    /// What the previous compaction traded, when there was one: a conversation compacted once
    /// usually compacts again, and the last result sets the expectation for this wait.
    public let lastTime: String?
    public let wait: String
    public let confirmTitle: String

    public static func make(messageCount: Int, lastCompaction: Compaction?) -> CompactPreflight {
        CompactPreflight(
            headline: Localized.text("Free up the context window"),
            subtitle: messageCount > 0
                ? Localized.text("%@ messages in this conversation", "\(messageCount)")
                : Localized.text("This conversation"),
            paragraphs: [
                Localized.text(
                    "The agent re-reads this conversation, writes a summary of it, and carries the summary forward instead of the whole transcript."
                ),
                Localized.text(
                    "Nothing here disappears — you keep every message. Only the agent's memory shrinks."
                ),
            ],
            fieldCaption: Localized.text("What must the summary keep?"),
            fieldPlaceholder: Localized.text("Optional — e.g. the failing test names"),
            lastTime: lastTimeLine(lastCompaction),
            wait: Localized.text(
                "Takes a minute or two, and the conversation is busy until it finishes."),
            confirmTitle: Localized.text("Compact conversation"))
    }

    /// Reads the two facts the screen leads with straight off the conversation: how much is here,
    /// and what the previous compaction of it traded.
    public static func make(state: ConversationState?) -> CompactPreflight {
        let messages = state?.messages ?? []
        var last: Compaction?
        for message in messages {
            for part in message.parts {
                if case .compaction(let compaction) = part.kind { last = compaction }
            }
        }
        return make(messageCount: messages.count, lastCompaction: last)
    }

    private static func lastTimeLine(_ compaction: Compaction?) -> String? {
        guard let compaction, let before = compaction.tokensBefore,
            let after = compaction.tokensAfter
        else { return nil }
        var text = Localized.text(
            "Last time: %@ → %@ tokens", StatusFacts.tokens(before), StatusFacts.tokens(after))
        if let duration = compaction.duration, duration >= 1 {
            text += " " + Localized.text("in %@", StatusFacts.clock(duration))
        }
        return text + "."
    }
}

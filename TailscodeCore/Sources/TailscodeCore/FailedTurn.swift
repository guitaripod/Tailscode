import CodingAgentKit
import Foundation

/// A turn that stopped with an error, read into a card a person can act on.
///
/// The server's account of a failed turn is a string, and the clients used to draw that string as
/// if it were an answer: a bubble on the phone, nothing at all on the desktops beyond a clipped
/// word in the status band. A failure that reads like prose is skimmed past, and one that is
/// missing from the transcript is a turn that seems to have been ignored. This is the same shape
/// as `AnswerlessTurn` — what happened, the server's own words quoted rather than paraphrased, and
/// the one thing worth trying — so the two outcomes that end a turn badly look like relatives.
public struct FailedTurn: Sendable, Hashable {
    public let title: String
    public let detail: String
    /// What the server said, tidied to one readable paragraph and never reworded: a cause the
    /// transcript cannot show is not one this card claims.
    public let reason: String
    public let action: String
    /// The words that started the turn, ready to be sent again. Empty when the prompt was a
    /// picture with nothing typed beside it, in which case no client offers the action.
    public let prompt: String
    public let spoken: String

    public var offersRemedy: Bool { !prompt.isEmpty }

    /// A settled outcome carries no motion: stillness is how a reader tells a turn that stopped
    /// from one that is slow.
    public static let symbol = "exclamationmark.triangle"
    public static let glyph = "✖"
    public static let tone = ActivityTone.danger
}

public enum FailedTurnReading {
    static let longest = 280

    /// Reads an assistant message into the failure it records, or `nil` when it recorded none.
    ///
    /// - Parameter prompt: the user message this turn answers, whose words are what "try again"
    ///   sends.
    public static func read(_ message: ChatMessage, prompt: ChatMessage?) -> FailedTurn? {
        guard message.role == .assistant, let raw = message.error else { return nil }
        let reason = tidy(raw)
        guard !reason.isEmpty else { return nil }
        let title = Localized.text("The turn failed")
        let detail = opening(model: message.modelID)
        let words = prompt?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FailedTurn(
            title: title, detail: detail, reason: reason, action: Localized.text("Try again"),
            prompt: words, spoken: "\(title). \(detail) \(reason)")
    }

    private static func opening(model: String?) -> String {
        guard let model, !model.isEmpty else {
            return Localized.text("The turn stopped with an error and did not finish.")
        }
        return Localized.text("%@ stopped with an error and did not finish.", model)
    }

    /// One paragraph, no runs of whitespace, no longer than a card can hold; the cut is marked.
    static func tidy(_ raw: String) -> String {
        let words = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard words.count > longest else { return words }
        return String(words.prefix(longest)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

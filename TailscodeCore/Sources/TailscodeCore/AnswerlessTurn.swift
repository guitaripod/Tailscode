import CodingAgentKit
import Foundation

/// A turn that finished and said nothing, read into words a person can act on.
///
/// The transcript is built from what a turn produced, so a turn that produced nothing draws
/// nothing: no answer row, no tool row, no error card, and — because the server reported no
/// failure — no banner either. The whole turn is then invisible, and the only thing the sender
/// sees is a spinner that stops. This is the face that outcome wears instead: what happened,
/// what the server called it, and the one thing worth trying next.
///
/// It says only what is known. The provider's reason for refusing is not in the transcript, so
/// nothing here claims one; the question having carried a picture *is* in the transcript, and a
/// picture is the commonest thing a model is refused for holding, so that fact is stated and the
/// remedy follows from it rather than from a diagnosis nobody made.
public struct AnswerlessTurn: Sendable, Hashable {
    /// The one action offered, chosen from what the transcript can actually carry out: the words
    /// are in the transcript and can be sent again, the pictures are bytes on the server and
    /// cannot, so "again" always means the words.
    public enum Remedy: String, Sendable, Hashable {
        case askAgain
        case askWithoutPictures
    }

    public let title: String
    public let detail: String
    public let remedy: Remedy
    public let action: String
    /// The words that started the turn, ready to be sent again. Empty when the prompt was a
    /// picture with nothing typed beside it, in which case no client offers the action.
    public let prompt: String
    public let spoken: String

    public var offersRemedy: Bool { !prompt.isEmpty }

    /// The face, in the same two alphabets every other state in this app is drawn in. It is a
    /// settled outcome, so it carries no motion at all: stillness is how a reader tells a turn
    /// that stopped from one that is slow.
    public static let symbol = "exclamationmark.bubble"
    public static let glyph = "∅"
    public static let tone = ActivityTone.attention
}

public enum AnswerlessTurnReading {
    /// Reads an assistant message into the outcome it represents, or `nil` when the turn said
    /// something — which is nearly always.
    ///
    /// - Parameter prompt: the user message this turn answers, which is where the picture that
    ///   may have caused the silence lives.
    public static func read(_ message: ChatMessage, prompt: ChatMessage?) -> AnswerlessTurn? {
        guard message.isAnswerless else { return nil }
        let pictures = prompt.map(pictureCount) ?? 0
        let words = prompt?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = Localized.text("Nothing came back")
        var detail = opening(model: message.modelID)
        if let ending = ending(message.finishReason) { detail += " " + ending }
        if pictures > 0 { detail += " " + pictureLine(count: pictures) }
        let remedy: AnswerlessTurn.Remedy = pictures > 0 ? .askWithoutPictures : .askAgain
        return AnswerlessTurn(
            title: title, detail: detail, remedy: remedy, action: action(remedy, count: pictures),
            prompt: words, spoken: "\(title). \(detail)")
    }

    private static func pictureCount(_ prompt: ChatMessage) -> Int {
        prompt.parts.count { part in
            guard case .file(let file) = part.kind else { return false }
            return file.mime?.hasPrefix("image/") ?? false
        }
    }

    private static func opening(model: String?) -> String {
        guard let model, !model.isEmpty else {
            return Localized.text(
                "The turn ended without a word — no answer, no tool call, and no error to explain it.")
        }
        return Localized.text(
            "%@ ended the turn without a word — no answer, no tool call, and no error to explain it.",
            model)
    }

    /// The server's own word for the ending, quoted rather than translated — and only when it
    /// adds something, which a plain `stop` does not.
    private static func ending(_ finish: String?) -> String? {
        guard let finish, !finish.isEmpty, finish.lowercased() != "stop" else { return nil }
        return Localized.text("The server calls the ending “%@”.", finish)
    }

    private static func pictureLine(count: Int) -> String {
        count == 1
            ? Localized.text(
                "The question carried a picture, and a model that will not be handed one answers exactly like this.")
            : Localized.text(
                "The question carried %d pictures, and a model that will not be handed one answers exactly like this.",
                count)
    }

    private static func action(_ remedy: AnswerlessTurn.Remedy, count: Int) -> String {
        switch remedy {
        case .askAgain: return Localized.text("Ask again")
        case .askWithoutPictures:
            return count == 1
                ? Localized.text("Ask again without the picture")
                : Localized.text("Ask again without the pictures")
        }
    }
}

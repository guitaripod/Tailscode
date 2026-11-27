import Foundation

/// A prompt that is a whole message on its own, offered as one press beside an empty prompt box.
///
/// Two words make up most of what anybody types alone into a chat that has gone quiet: "resume",
/// after a spent quota, a lapsed sign-in, a stop, or a turn that ended without carrying on, and
/// "status?", after the agent left work running and stopped talking. Each is a key of its own, and
/// a press sends exactly those words through the chat's ordinary send, so the message is echoed,
/// queued and refused like anything typed and nothing on the server learns a new command.
public struct ChatNudge: Sendable, Hashable, Identifiable {
    public let id: String
    public let symbol: String
    public let glyph: String
    public let title: String
    public let prompt: String

    /// What a press does, for a screen reader and a pointer's tooltip.
    public var hint: String { Localized.text("Sends “%@” to the agent.", prompt) }

    public static var resume: ChatNudge {
        ChatNudge(
            id: "resume", symbol: "play", glyph: "▸", title: Localized.text("Resume"),
            prompt: Localized.text("resume"))
    }

    public static var status: ChatNudge {
        ChatNudge(
            id: "status", symbol: "questionmark.bubble", glyph: "?", title: Localized.text("Status?"),
            prompt: Localized.text("status?"))
    }

    public static var all: [ChatNudge] { [resume, status] }

    /// Whether a chat offers its nudges right now. All of them or none, so the keys never shuffle,
    /// and a Bool rather than the list because it is asked on every state a turn streams.
    ///
    /// None while a turn is out: it answers on its own, and the words would only queue behind it.
    /// None over anything the box holds — words, a folded paste, a picture, a waiting message open
    /// for rewriting, a take still being heard — because a press sends its own words and the
    /// person's must never ride out with them or be left behind by them. None in a conversation
    /// nothing has been said in yet, where there is nothing to resume or report on.
    public static func offers(
        running: Bool, holdsWords: Bool, holdsAttachments: Bool, editingQueued: Bool,
        dictating: Bool, hasTranscript: Bool
    ) -> Bool {
        hasTranscript && !running && !holdsWords && !holdsAttachments && !editingQueued && !dictating
    }
}

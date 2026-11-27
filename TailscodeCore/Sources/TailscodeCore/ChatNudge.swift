import CodingAgentKit
import Foundation

/// A prompt that is a whole message on its own, sent to a chat, or to every marked chat, as one
/// verb.
///
/// Two words make up most of what anybody types alone into a chat that has gone quiet: "resume",
/// after a spent quota, a lapsed sign-in, a stop, or a turn that ended without carrying on, and
/// "status?", after the agent left work running and stopped talking. They are verbs of the chat
/// row, of a marked set and of the chat's own menu, never chrome that takes room while nothing
/// needs them, and a press sends exactly those words, so nothing on the server learns a new
/// command.
public struct ChatNudge: Sendable, Hashable, Identifiable {
    public let id: String
    public let symbol: String
    public let title: String
    public let prompt: String

    /// What a press does, for a menu's second line, a screen reader and a pointer's tooltip.
    public var hint: String { Localized.text("Sends “%@” to the agent.", prompt) }

    public static var resume: ChatNudge {
        ChatNudge(
            id: "resume", symbol: "play", title: Localized.text("Resume"),
            prompt: Localized.text("resume"))
    }

    public static var status: ChatNudge {
        ChatNudge(
            id: "status", symbol: "questionmark.bubble", title: Localized.text("Status?"),
            prompt: Localized.text("status?"))
    }

    public static var all: [ChatNudge] { [resume, status] }

    /// Whether the chat on screen offers its nudges in its own menu: not while its turn is out,
    /// which answers on its own and would only queue the words behind it, and not before anything
    /// has been said, where there is nothing to resume or report on.
    public static func offers(running: Bool, hasTranscript: Bool) -> Bool {
        hasTranscript && !running
    }

    /// Whether a listed chat's turn is out, as the listing says: the turn itself where the server
    /// tells it apart, else the session's activity. Work left running between turns is not a turn,
    /// and it is exactly when "status?" is asked.
    public static func turnOpen(_ entry: SessionEntry) -> Bool {
        entry.session.turnOpen ?? (entry.session.isActive == true)
    }
}

/// A nudge sent to several chats at once, straight to each one's server, on the model and level
/// the chat's row names, so a set of chats stopped by the same spent quota is picked up in one
/// gesture. A chat whose turn is out is passed over rather than queued behind it.
public enum ChatNudgeRun {
    public static func ready(_ entries: [SessionEntry]) -> [SessionEntry] {
        entries.filter { !ChatNudge.turnOpen($0) }
    }

    /// Every send at once, counted rather than thrown: a fan-out that fails usually fails the same
    /// way for every chat, so the first reason speaks for the rest.
    public static func send(
        _ nudge: ChatNudge, to entries: [SessionEntry],
        backend: @escaping @Sendable (SessionEntry) async -> (any CodingAgentBackend)?
    ) async -> ChatNudgeOutcome {
        let chosen = ready(entries)
        let working = entries.count - chosen.count
        let prompts = chosen.map { entry in
            (entry: entry, prompt: prompt(nudge, for: entry))
        }
        return await withTaskGroup(of: String?.self) { group in
            for (entry, prompt) in prompts {
                group.addTask {
                    guard let backend = await backend(entry) else {
                        return Localized.text("that server is not configured any more")
                    }
                    do {
                        try await backend.send(prompt, to: entry.session.id)
                        return nil
                    } catch {
                        return AgentErrorText.readable(error)
                    }
                }
            }
            var sent = 0
            var reasons: [String] = []
            for await failure in group {
                if let failure { reasons.append(failure) } else { sent += 1 }
            }
            return ChatNudgeOutcome(
                nudge: nudge, sent: sent, working: working, failed: reasons.count,
                reason: reasons.first)
        }
    }

    /// The words on the model and level the chat would open on here, so a nudge never moves a chat
    /// to this server's default model behind the row that names another.
    static func prompt(_ nudge: ChatNudge, for entry: SessionEntry) -> SendPrompt {
        let key = "\(entry.profileID)/\(entry.session.id)"
        return SendPrompt(
            text: nudge.prompt,
            model: ModelPreferenceStore.initialModel(
                sessionKey: key, contextID: entry.profileID, sessionModel: entry.session.model,
                sessionModelProviderID: entry.session.modelProviderID),
            reasoningEffort: EffortPreferenceStore.initialEffort(
                sessionKey: key, contextID: entry.profileID,
                sessionEffort: entry.session.reasoningEffort))
    }
}

/// What a nudge sent to a set came back with, said in one sentence.
public struct ChatNudgeOutcome: Sendable, Equatable {
    public let nudge: ChatNudge
    public let sent: Int
    public let working: Int
    public let failed: Int
    public let reason: String?

    public init(nudge: ChatNudge, sent: Int, working: Int, failed: Int, reason: String?) {
        self.nudge = nudge
        self.sent = sent
        self.working = working
        self.failed = failed
        self.reason = reason
    }

    public var isClean: Bool { failed == 0 && working == 0 }

    public var sentence: String {
        var parts: [String] = []
        if sent > 0 {
            parts.append(
                sent == 1
                    ? Localized.text("Sent “%@”", nudge.prompt)
                    : Localized.text("Sent “%@” to %@ chats", nudge.prompt, "\(sent)"))
        }
        if working > 0 {
            parts.append(
                working == 1
                    ? Localized.text("1 was working and was left alone")
                    : Localized.text("%@ were working and were left alone", "\(working)"))
        }
        if failed > 0 {
            parts.append(
                Localized.text("%@ did not go: %@", "\(failed)", reason ?? ""))
        }
        return parts.joined(separator: " · ")
    }
}

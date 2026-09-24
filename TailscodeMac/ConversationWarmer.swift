import CodingAgentKit
import Foundation
import TailscodeCore

/// A conversation started a moment before it is asked for.
///
/// Opening a chat used to begin when the click finished: a conversation was made, its transcript
/// read from disk and asked for over the tailnet, and the pane said Loading… for as long as that
/// took. A pointer resting on a row is most of the way to a click, and a button going down on one
/// is a click that has not finished yet, so either starts the conversation there and then, and the
/// pane that opens it a moment later finds the words already in it. A warm conversation nobody
/// takes lets go of its server after a while, and only a few are ever held at once.
@MainActor
final class ConversationWarmer {
    static let shared = ConversationWarmer()

    private struct Held {
        let conversation: AgentConversation
        let listening: Task<Void, Never>
        let expiry: Task<Void, Never>
    }

    private var held: [String: Held] = [:]
    private var order: [String] = []
    /// Enough for a pointer that wavers between two rows and settles on a third.
    private static let limit = 3
    /// Long enough for a hesitation, short enough that a list skimmed on the way to somewhere else
    /// leaves nothing listening to its servers.
    private static let patience: Duration = .seconds(20)

    func warm(_ entry: SessionEntry, backend: any CodingAgentBackend) {
        let key = SessionPinStore.key(entry.profileID, entry.session.id)
        guard held[key] == nil else { return }
        let conversation = AgentConversation(
            backend: backend, sessionID: entry.session.id, cache: AppCache.sessionCache)
        let listening = Task {
            for await _ in await conversation.states() {}
        }
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: Self.patience)
            guard !Task.isCancelled else { return }
            self?.drop(key)
        }
        held[key] = Held(conversation: conversation, listening: listening, expiry: expiry)
        order.append(key)
        while order.count > Self.limit, let oldest = order.first {
            drop(oldest)
        }
    }

    /// The conversation warmed for this chat, handed over once. The warming listener stays a moment
    /// longer, so the conversation never has nobody listening between the hand-over and its new
    /// owner's own subscription — which would stop it and throw away what it had already read.
    func take(_ entry: SessionEntry) -> AgentConversation? {
        let key = SessionPinStore.key(entry.profileID, entry.session.id)
        guard let taken = held.removeValue(forKey: key) else { return nil }
        order.removeAll { $0 == key }
        taken.expiry.cancel()
        let listening = taken.listening
        Task {
            try? await Task.sleep(for: .seconds(2))
            listening.cancel()
        }
        return taken.conversation
    }

    /// Whether a chat is warm, for a harness.
    func isWarm(_ entry: SessionEntry) -> Bool {
        held[SessionPinStore.key(entry.profileID, entry.session.id)] != nil
    }

    private func drop(_ key: String) {
        guard let dropped = held.removeValue(forKey: key) else { return }
        order.removeAll { $0 == key }
        dropped.listening.cancel()
        dropped.expiry.cancel()
    }
}

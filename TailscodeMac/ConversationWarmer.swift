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

    /// A warm chat is a glance-interest lease on the process's one conversation for it, so the pane
    /// that opens it a moment later takes the same conversation from the hub rather than a second
    /// one built beside it.
    private struct Held {
        let lease: LiveLease
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
        let (lease, _) = TileRuntime.shared.lease(
            entry, backend: backend, interest: .glance, dirty: {})
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: Self.patience)
            guard !Task.isCancelled else { return }
            self?.drop(key)
        }
        held[key] = Held(lease: lease, expiry: expiry)
        order.append(key)
        while order.count > Self.limit, let oldest = order.first {
            drop(oldest)
        }
    }

    /// The pane that opened this chat holds it now. The warm lease goes at once: the pane's own
    /// lease is already keeping the stream, so the conversation never has nobody listening.
    func handOver(_ entry: SessionEntry) {
        drop(SessionPinStore.key(entry.profileID, entry.session.id))
    }

    /// Whether a chat is warm, for a harness.
    func isWarm(_ entry: SessionEntry) -> Bool {
        held[SessionPinStore.key(entry.profileID, entry.session.id)] != nil
    }

    private func drop(_ key: String) {
        guard let dropped = held.removeValue(forKey: key) else { return }
        order.removeAll { $0 == key }
        dropped.lease.cancel()
        dropped.expiry.cancel()
    }
}

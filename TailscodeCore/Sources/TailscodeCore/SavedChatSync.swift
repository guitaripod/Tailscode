import CodingAgentKit
import Foundation

/// Tells the servers what this device decided about its bookmarks.
///
/// A bookmark is pressed in a list that is drawn from a cache and answers instantly, so the press
/// cannot wait on a server and must not be lost when there is no server to wait on. Every press
/// leaves a ``PendingSaveIntent`` behind and this drains them: a server that keeps bookmarks is
/// told, one that has no notion of them retires the intent unsent — the mark stays on the device,
/// which is where it has always lived — and a server that could not be reached keeps its intent
/// for the next listing, where it outranks whatever the listing says.
public enum SavedChatSync {
    public enum Outcome: Sendable {
        /// The server took the mark.
        case delivered
        /// The server has no notion of a bookmark, and never will have for this conversation.
        case unsupported
        /// Nobody answered. The intent stays, and outranks the listing until somebody does.
        case unreachable
    }

    /// Drains every undelivered decision, oldest first, so two presses on the same conversation
    /// reach the server in the order they were made.
    ///
    /// - Parameter push: delivers one intent, or says why it could not be delivered. A profile the
    ///   caller no longer has answers `.unsupported`, which is how a disconnected server's leftover
    ///   intents are cleared rather than retried forever.
    /// - Returns: whether anything was delivered, which is the caller's cue to re-read the listing.
    @discardableResult
    public static func drain(_ push: (PendingSaveIntent) async -> Outcome) async -> Bool {
        let intents = SavedChatStore.pending().sorted { $0.at < $1.at }
        guard !intents.isEmpty else { return false }
        var delivered = false
        for intent in intents {
            switch await push(intent) {
            case .delivered:
                delivered = true
                SavedChatStore.forget(profileID: intent.profileID, sessionID: intent.sessionID)
            case .unsupported:
                SavedChatStore.forget(profileID: intent.profileID, sessionID: intent.sessionID)
            case .unreachable:
                continue
            }
        }
        return delivered
    }
}

extension SavedChatSync {
    /// The ordinary drain, over the servers a client already holds. A profile it no longer has, or
    /// one whose backend keeps no bookmarks, retires its intents rather than holding them forever;
    /// anything that could plausibly work on a second attempt (``AgentError/isRetryable``) is kept.
    @discardableResult
    public static func drain(
        backendFor: @Sendable (String) async -> (any CodingAgentBackend)?
    ) async -> Bool {
        await drain { intent in
            guard let backend = await backendFor(intent.profileID),
                backend.capabilities.supportsSavedChats
            else { return .unsupported }
            do {
                try await backend.setSessionSaved(intent.sessionID, saved: intent.saved)
                return .delivered
            } catch let error as AgentError {
                return error.isRetryable ? .unreachable : .unsupported
            } catch {
                return .unreachable
            }
        }
    }
}

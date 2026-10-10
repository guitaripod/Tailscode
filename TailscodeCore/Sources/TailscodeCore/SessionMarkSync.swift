import CodingAgentKit
import Foundation

/// Tells the servers what this device decided about its conversations, and promptly.
///
/// A mark is made in a list that answers from the device, so the press cannot wait on a server and
/// must not be lost when there is none in reach. Each press leaves an intent behind
/// (``MarkIntent``, or ``PendingSaveIntent`` for a bookmark); this delivers them — a second after
/// the last press, so a swipe down a list that marks twelve chats read is twelve requests in one
/// breath rather than twelve round trips on the main thread's heels, and again whenever a listing
/// lands. A server that keeps no marks retires the intent unsent and the mark stays on the device,
/// which is where it has always lived; a server that could not be reached keeps it for next time.
public final class SessionMarkSync: @unchecked Sendable {
    public static let shared = SessionMarkSync()

    public typealias BackendFor = @Sendable (String) async -> (any CodingAgentBackend)?

    private let lock = NSLock()
    private var backendFor: BackendFor?
    private var scheduled: Task<Void, Never>?

    /// Says how to reach the servers. Until a client does, a press only leaves its intent behind
    /// and the next listing's drain delivers it.
    public func configure(backendFor: @escaping BackendFor) {
        lock.lock()
        self.backendFor = backendFor
        lock.unlock()
        schedule(after: .seconds(2))
    }

    /// Asks for a drain soon. The first request in a burst sets the clock and the ones behind it
    /// ride along, so a press every second still reaches the server every second and a half.
    public func schedule(after delay: Duration = .milliseconds(1200)) {
        lock.lock()
        defer { lock.unlock() }
        guard backendFor != nil, scheduled == nil else { return }
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.run()
        }
    }

    private func run() async {
        guard let resolve = takeResolver() else { return }
        await Self.drain(backendFor: resolve)
    }

    private func takeResolver() -> BackendFor? {
        lock.lock()
        defer { lock.unlock() }
        scheduled = nil
        return backendFor
    }

    /// Delivers every undelivered decision, bookmarks and marks alike.
    /// - Returns: whether anything was delivered, which is the caller's cue to re-read the listing.
    @discardableResult
    public static func drain(backendFor: BackendFor) async -> Bool {
        let saved = await SavedChatSync.drain(backendFor: backendFor)
        let marks = await drain { intent in await deliver(intent, backendFor: backendFor) }
        return saved || marks
    }

    /// Delivers the marks one at a time, oldest first, so two presses on the same conversation
    /// reach the server in the order they were made.
    @discardableResult
    public static func drain(_ push: (MarkIntent) async -> SavedChatSync.Outcome) async -> Bool {
        let intents = MarkIntentStore.all().sorted { $0.at < $1.at }
        var delivered = false
        for intent in intents {
            switch await push(intent) {
            case .delivered:
                delivered = true
                MarkIntentStore.forget(intent, delivered: true)
            case .unsupported:
                MarkIntentStore.forget(intent)
            case .unreachable:
                continue
            }
        }
        return delivered
    }

    private static func deliver(_ intent: MarkIntent, backendFor: BackendFor) async
        -> SavedChatSync.Outcome
    {
        guard let profileID = intent.profileID ?? SessionOwners.profile(of: intent.sessionID)
        else { return .unreachable }
        guard let backend = await backendFor(profileID), backend.capabilities.supportsSessionMarks
        else { return .unsupported }
        do {
            try await backend.setSessionMarks(intent.sessionID, intent.change)
            return .delivered
        } catch let error as AgentError {
            return error.isRetryable ? .unreachable : .unsupported
        } catch {
            return .unreachable
        }
    }
}

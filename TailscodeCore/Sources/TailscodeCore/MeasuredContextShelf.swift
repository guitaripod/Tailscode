import CodingAgentKit
import Foundation

/// The window each conversation's agent last measured, kept so a Range sheet that is read again
/// every few seconds draws the measurement without asking for it again. Asked when a sheet opens
/// and again at most every half minute while it stays open; a conversation the server cannot
/// measure — a new chat with no transcript yet, an agent other than Claude — is asked again only
/// after a few minutes.
public final class MeasuredContextShelf: @unchecked Sendable {
    public static let shared = MeasuredContextShelf()

    public static let freshFor: TimeInterval = 30
    public static let cannotSayFor: TimeInterval = 300
    public static let didChange = Notification.Name("MeasuredContextShelf.didChange")

    private let lock = NSLock()
    private var held: [String: MeasuredContext] = [:]
    private var askedAt: [String: Date] = [:]
    private var cannotSay: [String: Date] = [:]

    public init() {}

    public func value(for sessionID: String) -> MeasuredContext? {
        lock.withLock { held[sessionID] }
    }

    /// Asks the backend again when the held measurement is older than ``freshFor``, and posts
    /// ``didChange`` with the session id when a new one arrives.
    public func refresh(_ backend: any CodingAgentBackend, sessionID: String, now: Date = Date()) async {
        guard let measuring = backend as? any ContextMeasuring else { return }
        let due = lock.withLock { () -> Bool in
            if let at = cannotSay[sessionID], now.timeIntervalSince(at) < Self.cannotSayFor { return false }
            if let at = askedAt[sessionID], now.timeIntervalSince(at) < Self.freshFor { return false }
            askedAt[sessionID] = now
            return true
        }
        guard due else { return }
        let answer: MeasuredContext?
        do {
            answer = try await measuring.measuredContext(for: sessionID)
        } catch {
            return
        }
        let changed = lock.withLock { () -> Bool in
            guard let answer else {
                cannotSay[sessionID] = now
                return held.removeValue(forKey: sessionID) != nil
            }
            defer { held[sessionID] = answer }
            return held[sessionID] != answer
        }
        if changed { NotificationCenter.default.post(name: Self.didChange, object: sessionID) }
    }
}

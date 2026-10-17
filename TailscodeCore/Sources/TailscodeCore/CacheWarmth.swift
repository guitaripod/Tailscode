import CodingAgentKit
import Foundation

/// Whether the provider is still holding this conversation's prompt cache, and what it costs to
/// find out it is not.
///
/// A prompt cache lives for a fixed time after it was last used, and every request that reads it
/// pushes the time out again. A conversation left alone past that time is read in full, at the
/// price of fresh input, by the next request. That is the one variable that decides what a send
/// costs and appears nowhere a person looks, so it is stated here: the lifetime is the server's
/// (the bridge reads it off the cache writes the CLI made, `MessageUsage.cacheLifetime` — an hour
/// on one machine and five minutes on another), the last use is when the last turn ended, and the
/// cost of going cold is said in tokens, never in money, because a conversation that is read again
/// at full price is a fact about the conversation and a price list is a fact about the provider.
public struct CacheWarmth: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case warm(remaining: TimeInterval)
        case cold(for: TimeInterval)
    }

    public let state: State
    public let lifetime: TimeInterval
    public let lastUse: Date
    /// What the next request re-reads in full once the cache has lapsed.
    public let tokens: Int

    /// A conversation smaller than this loses nothing worth a chip by going cold.
    public static let coldNewsFloor = 20_000
    /// Inside this the row says what is about to happen instead of just counting.
    public static let closingIn: TimeInterval = 600
    /// How far back to look for a message that says how long the cache lives.
    private static let lookback = 60

    public var isCold: Bool {
        if case .cold = state { return true }
        return false
    }

    public var remaining: TimeInterval? {
        if case .warm(let remaining) = state { return remaining }
        return nil
    }

    /// Cold and large enough that the next send will notice.
    public var coldIsNews: Bool { isCold && tokens >= Self.coldNewsFloor }

    /// Warm with little left, or cold: the states where a sentence is owed.
    public var needsWords: Bool {
        switch state {
        case .warm(let remaining): return remaining <= Self.closingIn && tokens >= Self.coldNewsFloor
        case .cold: return true
        }
    }

    /// How much of its lifetime is left, `0...1`, for the bar that counts it down.
    public var fractionLeft: Double {
        guard let remaining else { return 0 }
        return min(1, max(0, remaining / lifetime))
    }

    /// Nil while a turn is running (the request in flight is about to renew it), when the last
    /// turn did not use a cache at all, or when no message says how long it lives.
    public static func read(
        messages: [ChatMessage], isRunning: Bool, now: Date = Date()
    ) -> CacheWarmth? {
        guard !isRunning else { return nil }
        var latest: (message: ChatMessage, index: Int)?
        var lifetime: TimeInterval?
        for (offset, message) in messages.enumerated().reversed() {
            if messages.count - offset > lookback { break }
            guard message.role == .assistant, !message.isStreaming,
                let context = message.context, !context.isEmpty
            else { continue }
            if latest == nil {
                guard context.cacheRead + context.cacheWrite > 0 else { return nil }
                latest = (message, offset)
            }
            if let seen = context.cacheLifetime {
                lifetime = seen
                break
            }
        }
        guard let latest, let lifetime, let context = latest.message.context else { return nil }
        let lastUse = endOfTurn(of: latest.message, at: latest.index, in: messages)
        let elapsed = max(0, now.timeIntervalSince(lastUse))
        let state: State =
            elapsed < lifetime ? .warm(remaining: lifetime - elapsed) : .cold(for: elapsed - lifetime)
        return CacheWarmth(state: state, lifetime: lifetime, lastUse: lastUse, tokens: context.read)
    }

    /// When a turn's last request went out: the moment it was stamped complete where the backend
    /// stamps that, otherwise the prompt that began it plus how long the server measured the turn
    /// to take. A message's own creation time is when its first words arrived, which for a long
    /// turn is minutes before its last request — reading the cache as colder than it is by that
    /// much is a lie in the harmless direction, and still a lie, so it is the last resort.
    static func endOfTurn(of message: ChatMessage, at index: Int, in messages: [ChatMessage]) -> Date {
        if let completed = message.completedAt { return completed }
        guard let duration = message.duration, duration > 0 else { return message.createdAt }
        var cursor = index - 1
        while cursor >= 0 {
            if messages[cursor].role == .user {
                return max(message.createdAt, messages[cursor].createdAt.addingTimeInterval(duration))
            }
            cursor -= 1
        }
        return message.createdAt.addingTimeInterval(duration)
    }
}

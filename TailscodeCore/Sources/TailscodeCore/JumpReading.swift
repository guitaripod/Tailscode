import Foundation

/// What the jump-to-the-end control says, so it can carry the one thing worth knowing about the
/// part of the conversation the reader is not looking at.
///
/// A bare arrow answers "take me down". It cannot say that an approval is waiting there — the
/// fact that stops the whole turn — or that eleven rows arrived while the reader was a screen
/// up, so a needs-you card two screens below was only discoverable by scrolling to find out. The
/// control is the same one on every client; only its words and its tone change.
public struct JumpReading: Sendable, Equatable {
    public enum Cause: Sendable, Equatable {
        case plain
        case news(Int)
        case needsYou
    }

    public let cause: Cause

    public init(cause: Cause) { self.cause = cause }

    /// Nil for the bare arrow.
    public var label: String? {
        switch cause {
        case .plain: return nil
        case .news(let count): return Localized.text("%d new", count)
        case .needsYou: return Localized.text("Needs you")
        }
    }

    /// Attention only for what blocks the turn; arrivals are quiet news.
    public var tone: ActivityTone {
        if case .needsYou = cause { return .attention }
        return .quiet
    }

    public var spoken: String {
        switch cause {
        case .plain: return Localized.text("Jump to the newest")
        case .news(let count):
            return Localized.text("Jump to the newest, %d new", count)
        case .needsYou: return Localized.text("Jump to what needs you")
        }
    }

    /// - Parameters:
    ///   - rowsNow: how many rows the transcript holds.
    ///   - rowsAtDeparture: how many it held when the reader last left the end, nil when they
    ///     never have.
    ///   - needsYou: a permission or a question is waiting at the end.
    public static func read(rowsNow: Int, rowsAtDeparture: Int?, needsYou: Bool) -> JumpReading {
        if needsYou { return JumpReading(cause: .needsYou) }
        guard let rowsAtDeparture, rowsNow > rowsAtDeparture else {
            return JumpReading(cause: .plain)
        }
        return JumpReading(cause: .news(rowsNow - rowsAtDeparture))
    }
}

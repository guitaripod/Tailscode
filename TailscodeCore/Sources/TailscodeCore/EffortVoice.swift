import CodingAgentKit
import Foundation

/// What one step of the effort dial amounted to. Every client states it the same way and only to a
/// reader who cannot see the pill: the pill's word and bars move for everyone else, so a step is
/// never drawn as text.
public struct EffortNotch: Sendable, Equatable {
    public let level: String?
    public let moved: Bool
    public let direction: Int

    public init(level: String?, moved: Bool, direction: Int) {
        self.level = level
        self.moved = moved
        self.direction = direction
    }

    /// The words a screen reader hears: the level a step landed on, or that it is already the
    /// hottest or the coldest the model takes.
    public var spoken: String {
        let landed = ModelDial.stepped(to: level)
        guard !moved, level != nil else { return landed }
        return direction > 0
            ? Localized.text("%@, the highest level", landed)
            : Localized.text("%@, the lowest level", landed)
    }
}

/// The one voice of the effort dial. A key held down steps many times a second, and a screen
/// reader that is told about each of them is a screen reader that has not finished saying the
/// first when the last arrives; so a step is held for ``settle`` and replaced by the next, and
/// what is spoken is where the hand stopped — once, whether it stopped between levels or leaning
/// on the end of the ladder.
public final class EffortVoice: @unchecked Sendable {
    public static let settle: TimeInterval = 0.4

    public typealias Sleeper = @Sendable (TimeInterval) async -> Void

    private let delay: TimeInterval
    private let sleeper: Sleeper
    private let speak: @Sendable (String) -> Void
    private let lock = NSLock()
    private var generation = 0

    /// `sleeper` is the wait between a step and its announcement: a clock in production, a hand
    /// the test turns when it needs the pause to be over without watching a wall clock.
    public init(
        settle: TimeInterval = EffortVoice.settle,
        sleeper: @escaping Sleeper = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        speak: @escaping @Sendable (String) -> Void
    ) {
        self.delay = settle
        self.sleeper = sleeper
        self.speak = speak
    }

    public func note(_ notch: EffortNotch) {
        let words = notch.spoken
        lock.lock()
        generation += 1
        let mine = generation
        lock.unlock()
        Task.detached { [delay, sleeper, speak, weak self] in
            await sleeper(delay)
            guard let self, self.isCurrent(mine) else { return }
            speak(words)
        }
    }

    private func isCurrent(_ mine: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == mine
    }
}

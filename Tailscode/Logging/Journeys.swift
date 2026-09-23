import CodingAgentKit
import Foundation

/// The wait between sending a prompt and seeing the answer begin, which is the one a person
/// feels on every turn. Timed from the press, on this device's clock, to the first state that
/// shows the agent's reply carrying anything at all, and written to the log, so a slow day has a
/// number instead of an impression.
struct FirstAnswerClock {
    private var sentAt: ContinuousClock.Instant?
    private var promptsBefore = 0

    mutating func sent(promptsBefore: Int) {
        sentAt = .now
        self.promptsBefore = promptsBefore
    }

    /// The milliseconds the answer took to begin, the first time `state` shows it has.
    mutating func answered(_ state: ConversationState) -> Int? {
        guard let sentAt else { return nil }
        guard state.messages.count(where: { $0.role == .user }) > promptsBefore,
            Self.answerHasBegun(state.messages)
        else { return nil }
        self.sentAt = nil
        return Self.milliseconds(since: sentAt)
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Whether the reply after the newest prompt has put anything on the page.
    private static func answerHasBegun(_ messages: [ChatMessage]) -> Bool {
        for message in messages.reversed() {
            if message.role == .user { return false }
            guard message.role == .assistant else { continue }
            let begun = message.parts.contains { part in
                switch part.kind {
                case .text(let text), .reasoning(let text): return !text.isEmpty
                case .tool, .file, .compaction: return true
                case .unknown: return false
                }
            }
            if begun { return true }
        }
        return false
    }
}

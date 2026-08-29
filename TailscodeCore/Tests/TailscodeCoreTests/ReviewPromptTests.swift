import Foundation
import Testing

@testable import TailscodeCore

/// Nested under `DeviceStores` on purpose: every device-local store shares one
/// `UserDefaults`, and corelibs' is not safe to write from two threads at once, so a
/// suite that writes one has to be serialized against every other suite that does.
extension DeviceStores {
    @Suite("Review prompt policy", .serialized)
    struct ReviewPromptTests {
        private static let keys = [
            ReviewPromptPolicy.turnsKey,
            ReviewPromptPolicy.lastAskedKey,
        ]

        private func withCleanStore(_ body: () -> Void) {
            let defaults = UserDefaults.standard
            let previous = Self.keys.map { ($0, defaults.object(forKey: $0)) }
            for key in Self.keys { defaults.removeObject(forKey: key) }
            body()
            for (key, value) in previous {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        private static func seed(turns: Int) {
            UserDefaults.standard.set(turns, forKey: ReviewPromptPolicy.turnsKey)
        }

        @Test("Below the turn threshold nothing is due, and every success still counts")
        func turnThreshold() {
            withCleanStore {
                let now = Date()
                for _ in 1..<ReviewPromptPolicy.minimumTurns {
                    #expect(!ReviewPromptPolicy.recordSuccessfulTurn(now: now))
                }
                #expect(ReviewPromptPolicy.successfulTurns == ReviewPromptPolicy.minimumTurns - 1)
                #expect(ReviewPromptPolicy.recordSuccessfulTurn(now: now))
            }
        }

        @Test("A brand-new install is due the moment enough turns have succeeded")
        func noAgeGate() {
            withCleanStore {
                Self.seed(turns: ReviewPromptPolicy.minimumTurns - 1)
                #expect(ReviewPromptPolicy.recordSuccessfulTurn(now: Date()))
            }
        }

        @Test("One ask per cooldown, then the gate opens again")
        func cooldown() {
            withCleanStore {
                let now = Date()
                Self.seed(turns: ReviewPromptPolicy.minimumTurns)
                #expect(ReviewPromptPolicy.recordSuccessfulTurn(now: now))
                ReviewPromptPolicy.markAsked(now: now)
                #expect(
                    !ReviewPromptPolicy.recordSuccessfulTurn(
                        now: now.addingTimeInterval(ReviewPromptPolicy.askCooldown - 60)))
                #expect(
                    ReviewPromptPolicy.recordSuccessfulTurn(
                        now: now.addingTimeInterval(ReviewPromptPolicy.askCooldown + 60)))
            }
        }

        @Test("A trophy waives the turn count entirely, but not the cooldown")
        func trophyWaivesTurns() {
            withCleanStore {
                let now = Date()
                #expect(ReviewPromptPolicy.noteTrophyEarned(now: now))
                ReviewPromptPolicy.markAsked(now: now)
                #expect(!ReviewPromptPolicy.noteTrophyEarned(now: now.addingTimeInterval(60)))
            }
        }

        @Test("Returning to finished work is due after two successful turns, not five")
        func returnToFinishedWork() {
            withCleanStore {
                let now = Date()
                #expect(!ReviewPromptPolicy.noteReturnedToFinishedWork(now: now))
                Self.seed(turns: ReviewPromptPolicy.minimumTurnsForReturn - 1)
                #expect(!ReviewPromptPolicy.noteReturnedToFinishedWork(now: now))
                Self.seed(turns: ReviewPromptPolicy.minimumTurnsForReturn)
                #expect(ReviewPromptPolicy.noteReturnedToFinishedWork(now: now))
                #expect(!ReviewPromptPolicy.recordSuccessfulTurn(now: now))
                ReviewPromptPolicy.markAsked(now: now)
                #expect(!ReviewPromptPolicy.noteReturnedToFinishedWork(now: now.addingTimeInterval(60)))
            }
        }
    }
}

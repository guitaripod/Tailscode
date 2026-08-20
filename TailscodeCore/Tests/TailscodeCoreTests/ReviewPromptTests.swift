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
            ReviewPromptPolicy.installedAtKey,
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

        private static func install(_ age: TimeInterval, turns: Int) -> Date {
            let now = Date()
            UserDefaults.standard.set(now.timeIntervalSince1970 - age, forKey: ReviewPromptPolicy.installedAtKey)
            UserDefaults.standard.set(turns, forKey: ReviewPromptPolicy.turnsKey)
            return now
        }

        @Test("Below the turn threshold nothing is due, and every success still counts")
        func turnThreshold() {
            withCleanStore {
                let now = Self.install(ReviewPromptPolicy.minimumAge + 60, turns: 0)
                #expect(!ReviewPromptPolicy.recordSuccessfulTurn(now: now))
                #expect(!ReviewPromptPolicy.recordSuccessfulTurn(now: now))
                #expect(ReviewPromptPolicy.successfulTurns == 2)
                #expect(ReviewPromptPolicy.recordSuccessfulTurn(now: now))
            }
        }

        @Test("A young install is not due even past the turn threshold")
        func ageGate() {
            withCleanStore {
                let now = Self.install(60, turns: ReviewPromptPolicy.minimumTurns)
                #expect(!ReviewPromptPolicy.recordSuccessfulTurn(now: now))
            }
        }

        @Test("The first success anchors the install date once and never again")
        func installAnchor() {
            withCleanStore {
                let anchored = Date(timeIntervalSince1970: 1_000)
                let later = anchored.addingTimeInterval(90 * 24 * 60 * 60)
                ReviewPromptPolicy.recordSuccessfulTurn(now: anchored)
                ReviewPromptPolicy.recordSuccessfulTurn(now: later)
                #expect(ReviewPromptPolicy.installedAt == anchored)
            }
        }

        @Test("One ask per cooldown, then the gate opens again")
        func cooldown() {
            withCleanStore {
                let now = Self.install(
                    ReviewPromptPolicy.minimumAge + 60, turns: ReviewPromptPolicy.minimumTurns)
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

        @Test("A trophy waives the turn count but never the age gate")
        func trophyWaivesTurns() {
            withCleanStore {
                let now = Self.install(
                    ReviewPromptPolicy.minimumAge + 60, turns: ReviewPromptPolicy.minimumTurns - 1)
                #expect(ReviewPromptPolicy.noteTrophyEarned(now: now))

                let young = Self.install(60, turns: ReviewPromptPolicy.minimumTurns)
                #expect(!ReviewPromptPolicy.noteTrophyEarned(now: young))
            }
        }

        @Test("Without an install anchor a trophy is not due")
        func noAnchor() {
            withCleanStore {
                #expect(!ReviewPromptPolicy.noteTrophyEarned(now: Date()))
            }
        }
    }
}

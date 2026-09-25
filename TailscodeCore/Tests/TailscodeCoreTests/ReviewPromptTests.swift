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
            ReviewPromptPolicy.successCountKey,
            ReviewPromptPolicy.askDatesKey,
            ReviewPromptPolicy.successCountAtLastAskKey,
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

        private static func seed(successes: Int) {
            UserDefaults.standard.set(successes, forKey: ReviewPromptPolicy.successCountKey)
        }

        @Test("Nothing is due at one success")
        func noAskAtOneSuccess() {
            withCleanStore {
                #expect(!ReviewPromptPolicy.recordSuccess(now: Date()))
                #expect(ReviewPromptPolicy.successCount == 1)
            }
        }

        @Test("The first ask is due the moment a second success lands")
        func askAtTwoSuccesses() {
            withCleanStore {
                let now = Date()
                #expect(!ReviewPromptPolicy.recordSuccess(now: now))
                #expect(ReviewPromptPolicy.recordSuccess(now: now))
            }
        }

        @Test("No re-ask before fourteen days, even with successes to spare")
        func noReaskBeforeCooldown() {
            withCleanStore {
                let now = Date()
                Self.seed(successes: 2)
                ReviewPromptPolicy.markAsked(now: now)
                #expect(
                    !ReviewPromptPolicy.recordSuccess(
                        now: now.addingTimeInterval(13 * 24 * 60 * 60)))
                Self.seed(successes: ReviewPromptPolicy.successCount + 10)
                #expect(
                    !ReviewPromptPolicy.recordSuccess(
                        now: now.addingTimeInterval(13 * 24 * 60 * 60)))
            }
        }

        @Test("No re-ask before three fresh successes, even once fourteen days have passed")
        func noReaskBeforeFreshSuccesses() {
            withCleanStore {
                let now = Date()
                Self.seed(successes: 2)
                ReviewPromptPolicy.markAsked(now: now)
                let later = now.addingTimeInterval(20 * 24 * 60 * 60)
                #expect(!ReviewPromptPolicy.recordSuccess(now: later))
                #expect(!ReviewPromptPolicy.recordSuccess(now: later))
            }
        }

        @Test("A re-ask is due once both the cooldown and three fresh successes have passed")
        func reaskAfterBothGatesClear() {
            withCleanStore {
                let now = Date()
                Self.seed(successes: 2)
                ReviewPromptPolicy.markAsked(now: now)
                let later = now.addingTimeInterval(15 * 24 * 60 * 60)
                #expect(!ReviewPromptPolicy.recordSuccess(now: later))
                #expect(!ReviewPromptPolicy.recordSuccess(now: later))
                #expect(ReviewPromptPolicy.recordSuccess(now: later))
            }
        }

        @Test("Never a fourth ask inside the same rolling year")
        func neverAFourthAskWithinAYear() {
            withCleanStore {
                let start = Date()
                Self.seed(successes: 2)
                #expect(ReviewPromptPolicy.recordSuccess(now: start))
                ReviewPromptPolicy.markAsked(now: start)

                var when = start
                for _ in 0..<2 {
                    when = when.addingTimeInterval(15 * 24 * 60 * 60)
                    #expect(!ReviewPromptPolicy.recordSuccess(now: when))
                    #expect(!ReviewPromptPolicy.recordSuccess(now: when))
                    #expect(ReviewPromptPolicy.recordSuccess(now: when))
                    ReviewPromptPolicy.markAsked(now: when)
                }
                #expect(ReviewPromptPolicy.askDates.count == 3)

                Self.expectCappedRegardlessOfFreshSuccesses(
                    now: start.addingTimeInterval(300 * 24 * 60 * 60))
            }
        }

        /// Plenty of fresh successes and the cooldown both clear at this point, but three asks
        /// already sit inside the trailing year, so a fourth stays refused regardless of how
        /// many more successes land.
        private static func expectCappedRegardlessOfFreshSuccesses(now: Date) {
            for _ in 0..<5 {
                #expect(!ReviewPromptPolicy.recordSuccess(now: now))
            }
        }

        @Test("A fourth ask is allowed once the oldest of the three ages out of the year")
        func fourthAskOnceOldestAgesOut() {
            withCleanStore {
                let start = Date()
                Self.seed(successes: 2)
                #expect(ReviewPromptPolicy.recordSuccess(now: start))
                ReviewPromptPolicy.markAsked(now: start)

                var when = start
                for _ in 0..<2 {
                    when = when.addingTimeInterval(15 * 24 * 60 * 60)
                    #expect(!ReviewPromptPolicy.recordSuccess(now: when))
                    #expect(!ReviewPromptPolicy.recordSuccess(now: when))
                    #expect(ReviewPromptPolicy.recordSuccess(now: when))
                    ReviewPromptPolicy.markAsked(now: when)
                }
                #expect(ReviewPromptPolicy.askDates.count == 3)

                Self.expectDueOnceCooldownAndFreshSuccessesClear(
                    now: start.addingTimeInterval(366 * 24 * 60 * 60))
            }
        }

        /// The oldest of the three (`start`) is now more than a year back, so the cap no longer
        /// counts it — but the ordinary cooldown and fresh-success floor still apply on top of
        /// that, measured from the third ask.
        private static func expectDueOnceCooldownAndFreshSuccessesClear(now: Date) {
            #expect(!ReviewPromptPolicy.recordSuccess(now: now))
            #expect(!ReviewPromptPolicy.recordSuccess(now: now))
            #expect(ReviewPromptPolicy.recordSuccess(now: now))
        }

        private static let legacyTurnsKey = "tailscode.review.successfulTurns"
        private static let legacyLastAskedKey = "tailscode.review.lastAsked"

        @Test("Migrating from the old mechanism carries the count over and the old ask counts toward the cap")
        func migratesFromLegacyKeys() {
            withCleanStore {
                let defaults = UserDefaults.standard
                let askedAt = Date().addingTimeInterval(-10 * 24 * 60 * 60)
                defaults.set(7, forKey: Self.legacyTurnsKey)
                defaults.set(askedAt.timeIntervalSince1970, forKey: Self.legacyLastAskedKey)
                defer {
                    defaults.removeObject(forKey: Self.legacyTurnsKey)
                    defaults.removeObject(forKey: Self.legacyLastAskedKey)
                }

                ReviewPromptPolicy.migrateIfNeeded()

                #expect(ReviewPromptPolicy.successCount == 7)
                #expect(ReviewPromptPolicy.askDates.count == 1)
                #expect(
                    abs(
                        ReviewPromptPolicy.askDates[0].timeIntervalSince1970
                            - askedAt.timeIntervalSince1970) < 1)
                #expect(defaults.object(forKey: Self.legacyTurnsKey) == nil)
                #expect(defaults.object(forKey: Self.legacyLastAskedKey) == nil)
                Self.expectMigratedAskCountsTowardCooldown(askedAt: askedAt)
            }
        }

        /// The migrated ask is a real ask, not a fresh install's clean slate: ten days past it,
        /// still inside the fourteen-day cooldown, nothing is due even with successes to spare.
        private static func expectMigratedAskCountsTowardCooldown(askedAt: Date) {
            #expect(
                !ReviewPromptPolicy.recordSuccess(now: askedAt.addingTimeInterval(10 * 24 * 60 * 60)))
        }
    }
}

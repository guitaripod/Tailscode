import Foundation
import Testing

@testable import TailscodeCore

extension DeviceStores {
    @Suite("Pro invitation", .serialized)
    struct ProInvitationTests {
        private static let keys = [
            ProInvitation.turnsKey, ProInvitation.settledKey, ProInvitation.legacyTurnsKey, ProInvitation.legacySettledKey,
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

        private func turns(_ count: Int) {
            for _ in 0..<count { ProInvitation.recordSuccessfulTurn() }
        }

        @Test("Due exactly at the turn threshold and not one turn before")
        func threshold() {
            withCleanStore {
                turns(ProInvitation.minimumTurns - 1)
                #expect(!ProInvitation.isDue(isPro: false))
                turns(1)
                #expect(ProInvitation.isDue(isPro: false))
                #expect(ProInvitation.successfulTurns == ProInvitation.minimumTurns)
            }
        }

        @Test("Never due while Pro is open")
        func proHeld() {
            withCleanStore {
                turns(ProInvitation.minimumTurns + 5)
                #expect(!ProInvitation.isDue(isPro: true))
            }
        }

        @Test("Not now ends it for good, whatever comes after")
        func dismissal() {
            withCleanStore {
                turns(ProInvitation.minimumTurns)
                ProInvitation.dismiss()
                #expect(ProInvitation.isSettled)
                #expect(!ProInvitation.isDue(isPro: false))
                turns(50)
                #expect(!ProInvitation.isDue(isPro: false))
                #expect(ProInvitation.successfulTurns == ProInvitation.minimumTurns)
            }
        }

        @Test("A purchase or the week taken up settles it even before it was ever due")
        func settling() {
            withCleanStore {
                turns(2)
                ProInvitation.settle()
                turns(ProInvitation.minimumTurns)
                #expect(!ProInvitation.isDue(isPro: false))
            }
        }

        @Test("The keys are its own, not the review prompt's, and nothing is called supporter")
        func ownKeys() {
            #expect(ProInvitation.turnsKey != ReviewPromptPolicy.successCountKey)
            #expect(!ProInvitation.turnsKey.contains("supporter"))
            #expect(!ProInvitation.settledKey.contains("supporter"))
            #expect(!ProInvitation.didChange.rawValue.contains("supporter"))
        }

        @Test("A card set aside under the old keys stays set aside, and the old keys go")
        func earlierDismissalStands() {
            withCleanStore {
                let defaults = UserDefaults.standard
                defaults.set(12, forKey: ProInvitation.legacyTurnsKey)
                defaults.set(true, forKey: ProInvitation.legacySettledKey)

                #expect(ProInvitation.isSettled)
                #expect(!ProInvitation.isDue(isPro: false))
                #expect(ProInvitation.successfulTurns == 12)
                #expect(defaults.object(forKey: ProInvitation.legacyTurnsKey) == nil)
                #expect(defaults.object(forKey: ProInvitation.legacySettledKey) == nil)
            }
        }

        @Test("Turns counted under the old key still count toward the card")
        func earlierTurnsCount() {
            withCleanStore {
                UserDefaults.standard.set(ProInvitation.minimumTurns - 1, forKey: ProInvitation.legacyTurnsKey)

                #expect(!ProInvitation.isDue(isPro: false))
                turns(1)
                #expect(ProInvitation.isDue(isPro: false))
                #expect(ProInvitation.successfulTurns == ProInvitation.minimumTurns)
            }
        }

        @Test("The old keys never overwrite what the new ones already hold")
        func newKeysWin() {
            withCleanStore {
                let defaults = UserDefaults.standard
                defaults.set(3, forKey: ProInvitation.turnsKey)
                defaults.set(40, forKey: ProInvitation.legacyTurnsKey)
                defaults.set(false, forKey: ProInvitation.legacySettledKey)

                #expect(ProInvitation.successfulTurns == 3)
                #expect(!ProInvitation.isSettled)
            }
        }

        @Test("A copy that can still start its week is handed the week, any other is told what Pro does")
        func gift() {
            #expect(ProInvitation.gift(canStartWeek: true) == .week)
            #expect(ProInvitation.gift(canStartWeek: false) == .pro)
        }

        @Test("The week's card carries the week's whole terms and its own start button")
        func weekCard() {
            #expect(ProInvitation.body(.week) == ProWeek.offerBody)
            #expect(ProInvitation.primaryAction(.week, price: nil) == ProWeek.startTitle)
            #expect(ProInvitation.primaryAction(.week, price: "$14.99") == ProWeek.startTitle)
        }

        @Test("The Pro card names the unlock, with the price only when the store gave one")
        func proCard() {
            #expect(ProInvitation.primaryAction(.pro, price: nil) == ProOffer.title)
            #expect(ProInvitation.primaryAction(.pro, price: "$14.99").contains("$14.99"))
            #expect(ProInvitation.primaryAction(.pro, price: "$14.99").hasPrefix(ProOffer.title))
            #expect(ProInvitation.body(.pro).contains("every machine on your tailnet"))
        }

        @Test("The title counts the person's turns, or says what Pro is without enough of them")
        func title() {
            #expect(ProInvitation.title(ProPersonalDetails.Facts(turns: 37)) == "37 turns finished with your agents")
            #expect(ProInvitation.title(ProPersonalDetails.Facts(turns: 3)) == ProOffer.headline)
        }
    }
}

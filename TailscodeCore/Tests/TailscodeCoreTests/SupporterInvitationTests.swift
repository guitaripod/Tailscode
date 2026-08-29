import Foundation
import Testing

@testable import TailscodeCore

extension DeviceStores {
    @Suite("Supporter invitation", .serialized)
    struct SupporterInvitationTests {
        private static let keys = [SupporterInvitation.turnsKey, SupporterInvitation.settledKey]

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
            for _ in 0..<count { SupporterInvitation.recordSuccessfulTurn() }
        }

        @Test("Due exactly at the turn threshold and not one turn before")
        func threshold() {
            withCleanStore {
                turns(SupporterInvitation.minimumTurns - 1)
                #expect(!SupporterInvitation.isDue(isPro: false))
                turns(1)
                #expect(SupporterInvitation.isDue(isPro: false))
                #expect(SupporterInvitation.successfulTurns == SupporterInvitation.minimumTurns)
            }
        }

        @Test("Never due while Pro is held")
        func proHeld() {
            withCleanStore {
                turns(SupporterInvitation.minimumTurns + 5)
                #expect(!SupporterInvitation.isDue(isPro: true))
            }
        }

        @Test("Not now ends it for good, whatever comes after")
        func dismissal() {
            withCleanStore {
                turns(SupporterInvitation.minimumTurns)
                SupporterInvitation.dismiss()
                #expect(SupporterInvitation.isSettled)
                #expect(!SupporterInvitation.isDue(isPro: false))
                turns(50)
                #expect(!SupporterInvitation.isDue(isPro: false))
                #expect(SupporterInvitation.successfulTurns == SupporterInvitation.minimumTurns)
            }
        }

        @Test("A purchase settles it even before it was ever due")
        func purchaseSettles() {
            withCleanStore {
                turns(2)
                SupporterInvitation.settle()
                turns(SupporterInvitation.minimumTurns)
                #expect(!SupporterInvitation.isDue(isPro: false))
            }
        }

        @Test("The keys are its own, not the review prompt's")
        func ownKeys() {
            #expect(SupporterInvitation.turnsKey != ReviewPromptPolicy.turnsKey)
        }

        @Test("The primary action carries the price only when the store gave one")
        func primaryAction() {
            #expect(SupporterInvitation.primaryAction(price: nil) == ProOffer.title)
            #expect(SupporterInvitation.primaryAction(price: "$14.99").contains("$14.99"))
            #expect(SupporterInvitation.primaryAction(price: "$14.99").hasPrefix(ProOffer.title))
        }
    }
}

import Foundation
import MidgarCommerce
import Testing
import TailscodeCore

@testable import Tailscode

/// What the Pro access model keeps that the purchase engine does not, and how a store failure reads.
@MainActor
struct ProAccessTests {
    private func freshDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "tailscode-tests-" + UUID().uuidString))
    }

    @Test func theStoreSellsProAndTheTipsAndOnlyProGrantsAnything() {
        let configuration = TailscodeMidgar.storeConfiguration()

        #expect(configuration.appID == "tailscode")
        #expect(
            configuration.productIDs == [
                "com.guitaripod.tailscode.pro",
                "com.guitaripod.tailscode.tip.small",
                "com.guitaripod.tailscode.tip.medium",
                "com.guitaripod.tailscode.tip.large",
            ])
        #expect(configuration.entitlementsByProduct == ["com.guitaripod.tailscode.pro": "pro"])
        #expect(configuration.mode == .purchases)
        #expect(configuration.crossAppEntitlements.isEmpty)
    }

    @Test func aLaunchWithoutANetworkOpensAsProFromTheCachedFlag() throws {
        let defaults = try freshDefaults()
        defaults.set(true, forKey: "tailscode.isPro")

        #expect(ProAccess(store: nil, sellsPro: true, defaults: defaults).isPro)
        #expect(!ProAccess(store: nil, sellsPro: true, defaults: try freshDefaults()).isPro)
    }

    @Test func aCopyThatSellsNothingIsUnlocked() throws {
        let access = ProAccess(store: nil, sellsPro: false, defaults: try freshDefaults())

        #expect(access.isPro)
        #expect(!access.sellsPro)
    }

    @Test func aStoreFailureBecomesASentenceAndACancelIsNotOne() {
        #expect(PurchaseFailure(.storeKit("networkError(NSURLErrorDomain -1009)")) == .unreachable)
        #expect(PurchaseFailure(.storeKit("notAvailableInStorefront")) == .notAvailableInStorefront)
        #expect(PurchaseFailure(.unknownProduct(ProOffer.productID)) == .notAvailableInStorefront)
        #expect(PurchaseFailure(.unverifiedTransaction(productID: ProOffer.productID)) == .unverified)
        #expect(PurchaseFailure(.storeKit("systemError")) == .other)
        #expect(PurchaseFailure(.readOnly) == .other)
        #expect(PurchaseFailure.isCancellation(.storeKit("userCancelled")))
        #expect(!PurchaseFailure.isCancellation(.unverifiedTransaction(productID: ProOffer.productID)))
        #expect(
            [PurchaseFailure.unreachable, .notAvailableInStorefront, .unverified, .other].allSatisfy {
                !($0.errorDescription ?? "").isEmpty
            })
    }
}

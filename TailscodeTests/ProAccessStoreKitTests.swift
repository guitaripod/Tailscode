import Foundation
import MidgarCommerce
import StoreKit
import StoreKitTest
import Testing
import TailscodeCore

@testable import Tailscode

/// Buys Pro and the tips through `ProAccess` on a `MidgarStore` with Tailscode's own configuration against
/// `Tailscode.storekit`, the file the scheme runs with, so the products, the entitlement map and the model
/// are checked together on a real StoreKit. StoreKit is process-wide, so the suite runs serially.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ProAccessStoreKitTests {
    private static let midgarToken = UUID(uuidString: StubIdentity.midgarID)

    /// How long a finished tip may still be listed as unfinished. StoreKit testing keeps a consumable
    /// bought through `MidgarStore` in `Transaction.unfinished` for about fifteen seconds after the store
    /// finished it, where a plain `Product.purchase` followed by `finish()` clears it at once.
    private static let finishAllowance = Duration.seconds(40)

    @Test func theConfigurationFileSellsExactlyTheProductsTheStoreHandles() throws {
        let file = try JSONDecoder().decode(
            StoreKitFile.self, from: Data(contentsOf: StoreHarness.storeKitFile))

        #expect(Set(file.products.map(\.productID)) == Set(TailscodeMidgar.storeConfiguration().productIDs))
    }

    @Test func buyingProGrantsProAndCarriesTheMidgarID() async throws {
        let harness = try StoreHarness()
        await harness.access.refreshEntitlements()
        #expect(!harness.access.isPro)

        #expect(try await harness.buy(ProOffer.productID) == .success)

        #expect(harness.access.isPro)
        #expect(harness.defaults.bool(forKey: "tailscode.isPro"))
        #expect(await harness.accountToken(of: ProOffer.productID) == Self.midgarToken)
        #expect(LedgerStub.reportCount == 0)
        await harness.store.stop()
    }

    @Test func anUnlockBoughtBeforeTheStoreExistedIsProAtLaunchWithoutARestore() async throws {
        let earlier = try StoreHarness()
        try earlier.session.buyProduct(productIdentifier: ProOffer.productID)
        await earlier.store.stop()

        let launched = try earlier.relaunched()
        #expect(!launched.access.isPro)
        await launched.access.refreshEntitlements()

        #expect(launched.access.isPro)
        await launched.store.stop()
    }

    @Test func restoreFindsAnEarlierPurchase() async throws {
        let harness = try StoreHarness()
        try harness.session.buyProduct(productIdentifier: ProOffer.productID)

        #expect(try await harness.access.restore() == .restored)

        #expect(harness.access.isPro)
        await harness.store.stop()
    }

    @Test func restoreWithNothingBoughtSaysSo() async throws {
        let harness = try StoreHarness()

        #expect(try await harness.access.restore() == .nothingFound)

        #expect(!harness.access.isPro)
        await harness.store.stop()
    }

    @Test func aDismissedSignInDuringRestoreIsACancelNotAnError() async throws {
        let harness = try StoreHarness()
        try await harness.session.setSimulatedError(.generic(.userCancelled), forAPI: .appStoreSync)

        #expect(try await harness.access.restore() == .cancelled)

        try await harness.session.setSimulatedError(nil, forAPI: .appStoreSync)
        await harness.store.stop()
    }

    @Test func theDeveloperUnlockHoldsWhateverTheStoreSays() async throws {
        let harness = try StoreHarness()
        let developer = ProAccess(
            store: harness.store, sellsPro: true, defaults: harness.defaults, debugUnlock: true)

        await developer.refreshEntitlements()

        #expect(developer.isPro)
        #expect(!harness.defaults.bool(forKey: "tailscode.isPro"))
        await harness.store.stop()
    }

    @Test func aRefundTakesProAwayWithoutAskingTheStoreAgain() async throws {
        let harness = try StoreHarness()
        harness.access.start()
        _ = try await harness.buy(ProOffer.productID)
        #expect(harness.access.isPro)
        let transaction = try #require(harness.session.allTransactions().first)

        try harness.session.refundTransaction(identifier: UInt(transaction.identifier))

        #expect(await eventually { !harness.access.isPro })
        await harness.store.stop()
    }

    @Test func askToBuyIsPendingUntilApprovedAndThenUnlocksByItself() async throws {
        let harness = try StoreHarness(askToBuy: true)
        harness.access.start()

        #expect(try await harness.buy(ProOffer.productID) == .pending)
        #expect(!harness.access.isPro)

        let pending = try #require(harness.session.allTransactions().first)
        try harness.session.approveAskToBuyTransaction(identifier: UInt(pending.identifier))

        #expect(await eventually { harness.access.isPro })
        await harness.store.stop()
    }

    @Test(arguments: ProOffer.tipIDs)
    func aTipIsBoughtAndFinishedAndGrantsNothing(_ tip: String) async throws {
        let harness = try StoreHarness()
        await harness.access.refreshEntitlements()

        #expect(try await harness.buy(tip) == .success)

        #expect(!harness.access.isPro)
        #expect(await harness.store.entitlements.isEmpty)
        #expect(await harness.accountToken(of: tip) == Self.midgarToken)
        #expect(
            await eventually(timeout: Self.finishAllowance) {
                !(await unfinishedProductIDs()).contains(tip)
            })
        await harness.store.stop()
    }

    @Test func aStoreFailureReachesTheScreenAsASentence() async throws {
        let harness = try StoreHarness()
        await harness.access.refreshEntitlements()

        try await harness.session.setSimulatedError(
            .generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .purchase)
        let failure = await #expect(throws: PurchaseFailure.self) {
            _ = try await harness.buy(ProOffer.productID)
        }

        let sentence = failure?.errorDescription ?? ""
        #expect(!sentence.isEmpty)
        #expect(!harness.access.isPro)
        try await harness.session.setSimulatedError(nil, forAPI: .purchase)
        await harness.store.stop()
    }

    @Test func aDismissedSheetIsACancelAndEveryOtherFailureIsASentence() async throws {
        let harness = try StoreHarness()

        let cancelled = try await harness.access.settle { _ in
            throw MidgarStoreError.storeKit("userCancelled")
        }
        let unverified = try await harness.access.settle { _ in
            throw MidgarStoreError.unverifiedTransaction(productID: ProOffer.productID)
        }
        let unreachable = await #expect(throws: PurchaseFailure.self) {
            _ = try await harness.access.settle { _ in
                throw MidgarStoreError.storeKit("networkError(NSURLErrorDomain -1009)")
            }
        }

        #expect(cancelled == .cancelled)
        #expect(unverified == .unverified)
        let sentence = unreachable?.errorDescription ?? ""
        #expect(unreachable == .unreachable)
        #expect(!sentence.isEmpty)
        #expect(!harness.access.isPro)
        await harness.store.stop()
    }

    private func unfinishedProductIDs() async -> [String] {
        var ids: [String] = []
        for await update in Transaction.unfinished {
            if case .verified(let transaction) = update { ids.append(transaction.productID) }
        }
        return ids
    }
}

/// The parts of a StoreKit configuration file the product check reads.
private struct StoreKitFile: Decodable {
    struct Item: Decodable {
        let productID: String
    }

    let products: [Item]
}

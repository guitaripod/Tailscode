import AppKit
import Foundation
import StoreKit
import os
import TailscodeCore

/// The Pro unlock on the Mac, which only one of the two Mac builds can have.
///
/// A purchase is a receipt, and a receipt comes from the App Store — the ad-hoc copy a person
/// installs themselves has no relationship with it and never will, so that build is simply
/// unlocked rather than pretending to sell something it cannot verify. The store copy is the one
/// that asks, and it asks for the same product identifier the phone does, so a person who has
/// already bought it on iPhone is a supporter here the moment they open the app.
@MainActor
final class MacProStore {
    static let shared = MacProStore()

    static let didChange = Notification.Name("MacProStore.didChange")

    enum PurchaseOutcome {
        case success, pending, cancelled, unverified
    }

    private static let cacheKey = "tailscode.isPro"
    private static let log = Logger(subsystem: "com.guitaripod.tailscode", category: "purchase")

    private(set) var isPro: Bool
    private var updatesTask: Task<Void, Never>?

    private init() {
        #if TAILSCODE_MAS
            isPro = UserDefaults.standard.bool(forKey: Self.cacheKey)
        #else
            isPro = true
        #endif
    }

    /// Whether this copy can sell anything. The direct build answers no, and every surface that
    /// would offer a purchase reads this rather than the compile flag.
    var sellsPro: Bool {
        #if TAILSCODE_MAS
            return true
        #else
            return false
        #endif
    }

    func start() {
        guard sellsPro else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self?.refreshEntitlements()
            }
        }
        Task { await refreshEntitlements() }
    }

    func refreshEntitlements() async {
        guard sellsPro else { return }
        var pro = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
                transaction.productID == ProOffer.productID, transaction.revocationDate == nil
            {
                pro = true
            }
        }
        setPro(pro)
    }

    private func setPro(_ value: Bool) {
        guard isPro != value else { return }
        isPro = value
        UserDefaults.standard.set(value, forKey: Self.cacheKey)
        Self.log.info("pro entitlement -> \(value)")
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func products() async -> (pro: Product?, tips: [Product]) {
        let all = (try? await Product.products(for: [ProOffer.productID] + ProOffer.tipIDs)) ?? []
        return (
            all.first { $0.id == ProOffer.productID },
            ProOffer.tipIDs.compactMap { id in all.first { $0.id == id } }
        )
    }

    func purchase(_ product: Product) async throws -> PurchaseOutcome {
        let result = try await product.purchase(confirmIn: NSApplication.shared.keyWindow ?? NSWindow())
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                Self.log.error("purchase of \(product.id) failed verification")
                return .unverified
            }
            await transaction.finish()
            if transaction.productID == ProOffer.productID { setPro(true) }
            return .success
        case .pending:
            Self.log.info("purchase of \(product.id) pending approval")
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func restore() async throws {
        try await AppStore.sync()
        await refreshEntitlements()
    }
}

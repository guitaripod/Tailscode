import Foundation
import StoreKit

/// StoreKit 2 entitlements for the one-time Pro unlock and the tip jar.
/// The app is open source — Pro is a convenience-and-support purchase, so
/// entitlement checks are honest gates, not obfuscation.
@MainActor
final class ProStore {
    static let shared = ProStore()

    static let proID = "com.guitaripod.tailscode.pro"
    static let tipIDs = [
        "com.guitaripod.tailscode.tip.small",
        "com.guitaripod.tailscode.tip.medium",
        "com.guitaripod.tailscode.tip.large",
    ]

    static let didChange = Notification.Name("ProStore.didChange")

    enum PurchaseOutcome {
        case success, pending, cancelled, unverified
    }

    private static let cacheKey = "tailscode.isPro"

    private(set) var isPro: Bool
    private var updatesTask: Task<Void, Never>?

    /// Debug builds are Pro by default so the developer's own device is never
    /// gated; pass `--simulate-free` to exercise the paywall and gates.
    private init() {
        isPro = UserDefaults.standard.bool(forKey: Self.cacheKey)
        #if DEBUG
            if !CommandLine.arguments.contains("--simulate-free") { isPro = true }
        #endif
    }

    func start() {
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
        var pro = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
                transaction.productID == Self.proID, transaction.revocationDate == nil
            {
                pro = true
            }
        }
        setPro(pro)
    }

    private func setPro(_ value: Bool) {
        #if DEBUG
            if !CommandLine.arguments.contains("--simulate-free") { return }
        #endif
        guard isPro != value else { return }
        isPro = value
        UserDefaults.standard.set(value, forKey: Self.cacheKey)
        AppLogger.lifecycle.info("pro entitlement -> \(value)")
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func products() async -> (pro: Product?, tips: [Product]) {
        let all = (try? await Product.products(for: [Self.proID] + Self.tipIDs)) ?? []
        let pro = all.first { $0.id == Self.proID }
        let tips = Self.tipIDs.compactMap { id in all.first { $0.id == id } }
        return (pro, tips)
    }

    func purchase(_ product: Product) async throws -> PurchaseOutcome {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                AppLogger.lifecycle.error("purchase of \(product.id) failed verification")
                return .unverified
            }
            await transaction.finish()
            if transaction.productID == Self.proID { setPro(true) }
            return .success
        case .pending:
            AppLogger.lifecycle.info("purchase of \(product.id) pending approval")
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

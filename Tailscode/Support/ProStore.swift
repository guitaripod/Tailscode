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

    private static let cacheKey = "tailscode.isPro"

    private(set) var isPro: Bool
    var onChange: (() -> Void)?
    private var updatesTask: Task<Void, Never>?

    private init() {
        isPro = UserDefaults.standard.bool(forKey: Self.cacheKey)
        #if DEBUG
            if CommandLine.arguments.contains("--pro") { isPro = true }
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
            if CommandLine.arguments.contains("--pro") { return }
        #endif
        guard isPro != value else { return }
        isPro = value
        UserDefaults.standard.set(value, forKey: Self.cacheKey)
        AppLogger.lifecycle.info("pro entitlement -> \(value)")
        onChange?()
    }

    func products() async -> (pro: Product?, tips: [Product]) {
        let all = (try? await Product.products(for: [Self.proID] + Self.tipIDs)) ?? []
        let pro = all.first { $0.id == Self.proID }
        let tips = Self.tipIDs.compactMap { id in all.first { $0.id == id } }
        return (pro, tips)
    }

    /// Returns true when the purchase completed (verified and finished).
    func purchase(_ product: Product) async throws -> Bool {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { return false }
            await transaction.finish()
            if transaction.productID == Self.proID { setPro(true) }
            return true
        case .userCancelled, .pending:
            return false
        @unknown default:
            return false
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }
}

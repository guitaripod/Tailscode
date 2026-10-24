import Foundation
import MidgarCommerce
import MidgarCore
import Observation
import TailscodeCore

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Whether Pro is held, and the one way the iPhone app and the Mac app buy, tip and restore it.
///
/// The app is open source, so Pro is a convenience-and-support purchase and every check here is an honest
/// gate. The purchase engine is `MidgarStore`: it listens to `Transaction.updates`, finishes what it grants,
/// carries the Midgar ID as the `appAccountToken` and reports every purchase to the Midgar ledger. This
/// model reads `store.isEntitled(to: "pro")` and keeps three things the engine does not:
///
/// - A cached flag, so a launch without a network still opens as Pro until the engine has answered.
/// - A copy that sells nothing, the direct Mac build, which is unlocked rather than pretending to sell.
/// - A developer unlock for debug builds on the phone, switched off by `--simulate-free`.
@MainActor
@Observable
final class ProAccess {
    enum PurchaseOutcome: Sendable, Equatable {
        case success, pending, cancelled, unverified
    }

    enum RestoreOutcome: Sendable, Equatable {
        case restored, nothingFound, cancelled
    }

    static let shared = ProAccess(
        store: TailscodeMidgar.shared.store,
        sellsPro: TailscodeMidgar.sellsPro,
        debugUnlock: debugUnlockByDefault)

    static let didChange = Notification.Name("ProAccess.didChange")

    private static let cacheKey = "tailscode.isPro"

    /// Whether this copy can sell anything. Every surface that would offer a purchase reads this rather
    /// than the compile flag.
    let sellsPro: Bool

    private(set) var isPro: Bool

    @ObservationIgnored private let store: MidgarStore?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let debugUnlock: Bool
    @ObservationIgnored private var eventsTask: Task<Void, Never>?

    /// Debug builds on the phone are Pro by default so the developer's own device is never gated; pass
    /// `--simulate-free` to exercise the paywall and gates.
    static var debugUnlockByDefault: Bool {
        #if DEBUG && os(iOS)
            return !CommandLine.arguments.contains("--simulate-free")
        #else
            return false
        #endif
    }

    init(
        store: MidgarStore?, sellsPro: Bool, defaults: UserDefaults = .standard,
        debugUnlock: Bool = false
    ) {
        self.store = store
        self.sellsPro = sellsPro
        self.defaults = defaults
        self.debugUnlock = debugUnlock
        isPro = debugUnlock || !sellsPro || defaults.bool(forKey: Self.cacheKey)
    }

    /// Reads what the store holds at launch, reports the purchases made before the store existed to the
    /// ledger once, and follows the store from then on: an Ask to Buy approval, a refund and a purchase
    /// made on another device all arrive as events.
    func start() {
        guard sellsPro, let store, eventsTask == nil else { return }
        eventsTask = Task { [weak self] in
            let events = await store.events()
            await self?.refreshEntitlements()
            await store.reportPurchaseHistory()
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    func refreshEntitlements() async {
        guard sellsPro, let store else { return }
        await store.refresh()
        await adoptEntitlement(of: store)
    }

    /// The unlock and the tips as StoreKit prices them for this storefront, tips in the order the offer
    /// lists them. An unreachable store answers with nothing rather than failing.
    func products() async -> (pro: StoreProduct?, tips: [StoreProduct]) {
        guard let store else { return (nil, []) }
        let all = (try? await store.products()) ?? []
        let pro = all.first { $0.id == ProOffer.productID }
        let tips = ProOffer.tipIDs.compactMap { id in all.first { $0.id == id } }
        return (pro, tips)
    }

    #if os(iOS)
        /// - Parameter scene: the scene the confirmation sheet hangs from. Without one StoreKit finds the
        ///   foreground window itself, which a test host has none of.
        func purchase(_ product: StoreProduct, confirmIn scene: UIScene? = nil) async throws
            -> PurchaseOutcome
        {
            try await settle { store in
                if let scene {
                    return try await store.purchase(product.id, confirmIn: scene)
                }
                return try await store.purchase(product.id)
            }
        }
    #endif

    #if os(macOS)
        /// - Parameter window: the window the purchase was asked for from, which is where StoreKit hangs
        ///   its confirmation. Read from whatever happened to be key, a purchase started as a sheet or a
        ///   popover closed could find no window at all and confirm into one never shown.
        func purchase(_ product: StoreProduct, in window: NSWindow?) async throws -> PurchaseOutcome {
            let host = window ?? NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
            return try await settle { store in
                if let host {
                    return try await store.purchase(product.id, confirmIn: host)
                }
                return try await store.purchase(product.id)
            }
        }
    #endif

    func restore() async throws -> RestoreOutcome {
        guard let store else { throw PurchaseFailure.other }
        do {
            try await store.restore()
        } catch let error as MidgarStoreError {
            if PurchaseFailure.isCancellation(error) { return .cancelled }
            throw PurchaseFailure(error)
        }
        await adoptEntitlement(of: store)
        return isPro ? .restored : .nothingFound
    }

    /// Runs one purchase on the store and turns what it ended in into the outcomes the screens show. A
    /// transaction that failed verification is an outcome, a dismissed sheet is a cancel, and every other
    /// store failure is thrown as a sentence.
    func settle(
        _ attempt: (MidgarStore) async throws -> MidgarPurchaseResult
    ) async throws -> PurchaseOutcome {
        guard let store else { throw PurchaseFailure.other }
        do {
            let result = try await attempt(store)
            await adoptEntitlement(of: store)
            switch result {
            case .purchased: return .success
            case .pending: return .pending
            case .cancelled: return .cancelled
            }
        } catch let error as MidgarStoreError {
            if PurchaseFailure.isCancellation(error) { return .cancelled }
            if case .unverifiedTransaction = error { return .unverified }
            throw PurchaseFailure(error)
        }
    }

    private func handle(_ event: MidgarStoreEvent) async {
        switch event {
        case .entitlementsChanged:
            if let store { await adoptEntitlement(of: store) }
        case .purchaseApproved(let productID):
            MidgarLog.info("purchase of \(productID) approved", category: .commerce)
        case .refused(let productID):
            MidgarLog.error("purchase of \(productID) failed verification", category: .commerce)
        }
    }

    private func adoptEntitlement(of store: MidgarStore) async {
        setPro(await store.isEntitled(to: TailscodeMidgar.entitlement))
    }

    private func setPro(_ value: Bool) {
        guard !debugUnlock, isPro != value else { return }
        isPro = value
        defaults.set(value, forKey: Self.cacheKey)
        MidgarLog.info("pro entitlement -> \(value)", category: .commerce)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

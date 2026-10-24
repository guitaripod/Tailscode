import Foundation
import MidgarCommerce
import TailscodeCore

/// A purchase that did not go through, in words a person can read. MidgarStore wraps StoreKit's own error
/// in its description, so the network, storefront and cancellation cases are read from it.
nonisolated enum PurchaseFailure: LocalizedError, Equatable {
    case unreachable
    case notAvailableInStorefront
    case unverified
    case other

    init(_ error: MidgarStoreError) {
        switch error {
        case .unverifiedTransaction:
            self = .unverified
        case .unknownProduct:
            self = .notAvailableInStorefront
        case .storeKit(let description) where description.contains("notAvailableInStorefront"):
            self = .notAvailableInStorefront
        case .storeKit(let description) where description.contains("networkError"):
            self = .unreachable
        case .storeKit, .readOnly, .unsupportedPlatform:
            self = .other
        }
    }

    /// A dismissed App Store sheet or sign-in prompt is the person's decision, not a failure to report.
    static func isCancellation(_ error: MidgarStoreError) -> Bool {
        guard case .storeKit(let description) = error else { return false }
        return description.contains("userCancelled")
    }

    var errorDescription: String? {
        switch self {
        case .unreachable:
            Localized.text("Couldn't reach the App Store. Check your connection and try again.")
        case .notAvailableInStorefront:
            Localized.text("This isn't available in your country or region.")
        case .unverified:
            Localized.text("That purchase could not be verified. Nothing was charged.")
        case .other:
            Localized.text("The purchase didn't go through. Try again in a moment.")
        }
    }
}

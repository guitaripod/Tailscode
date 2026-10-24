import Foundation
import MidgarCommerce
import MidgarCore
import MidgarPortal
import TailscodeCore

/// The composition root of everything Tailscode shares with the other Midgar apps: the Midgar ID, the
/// gateway client built on it, and the purchase engine. The iPhone app and the Mac app both build it, so
/// one instance lives for the whole process and there is one identity.
///
/// A copy that cannot sell anything has no services at all: a test host, a screenshot launch that holds
/// StoreKit back, and the direct Mac build, which is unlocked rather than pretending to sell a purchase it
/// cannot verify. The portal card still opens in that copy, with no account behind it.
@MainActor
final class TailscodeMidgar {
    /// The registry slug: the `X-App-ID` of every gateway call and the `app` of the ledger entries this
    /// app honours.
    nonisolated static let appID = "tailscode"

    /// The bundle id the identity service checks against the registry when it mints or attaches an ID.
    /// The iPhone and Mac apps share it, so one purchase covers both.
    nonisolated static let bundleID = "com.guitaripod.tailscode"

    /// The entitlement the registry names for Pro.
    nonisolated static let entitlement = "pro"

    static let shared = TailscodeMidgar()

    struct Services: Sendable {
        let identity: MidgarIdentity
        let account: MidgarHTTPClient
        let store: MidgarStore
    }

    let services: Services?

    var store: MidgarStore? { services?.store }

    private init() {
        services = Self.reachesMidgarServices ? Self.makeServices() : nil
    }

    /// What Tailscode sells: the one-time Pro unlock, which grants `pro`, and the tips, which are bought,
    /// finished and reported to the ledger but grant nothing.
    nonisolated static func storeConfiguration(directory: URL? = nil) -> MidgarStoreConfiguration {
        MidgarStoreConfiguration(
            appID: appID,
            productIDs: [ProOffer.productID] + ProOffer.tipIDs,
            entitlementsByProduct: [ProOffer.productID: entitlement],
            mode: .purchases,
            directory: directory
        )
    }

    /// Whether this copy of the app sells Pro. The direct Mac build sells nothing and is unlocked.
    nonisolated static var sellsPro: Bool {
        #if os(macOS) && !TAILSCODE_MAS
            return false
        #else
            return true
        #endif
    }

    /// False inside an XCTest or Swift Testing host, in a copy that sells nothing and in a screenshot
    /// launch that keeps away from StoreKit, none of which may mint identities or reach the production
    /// services.
    static var reachesMidgarServices: Bool {
        guard sellsPro else { return false }
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil { return false }
        #if DEBUG && os(macOS)
            if LiveShot.holdsBack("StoreKit") { return false }
        #endif
        return true
    }

    /// The portal configuration of Settings: the authorized client, so "Your Midgar" shows what the person
    /// owns in the other apps and a cross-sell skips an app they already use.
    var portalConfig: MidgarPortal.MidgarConfig {
        MidgarPortal.MidgarConfig(placement: "settings", account: services?.account)
    }

    /// Configures anonymous signals for the portal and starts the Midgar ID in the background, so the
    /// first purchase finds one. Call once at launch.
    func start() {
        guard let identity = services?.identity else {
            MidgarLog.info("Midgar services not started: nothing to sell here", category: .account)
            return
        }
        MidgarSignals.configure(configuration: MidgarHTTPConfiguration(appID: Self.appID))
        Task {
            do {
                _ = try await identity.midgarId
                MidgarLog.info("Midgar ID ready", category: .account)
            } catch {
                MidgarLog.info("Midgar ID not available yet: \(error)", category: .account)
            }
        }
    }

    private static func makeServices() -> Services {
        let configuration = MidgarHTTPConfiguration(appID: appID)
        let identity = MidgarIdentity(
            httpConfiguration: configuration, bundleID: Bundle.main.bundleIdentifier ?? bundleID)
        let account = MidgarHTTPClient(configuration: identity.authorizing(configuration))
        let store = MidgarStore(
            configuration: storeConfiguration(), identity: identity, http: account)
        return Services(identity: identity, account: account, store: store)
    }
}

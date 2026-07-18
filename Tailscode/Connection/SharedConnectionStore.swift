import CodingAgentKitApple
import Foundation

/// The profile store the app and the widget extension share: metadata in the App Group
/// container, passwords in the App Group keychain access group. This is what lets the
/// widget mint backends and refresh quotas on its own timeline schedule, without the
/// app ever launching.
enum SharedConnectionStore {
    static let appGroup = "group.com.guitaripod.tailscode"

    private struct ContainerUnavailable: Error {}

    static func make() throws -> ConnectionProfileStore {
        try ConnectionProfileStore(directory: directory(), keychain: keychain())
    }

    /// The simulator build is unsigned (`CODE_SIGNING_ALLOWED=NO`), so an explicit
    /// keychain access group fails with `errSecMissingEntitlement` there; the plain
    /// app keychain keeps simulator flows working and only the widget-side read —
    /// which simulator runs never exercise — is lost.
    private static func keychain() -> KeychainSecretStore {
        #if targetEnvironment(simulator)
            KeychainSecretStore()
        #else
            KeychainSecretStore(accessGroup: appGroup)
        #endif
    }

    private static func directory() throws -> URL {
        guard
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroup)
        else { throw ContainerUnavailable() }
        return container.appendingPathComponent("CodingAgentKit", isDirectory: true)
    }
}

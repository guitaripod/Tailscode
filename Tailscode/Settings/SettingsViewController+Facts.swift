import CodingAgentKitApple
import TailscodeCore
import UIKit

/// What the rows read that is not in memory: the profile file, the update ledger and the
/// Keychain. They are read when the screen appears or the thing they describe changes, and a row
/// being configured reads this copy, because a row is configured on every frame a scroll needs one.
@MainActor
struct SettingsFacts {
    /// Every saved server, the ones resting after the Pro week included.
    var profiles: [ConnectionProfile]
    var resting: Set<String>
    var updates: UpdateRollup
    var tailnetKey: TailnetKey
    var hasOllamaKey: Bool
    var hasDeepSeekKey: Bool

    static func read() -> SettingsFacts {
        SettingsFacts(
            profiles: ConnectionController.shared.savedProfiles,
            resting: Set(ConnectionController.shared.savedProfiles.map(\.id).filter(ConnectionController.shared.isResting)),
            updates: UpdateLedger.rollup(),
            tailnetKey: TailnetCredentials.key,
            hasOllamaKey: OllamaCredentials.hasToken, hasDeepSeekKey: DeepSeekCredentials.hasToken)
    }

    /// The facts a change in the profiles or the ledger moves, with the Keychain's left as read.
    func refreshingStores() -> SettingsFacts {
        var next = self
        next.profiles = ConnectionController.shared.savedProfiles
        next.resting = Set(next.profiles.map(\.id).filter(ConnectionController.shared.isResting))
        next.updates = UpdateLedger.rollup()
        return next
    }
}

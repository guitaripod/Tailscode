import Foundation
import MidgarUI

extension SettingsViewController {
    /// The version row as every Midgar app words it: MidgarUI's title and `1.79 (199)` detail, which is
    /// also what a long press copies.
    static var versionRow: MidgarSettingsRow {
        .version(MidgarVersionInfo())
    }

    static var privacyRow: MidgarSettingsRow {
        .privacyPolicy(url: URL(string: privacyURL)!)
    }

    static var supportRow: MidgarSettingsRow {
        .support(address: supportEmail)
    }
}

import Foundation
import TailscodeCore

extension Preferences {
    private static let agentsWidthKey = "tailscode.agents.width"
    private static let agentsHeightKey = "tailscode.agents.height"

    /// The size the person left the agents window at, nil until they have resized it once.
    static var agentsWindowSize: (width: Int32, height: Int32)? {
        let width = UserDefaults.standard.integer(forKey: agentsWidthKey)
        let height = UserDefaults.standard.integer(forKey: agentsHeightKey)
        return width >= 640 && height >= 420 ? (Int32(width), Int32(height)) : nil
    }

    static func setAgentsWindowSize(width: Int32, height: Int32) {
        guard width >= 640, height >= 420 else { return }
        guard agentsWindowSize.map({ $0 != (width, height) }) ?? true else { return }
        SettingsFile.set(Int(width), forKey: agentsWidthKey)
        SettingsFile.set(Int(height), forKey: agentsHeightKey)
    }

    private static let plainWordsKey = "tailscode.watch.plainWords"
    private static let plainWordsAddressKey = "tailscode.watch.plainWordsAddress"
    private static let plainWordsModelKey = "tailscode.watch.plainWordsModel"

    /// Whether a model the person runs themselves may say the commands the rules could not read.
    /// Off until they turn it on.
    static var plainWords: Bool { UserDefaults.standard.bool(forKey: plainWordsKey) }

    static var plainWordsAddress: String { UserDefaults.standard.string(forKey: plainWordsAddressKey) ?? "" }

    static var plainWordsModel: String { UserDefaults.standard.string(forKey: plainWordsModelKey) ?? "" }

    static func setPlainWords(_ on: Bool) {
        SettingsFile.set(on ? true : nil, forKey: plainWordsKey)
    }

    static func setPlainWordsAddress(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsFile.set(trimmed.isEmpty ? nil : trimmed, forKey: plainWordsAddressKey)
    }

    static func setPlainWordsModel(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsFile.set(trimmed.isEmpty ? nil : trimmed, forKey: plainWordsModelKey)
    }

    private static let watchStyleKey = "agentsWatchStyle"

    /// How the wall looks and behaves on this device: Core's `WallStyle`, kept as its own JSON text
    /// and read when a wall opens and when Settings changes it, never on a timer. Nothing stored,
    /// or text that does not decode, is the Studio style.
    static var agentsWatchStyle: WallStyle {
        WallStyle.decoded(UserDefaults.standard.string(forKey: watchStyleKey))
    }

    static func setAgentsWatchStyle(_ style: WallStyle?) {
        SettingsFile.set(style?.encoded(), forKey: watchStyleKey)
    }

    static func forgetAgentsWindowSize() {
        SettingsFile.set(nil, forKey: agentsWidthKey)
        SettingsFile.set(nil, forKey: agentsHeightKey)
    }
}

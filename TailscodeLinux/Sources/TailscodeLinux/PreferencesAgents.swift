import Foundation

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

    static func forgetAgentsWindowSize() {
        SettingsFile.set(nil, forKey: agentsWidthKey)
        SettingsFile.set(nil, forKey: agentsHeightKey)
    }
}

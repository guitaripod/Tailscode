import Foundation

/// Whether addresses in the transcript wear their preview cards. On until somebody turns it off:
/// the card is the feature, and the opt-out is for readers who want their links as plain blue
/// text. Device-local, like every other thing about how this app looks.
public enum LinkEmbedsSetting {
    public static let defaultsKey = "tailscode.linkEmbeds"
    public static let didChange = Notification.Name("tailscode.linkEmbeds.didChange")

    public static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: defaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    public static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: defaultsKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static var title: String { Localized.text("Link preview cards") }

    public static var explanation: String {
        Localized.text(
            "An address the agent mentions gets a small card under it — the page's title and icon, tapped to open. Turn off for plain links.")
    }
}

import Foundation

/// The way out of the demo, said out loud.
///
/// The demo is a believable two-server world, which is the reason a person can wander in it
/// without ever learning that the real thing needs a computer of their own. This is the one card
/// that tells them, and it only ever informs: setting it aside hides it for the rest of that
/// demo, and entering the demo again starts a fresh one. Leaving the demo — by choice or by
/// saving a real server — ends the question altogether.
public enum DemoNudge: Sendable {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    public static let dismissedKey = "tailscode.demoNudge.dismissed"

    public static var isDismissed: Bool {
        defaults.bool(forKey: dismissedKey)
    }

    public static func isShown(demoActive: Bool) -> Bool {
        demoActive && !isDismissed
    }

    public static func dismiss() {
        defaults.set(true, forKey: dismissedKey)
    }

    public static func reset() {
        defaults.removeObject(forKey: dismissedKey)
    }

    public static var title: String { Localized.text("Connect your machine") }

    public static var body: String {
        Localized.text(
            "You are looking at sample data. Link a computer that runs your agent and this becomes your own.")
    }

    public static var primaryAction: String { Localized.text("Set up my machine") }

    public static var secondaryAction: String { Localized.text("Not now") }
}

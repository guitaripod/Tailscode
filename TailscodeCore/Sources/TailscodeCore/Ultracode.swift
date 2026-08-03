import Foundation

/// The shared definition of "ultracode is happening": one detector, one state
/// rule, one rainbow. The clients differ only in how they paint it — what
/// counts as active, and which colors the aura cycles through, must never
/// drift between toolkits (or between a client and the bridge, whose
/// `SessionStore.invokesUltracode` mirrors ``invokes(_:)``).
public enum Ultracode {
    public static let effortLevel = "ultracode"

    /// Whether a prompt summons ultracode by word — the keyword the CLI honours
    /// interactively, granted the same power by the bridge for one turn.
    public static func invokes(_ prompt: String) -> Bool {
        prompt.range(of: #"(?i)\bultracode\b"#, options: .regularExpression) != nil
    }

    /// Whether the aura shows: the chat runs at ultracode effort, the draft
    /// summons it by word, or the turn in flight was sent with it. The draft
    /// lighting up as the word is typed is the point — the unlock is visible
    /// before the prompt is ever sent.
    public static func auraActive(
        effort: String?, draft: String, inFlightInvoked: Bool = false
    ) -> Bool {
        effort == effortLevel || invokes(draft) || inFlightInvoked
    }

    /// The rainbow, as RGB stops (0–1) ending where they began so a rotating
    /// gradient meets itself seamlessly. Every client renders these exact
    /// stops: the aura is one effect that happens to run on three toolkits.
    public static let rainbowStops: [(red: Double, green: Double, blue: Double)] = [
        (1.00, 0.20, 0.25),
        (1.00, 0.58, 0.00),
        (1.00, 0.84, 0.04),
        (0.20, 0.84, 0.29),
        (0.35, 0.78, 0.98),
        (0.04, 0.52, 1.00),
        (0.75, 0.35, 0.95),
        (1.00, 0.20, 0.25),
    ]

    /// How the effort menu should present the tier: a power, not a level.
    public static var menuTitle: String { Localized.text("Ultracode") }
    public static var menuSubtitle: String { Localized.text("Unlocks multi-agent workflows") }
}

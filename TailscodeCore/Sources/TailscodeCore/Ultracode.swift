import Foundation

/// The shared definition of "ultracode is happening": one detector, one state
/// rule, one rainbow. The clients differ only in how they paint it — what
/// counts as active, and which colors the aura cycles through, must never
/// drift between toolkits (or between a client and the bridge, whose
/// `SessionStore.invokesUltracode` mirrors ``invokes(_:)``).
public enum Ultracode {
    public static let effortLevel = "ultracode"

    private static let invocation = try! NSRegularExpression(pattern: #"(?i)\bultracode\b"#)

    /// Whether a prompt summons ultracode by word — the keyword the CLI honours
    /// interactively, granted the same power by the bridge for one turn. This
    /// runs on every keystroke of every composer, so the compiled expression is
    /// hoisted and gated behind a plain substring scan that almost always says no.
    public static func invokes(_ prompt: String) -> Bool {
        guard prompt.range(of: "ultracode", options: .caseInsensitive) != nil else { return false }
        let range = NSRange(prompt.startIndex..., in: prompt)
        return invocation.firstMatch(in: prompt, options: [], range: range) != nil
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

    /// How long one full turn of the aura takes, and how long one breath of its
    /// glow does. Deliberately not a multiple of each other: two cycles that
    /// divide evenly lock into a visible beat, and the aura reads as a machine
    /// counting rather than something lit.
    public static let auraTurnSeconds: Double = 4
    public static let auraBreathSeconds: Double = 1.6

    /// The dimmest the glow ever goes. A breath that reaches zero is a blink,
    /// and the aura is a state — it must never look like it switched off.
    public static let auraBreathFloor: Double = 0.72

    /// Where the rainbow's head sits and how brightly the glow burns at a given
    /// moment, for a client that paints its own frames rather than handing the
    /// animation to a compositor. Derived from the clock rather than from a
    /// counter the caller increments: a dropped frame then costs a frame, not
    /// the phase, so the aura runs at the same speed whatever the renderer is
    /// doing.
    public static func aura(at time: Double) -> (phase: Double, glow: Double) {
        let phase = (time / auraTurnSeconds).truncatingRemainder(dividingBy: 1)
        let breath = (time / (auraBreathSeconds * 2)).truncatingRemainder(dividingBy: 1)
        let eased = 0.5 - 0.5 * cos(breath * 2 * Double.pi)
        return (phase < 0 ? phase + 1 : phase, auraBreathFloor + (1 - auraBreathFloor) * eased)
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

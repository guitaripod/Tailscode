import CodingAgentKit
import CodingAgentKitApple
import Foundation

/// What the main pane says when the app holds no real server, as data every desktop draws. A blank
/// transcript is a dead end for a stranger, so the pane asks the one question that is open: the
/// next step is read from the same `FirstRunPlan` the first-run window draws (Tailscale's own
/// remedy, then the machine, then Claude's sign-in), and the buttons open that window rather than
/// repeating it. A client decides only how the welcome is drawn and invents no sentence.
public struct EmptyWelcome: Sendable, Equatable {
    public enum Intent: Sendable, Equatable {
        case setUpMachine
        case pasteLink
        case tryDemo
        case openTailscale
        case signIn
    }

    public struct Action: Sendable, Equatable, Identifiable {
        public let intent: Intent
        public let title: String
        public let help: String
        public var id: Intent { intent }
    }

    /// The one thing that stands between this person and a conversation, with the press that
    /// settles it when the app can do that press itself.
    public struct Step: Sendable, Equatable {
        public let title: String
        public let detail: String
        public let fix: Action?
    }

    public let title: String
    public let detail: String
    public let step: Step
    public let primary: Action
    public let secondary: [Action]

    public var actions: [Action] { [primary] + secondary }

    /// Whether the app has nothing of the person's own to show: demo servers are a place to look
    /// around, not a machine, and do not stop the welcome.
    public static func holdsNoRealServer(_ profiles: [ConnectionProfile]) -> Bool {
        !profiles.contains { !$0.id.hasPrefix(DemoWorld.profilePrefix) }
    }

    public static var sidebarLine: String {
        Localized.text("No servers yet — add the machine your agent runs on")
    }

    public static var setUpTitle: String { Localized.text("Set up a machine") }

    /// - Parameter demoActive: whether the demo's servers are already what the app holds, in which
    ///   case offering the demo again would be a button that does nothing.
    public static func make(_ state: FirstRunState, demoActive: Bool = false) -> EmptyWelcome {
        let plan = FirstRunPlan.make(state)
        let setUp = Action(
            intent: .setUpMachine, title: setUpTitle,
            help: Localized.text("Checks Tailscale, then finds or installs the agent on your computer."))
        let paste = Action(
            intent: .pasteLink, title: Localized.text("Paste a link"),
            help: Localized.text("Paste the link your machine printed when its install finished."))
        let demo = demoActive ? nil : plan.demo.map {
            Action(intent: .tryDemo, title: $0.title, help: $0.detail)
        }
        let step = nextStep(plan)
        if let fix = step.fix, fix.intent == .signIn {
            let alone = Step(title: step.title, detail: step.detail, fix: nil)
            return EmptyWelcome(
                title: welcomeTitle, detail: intro, step: alone, primary: fix, secondary: [])
        }
        return EmptyWelcome(
            title: welcomeTitle, detail: intro, step: step, primary: setUp,
            secondary: [paste] + (demo.map { [$0] } ?? []))
    }

    private static var welcomeTitle: String { Localized.text("Welcome to Tailscode") }

    private static var intro: String {
        Localized.text(
            "Tailscode drives the coding agent on your computer, over your Tailscale network. Add the machine it runs on to begin."
        )
    }

    private static func nextStep(_ plan: FirstRunPlan) -> Step {
        if let step = tailscaleStep(plan) { return step }
        if let card = signInCard(plan) {
            return Step(
                title: card.title, detail: card.detail,
                fix: Action(intent: .signIn, title: card.action, help: card.detail))
        }
        return Step(
            title: FirstRunReading.machineTitle, detail: FirstRunReading.whatAMachineIs, fix: nil)
    }

    private static func tailscaleStep(_ plan: FirstRunPlan) -> Step? {
        guard let row = plan.row(.tailscale),
            let reading = row.blocks.compactMap({ block -> TailscaleReading? in
                if case .remedy(let reading) = block { return reading }
                return nil
            }).first,
            reading.blocksReaching
        else { return nil }
        let title = reading.actionTitle ?? FirstRunReading.openTailscale
        return Step(
            title: row.title, detail: reading.detail ?? "",
            fix: Action(intent: .openTailscale, title: title, help: reading.detail ?? title))
    }

    private static func signInCard(_ plan: FirstRunPlan) -> FirstRunPlan.SignInCard? {
        plan.row(.connected)?.blocks.compactMap { block -> FirstRunPlan.SignInCard? in
            if case .signIn(let card) = block { return card }
            return nil
        }.first
    }
}

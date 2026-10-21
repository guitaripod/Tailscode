import CodingAgentKit
import Foundation

/// The words of first run. Every sentence a stranger reads between launching the app and their
/// first conversation is here, so a phone, a Mac and a Linux desktop cannot drift into three
/// slightly different explanations of the same machine.
enum FirstRunReading {
    static var intro: String {
        Localized.text(
            "Tailscode drives the coding agent on your computer. Each step below is checked for you.")
    }

    static var demo: FirstRunPlan.Demo {
        FirstRunPlan.Demo(
            title: Localized.text("Try the demo"),
            detail: Localized.text("Two sample servers. Nothing real."))
    }

    static var checking: String { Localized.text("Checking…") }
    static var notConnected: String { Localized.text("Not connected") }
    static var openTailscale: String { Localized.text("Open Tailscale") }
    static var connect: String { Localized.text("Connect") }
    static var connecting: String { Localized.text("Connecting…") }
    static var later: String { Localized.text("Later") }
    static var back: String { Localized.text("Back") }
    static var waiting: String { Localized.text("Waiting") }
    static var machineTitle: String { Localized.text("Your machine") }
    static var connectedTitle: String { Localized.text("Connected") }
    static var connectedPill: String { Localized.text("Connected") }
    static var signedOutPill: String { Localized.text("Signed out") }
    static var signInAction: String { Localized.text("Sign in to Claude") }
    static var wantsItsPassword: String { Localized.text("Wants its password") }
    static var saving: String { Localized.text("Connecting…") }

    static var installTailscaleHere: String {
        Localized.text(
            "Install Tailscale here and on the computer that will run the agent, then sign both into the same account. Free for personal use."
        )
    }

    static var whatAMachineIs: String {
        Localized.text("A machine is the computer that runs your coding agent, on your Tailscale network.")
    }

    static func tailscaleTitle(_ platform: FirstRunPlatform) -> String {
        switch platform {
        case .iPhone: return Localized.text("Tailscale on this iPhone")
        case .iPad: return Localized.text("Tailscale on this iPad")
        case .mac: return Localized.text("Tailscale on this Mac")
        case .linux: return Localized.text("Tailscale on this computer")
        }
    }

    static func onTailnet(_ platform: FirstRunPlatform) -> String {
        switch platform {
        case .iPhone:
            return Localized.text(
                "This iPhone is on your tailnet. The computer that runs the agent has to be signed into the same account."
            )
        case .iPad:
            return Localized.text(
                "This iPad is on your tailnet. The computer that runs the agent has to be signed into the same account."
            )
        case .mac:
            return Localized.text(
                "This Mac is on your tailnet. The machine that runs the agent has to be signed into the same account."
            )
        case .linux:
            return Localized.text(
                "This computer is on your tailnet. The machine that runs the agent has to be signed into the same account."
            )
        }
    }

    static func ways(_ state: FirstRunState, includingInstall: Bool) -> [FirstRunPlan.Way] {
        var ways: [FirstRunPlan.Way] = []
        if state.platform.scansCodes {
            ways.append(
                FirstRunPlan.Way(
                    kind: .scan, title: Localized.text("Scan the code your computer printed"),
                    detail: Localized.text("It prints a code and a link when the install finishes.")))
        }
        ways.append(
            FirstRunPlan.Way(
                kind: .link, title: Localized.text("Open or paste a link"),
                detail: state.platform.isPhone
                    ? Localized.text("Open the link on this device, or paste it here.")
                    : Localized.text("Paste the link your machine printed.")))
        if includingInstall {
            ways.append(
                FirstRunPlan.Way(
                    kind: .install, title: Localized.text("I don't have a machine set up yet"),
                    detail: Localized.text("One command installs it. You run it on the computer.")))
        }
        if state.offersTailnetScan, includingInstall || !state.platform.watchesTailnet {
            ways.append(
                FirstRunPlan.Way(
                    kind: .tailnet, title: Localized.text("Find it on my tailnet"),
                    detail: Localized.text("For a machine that already runs an agent.")))
        }
        return ways
    }

    static func paste(_ state: FirstRunState) -> FirstRunPlan.Paste {
        FirstRunPlan.Paste(
            text: state.typed,
            placeholder: Localized.text("Paste a link or an address"),
            reading: addressHint(state),
            offer: state.clipboard.map { Localized.text("Add %@ from your clipboard", ConnectLinkReading.displayName($0)) },
            message: state.notice)
    }

    static func addressHint(_ state: FirstRunState) -> String? {
        let text = state.typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        switch HostAddress.read(text, defaultPort: HostAddress.port(for: state.agent)) {
        case .empty: return nil
        case .address(let address): return "→ \(address.url.absoluteString)"
        case .bindAll:
            return Localized.text("0.0.0.0 is what the server binds to. Use that machine's own address.")
        case .unsupportedScheme(let scheme):
            return Localized.text("%@:// isn't supported — use http.", scheme)
        case .invalid:
            return Localized.text("An address like 100.101.102.103 or studio:4098.")
        }
    }

    static func agentChoices(_ state: FirstRunState) -> [FirstRunPlan.AgentChoice] {
        [AgentType.claudeCode, .openCode, .omp].map { agent in
            FirstRunPlan.AgentChoice(
                agent: agent, title: agentTitle(agent), detail: agentDetail(agent),
                isSelected: agent == state.agent)
        }
    }

    static func agentTitle(_ agent: AgentType) -> String {
        switch agent {
        case .claudeCode: return Localized.text("Claude Code")
        case .openCode: return Localized.text("opencode")
        case .omp: return Localized.text("Oh My Pi")
        }
    }

    static func agentDetail(_ agent: AgentType) -> String {
        switch agent {
        case .claudeCode: return Localized.text("Your own Claude subscription, through claude-bridge.")
        case .openCode: return Localized.text("Any provider you have configured. One command, no build.")
        case .omp: return Localized.text("Your own oh-my-pi agent, through omp-bridge.")
        }
    }

    static func commandCard(_ install: BridgeInstall.Install, state: FirstRunState)
        -> FirstRunPlan.CommandCard
    {
        FirstRunPlan.CommandCard(
            title: Localized.text("Run this on your machine"),
            detail: Localized.text(
                "Paste it in a terminal on the computer. It installs the agent, starts it and prints a code and a link."
            ),
            command: install.command,
            note: commandNote(install),
            copyTitle: Localized.text("Copy"),
            sendTitle: state.platform.sharesToComputer ? SetupHandoff.action : nil,
            sharedMessage: SetupHandoff.message(installCommand: install.command))
    }

    private static func commandNote(_ install: BridgeInstall.Install) -> String {
        let base: String
        switch install.agent {
        case .claudeCode: base = Localized.text("Downloads a prebuilt program in seconds. No Swift or git needed.")
        case .openCode:
            base = Localized.text(
                "Installs opencode if it is missing, serves it on port 4096, and keeps its model list current."
            )
        case .omp:
            base = Localized.text(
                "Drives oh-my-pi (install it first) on port 4099. Needs git and a Swift 6 toolchain.")
        }
        guard install.password != nil else { return base }
        return base + " "
            + Localized.text(
                "This one has a password. It is in the command, and this device fills it in when you copy or send the command."
            )
    }

    static func waitingForMachine(_ platform: FirstRunPlatform) -> String {
        platform.watchesTailnet
            ? Localized.text(
                "Waiting for your machine. It shows up here when the install finishes, or paste the link it prints."
            )
            : Localized.text(
                "Waiting for your machine. When the install finishes, scan the code it prints or open its link."
            )
    }

    static func answering(_ found: FirstRunState.Found) -> String {
        let name = ServerLabel.agent(found.agent)
        guard let version = found.version, !version.isEmpty else { return name }
        return "\(name) \(version)"
    }

    static func holdsKey(_ label: String) -> String {
        Localized.text(
            "%@ answered and wants a password. The link brought it, and it is used when you press Connect.",
            label)
    }

    static func linkCard(_ plan: ConnectLinkPlan, confirmed: Bool) -> FirstRunPlan.LinkCard {
        FirstRunPlan.LinkCard(
            headline: ConnectLinkReading.headline(plan.link),
            lines: plan.lines,
            connectAnywayTitle: plan.isOnTailnet || confirmed ? nil : ConnectLinkReading.connectAnyway)
    }

    static func looking(_ label: String) -> String { Localized.text("Looking for %@…", label) }

    static func savedNothing(_ label: String) -> String {
        Localized.text("Saved nothing yet. Press Connect to add %@.", label)
    }

    static func connectTo(_ label: String) -> String { Localized.text("Connect to %@", label) }
    static func addTitle(_ label: String) -> String { Localized.text("Add %@", label) }

    static func readingClaude(_ name: String) -> String {
        Localized.text("Connected to %@. Reading Claude's sign-in…", name)
    }

    static func signInCard(_ name: String) -> FirstRunPlan.SignInCard {
        FirstRunPlan.SignInCard(
            title: Localized.text("Claude is signed out on %@", name),
            detail: Localized.text(
                "%@ is connected, but Claude is signed out there. Every turn would be refused until it signs in.",
                name),
            action: signInAction)
    }

    static func signedInDetail(_ name: String, account: String?) -> String {
        guard let account, !account.isEmpty else {
            return Localized.text("Connected to %@. Claude is signed in.", name)
        }
        return Localized.text("Connected to %@, signed in to Claude as %@.", name, account)
    }

    static func connectedDetail(_ name: String) -> String { Localized.text("Connected to %@.", name) }

    static func profileName(for url: URL) -> String {
        guard let host = url.host, !host.isEmpty else { return Localized.text("Server") }
        let label = host.split(separator: ".").first.map(String.init) ?? host
        if Int(label) != nil { return host }
        return label
    }
}

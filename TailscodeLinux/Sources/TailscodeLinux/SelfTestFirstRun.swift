import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// What first run promises on this desk that Core cannot prove: that the desktop entry
    /// declares the `tailscode://` scheme and takes a URL, that the launch arguments a desktop
    /// hands over reach the link handler, and that the window draws each state of the plan —
    /// the three ways, the install command without a password for claude-bridge, the machine
    /// that was found, the signed-out Claude — with nothing in it the plan did not say.
    static func checkFirstRun() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("first run: \(label)") }
            checks += 1
        }

        let entry = DesktopIntegration.entryText(exec: "/usr/bin/tailscode")
        try expect(entry.contains("MimeType=x-scheme-handler/tailscode;"), "the entry declares the scheme")
        try expect(entry.contains("Exec=/usr/bin/tailscode %u"), "the entry takes a URL")

        let link = "tailscode://connect?v=1&host=studio.tail1.ts.net&port=4098&agent=claude"
        try expect(
            LaunchLink.request(arguments: ["tailscode", link]) == .link(link),
            "a bare link argument reaches the handler")
        try expect(
            LaunchLink.request(arguments: ["tailscode", "--connect", link]) == .link(link),
            "--connect with a link reaches the handler")
        try expect(
            LaunchLink.isHeadlessConnect(arguments: ["tailscode", "--connect", "100.64.0.9"]),
            "--connect with an address stays headless")

        guard gtk_init_check() != 0 else { return checks }
        try checkFirstRunWindow(expect)
        return checks
    }

    private static func checkFirstRunWindow(_ expect: (Bool, String) throws -> Void) throws {
        var state = FirstRunState(platform: .linux)
        state.tailscale = .up(address: "100.101.102.103")
        let dialog = FirstRunDialog.forTesting(mode: .firstRun)

        dialog.applyForTesting(FirstRunPlan.make(state))
        var texts = dialog.renderedTexts()
        try expect(texts.contains("Open or paste a link"), "the way to paste a link is drawn")
        try expect(texts.contains("I don't have a machine set up yet"), "the install way is drawn")
        try expect(!texts.contains { $0.hasPrefix("Scan the code") }, "a desktop draws no scanner")
        try expect(texts.contains("100.101.102.103"), "Tailscale is proven by its address")
        try expect(!dialog.isShowingPassword(), "no password field before one is asked for")

        state.way = .install
        state.install = BridgeInstall.install(for: .claudeCode)
        dialog.applyForTesting(FirstRunPlan.make(state))
        texts = dialog.renderedTexts()
        try expect(
            texts.contains { $0.hasPrefix("curl -fsSL") && !$0.contains("PASSWORD") },
            "the claude-bridge install command carries no password")
        try expect(texts.contains("Waiting"), "the install waits for the machine")
        try expect(!dialog.isShowingPassword(), "no password field beside a command without one")

        state.agent = .openCode
        state.install = BridgeInstall.install(for: .openCode, password: "pw")
        state.password = "pw"
        state.passwordShown = true
        dialog.applyForTesting(FirstRunPlan.make(state))
        texts = dialog.renderedTexts()
        try expect(
            texts.contains { $0.contains("OPENCODE_SERVER_PASSWORD=pw") },
            "an agent that needs a password carries it in the command")
        try expect(dialog.isShowingPassword(), "and the password field is there once it is in play")

        state = FirstRunState(platform: .linux)
        state.tailscale = .up(address: "100.101.102.103")
        state.way = .link
        state.link = ConnectLinkPlan.make(
            link: PairingLink(host: "studio.tail1.ts.net", port: 4098, agent: .claude, name: "Studio")!,
            profiles: [])
        state.machine = .found(
            FirstRunState.Found(
                agent: .claudeCode, version: "1.14.0",
                url: URL(string: "http://studio.tail1.ts.net:4098")!, label: "Studio"))
        dialog.applyForTesting(FirstRunPlan.make(state))
        texts = dialog.renderedTexts()
        try expect(texts.contains("Claude Code 1.14.0"), "the machine that answered is named")
        try expect(texts.contains("Connect to Studio"), "the one press is Connect to the machine")
        try expect(texts.contains("Add Studio"), "the link says what it would add")
        try expect(!dialog.isShowingPassword(), "no password field for a machine that wants none")

        state.connection = .saved(name: "Studio")
        state.claude = .signedOut
        dialog.applyForTesting(FirstRunPlan.make(state))
        texts = dialog.renderedTexts()
        try expect(
            texts.filter { $0 == "Sign in to Claude" }.count >= 1,
            "a signed-out Claude opens the sign-in inside first run")
        try expect(texts.contains("Signed out"), "and the row says so")
        try expect(
            texts.filter { $0 == "Sign in to Claude" }.count == 1,
            "and the sign-in is pressed in one place")
        try checkFirstRunStates(expect)
    }

    private static func checkFirstRunStates(_ expect: (Bool, String) throws -> Void) throws {
        func texts(_ dialog: FirstRunDialog, _ name: String) throws -> [String] {
            guard let state = FirstRunFixtures.state(named: name, platform: .linux) else {
                throw SelfTestFailure("first run: no state \(name)")
            }
            dialog.applyForTesting(FirstRunPlan.make(state))
            return dialog.renderedTexts()
        }
        let dialog = FirstRunDialog.forTesting(mode: .firstRun)
        for name in FirstRunFixtures.names {
            try expect(!(try texts(dialog, name)).isEmpty, "\(name) draws words")
        }

        var drawn = try texts(dialog, "link-offered")
        try expect(drawn.contains("Use the link you copied"), "a copied link is offered")
        try expect(
            drawn.contains("Studio · studio.tail1234.ts.net:4098"), "by the machine's name and place")

        drawn = try texts(dialog, "link-pasted")
        try expect(drawn.contains("Connect to Studio"), "a link in play is connected to by name")
        try expect(!drawn.contains("Use the link you copied"), "and is not offered again")

        drawn = try texts(dialog, "tailscale-down")
        try expect(drawn.contains(TailscaleReading.daemonDown.title), "Tailscale not running is the pill")
        try expect(
            drawn.contains(TailscaleReading.daemonDown.actionTitle ?? ""), "and its own remedy is a button")

        drawn = try texts(dialog, "failed:refused")
        try expect(
            drawn.contains { $0.hasPrefix("Nothing is listening on ") && $0.contains("studio") },
            "a failure names the machine")
        try expect(drawn.contains("Try again"), "and offers the one tap that fixes it")

        drawn = try texts(dialog, "failed:off-tailnet")
        try expect(drawn.contains("Open Tailscale"), "a machine off the tailnet opens Tailscale")

        let adding = FirstRunDialog.forTesting(mode: .addition)
        drawn = try texts(adding, "machine-asking+add")
        try expect(!drawn.contains("Try the demo"), "adding offers no demo")
        try expect(!drawn.contains { $0.hasPrefix("Tailscale on this") }, "adding never claims Tailscale is missing")
        try expect(drawn.contains("Not now"), "adding is dismissed with Not now")

        try checkWelcome(expect)
    }

    private static func checkWelcome(_ expect: (Bool, String) throws -> Void) throws {
        func shown(_ name: String) throws -> [String] {
            guard let state = FirstRunFixtures.state(named: name, platform: .linux) else {
                throw SelfTestFailure("first run: no state \(name)")
            }
            let view = ChatPane.welcomeView(EmptyWelcome.make(state)) { _ in }
            var texts: [String] = []
            FirstRunDialog.collect(from: view, into: &texts)
            return texts
        }
        var drawn = try shown("machine-asking")
        try expect(drawn.contains("Welcome to Tailscode"), "an empty pane draws the welcome")
        try expect(
            drawn.filter { ["Set up a machine", "Paste a link", "Try the demo"].contains($0) }
                == ["Set up a machine", "Paste a link", "Try the demo"],
            "with a machine first, then a link, then the demo")
        drawn = try shown("tailscale-down")
        try expect(
            drawn.contains(TailscaleReading.daemonDown.actionTitle ?? ""),
            "Tailscale down leads with Tailscale's own remedy")
        drawn = try shown("signed-out")
        try expect(
            drawn.filter { $0 == "Sign in to Claude" }.count == 1,
            "a signed-out Claude is the one thing offered")
    }
}

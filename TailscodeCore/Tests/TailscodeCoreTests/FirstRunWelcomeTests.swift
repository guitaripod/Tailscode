import CodingAgentKit
import CodingAgentKitApple
import Foundation
import Testing

@testable import TailscodeCore

private let studio = "http://studio.tail1234.ts.net:4098"
private let secret = "S3CRET-KEY-VALUE"

private func profile(_ id: String, name: String = "Studio") -> ConnectionProfile {
    ConnectionProfile(
        id: id, name: name, backend: .claudeCode, baseURL: URL(string: studio)!)
}

private func state(_ tailscale: TailscaleReading? = .up(address: "100.101.102.103")) -> FirstRunState {
    var state = FirstRunState(platform: .mac)
    state.tailscale = tailscale
    return state
}

private func recorderFlow(
    _ recorder: FirstRunRecorder, mode: FirstRunState.Mode = .firstRun
) async -> FirstRunFlow {
    let flow = FirstRunFlow(platform: .mac, mode: mode, environment: recorder.environment())
    await flow.tailscale(.up(address: "100.101.102.103"))
    return flow
}

@Suite("Empty welcome")
struct EmptyWelcomeTests {
    @Test("demo servers are not a machine, a real one is")
    func realServersOnly() {
        #expect(EmptyWelcome.holdsNoRealServer([]))
        #expect(EmptyWelcome.holdsNoRealServer(DemoWorld.profiles))
        #expect(!EmptyWelcome.holdsNoRealServer(DemoWorld.profiles + [profile("real")]))
    }

    @Test("a healthy Tailscale leaves the machine as the next step, with one primary and two ways round")
    func machineIsNext() {
        let welcome = EmptyWelcome.make(state())
        #expect(welcome.title == "Welcome to Tailscode")
        #expect(welcome.step.title == "Your machine")
        #expect(welcome.step.detail == FirstRunReading.whatAMachineIs)
        #expect(welcome.step.fix == nil)
        #expect(welcome.primary.intent == .setUpMachine)
        #expect(welcome.primary.title == "Set up a machine")
        #expect(welcome.secondary.map(\.intent) == [.pasteLink, .tryDemo])
        #expect(welcome.secondary.map(\.title) == ["Paste a link", "Try the demo"])
        #expect(welcome.actions.count == 3)
        #expect(welcome.actions.allSatisfy { !$0.help.isEmpty })
    }

    @Test("the demo is not offered again while the demo is what the app holds")
    func demoOnlyOnce() {
        let welcome = EmptyWelcome.make(state(), demoActive: true)
        #expect(welcome.secondary.map(\.intent) == [.pasteLink])
        #expect(welcome.primary.intent == .setUpMachine)
    }

    @Test("Tailscale not running is the step, in the Tailscale row's own words and remedy")
    func tailscaleDown() throws {
        for reading in [TailscaleReading.daemonDown, .loggedOut, .notInstalled] {
            let welcome = EmptyWelcome.make(state(reading))
            #expect(welcome.step.title == "Tailscale on this Mac")
            #expect(welcome.step.detail == reading.detail)
            let fix = try #require(welcome.step.fix)
            #expect(fix.intent == .openTailscale)
            #expect(fix.title == reading.actionTitle)
            #expect(welcome.primary.intent == .setUpMachine)
        }
    }

    @Test("a sandbox that cannot see Tailscale is not told Tailscale is the problem")
    func sandboxedIsNotABlocker() {
        let welcome = EmptyWelcome.make(state(.sandboxed))
        #expect(welcome.step.title == "Your machine")
        #expect(welcome.step.fix == nil)
    }

    @Test("a signed-out Claude makes the sign-in the one thing offered")
    func signedOut() throws {
        var signedOut = state()
        signedOut.connection = .saved(name: "Studio")
        signedOut.claude = .signedOut
        let welcome = EmptyWelcome.make(signedOut)
        #expect(welcome.primary.intent == .signIn)
        #expect(welcome.primary.title == "Sign in to Claude")
        #expect(welcome.secondary.isEmpty)
        #expect(welcome.step.fix == nil)
        #expect(welcome.step.title == "Claude is signed out on Studio")
    }

    @Test("the sidebar says the same thing about an empty list on every desk")
    func sidebar() {
        #expect(EmptyWelcome.sidebarLine == "No servers yet — add the machine your agent runs on")
        #expect(EmptyWelcome.setUpTitle == EmptyWelcome.make(state()).primary.title)
    }
}

@Suite("Copied link offer")
struct FirstRunOfferTests {
    @Test("a copied link is offered with the machine's name and place and never its key")
    func offerNamesTheMachineNotTheKey() throws {
        var offered = state()
        offered.clipboard = PairingLink(
            host: "studio.tail1234.ts.net", port: 4098, agent: .claude, name: "Studio", key: secret)
        let offer = try #require(FirstRunPlan.make(offered).offer)
        #expect(offer.title == "Use the link you copied")
        #expect(offer.detail == "Studio · studio.tail1234.ts.net:4098")
        #expect(!offer.detail.contains(secret) && !offer.title.contains(secret))
        let words = "\(FirstRunPlan.make(offered))"
        #expect(!words.contains(secret))
    }

    @Test("there is no offer without a link, once a link is in play, or after saving")
    func offerOnlyWhileItCanBeTaken() {
        var plain = state()
        #expect(FirstRunPlan.make(plain).offer == nil)
        plain.clipboard = PairingLink(host: "studio", port: 4098, agent: .claude)
        #expect(FirstRunPlan.make(plain).offer != nil)
        plain.way = .link
        #expect(FirstRunPlan.make(plain).offer == nil)
        plain.way = .choosing
        plain.connection = .saved(name: "Studio")
        #expect(FirstRunPlan.make(plain).offer == nil)
    }

    @Test("a link on the pasteboard is read, held and never probed or saved until it is taken")
    func neverUsedSilently() async throws {
        let recorder = FirstRunRecorder()
        await recorder.answer(studio, with: .ok(agentType: .claudeCode, version: "1.14.0"))
        let flow = await recorderFlow(recorder)
        let url = PairingLink(
            host: "studio.tail1234.ts.net", port: 4098, agent: .claude, name: "Studio", key: secret)!
            .url.absoluteString
        await flow.clipboard("here you go \(url)")
        try await Task.sleep(for: .milliseconds(80))
        #expect(await recorder.probes.isEmpty)
        #expect(await recorder.saves.isEmpty)
        let held = await flow.snapshot
        #expect(held.way == .choosing)
        #expect(held.link == nil)
        #expect(held.clipboard?.host == "studio.tail1234.ts.net")
        #expect(FirstRunPlan.make(held).offer?.detail == "Studio · studio.tail1234.ts.net:4098")

        await flow.useClipboardLink()
        let taken = await settle(flow) {
            if case .found = $0.machine { return true }
            return false
        }
        #expect(taken.way == .link)
        #expect(await recorder.saves.isEmpty)
        #expect(await recorder.probes.allSatisfy { $0.password == nil })
        #expect(FirstRunPlan.make(taken).offer == nil)
    }

    @Test("the link's key is redacted in the log line and in what the flow logs")
    func keyIsRedacted() async {
        let recorder = FirstRunRecorder()
        await recorder.answer(studio, with: .ok(agentType: .claudeCode, version: "1.14.0"))
        let flow = await recorderFlow(recorder)
        let link = PairingLink(
            host: "studio.tail1234.ts.net", port: 4098, agent: .claude, name: "Studio", key: secret)!
        await flow.clipboard(link.url.absoluteString)
        await flow.useClipboardLink()
        _ = await settle(flow) {
            if case .holdsKey = $0.machine { return true }
            return false
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ConnectLink.logLine(link).contains("<redacted>"))
        #expect(!ConnectLink.logLine(link).contains(secret))
        #expect(await recorder.logs.allSatisfy { !$0.contains(secret) })
    }
}

@Suite("First run landing")
struct FirstRunLandingTests {
    @Test("a saved machine lands the person on its own chooser with a toast naming it")
    func landsOnTheMachine() async throws {
        let recorder = FirstRunRecorder()
        await recorder.answer(studio, with: .ok(agentType: .claudeCode, version: "1.14.0"))
        await recorder.setAuth(
            ServerAuth(loggedIn: true, email: "me@example.com"))
        let flow = await recorderFlow(recorder)
        #expect(await flow.landing == nil)
        await flow.paste(PairingLink(host: "studio.tail1234.ts.net", port: 4098, agent: .claude, name: "Studio")!.url.absoluteString)
        _ = await settle(flow) {
            if case .found = $0.machine { return true }
            return false
        }
        await flow.connect()
        let landing = try #require(await flow.landing)
        let saved = try #require(await recorder.saves.first?.0)
        #expect(landing.profileID == saved.id)
        #expect(landing.toast == "Connected to Studio. Start a chat on it.")
        #expect(await flow.plan.isFinished)
    }

    @Test("the chooser opens on that machine's step even when there are several")
    func chooserSkipsTheQuestion() {
        let alpha = PaneChooserServer(
            profileID: "a", name: "alpha", backend: .claudeCode, address: "100.0.0.1:4098")
        let beta = PaneChooserServer(
            profileID: "b", name: "beta", backend: .openCode, address: "100.0.0.2:4096")
        let landing = FirstRunLanding(profileID: "b", toast: "")
        let chooser = landing.chooser(servers: [alpha, beta], entries: [])
        #expect(chooser.serverID == "b")
        #expect(chooser.rows.first?.action == .newChat(profileID: "b"))
        #expect(chooser.rows.first?.isPrimary == true)
        let unknown = FirstRunLanding(profileID: "gone", toast: "").chooser(
            servers: [alpha, beta], entries: [])
        #expect(unknown.serverID == nil)
        var asked = PaneChooser(servers: [alpha, beta], entries: [], preferredServer: "b")
        #expect(asked.serverID == nil)
        #expect(asked.activate() == nil)
    }
}

@Suite("First run fixtures")
struct FirstRunFixtureTests {
    @Test("every named state draws a plan on every desk, and an unknown name draws nothing")
    func everyNameIsAState() {
        for platform in [FirstRunPlatform.mac, .linux] {
            for name in FirstRunFixtures.names + FirstRunFixtures.names.map({ $0 + "+add" }) {
                #expect(FirstRunFixtures.state(named: name, platform: platform) != nil, "\(name)")
            }
        }
        #expect(FirstRunFixtures.state(named: "nonsense", platform: .mac) == nil)
        #expect(FirstRunFixtures.state(named: "failed:nonsense", platform: .mac) == nil)
    }

    @Test("each failure names its cause and offers the one tap that fixes it")
    func failuresCarryTheirFix() throws {
        let expected: [String: ConnectDiagnosis.Fix] = [
            "refused": .retry, "no-answer": .retry, "off-tailnet": .openTailscale,
            "wants-password": .revealPassword, "wrong-password": .revealPassword,
            "not-an-agent": .retry, "unresolved": .retry, "tailnet-only": .openTailscale,
        ]
        for (cause, fix) in expected {
            let fixture = try #require(
                FirstRunFixtures.state(named: "failed:\(cause)", platform: .mac), "\(cause)")
            guard case .failed(let diagnosis) = fixture.machine else {
                Issue.record("\(cause) is not a failure")
                continue
            }
            #expect(diagnosis.fix == fix, "\(cause)")
        }
    }

    @Test("the add-another mode never says Tailscale is missing and offers no demo and no Later")
    func addingIsNotFirstRun() throws {
        let fixture = try #require(FirstRunFixtures.state(named: "machine-asking+add", platform: .mac))
        let plan = FirstRunPlan.make(fixture)
        #expect(plan.rows.map(\.id) == [.machine, .connected])
        #expect(plan.demo == nil)
        #expect(plan.later == nil)
        #expect(plan.dismiss == "Not now")
    }

    @Test("a copy that cannot scan the tailnet says so once and still leads with the link")
    func sandboxedSaysSo() throws {
        var sandboxed = state()
        sandboxed.offersTailnetScan = false
        let plan = FirstRunPlan.make(sandboxed)
        let blocks = try #require(plan.row(.machine)?.blocks)
        guard case .ways(let ways) = try #require(blocks.first) else {
            Issue.record("the ways lead")
            return
        }
        #expect(ways.first?.kind == .link)
        #expect(!ways.contains { $0.kind == .tailnet })
        let notes = blocks.compactMap { block -> String? in
            if case .note(let text) = block { return text }
            return nil
        }
        #expect(notes == [FirstRunReading.tailnetScanUnavailable])
        #expect(FirstRunPlan.make(state()).row(.machine)?.blocks.contains {
            if case .note = $0 { return true }
            return false
        } == false)
        var phone = FirstRunState(platform: .iPhone)
        phone.offersTailnetScan = false
        #expect(FirstRunPlan.make(phone).row(.machine)?.blocks.contains {
            if case .note = $0 { return true }
            return false
        } == false)
    }
}

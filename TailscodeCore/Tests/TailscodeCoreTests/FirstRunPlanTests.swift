import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

private func state(
    _ platform: FirstRunPlatform = .iPhone, tailscale: TailscaleReading? = .up(address: "100.101.102.103")
) -> FirstRunState {
    var state = FirstRunState(platform: platform)
    state.tailscale = tailscale
    return state
}

private func found(_ agent: AgentType = .claudeCode) -> FirstRunState.Found {
    FirstRunState.Found(
        agent: agent, version: "1.14.0", url: URL(string: "http://studio.tail1234.ts.net:4098")!,
        label: "Studio")
}

@Suite("First run plan")
struct FirstRunPlanTests {
    @Test("the rows are Tailscale, the machine, then connected, in that order, on every client")
    func orderedRows() {
        for platform in FirstRunPlatform.allCases {
            let plan = FirstRunPlan.make(state(platform))
            #expect(plan.rows.map(\.id) == [.tailscale, .machine, .connected])
            #expect(plan.rows.map(\.number) == [1, 2, 3])
        }
    }

    @Test("the title of the first row says whose Tailscale it is")
    func titles() {
        let titles = FirstRunPlatform.allCases.map {
            FirstRunPlan.make(state($0)).rows[0].title
        }
        #expect(
            titles == [
                "Tailscale on this iPhone", "Tailscale on this iPad", "Tailscale on this Mac",
                "Tailscale on this computer",
            ])
    }

    @Test("Tailscale is proven by an address, still being read, or not proven")
    func tailscaleRow() throws {
        let up = try #require(FirstRunPlan.make(state()).row(.tailscale))
        #expect(up.glyph == .proven)
        #expect(up.pill == "100.101.102.103")
        #expect(up.blocks.isEmpty)

        let reading = try #require(FirstRunPlan.make(state(tailscale: nil)).row(.tailscale))
        #expect(reading.glyph == .working)
        #expect(reading.pill == "Checking…")

        let down = try #require(FirstRunPlan.make(state(tailscale: .daemonDown)).row(.tailscale))
        #expect(down.glyph == .attention)
        #expect(down.pill == "Not connected")
        #expect(down.blocks == [.remedy(.daemonDown)])
    }

    @Test("a desktop says which of the four reasons Tailscale is missing, a phone does not guess")
    func tailscaleReasons() throws {
        let linux = try #require(FirstRunPlan.make(state(.linux, tailscale: .loggedOut)).row(.tailscale))
        #expect(linux.pill == "Signed out")
        let phone = try #require(FirstRunPlan.make(state(.iPhone, tailscale: .loggedOut)).row(.tailscale))
        #expect(phone.pill == "Not connected")
    }

    @Test("the Mac that cannot see Tailscale from its sandbox says so rather than failing the row")
    func sandboxedMac() throws {
        let plan = FirstRunPlan.make(state(.mac, tailscale: .sandboxed))
        let row = try #require(plan.row(.tailscale))
        #expect(row.glyph == .current)
        #expect(row.pill == "Cannot see it")
        #expect(row.detail?.contains("sandbox") == true)
        #expect(TailscaleReading.sandboxed.blocksReaching == false)
    }

    @Test("with nothing chosen the machine row offers the three ways in, in order, and says what a machine is")
    func threeWays() throws {
        let phone = try #require(FirstRunPlan.make(state(.iPhone)).row(.machine))
        #expect(phone.detail == "A machine is the computer that runs your coding agent, on your Tailscale network.")
        guard case .ways(let ways) = phone.blocks.first else {
            Issue.record("expected ways")
            return
        }
        #expect(ways.map(\.kind) == [.scan, .link, .install, .tailnet])
        #expect(ways[0].title == "Scan the code your computer printed")
        #expect(ways[2].title == "I don't have a machine set up yet")
    }

    @Test("a desktop has no scanner, so it offers the link and the install and nothing it cannot do")
    func desktopWays() throws {
        for platform in [FirstRunPlatform.linux, .mac] {
            let row = try #require(FirstRunPlan.make(state(platform)).row(.machine))
            guard case .ways(let ways) = row.blocks.first else {
                Issue.record("expected ways")
                return
            }
            #expect(ways.map(\.kind) == [.link, .install, .tailnet])
        }
    }

    @Test("a client that cannot scan its tailnet does not offer it")
    func noTailnetScan() throws {
        var store = state(.mac)
        store.offersTailnetScan = false
        let row = try #require(FirstRunPlan.make(store).row(.machine))
        guard case .ways(let ways) = row.blocks.first else { return }
        #expect(!ways.contains { $0.kind == .tailnet })
    }

    @Test("choosing to install shows one command, no password for claude-bridge, and waits")
    func installClaude() throws {
        var store = state(.iPhone)
        store.way = .install
        store.install = BridgeInstall.install(for: .claudeCode)
        let row = try #require(FirstRunPlan.make(store).row(.machine))
        #expect(row.pill == "Waiting")
        let command = try #require(row.blocks.compactMap { block -> FirstRunPlan.CommandCard? in
            if case .command(let card) = block { return card }
            return nil
        }.first)
        #expect(!command.command.contains("PASSWORD"))
        #expect(command.sendTitle == SetupHandoff.action)
        #expect(command.sharedMessage.contains(command.command))
        #expect(!(command.note ?? "").contains("password"))
        #expect(row.blocks.contains { if case .waiting = $0 { return true } else { return false } })
        #expect(!row.blocks.contains { if case .password = $0 { return true } else { return false } })
    }

    @Test("an agent that needs a password says so in the note and carries it in the command")
    func installOpencode() throws {
        var store = state(.linux)
        store.agent = .openCode
        store.way = .install
        store.install = BridgeInstall.install(for: .openCode, password: "pw")
        let row = try #require(FirstRunPlan.make(store).row(.machine))
        let command = try #require(row.blocks.compactMap { block -> FirstRunPlan.CommandCard? in
            if case .command(let card) = block { return card }
            return nil
        }.first)
        #expect(command.command.contains("OPENCODE_SERVER_PASSWORD=pw"))
        #expect(command.note?.contains("password") == true)
        #expect(command.sendTitle == nil)
    }

    @Test("the install offers claude first and marks the one chosen")
    func agentChoices() throws {
        var store = state()
        store.way = .install
        store.agent = .omp
        store.install = BridgeInstall.install(for: .omp)
        let row = try #require(FirstRunPlan.make(store).row(.machine))
        guard case .agents(let choices) = row.blocks.first else {
            Issue.record("expected agents")
            return
        }
        #expect(choices.map(\.agent) == [.claudeCode, .openCode, .omp])
        #expect(choices.filter(\.isSelected).map(\.agent) == [.omp])
    }

    @Test("waiting words differ by what the client can watch")
    func waitingWords() {
        #expect(FirstRunReading.waitingForMachine(.iPhone).contains("scan the code"))
        #expect(FirstRunReading.waitingForMachine(.linux).contains("shows up here"))
    }

    @Test("a found machine proves its row, names the agent and version, and offers Connect")
    func foundMachine() throws {
        var store = state()
        store.machine = .found(found())
        let plan = FirstRunPlan.make(store)
        let machine = try #require(plan.row(.machine))
        #expect(machine.glyph == .proven)
        #expect(machine.pill == "Claude Code 1.14.0")
        let connected = try #require(plan.row(.connected))
        #expect(connected.glyph == .current)
        #expect(connected.detail == "Saved nothing yet. Press Connect to add Studio.")
        #expect(plan.primary?.title == "Connect to Studio")
        #expect(plan.primary?.intent == .connect)
        #expect(plan.primary?.isEnabled == true)
    }

    @Test("a machine that wants its password and holds the link's key says so")
    func holdsKey() throws {
        var store = state()
        store.machine = .holdsKey(label: "Studio", agent: .omp, url: URL(string: "http://studio:4099")!)
        let plan = FirstRunPlan.make(store)
        let machine = try #require(plan.row(.machine))
        #expect(machine.pill == "Wants its password")
        #expect(machine.detail?.contains("The link brought it") == true)
        #expect(plan.primary?.isEnabled == true)
    }

    @Test("a probe under way is the working glyph and a disabled button")
    func looking() throws {
        var store = state()
        store.way = .paste
        store.typed = "studio"
        store.machine = .looking(label: "studio")
        let plan = FirstRunPlan.make(store)
        #expect(plan.row(.machine)?.glyph == .working)
        #expect(plan.primary?.isLoading == true)
        #expect(plan.primary?.isEnabled == false)
        #expect(plan.row(.machine)?.blocks.contains(.waiting("Looking for studio…")) == true)
    }

    @Test("a failure is the diagnosis and nothing else about ports")
    func failure() throws {
        let address = HostAddress(url: URL(string: "http://studio:4098")!, portWasInferred: false)
        let diagnosis = try #require(
            ConnectDiagnosis.make(
                outcome: .unreachable(""), address: address, tailnetAddress: "100.1.1.1",
                alternatePort: nil, sentPassword: false, reachability: .refused))
        var store = state()
        store.way = .paste
        store.typed = "studio"
        store.machine = .failed(diagnosis)
        let row = try #require(FirstRunPlan.make(store).row(.machine))
        #expect(row.glyph == .attention)
        #expect(row.blocks.contains(.diagnosis(diagnosis)))
        #expect(!diagnosis.detail.localizedCaseInsensitiveContains("check the port"))
        #expect(diagnosis.detail.contains("studio"))
    }

    @Test("a phone with Tailscale down and nothing chosen gets Open Tailscale as its one press")
    func phoneOpensTailscale() {
        let plan = FirstRunPlan.make(state(.iPhone, tailscale: .daemonDown))
        #expect(plan.primary?.intent == .openTailscale)
        let desktop = FirstRunPlan.make(state(.linux, tailscale: .daemonDown))
        #expect(desktop.primary == nil)
    }

    @Test("the demo is one tap away until a server is being saved")
    func demo() {
        #expect(FirstRunPlan.make(state()).demo?.title == "Try the demo")
        var saving = state()
        saving.connection = .saving
        #expect(FirstRunPlan.make(saving).demo == nil)
    }

    @Test("connected is proven by a saved server and a Claude that is signed in")
    func connectedSignedIn() throws {
        var store = state()
        store.machine = .found(found())
        store.connection = .saved(name: "Studio")
        store.claude = .signedIn(account: "me@example.com")
        let plan = FirstRunPlan.make(store)
        let row = try #require(plan.row(.connected))
        #expect(row.glyph == .proven)
        #expect(row.detail == "Connected to Studio, signed in to Claude as me@example.com.")
        #expect(plan.primary == nil)
    }

    @Test("a signed-out Claude is read right away and opens the sign-in inside first run")
    func connectedSignedOut() throws {
        var store = state()
        store.machine = .found(found())
        store.connection = .saved(name: "Studio")
        store.claude = .signedOut
        let plan = FirstRunPlan.make(store)
        let row = try #require(plan.row(.connected))
        #expect(row.glyph == .attention)
        #expect(row.blocks.contains { if case .signIn = $0 { return true } else { return false } })
        #expect(plan.primary?.intent == .signIn)
        #expect(plan.primary?.title == "Sign in to Claude")
        #expect(plan.later == "Later")
        #expect(!plan.isFinished)
    }

    @Test("a server that cannot say whether it is signed in is connected, not signed out")
    func cannotSay() throws {
        var store = state()
        store.machine = .found(found(.openCode))
        store.connection = .saved(name: "Studio")
        store.claude = .cannotSay
        let row = try #require(FirstRunPlan.make(store).row(.connected))
        #expect(row.glyph == .proven)
        #expect(row.detail == "Connected to Studio.")
    }

    @Test("an addition has no Tailscale row and no demo, and its button says Add")
    func addition() throws {
        var store = FirstRunState(platform: .iPhone, mode: .addition)
        store.machine = .found(found())
        let plan = FirstRunPlan.make(store)
        #expect(plan.rows.map(\.id) == [.machine, .connected])
        #expect(plan.rows.map(\.number) == [1, 2])
        #expect(plan.demo == nil)
        #expect(plan.primary?.title == "Add Studio")
    }

    @Test("the link card lands with its lines and offers to go on when the host is off the tailnet")
    func linkCard() throws {
        let parsed = try #require(
            PairingLink(host: "192.168.1.20", port: 4098, agent: .claude, name: "Desk"))
        var store = state()
        store.way = .link
        store.link = ConnectLinkPlan.make(link: parsed, profiles: [])
        let row = try #require(FirstRunPlan.make(store).row(.machine))
        guard case .link(let card) = row.blocks.first else {
            Issue.record("expected the link card")
            return
        }
        #expect(card.headline == "Add Desk")
        #expect(card.connectAnywayTitle == "Connect anyway")
        #expect(card.lines.contains { $0.hasPrefix("This address is not on a tailnet") })
        store.offTailnetConfirmed = true
        guard case .link(let after) = FirstRunPlan.make(store).row(.machine)?.blocks.first else { return }
        #expect(after.connectAnywayTitle == nil)
    }

    @Test("the paste field offers a link found on the clipboard and reads what is typed")
    func pasteField() throws {
        var store = state(.linux)
        store.way = .paste
        store.typed = "studio"
        store.clipboard = PairingLink(host: "studio", port: 4098, agent: .claude, name: "Studio")
        let row = try #require(FirstRunPlan.make(store).row(.machine))
        guard case .paste(let paste) = row.blocks.first else {
            Issue.record("expected the paste field")
            return
        }
        #expect(paste.offer == "Add Studio from your clipboard")
        #expect(paste.reading == "→ http://studio:4098")
    }

    @Test("a link that could not be read is told in plain words in the paste field")
    func pasteMessage() throws {
        var store = state()
        store.way = .paste
        store.notice = ConnectLinkReading.rejection(.malformed)
        let row = try #require(FirstRunPlan.make(store).row(.machine))
        guard case .paste(let paste) = row.blocks.first else { return }
        #expect(paste.message?.title == "That link is damaged")
    }

    @Test("the password field appears only once something asked for it")
    func passwordField() throws {
        var store = state()
        store.way = .paste
        store.typed = "studio"
        #expect(!FirstRunPlan.make(store).rows[1].blocks.contains { if case .password = $0 { return true } else { return false } })
        store.passwordShown = true
        store.passwordNote = "note"
        #expect(FirstRunPlan.make(store).rows[1].blocks.contains(.password(note: "note")))
    }
}

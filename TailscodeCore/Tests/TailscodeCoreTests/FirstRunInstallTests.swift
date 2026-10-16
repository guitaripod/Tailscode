import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("First run install command")
struct FirstRunInstallTests {
    @Test("claude-bridge from 1.7.2 admits a node on the same Tailscale account, so its command has no password")
    func claudeBridgeTrustsTheTailnetFrom1_7_2() {
        #expect(!BridgeInstall.needsPassword(.claudeCode))
        let install = BridgeInstall.install(for: .claudeCode)
        #expect(install.password == nil)
        #expect(install.command == BridgeInstall.installCommand)
        #expect(!install.command.contains("PASSWORD"))
        #expect(install.command.contains("guitaripod/claude-bridge"))
    }

    @Test("omp-bridge 0.8 has no tailnet gate and refuses to start without OMP_PASSWORD")
    func ompBridge0_8WantsAPassword() {
        #expect(BridgeInstall.needsPassword(.omp))
        let install = BridgeInstall.install(for: .omp, password: "abc123")
        #expect(install.password == "abc123")
        #expect(install.command.contains("OMP_PASSWORD=abc123"))
    }

    @Test("opencode has no tailnet gate and opencode 2 always wants OPENCODE_SERVER_PASSWORD")
    func opencodeWantsAPassword() {
        #expect(BridgeInstall.needsPassword(.openCode))
        let install = BridgeInstall.install(for: .openCode, password: "abc123")
        #expect(install.command.contains("OPENCODE_SERVER_PASSWORD=abc123"))
    }

    @Test("a password is minted only for the agents that need one")
    func mintsOnlyWhereNeeded() {
        for agent in AgentType.allCases {
            let install = BridgeInstall.install(for: agent)
            #expect((install.password != nil) == BridgeInstall.needsPassword(agent))
            if let password = install.password {
                #expect(password.count == 16)
                #expect(install.command.contains(password))
            }
        }
    }

    @Test("a password the setup minted is still read back out of what a person pastes")
    func passwordInPaste() {
        let line = "BRIDGE_PASSWORD=pw9 claude-bridge"
        #expect(BridgeInstall.password(in: line) == "pw9")
    }

    @Test("the agent a link names maps onto the agent the app talks to, both ways")
    func agentMapping() {
        for agent in PairingAgent.allCases {
            #expect(agent.agentType.pairingAgent == agent)
        }
        for agent in AgentType.allCases {
            #expect(agent.pairingAgent.agentType == agent)
        }
    }
}

@Suite("Launch link arguments")
struct LaunchLinkTests {
    private let link = "tailscode://connect?v=1&host=studio&port=4098&agent=claude"

    @Test("a bare tailscode:// argument is a link, as a desktop hands one over")
    func bareArgument() {
        #expect(LaunchLink.request(arguments: ["tailscode", link]) == .link(link))
        #expect(LaunchLink.request(arguments: ["/usr/bin/tailscode", "TAILSCODE://connect?x=1"]) == .link("TAILSCODE://connect?x=1"))
    }

    @Test("--connect with a link is a link, and --connect with an address stays the headless save")
    func connectFlag() {
        #expect(LaunchLink.request(arguments: ["tailscode", "--connect", link]) == .link(link))
        #expect(LaunchLink.request(arguments: ["tailscode", "--connect", "100.64.0.9:4098"]) == .none)
        #expect(LaunchLink.isHeadlessConnect(arguments: ["tailscode", "--connect", "100.64.0.9"]))
        #expect(!LaunchLink.isHeadlessConnect(arguments: ["tailscode", "--connect", link]))
        #expect(!LaunchLink.isHeadlessConnect(arguments: ["tailscode", "--ask"]))
    }

    @Test("nothing else on the command line is a link")
    func otherArguments() {
        #expect(LaunchLink.request(arguments: ["tailscode"]) == .none)
        #expect(LaunchLink.request(arguments: []) == .none)
        #expect(LaunchLink.request(arguments: ["tailscode", "--ask"]) == .none)
        #expect(LaunchLink.request(arguments: ["tailscode", "--demo"]) == .none)
        #expect(LaunchLink.request(arguments: ["tailscode", "https://example.com"]) == .none)
        #expect(LaunchLink.request(arguments: ["tailscode", "--connect"]) == .none)
    }

    @Test("a value that happens to look like a link is not a link when a flag owns it")
    func flagValues() {
        #expect(LaunchLink.request(arguments: ["tailscode", "--password", link]) == .none)
        #expect(LaunchLink.request(arguments: ["tailscode", "--name", link, "--ask"]) == .none)
    }

    @Test("the first link wins and flags around it do not hide it")
    func firstWins() {
        #expect(LaunchLink.request(arguments: ["tailscode", "--demo", link, "tailscode://connect?other"]) == .link(link))
    }

    @Test("a link argument is read by the same handler a paste goes through")
    func argumentReachesTheHandler() throws {
        guard case .link(let argument) = LaunchLink.request(arguments: ["tailscode", link]) else {
            Issue.record("expected a link")
            return
        }
        #expect(try #require(ConnectLink.read(argument).link).host == "studio")
    }
}

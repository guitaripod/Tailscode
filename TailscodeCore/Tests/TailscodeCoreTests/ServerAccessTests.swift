import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// A tailnet is a credential. What these pin is that the words never call a trusted device
/// unprotected, never call a tailnet-only refusal a password prompt, and say nothing about a server
/// that said nothing.
@Suite("Server access")
struct ServerAccessTests {
    @Test("what let this device in is one line, and silence stays silent")
    func line() {
        #expect(ServerAccessReading.line(nil) == nil)
        #expect(
            ServerAccessReading.line(ServerAccess(mode: .tailnet, login: "me@example.com", node: "iphone"))
                == "Trusted through your tailnet as me@example.com — no password")
        #expect(
            ServerAccessReading.line(ServerAccess(mode: .tailnet))
                == "Trusted through your tailnet — no password")
        #expect(ServerAccessReading.line(ServerAccess(mode: .password)) == "Let in by its password")
        #expect(
            ServerAccessReading.line(ServerAccess(mode: .open))
                == "Open — no password and no tailnet check")
    }

    @Test("a tailnet-only refusal sends the person to Tailscale, never to a password field")
    func tailnetOnlyDiagnosis() throws {
        let address = HostAddress(url: URL(string: "http://arch:4098")!, portWasInferred: false)
        let diagnosis = try #require(
            ConnectDiagnosis.make(
                outcome: .authFailed(.tailnetOnly), address: address, tailnetAddress: "100.64.0.9",
                alternatePort: nil, sentPassword: false, reachability: .listening))
        #expect(diagnosis.fix == .openTailscale)
        #expect(diagnosis.title == "arch:4098 trusts only its own tailnet")
        #expect(diagnosis.detail.contains("no password"))

        let password = try #require(
            ConnectDiagnosis.make(
                outcome: .authFailed(.password), address: address, tailnetAddress: "100.64.0.9",
                alternatePort: nil, sentPassword: false, reachability: .listening))
        #expect(password.fix == .revealPassword)
    }

    @Test("a scan row tells the two locks apart")
    func suggestionNote() {
        let open = TailnetScanner.Suggestion(
            id: "a", name: "arch", baseURL: URL(string: "http://arch:4098")!, backend: .claudeCode,
            version: "1.7", requiresAuth: false, recommendedProfileName: "arch", os: nil, lastSeen: nil)
        var locked = TailnetScanner.Suggestion(
            id: "b", name: "arch", baseURL: URL(string: "http://arch:4098")!, backend: .claudeCode,
            version: nil, requiresAuth: true, recommendedProfileName: "arch", os: nil, lastSeen: nil)
        #expect(ServerAccessReading.suggestionNote(open) == nil)
        #expect(ServerAccessReading.suggestionNote(locked) == "wants a password")
        locked.tailnetOnly = true
        #expect(ServerAccessReading.suggestionNote(locked) == "its tailnet only")
    }
}

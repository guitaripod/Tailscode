import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("New chat failures")
struct NewChatAttemptTests {
    private let arch = NewChatServer(
        profileID: "P1", name: "arch", backend: .claudeCode, address: "100.91.211.44:4096")

    @Test("A profile on the other agent's port is fixed by the app, not explained to the user")
    func wrongPortRepoints() {
        let bridge = URL(string: "http://100.91.211.44:4098")!
        let failure = NewChatDiagnosis.failure(
            server: arch, directory: "/tmp", error: "401",
            witness: .wrongPort(found: .openCode, expectedAt: bridge))
        #expect(failure.fix == .repoint(profileID: "P1", url: bridge, backend: .claudeCode))
        #expect(failure.actionTitle == "Use :4098")
        #expect(failure.detail.contains("100.91.211.44:4096"))
        #expect(failure.detail.contains(":4098"))
    }

    @Test("A password rejected with no agent elsewhere is a password problem, not a port one")
    func wantsPassword() {
        let failure = NewChatDiagnosis.failure(
            server: arch, directory: nil, error: "401", witness: .wantsPassword)
        #expect(failure.fix == .editServer(profileID: "P1"))
        #expect(failure.title.contains("arch"))
    }

    @Test("Nothing listening names the address rather than a URLError")
    func silent() {
        let failure = NewChatDiagnosis.failure(
            server: arch, directory: "/tmp",
            error: "Error Domain=NSURLErrorDomain Code=-1004", witness: .silent)
        #expect(failure.fix == .editServer(profileID: "P1"))
        #expect(failure.detail.contains("100.91.211.44:4096"))
        #expect(!failure.detail.contains("NSURLErrorDomain"))
    }

    @Test("A healthy server that refuses is quoted, and the folder is named")
    func healthyRefusal() {
        let failure = NewChatDiagnosis.failure(
            server: arch, directory: "/nope", error: "no such directory", witness: .healthy)
        #expect(failure.fix == .retry)
        #expect(failure.title.contains("/nope"))
        #expect(failure.detail.contains("no such directory"))
    }

    @Test("The wrong agent on the machine says so instead of offering a port that is not there")
    func otherAgentHere() {
        let failure = NewChatDiagnosis.failure(
            server: arch, directory: nil, error: "", witness: .otherAgentHere(.openCode))
        #expect(failure.fix == .editServer(profileID: "P1"))
        #expect(failure.title.contains("opencode"))
        #expect(failure.title.contains("Claude Code"))
    }

    @Test("A device with no password for a server never reaches the network to find out")
    func noCredentials() {
        let failure = NewChatDiagnosis.noCredentials(server: arch)
        #expect(failure.fix == .editServer(profileID: "P1"))
        #expect(failure.title.contains("arch"))
    }

    @Test("Every failure carries words for a screen reader and a glyph for a text client")
    func everyFailureSpeaks() {
        let bridge = URL(string: "http://x:4098")!
        let witnesses: [NewChatWitness] = [
            .unknown, .silent, .wantsPassword, .healthy, .notAnAgentHere,
            .otherAgentHere(.openCode), .wrongPort(found: nil, expectedAt: bridge),
        ]
        for witness in witnesses {
            let failure = NewChatDiagnosis.failure(
                server: arch, directory: "/tmp", error: "x", witness: witness)
            #expect(!failure.title.isEmpty)
            #expect(!failure.detail.isEmpty)
            #expect(!failure.glyph.isEmpty)
            #expect(!failure.symbol.isEmpty)
            #expect(failure.spoken.contains(failure.title))
        }
    }

    @Test("A phase knows whether it is waiting and what it is holding")
    func phases() {
        #expect(NewChatPhase.asking.failure == nil)
        #expect(NewChatPhase.starting(server: "arch").isBusy)
        let failure = NewChatDiagnosis.noSuchServer()
        #expect(NewChatPhase.failed(failure).failure == failure)
        #expect(!NewChatPhase.failed(failure).isBusy)
        #expect(failure.fix == NewChatFailure.Fix.none)
        #expect(failure.actionTitle == nil)
    }
}

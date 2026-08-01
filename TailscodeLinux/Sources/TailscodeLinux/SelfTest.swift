import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// `tailscode --selftest` drives the whole chain with no window: tailnet reading, profile and
/// secret stores, every configured server's health and session list, then the newest session's
/// stream until a transcript lands.
///
/// This is how the Linux client is validated in a build loop — and on a headless box it is the
/// only way, since there is no display to render into and no Secret Service to answer.
public enum SelfTest {
    public static var isRequested: Bool { CommandLine.arguments.contains("--selftest") }

    public static func run() async -> Never {
        startWatchdog()
        var failures = 0

        let tailnet = TailnetStatusLinux.read()
        report("tailnet: \(tailnet.address ?? "no address") · \(tailnet.peers.count) peers")

        do {
            try await checkStores()
            report("stores: ok")
        } catch {
            report("stores: \(error)")
            failures += 1
        }

        await ServerDirectory.shared.reload()
        let profiles = await ServerDirectory.shared.profiles()
        guard !profiles.isEmpty else {
            report("no servers configured — set TAILSCODE_HOST to seed one")
            exit(1)
        }

        for profile in profiles {
            guard let backend = await ServerDirectory.shared.backend(for: profile) else {
                report("\(profile.name): no backend")
                failures += 1
                continue
            }
            do {
                let health = try await backend.health()
                let sessions = try await backend.listSessions()
                report("\(profile.name): \(health.version ?? "unknown") · \(sessions.count) sessions")
                guard let newest = sessions.max(by: { $0.updatedAt < $1.updatedAt }) else { continue }
                let state = try await firstState(of: newest, on: backend)
                report("  \(newest.title.prefix(50)): \(state.messages.count) messages")
                guard state.hasLoadedTranscript else {
                    report("  transcript never loaded")
                    failures += 1
                    continue
                }
            } catch {
                report("\(profile.name): \(error)")
                failures += 1
            }
        }

        let (entries, unreachable) = await ServerDirectory.shared.entries()
        report("list: \(entries.count) entries, \(unreachable.count) unreachable")

        report(failures == 0 ? "SELFTEST_OK" : "SELFTEST_FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// The stores are exercised against a throwaway directory rather than the real one: a self-test
    /// that rewrites the user's server list is not a test.
    private static func checkStores() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tailscode-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let secrets = FileSecretStore(url: scratch.appendingPathComponent("secrets.json"))
        try secrets.setValue("hunter2", for: "probe")
        guard try secrets.value(for: "probe") == "hunter2" else {
            throw SelfTestFailure("secret did not round-trip")
        }
        try secrets.removeValue(for: "probe")
        guard try secrets.value(for: "probe") == nil else {
            throw SelfTestFailure("secret survived removal")
        }

        let store = LinuxProfileStore(
            secrets: secrets, url: scratch.appendingPathComponent("profiles.json"))
        let profile = ConnectionProfile(
            id: "probe", name: "probe", backend: .claudeCode,
            baseURL: URL(string: "http://127.0.0.1:4098")!, username: "claude")
        try store.save(profile, password: "pw")
        guard try store.profiles().count == 1, try store.password(for: "probe") == "pw" else {
            throw SelfTestFailure("profile did not round-trip")
        }
        try store.delete(id: "probe")
        guard try store.profiles().isEmpty else {
            throw SelfTestFailure("profile survived deletion")
        }
    }

    private static func firstState(
        of session: AgentSession, on backend: any CodingAgentBackend
    ) async throws -> ConversationState {
        let conversation = AgentConversation(backend: backend, sessionID: session.id)
        var latest = ConversationState()
        let deadline = Date().addingTimeInterval(20)
        for await state in await conversation.states() {
            latest = state
            if state.hasLoadedTranscript || Date() > deadline { break }
        }
        return latest
    }

    private static func startWatchdog() {
        Task.detached {
            try? await Task.sleep(for: .seconds(90))
            FileHandle.standardOutput.write(Data("SELFTEST_TIMEOUT\n".utf8))
            exit(2)
        }
    }

    static func report(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

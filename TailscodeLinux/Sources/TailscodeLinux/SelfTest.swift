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

        var warmed: (backend: any CodingAgentBackend, session: AgentSession)?
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
                guard let newest = Self.observable(in: sessions) else { continue }
                let state = try await firstState(of: newest, on: backend)
                report("  \(newest.title.prefix(50)): \(state.messages.count) messages")
                guard state.hasLoadedTranscript else {
                    report("  transcript never loaded")
                    failures += 1
                    continue
                }
                if warmed == nil { warmed = (backend, newest) }
            } catch {
                report("\(profile.name): \(error)")
                failures += 1
            }
        }

        let (entries, unreachable) = await ServerDirectory.shared.entries()
        report("list: \(entries.count) entries, \(unreachable.count) unreachable")

        #if !HAS_VTE
            let shellOutput = TerminalPane.shell("echo tailscode-shell-ok", in: nil)
            if shellOutput.contains("tailscode-shell-ok") {
                report("shell: ok (one command at a time; install vte4 for a full terminal)")
            } else {
                report("shell: no output")
                failures += 1
            }
        #else
            report("shell: vte4 terminal")
        #endif

        if let warmed {
            do {
                let count = try await checkTwoObservers(
                    backend: warmed.backend, session: warmed.session)
                report("two observers: agree on \(count) messages")
            } catch {
                report("two observers: \(error)")
                failures += 1
            }
        } else {
            report("two observers: no loaded session to observe")
            failures += 1
        }

        if ProcessInfo.processInfo.environment["TAILSCODE_SELFTEST_SEND"] == "1" {
            do {
                try await checkRoundTrip(profiles)
                report("send: ok")
            } catch {
                report("send: \(error)")
                failures += 1
            }
        }

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

    /// Two observers on one conversation, which is the whole point of a desktop client that is a
    /// peer of the phone rather than a second app. Until recently the second call to `states()`
    /// tore down the first, so this is the check that the fix holds against a real server.
    private static func checkTwoObservers(
        backend: any CodingAgentBackend, session: AgentSession
    ) async throws -> Int {
        let conversation = AgentConversation(backend: backend, sessionID: session.id)
        async let first = settled(conversation)
        async let second = settled(conversation)
        let (a, b) = try await (first, second)

        guard !a.isEmpty else { throw SelfTestFailure("first observer saw nothing") }
        guard a == b else {
            throw SelfTestFailure("observers diverged: \(a.count) vs \(b.count) messages")
        }
        return a.count
    }

    /// Bounded from outside the stream: a `for await` whose server never answers receives no
    /// state to check a deadline against, so the deadline must not live inside the loop.
    private static func settled(_ conversation: AgentConversation) async throws -> [String] {
        try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask {
                for await state in await conversation.states() {
                    if state.hasLoadedTranscript { return state.messages.map(\.id) }
                }
                throw SelfTestFailure("observer stream ended before a transcript")
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(25))
                throw SelfTestFailure("observer never loaded a transcript in 25s")
            }
            guard let first = try await group.next() else {
                throw SelfTestFailure("no observer outcome")
            }
            group.cancelAll()
            return first
        }
    }

    /// Sends a real prompt through the same path the composer uses and waits for the answer, in a
    /// throwaway session in a throwaway directory. Opt-in, because it spends tokens and starts a
    /// turn on the user's own machine.
    private static func checkRoundTrip(_ profiles: [ConnectionProfile]) async throws {
        guard let profile = profiles.first,
            let backend = await ServerDirectory.shared.backend(for: profile)
        else { throw SelfTestFailure("no backend to send through") }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tailscode-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let session = try await backend.createSession(
            title: "selftest", directory: scratch.path)
        defer { Task { try? await backend.deleteSession(session.id) } }

        let conversation = AgentConversation(backend: backend, sessionID: session.id)
        let states = await conversation.states()
        try await conversation.send("Reply with the single word PONG and nothing else.")

        let deadline = Date().addingTimeInterval(90)
        for await state in states {
            let answered = state.messages.contains {
                $0.role == .assistant && $0.text.uppercased().contains("PONG")
            }
            if answered { return }
            if Date() > deadline { break }
        }
        throw SelfTestFailure("no answer within the deadline")
    }

    /// Bounded the same way as ``settled(_:)``: the deadline lives outside the stream, and it is
    /// generous — a bridge mid-turn on a large transcript legitimately takes tens of seconds
    /// today, and this test is about correctness, not the latency the sync plan will buy.
    private static func firstState(
        of session: AgentSession, on backend: any CodingAgentBackend
    ) async throws -> ConversationState {
        let conversation = AgentConversation(backend: backend, sessionID: session.id)
        return await withTaskGroup(of: ConversationState?.self) { group in
            group.addTask {
                for await state in await conversation.states() where state.hasLoadedTranscript {
                    return state
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(45))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? ConversationState()
        }
    }

    /// The newest session that is not mid-turn. An active session's transcript can be enormous
    /// and its server busy running it — that is the wrong subject for a bounded smoke test, and
    /// the two-observer check does not care which conversation it observes.
    private static func observable(in sessions: [AgentSession]) -> AgentSession? {
        let sorted = sessions.sorted { $0.updatedAt > $1.updatedAt }
        return sorted.first { !$0.isWorking } ?? sorted.first
    }

    private static func startWatchdog() {
        Task.detached {
            try? await Task.sleep(for: .seconds(150))
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

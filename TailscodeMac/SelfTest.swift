import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// `TailscodeMac --selftest` drives the whole chain with no window: it resolves the servers this
/// Mac knows about, lists their sessions, opens the newest one and waits for the first state the
/// stream delivers, then says what it saw and exits.
///
/// A Mac reached over ssh has no window server, so a screenshot cannot prove the app works from a
/// build loop. This can.
@MainActor
enum SelfTest {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest")
    }

    static func run() async -> Never {
        startWatchdog()
        let profiles = ServerDirectory.shared.profiles
        guard !profiles.isEmpty else {
            report("no servers configured — set TAILSCODE_HOST to seed one")
            exit(1)
        }

        var failures = 0
        for profile in profiles {
            guard let backend = ServerDirectory.shared.backend(for: profile) else {
                report("\(profile.name): no backend")
                failures += 1
                continue
            }
            do {
                let health = try await backend.health()
                let sessions = try await backend.listSessions()
                report(
                    "\(profile.name): \(health.version ?? "unknown") · \(sessions.count) sessions")
                guard let newest = sessions.first else { continue }
                let state = try await firstState(of: newest, on: backend)
                report(
                    "  \(newest.title): \(state.messages.count) messages · \(state.connection)")
            } catch {
                report("\(profile.name): \(error)")
                failures += 1
            }
        }
        do {
            let count = try await checkTwoObservers(profiles)
            report("two observers: agree on \(count) messages")
        } catch {
            report("two observers: \(error)")
            failures += 1
        }

        report(failures == 0 ? "SELFTEST_OK" : "SELFTEST_FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// Two observers on one conversation, which is the whole point of a desktop client that is a
    /// peer of the phone rather than a second app. Until recently the second call to `states()`
    /// tore down the first, so this is the check that the fix holds against a real server.
    private static func checkTwoObservers(_ profiles: [ConnectionProfile]) async throws -> Int {
        guard let profile = profiles.first,
            let backend = ServerDirectory.shared.backend(for: profile),
            let session = try await backend.listSessions().max(by: { $0.updatedAt < $1.updatedAt })
        else { throw SelfTestFailure("nothing to observe") }

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

    private static func settled(_ conversation: AgentConversation) async throws -> [String] {
        let deadline = Date().addingTimeInterval(20)
        for await state in await conversation.states() {
            if state.hasLoadedTranscript { return state.messages.map(\.id) }
            if Date() > deadline { break }
        }
        throw SelfTestFailure("observer never loaded a transcript")
    }

    /// The first snapshot that has actually loaded a transcript, or whatever arrived within the
    /// deadline — a stream that never delivers is the failure this is looking for.
    private static func firstState(
        of session: AgentSession, on backend: any CodingAgentBackend
    ) async throws -> ConversationState {
        let conversation = AgentConversation(backend: backend, sessionID: session.id)
        var latest = ConversationState()
        let deadline = Date().addingTimeInterval(15)
        for await state in await conversation.states() {
            latest = state
            if state.hasLoadedTranscript || Date() > deadline { break }
        }
        return latest
    }

    /// A self-test that hangs is worse than one that fails: it stalls the build loop on a machine
    /// nobody is looking at.
    private static func startWatchdog() {
        Task.detached {
            try? await Task.sleep(for: .seconds(60))
            FileHandle.standardOutput.write(Data("SELFTEST_TIMEOUT\n".utf8))
            exit(2)
        }
    }

    private static func report(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

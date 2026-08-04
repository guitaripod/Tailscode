import CodingAgentKit
import Foundation
import TailscodeCore

enum ProbeNewChat {
    static var isRequested: Bool { Arguments.contains("--probe-newchat") }

    static func run() async -> Never {
        let clock = ContinuousClock()
        var last = clock.now
        func mark(_ label: String) {
            let now = clock.now
            let ms = (now - last).components.attoseconds / 1_000_000_000_000_000
            print("PROBE \(label): \(ms)ms")
            last = now
        }

        await ServerDirectory.shared.reload()
        mark("reload")
        let profiles = await ServerDirectory.shared.profiles()
        guard let profile = profiles.first(where: { $0.backend == .claudeCode }) ?? profiles.first
        else {
            print("PROBE no profiles")
            exit(1)
        }
        mark("profiles")
        guard let backend = await ServerDirectory.shared.backend(for: profile) else {
            print("PROBE no backend")
            exit(1)
        }
        mark("backend(makeBackend)")

        let session: AgentSession
        do {
            session = try await backend.createSession(title: nil, directory: "/tmp")
        } catch {
            print("PROBE createSession failed: \(error)")
            exit(1)
        }
        mark("createSession")

        let (entries, unreachable) = await ServerDirectory.shared.entries()
        mark("entries(refresh) — \(entries.count) entries, \(unreachable.count) down")

        _ = try? await backend.messages(for: session.id)
        mark("messages(for:)")
        _ = try? await backend.pendingQuestions(for: session.id)
        mark("pendingQuestions(for:)")
        _ = try? await backend.goal(for: session.id)
        mark("goal(for:)")
        _ = try? await backend.availableModels()
        mark("availableModels")
        _ = try? await backend.availableCommands(directory: "/tmp")
        mark("availableCommands")

        var iterator = backend.events(for: session.id).makeAsyncIterator()
        let eventsTask = Task { _ = try? await iterator.next() }
        try? await Task.sleep(for: .milliseconds(50))
        mark("events(for:) subscribed")

        let conversation = AgentConversation(
            backend: backend, sessionID: session.id, cache: AppCache.sessionCache)
        let states = await conversation.states()
        mark("states() call")
        var sawFirst = false
        for await state in states {
            if !sawFirst {
                sawFirst = true
                mark("first state (loaded=\(state.hasLoadedTranscript))")
            }
            if state.hasLoadedTranscript {
                mark("loaded transcript (\(state.messages.count) messages)")
                break
            }
        }
        eventsTask.cancel()

        try? await backend.deleteSession(session.id)
        mark("deleteSession")
        print("PROBE_DONE")
        exit(0)
    }
}

import CodingAgentKit
import CodingAgentKitApple
import Foundation

@testable import TailscodeCore

actor FirstRunRecorder {
    struct Probe: Sendable, Equatable {
        let url: URL
        let password: String?
        let agent: AgentType
        let interactive: Bool
    }

    var probes: [Probe] = []
    var saves: [(ConnectionProfile, String?)] = []
    var logs: [String] = []
    var answers: [String: ConnectionProbe.Outcome] = [:]
    var fallback: ConnectionProbe.Outcome = .unreachable("")
    var reachability: PortReachability.Verdict?
    var saveResult: FirstRunSave = .saved
    var auth: ServerAuth?
    var profiles: [ConnectionProfile] = []
    var accountCalls = 0

    func answer(_ url: String, with outcome: ConnectionProbe.Outcome) {
        answers[url] = outcome
    }

    func setFallback(_ outcome: ConnectionProbe.Outcome) { fallback = outcome }
    func setSaveResult(_ result: FirstRunSave) { saveResult = result }
    func setAuth(_ value: ServerAuth?) { auth = value }
    func setProfiles(_ value: [ConnectionProfile]) { profiles = value }
    func setReachability(_ value: PortReachability.Verdict?) { reachability = value }

    func record(_ probe: Probe) -> FirstRunProbe {
        probes.append(probe)
        let outcome = answers[probe.url.absoluteString] ?? fallback
        return FirstRunProbe(url: probe.url, outcome: outcome, reachability: reachability)
    }

    func record(_ profile: ConnectionProfile, _ password: String?) -> FirstRunSave {
        saves.append((profile, password))
        return saveResult
    }

    func note(_ line: String) { logs.append(line) }
    func currentAuth() -> ServerAuth? {
        accountCalls += 1
        return auth
    }

    nonisolated func environment(offersTailnetScan: Bool = true) -> FirstRunEnvironment {
        FirstRunEnvironment(
            offersTailnetScan: offersTailnetScan,
            profiles: { await self.profiles },
            save: { await self.record($0, $1) },
            probe: { address, password, agent, interactive in
                await self.record(
                    Probe(url: address.url, password: password, agent: agent, interactive: interactive))
            },
            account: { _, _ in await self.currentAuth() },
            mintPassword: { "MINTED-PASSWORD" },
            log: { line in Task { await self.note(line) } },
            typingDelay: .zero)
    }
}

func settle(_ flow: FirstRunFlow, until condition: @Sendable (FirstRunState) -> Bool) async -> FirstRunState {
    for _ in 0..<400 {
        let state = await flow.snapshot
        if condition(state) { return state }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await flow.snapshot
}

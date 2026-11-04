import TailscodeCore
import CodingAgentKit
import Foundation

extension ChatViewModel {
    var supportsSubagents: Bool { backend.capabilities.supportsSubagents }

    func subagents() async -> [SubagentSummary] {
        (try? await backend.subagents(for: session.id)) ?? []
    }

    /// The turn that holds the agents: while it is open an agent the server calls active may be
    /// out, and once it is over none is, whatever the record goes on claiming.
    var agentHold: AgentHold { isBusy ? .going : .over(at: nil) }

    var subagentPresence: SubagentPresence {
        SubagentPresence(
            agents: trackedSubagents, hold: agentHold,
            since: state.messages.last(where: { $0.role == .user })?.createdAt)
    }

    var liveSubagentCount: Int { subagentPresence.liveCount }

    /// Subagents belong to this conversation, so the chat owns their tracking for
    /// as long as it is on screen. A server that pushes them (a bridge's stream) is
    /// followed, and read outright only now and then in case a frame was lost.
    /// Otherwise the cadence follows the work: quick while an agent is running or
    /// a card is open, slow once they have settled, and slower still for the
    /// ordinary chat that never spawned one — opencode answers this by listing
    /// every session, which is too costly to ask often.
    func startSubagentTracking() {
        guard supportsSubagents, subagentTask == nil else { return }
        let backend = backend
        let sessionID = session.id
        subagentStreamTask = Task { [weak self] in
            guard let streaming = backend as? SubagentStreaming,
                let changes = await streaming.subagentChanges(for: sessionID)
            else { return }
            self?.subagentsStreamed = true
            for await agents in changes {
                guard let self, !Task.isCancelled else { return }
                self.subagentFrames += 1
                await self.adoptSubagents(agents)
            }
        }
        subagentTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshSubagents()
                try? await Task.sleep(for: .seconds(self.subagentPollInterval))
            }
        }
    }

    private var subagentPollInterval: Int {
        if subagentsStreamed { return 30 }
        if liveSubagentCount > 0 || !expandedSubagents.isEmpty { return 4 }
        if state.status == .running { return 8 }
        return trackedSubagents.isEmpty ? 30 : 12
    }

    func stopSubagentTracking() {
        subagentTask?.cancel()
        subagentTask = nil
        subagentStreamTask?.cancel()
        subagentStreamTask = nil
        subagentsStreamed = false
    }

    func isSubagentExpanded(_ agentID: String) -> Bool { expandedSubagents.contains(agentID) }

    func toggleSubagent(_ agentID: String) {
        if expandedSubagents.remove(agentID) == nil {
            expandedSubagents.insert(agentID)
            if subagentTranscripts[agentID] == nil { loadingSubagents.insert(agentID) }
            Task { [weak self] in await self?.loadSubagentTranscript(agentID) }
        }
        onSubagentsChange?()
    }

    /// A read that failed says nothing about the agents, so the ones on screen stay; and a read the
    /// stream overtook — a frame landed while it was out — is older than what is already shown.
    private func refreshSubagents() async {
        let framesBefore = subagentFrames
        guard let fresh = try? await backend.subagents(for: session.id),
            subagentFrames == framesBefore
        else { return }
        await adoptSubagents(fresh)
    }

    private func adoptSubagents(_ heard: [SubagentSummary]) async {
        var fresh = heard
        #if DEBUG
            if let staged = Self.stagedAgents() { fresh = staged }
        #endif
        let changed = fresh != trackedSubagents
        trackedSubagents = fresh
        let stale = fresh.filter { expandedSubagents.contains($0.id) && $0.isActive && !$0.isCompleted }
            .map(\.id)
        for agentID in stale { await loadSubagentTranscript(agentID) }
        if changed || !stale.isEmpty { onSubagentsChange?() }
    }

    #if DEBUG
        /// `TAILSCODE_DEMO_AGENTS=live|finished` stands in for a server's agent list so the agents
        /// chip and the docked rows can be photographed: `live` has two agents out, `finished` has
        /// one that is done and one the record still calls active, which a turn that is over must
        /// not believe. `TAILSCODE_DEMO_AGENTS=background` lists none and puts the status in the
        /// between-turns state instead (see the chat's status update).
        static func stagedAgents() -> [SubagentSummary]? {
            let now = Date()
            switch ProcessInfo.processInfo.environment["TAILSCODE_DEMO_AGENTS"] {
            case "live":
                return [
                    SubagentSummary(
                        id: "demo-live-1", title: "Audit the retry paths", agentType: "Explore",
                        updatedAt: now, isActive: true, startedAt: now.addingTimeInterval(-40)),
                    SubagentSummary(
                        id: "demo-live-2", title: "Run the reconnect suite",
                        agentType: "general-purpose", updatedAt: now, isActive: true,
                        startedAt: now.addingTimeInterval(-25)),
                ]
            case "finished":
                return [
                    SubagentSummary(
                        id: "demo-done-1", title: "Survey the test targets", agentType: "Explore",
                        updatedAt: now.addingTimeInterval(-3_000), isCompleted: true,
                        startedAt: now.addingTimeInterval(-3_100)),
                    SubagentSummary(
                        id: "demo-stale-2", title: "Index the fixtures", agentType: "Explore",
                        updatedAt: now.addingTimeInterval(-60), isActive: true,
                        startedAt: now.addingTimeInterval(-300)),
                ]
            default:
                return nil
            }
        }
    #endif

    private func loadSubagentTranscript(_ agentID: String) async {
        let messages = try? await backend.subagentMessages(
            sessionID: session.id, agentID: agentID)
        loadingSubagents.remove(agentID)
        guard let messages else {
            onSubagentsChange?()
            return
        }
        let changed = subagentTranscripts[agentID] != messages
        subagentTranscripts[agentID] = messages
        if changed { onSubagentsChange?() }
    }
}

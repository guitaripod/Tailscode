import TailscodeCore
import CodingAgentKit
import UIKit

extension ChatViewController {
    /// A spawned agent lives in this conversation, so "open" means scroll to its
    /// card and expand it — never push a second chat the user has to come back from. A filmed
    /// tour animates the expansion: it inserts rows underneath the card, which a plain snapshot
    /// apply would shove into place in one frame.
    func revealSubagent(id agentID: String) {
        #if DEBUG
            if TourDriver.isFilming { animateNextRender = true }
        #endif
        if !viewModel.isSubagentExpanded(agentID) { viewModel.toggleSubagent(agentID) }
        let rowID = "agent:\(agentID)"
        if !dataSource.snapshot().itemIdentifiers.contains(rowID) {
            let groups = rowsByID.values.compactMap { row -> String? in
                guard case .subagentGroup(let group) = row.content else { return nil }
                return group.id
            }
            expandedAgentGroups.formUnion(groups)
            render(viewModel.state)
        }
        guard dataSource.snapshot().itemIdentifiers.contains(rowID) else {
            presentToast(String(localized: "That agent hasn't reported into this conversation yet."))
            return
        }
        userScrolledUp = true
        scrollTo(id: rowID)
        flash(rowID: rowID)
    }

    func revealSubagent(spawnedBy call: ToolCall) {
        guard let agent = viewModel.trackedSubagents.first(where: { $0.toolUseID == call.id })
        else {
            presentToast(String(localized: "No transcript for this agent yet."))
            return
        }
        revealSubagent(id: agent.id)
    }

    func toggleSubagent(_ agentID: String) {
        userScrolledUp = true
        viewModel.toggleSubagent(agentID)
        if viewModel.isSubagentExpanded(agentID) { revealToggledRow("agent:\(agentID)") }
    }

    /// A workflow agent has no spawning tool call to reveal, so opening one goes straight to its
    /// own transcript inside this conversation — never a chat screen of its own.
    /// A run copied out of the transcript reads as what it did, not as the launch receipt: the
    /// workflow, its phases, its agents, and the answer it came back with.
    static func workflowMarkdown(_ run: WorkflowRun) -> String {
        var lines = ["**" + String(localized: "Workflow · \(run.name)") + "**"]
        if let summary = run.summary { lines.append(summary) }
        if !run.phases.isEmpty {
            lines.append(run.phases.map(\.title).joined(separator: " → "))
        }
        if !run.agents.isEmpty {
            lines.append(String(localized: "\(run.doneCount) of \(run.agents.count) agents"))
        }
        if let result = run.result, !result.isEmpty { lines.append(result) }
        return lines.joined(separator: "\n\n")
    }

    func openWorkflowAgent(_ agentID: String) {
        revealSubagent(id: agentID)
    }

    /// The clock every live workflow card is drawn against. A background run outlives the turn that
    /// launched it, so the cards keep their own second hand after the turn ends — a frozen elapsed
    /// reads as a hang. The tick reconfigures exactly the live cards, never the whole transcript:
    /// a full render every second re-decides scrolling under the reader and costs rows that did
    /// not change, and the cards write the tick into the labels they already have.
    private func advanceWorkflowClock() {
        guard workflowRuns.contains(where: \.isLive), lastRenderedState != nil else { return }
        workflowNow = Date()
        var snapshot = dataSource.snapshot()
        let live = snapshot.itemIdentifiers.filter { id in
            guard case .workflow(let run) = rowsByID[id]?.content else { return false }
            return run.isLive
        }
        guard !live.isEmpty else { return }
        snapshot.reconfigureItems(live)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// A background run keeps working after the turn that launched it ended, so its cards need a
    /// second hand the turn's own ticker no longer provides. It stops the moment nothing is live.
    func updateWorkflowTicker() {
        let live = workflowRuns.contains(where: \.isLive)
        if live, workflowTicker == nil {
            workflowTicker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    self.advanceWorkflowClock()
                }
            }
        } else if !live {
            workflowTicker?.cancel()
            workflowTicker = nil
        }
    }
}

extension ChatViewController {
    func toggleAgentGroup(_ groupID: String) {
        userScrolledUp = true
        let opened = expandedAgentGroups.remove(groupID) == nil
        if opened { expandedAgentGroups.insert(groupID) }
        animateNextRender = true
        render(viewModel.state)
        if opened { revealToggledRow(groupID) }
    }

    /// A brief highlight after jumping, so a card reached from the agent list is
    /// obvious among the rows around it.
    func flash(rowID: String) {
        guard let index = dataSource.snapshot().indexOfItem(rowID),
            let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
        else { return }
        cell.contentView.alpha = 0.25
        UIView.animate(withDuration: 0.45, delay: 0.1) { cell.contentView.alpha = 1 }
    }

    func presentSubagents(_ agents: [SubagentSummary]) {
        let list = SubagentListViewController(
            backend: viewModel.backend, parentSessionID: viewModel.session.id, agents: agents,
            hold: { [weak self] in self?.viewModel.agentHold ?? .over(at: nil) })
        list.onSelect = { [weak self] agentID in
            self?.revealSubagent(id: agentID)
        }
        let nav = UINavigationController(rootViewController: list)
        nav.modalPresentationStyle = .pageSheet
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        nav.sheetPresentationController?.prefersGrabberVisible = true
        nav.presentationController?.delegate = self
        present(nav, animated: true)
    }
}

extension ChatViewController {
    /// Where each spawned agent's card belongs: against the tool call that
    /// spawned it when the server resolved one, otherwise trailing the workflow
    /// that fanned it out (workflow agents have no spawning call of their own).
    struct SubagentPlacement {
        var byToolUse: [String: SubagentCard] = [:]
        var unattached: [SubagentCard] = []
        var expandedGroups: Set<String> = []
    }

    func subagentPlacement(for messages: [ChatMessage]) -> SubagentPlacement {
        guard viewModel.supportsSubagents, !viewModel.trackedSubagents.isEmpty else {
            return SubagentPlacement()
        }
        agentReadAt = Date()
        let spawns = messages.flatMap { message in
            message.parts.compactMap { part -> ToolCall? in
                guard case .tool(let call) = part.kind, call.spawnsSubagent else { return nil }
                return call
            }
        }
        let spawnIDs = spawns.map(\.id)
        let known = Set(spawnIDs)
        holds = Dictionary(spawns.map { ($0.id, AgentHold($0)) }, uniquingKeysWith: { first, _ in
            first
        })
        var placement = SubagentPlacement(expandedGroups: expandedAgentGroups)
        var unmatched: [SubagentSummary] = []
        for agent in Self.inPlacementOrder(viewModel.trackedSubagents) {
            noteArrival(of: agent.id)
            if let toolUseID = agent.toolUseID, known.contains(toolUseID) {
                if placement.byToolUse[toolUseID] == nil {
                    placement.byToolUse[toolUseID] = subagentCard(for: agent, at: toolUseID)
                }
            } else {
                unmatched.append(agent)
            }
        }
        seat(unmatched, spawns: spawnIDs, known: known, into: &placement)
        return placement
    }

    /// How the call that spawned each agent holds it, read once per draw off the transcript this
    /// placement walked. An agent seated in a chair nobody named — a backend that never resolved
    /// the spawning call — is held by the turn instead, which is the same answer the status band
    /// gives: nothing is refreshing a subagent's record while this device is idle.
    func hold(at toolUseID: String?) -> AgentHold {
        if let toolUseID, let hold = holds[toolUseID] { return hold }
        return viewModel.state.status == .running ? .going : .over(at: nil)
    }

    /// Seats the cards whose spawning call the server never named, and remembers where each one sat.
    ///
    /// A card with no resolvable `toolUseID` lands wherever the seating order puts it, so the seating
    /// order is the pairing — and it may not be derived from anything that moves while the agent
    /// runs. Ordering on `updatedAt` did exactly that: two agents working at once traded chairs
    /// every four-second poll as whichever reported last sorted past the other, each card picking up
    /// the other's spawn summary, and the snapshot recording a real reorder rather than a repaint.
    /// So a seat is taken once, against the order the conversation first saw the agent, and then
    /// held: only a call that resolved its own agent can take a chair back, and the card it displaces
    /// takes the next free one rather than everybody shuffling along.
    func seat(
        _ agents: [SubagentSummary], spawns: [String], known: Set<String>,
        into placement: inout SubagentPlacement
    ) {
        let ordered = agents.sorted {
            (agentArrivals[$0.id] ?? 0, $0.id) < (agentArrivals[$1.id] ?? 0, $1.id)
        }
        var taken = Set(placement.byToolUse.keys)
        var displaced: [SubagentSummary] = []
        for agent in ordered {
            guard let slot = spawnSeats[agent.id], known.contains(slot), !taken.contains(slot) else {
                displaced.append(agent)
                continue
            }
            taken.insert(slot)
            placement.byToolUse[slot] = subagentCard(for: agent, at: slot)
        }
        var free = spawns.filter { !taken.contains($0) }[...]
        for agent in displaced {
            guard let slot = free.first else {
                placement.unattached.append(subagentCard(for: agent, at: nil))
                continue
            }
            free = free.dropFirst()
            spawnSeats[agent.id] = slot
            placement.byToolUse[slot] = subagentCard(for: agent, at: slot)
        }
    }

    /// Records when this conversation first laid eyes on an agent. Assigned while walking the agents
    /// in their one agreed order rather than from inside a sort's comparator, which would number
    /// them in whatever order the partitions happened to ask.
    private func noteArrival(of agentID: String) {
        guard agentArrivals[agentID] == nil else { return }
        agentArrivalCount += 1
        agentArrivals[agentID] = agentArrivalCount
    }

    /// The one order every device and every poll agrees on.
    ///
    /// A fan-out spawns its agents in the same tick — or against a server that stamps whole seconds —
    /// so ties are routine, and Swift's sort is an introsort and is not stable: the tie order is
    /// whatever the last partition happened to leave, which is a different arrangement of the same
    /// agents on the next four-second poll. Falling back to the agent's own identifier makes the
    /// order total, so this walk is the same walk every time and the arrival numbers it hands out
    /// are the same numbers every time.
    private static func inPlacementOrder(_ agents: [SubagentSummary]) -> [SubagentSummary] {
        agents.sorted { ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id) }
    }

    private func subagentCard(for agent: SubagentSummary, at toolUseID: String?) -> SubagentCard {
        let digest = ChatRowBuilder.digest(viewModel.subagentTranscripts[agent.id])
        return SubagentCard(
            agentID: agent.id,
            title: agent.title,
            agentType: agent.agentType,
            isActive: SubagentPresence(agents: [agent], hold: hold(at: toolUseID)).hasLive,
            isCompleted: agent.isCompleted,
            updatedAt: agent.updatedAt,
            expanded: viewModel.isSubagentExpanded(agent.id),
            isLoading: viewModel.loadingSubagents.contains(agent.id),
            steps: digest.steps,
            report: digest.report,
            progress: ChatRowBuilder.liveProgress(
                agent, at: agentReadAt, under: hold(at: toolUseID)))
    }
}

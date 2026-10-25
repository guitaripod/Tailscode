import TailscodeCore
import CodingAgentKit
import UIKit

extension ChatViewController {
    /// The level and the levels the brains were last drawn against.
    struct BrainEffortReading: Equatable {
        var effort: String?
        var options: [String]
    }

    /// A pick on the pill changes what every brain's header says, and a transcript is built again
    /// only for a state the server sent, so a pick that moved the level has the brains drawn again
    /// from the state already held.
    func redrawBrainsForEffort() {
        guard brain.isActive, let state = lastRenderedState,
            BrainEffortReading(
                effort: viewModel.displayedEffort, options: viewModel.reasoningEffortOptions)
                != brainEffort
        else { return }
        render(state)
    }
}

extension ChatViewController {
    var brainActions: BrainActions {
        BrainActions(
            toggle: { [weak self] id in self?.toggleBrain(id) },
            rows: { [weak self] id in self?.toggleBrainRows(id) },
            replay: { [weak self] id in self?.replayBrain(id) },
            share: { [weak self] id in self?.shareBrain(id) },
            revealAgent: { [weak self] turn, step in self?.revealAgent(turn: turn, step: step) },
            reply: { [weak self] quote in self?.replyFromBrain(quote) },
            goToAsk: { [weak self] _ in self?.revealPendingCard() },
            goToAnswer: { [weak self] id in self?.goToAnswer(ofTurn: id) },
            showInRows: { [weak self] turn, step in self?.showInRows(turn: turn, step: step) },
            openDiving: { [weak self] turn, zone in self?.openBrainDiving(turn, zone: zone) },
            landed: { [weak self] id in self?.brainLanded(id) })
    }

    /// A zone chip on a card opens the brain already diving into that zone.
    private func openBrainDiving(_ turnID: String, zone: NeuralZone) {
        brain.store.interaction(for: turnID).pendingDive = zone
        if brain.store.isOpen(turnID) {
            for case let cell as NeuralBrainCell in collectionView.visibleCells where cell.brainRow.turnID == turnID {
                cell.brainRow.openView?.stage.dive(to: zone)
            }
            brain.store.interaction(for: turnID).pendingDive = nil
        } else {
            toggleBrain(turnID)
        }
    }

    /// Reply puts the quoted words in the composer and puts the cursor under them; nothing is sent,
    /// because the agent is talked back to through the ordinary send.
    private func replyFromBrain(_ quote: String) {
        let existing = composer.currentText
        let draft = existing.isEmpty ? quote : existing + "\n\n" + quote
        composer.setDraft(draft, focus: true, cursorAtEnd: true)
        Theme.Haptics.tap()
    }

    /// The answer a turn ended on is the next row after its brain that carries words.
    private func goToAnswer(ofTurn turnID: String) {
        let brainID = NeuralOpenPolicy.rowID(turnID: turnID)
        guard let at = orderedIDs.firstIndex(of: brainID) else { return }
        for id in orderedIDs[(at + 1)...] {
            guard let row = rowsByID[id] else { continue }
            if row.role == .user { break }
            if case .text = row.content {
                userScrolledUp = true
                scrollTo(id: id)
                return
            }
        }
    }

    /// Lists a step's old row among the turn's rows, and brings the row into view.
    private func showInRows(turn turnID: String, step stepID: String) {
        userScrolledUp = true
        if !brain.store.showsRows(turnID) { brain.store.toggleRows(turnID) }
        render(lastRenderedState ?? viewModel.state)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let target = self.orderedIDs.first { id in
                guard let row = self.rowsByID[id] else { return false }
                if case .activity(let steps) = row.content {
                    return steps.contains {
                        if case .tool(let call) = $0 { return stepID.hasSuffix(":" + call.id) || stepID.contains(call.id) }
                        return false
                    }
                }
                return false
            }
            if let target { self.scrollTo(id: target) }
        }
    }

    /// An open brain landed: the row is as tall as it will be, so the reading gesture's reveal
    /// can ask how far to move.
    private func brainLanded(_ turnID: String) {
        revealToggledRow(NeuralOpenPolicy.rowID(turnID: turnID))
    }

    /// Opening a brain is a reading gesture like opening any row: the transcript stops chasing the
    /// bottom, the policy closes the one that was open, and the view moves only as far as the
    /// opened body needs.
    func toggleBrain(_ turnID: String) {
        userScrolledUp = true
        brain.store.toggle(turnID)
        render(lastRenderedState ?? viewModel.state)
    }

    private func toggleBrainRows(_ turnID: String) {
        userScrolledUp = true
        brain.store.toggleRows(turnID)
        render(lastRenderedState ?? viewModel.state)
    }

    /// Replay starts from the first step, and opens the brain first when it is closed: a replay
    /// is a thing to be watched.
    private func replayBrain(_ turnID: String) {
        userScrolledUp = true
        let opening = !brain.store.isOpen(turnID)
        if opening {
            brain.store.interaction(for: turnID).replayOnOpen = true
            brain.store.toggle(turnID)
        } else {
            brain.store.mutate(turnID) { $0.startReplay(now: CACurrentMediaTime()) }
        }
        render(lastRenderedState ?? viewModel.state)
    }

    /// Sends a settled turn out as its poster: the sheet draws it at the look the person last chose
    /// for cards, with the words that started the turn as its quote.
    private func shareBrain(_ turnID: String) {
        guard let model = brain.store.model(for: turnID), model.turn.outcome != .running else {
            return
        }
        let messages = viewModel.state.messages
        let start = messages.firstIndex { $0.id == turnID } ?? messages.endIndex
        let prompt = messages[..<start].last { $0.role == .user }.map { message -> String in
            message.parts.compactMap { part -> String? in
                if case .text(let words) = part.kind { return words }
                return nil
            }.joined(separator: "\n")
        } ?? ""
        Theme.Haptics.tap()
        NeuralShareViewController.present(
            turn: model.turn, prompt: prompt, look: CardStyleSelection.current, from: self)
    }

    /// A double tap on a delegate node goes to the card of the agent it spawned, inside this
    /// conversation, never to a chat of its own.
    private func revealAgent(turn turnID: String, step stepID: String) {
        guard let call = toolCall(forStep: stepID) else { return }
        revealSubagent(spawnedBy: call)
    }

    private func toolCall(forStep stepID: String) -> ToolCall? {
        for message in viewModel.state.messages.reversed() {
            guard stepID.hasPrefix(message.id + ":") else { continue }
            for part in message.parts where "\(message.id):\(part.id)" == stepID {
                if case .tool(let call) = part.kind { return call }
            }
        }
        return nil
    }

    #if DEBUG
        /// Plays `TAILSCODE_NEURAL_WALK` against the open brain on its own clock.
        func startBrainWalk() {
            for step in BrainDebug.walk {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(step.delay))
                    self?.brainWalkStep(step.verb, step.value)
                }
            }
        }

        /// Runs `TAILSCODE_NEURAL_CHECK`'s claims against this conversation's brains.
        func startBrainChecks() {
            guard BrainChecks.isEnabled || BrainChecks.isPerf else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                if BrainChecks.isPerf {
                    guard let self else { return }
                    await BrainChecks.runPerf(
                        collection: self.collectionView, store: self.brain.store,
                        toggle: { [weak self] id in self?.toggleBrain(id) })
                    return
                }
                BrainChecks.runModel()
                guard let self else { return }
                if ProcessInfo.processInfo.environment["TAILSCODE_NEURAL_DEMO"] == "write" {
                    await BrainChecks.runReaderScreen(
                        collection: self.collectionView, store: self.brain.store,
                        toggle: { [weak self] id in self?.toggleBrain(id) })
                    return
                }
                await BrainChecks.runScreen(
                    collection: self.collectionView, store: self.brain.store,
                    toggle: { [weak self] id in self?.toggleBrain(id) })
            }
        }

        func tourBrain(_ verb: String, _ value: String = "") { brainWalkStep(verb, value) }

        private func brainWalkStep(_ verb: String, _ value: String) {
            BrainWalk.run(
                verb: verb, value: value, store: brain.store, collection: collectionView,
                toggle: { [weak self] id in self?.toggleBrain(id) },
                rows: { [weak self] id in self?.toggleBrainRows(id) },
                share: { [weak self] id in self?.shareBrain(id) },
                refresh: { [weak self] in self?.render(self?.lastRenderedState ?? self?.viewModel.state ?? ConversationState()) })
        }
    #endif

    /// Reads the brain cells on screen again: the ticker's latest step, the chips, the line's
    /// clock. Nothing is rebuilt, and a row whose value did not change is not reconfigured.
    func refreshBrainCells() {
        for case let cell as NeuralBrainCell in collectionView.visibleCells { cell.refreshLive() }
    }
}

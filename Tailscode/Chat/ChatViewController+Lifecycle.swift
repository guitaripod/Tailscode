import TailscodeCore
import CodingAgentKit
import UIKit

extension ChatViewController {
    /// Builds the view and lays its chrome out at the size the stack will give it, in a turn before
    /// the push that shows it, so that the push finds the constraints already solved.
    func layOutBeforePush(in bounds: CGRect) {
        loadViewIfNeeded()
        view.frame = bounds
        view.layoutIfNeeded()
    }

    /// A chat says which conversation it is when it arrives, once, because the failure a wrong
    /// open has is being quiet about it. The title is always in the header now, so the arrival is
    /// told to a screen reader, and a press on the chat already open blinks the title once.
    /// Reduced motion keeps the announcement and drops the movement.
    func announceIdentity() {
        UIAccessibility.post(notification: .announcement, argument: navDisplayTitle)
        guard !UIAccessibility.isReduceMotionEnabled, isViewLoaded, view.window != nil else { return }
        navTitleLabel.alpha = 0.3
        UIView.animate(withDuration: 0.35) { self.navTitleLabel.alpha = 1 }
    }
}

extension ChatViewController {
    /// Tab takes the keyboard into the open brain, which is a focus group of its own: the list, the
    /// stage and the account answer the same keys, and nothing here takes a key while the composer
    /// has the keyboard, because then this screen is not the one asked.
    func enterBrainWithTab(_ presses: Set<UIPress>) -> Bool {
        guard !composer.isEditing,
            let press = presses.first(where: { $0.key?.keyCode == .keyboardTab && $0.key?.modifierFlags.isDisjoint(with: [.shift, .command, .control, .alternate]) == true }),
            press.key != nil
        else { return false }
        for case let cell as NeuralBrainCell in collectionView.visibleCells {
            if let open = cell.brainRow.openView, open.becomeFirstResponder() { return true }
        }
        return false
    }

    /// Whether the screen now in front of this one in its stack is another conversation, which is
    /// the reader having gone to a different chat rather than into a part of this one.
    var isCoveredByAnotherChat: Bool {
        guard let top = navigationController?.topViewController as? ChatViewController else { return false }
        return top !== self
    }

    /// The reader has left this conversation: it stops being bound, stops streaming unless a turn
    /// is still out, and drops an enhancement in flight. A chat that leaves the screen says so
    /// through its own disappearance; one a stack drops while it was buried under another never
    /// appears or disappears, so whoever drops it has to say so here.
    func releaseConversation() {
        callController.chatLeft()
        viewModel.isBound = false
        if !viewModel.isBusy { viewModel.stop() }
        enhancement.cancel()
        enhanceOverlay?.removeFromSuperview()
        enhanceOverlay = nil
    }

    /// The chat title is the conversation's own name; auto-generated
    /// placeholder titles fall back to the agent's name.
    var navDisplayTitle: String {
        AgentSession.isPlaceholderTitle(viewModel.title)
            ? viewModel.backend.agentType.displayName
            : viewModel.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The composer writes for this conversation, so what is in it belongs to the chat rather than
    /// to the screen showing it: the same pairing `SessionEntry` uses for identity.
    var draftScope: DraftScope {
        .chat(profileID: viewModel.contextID, sessionID: viewModel.session.id)
    }

    var compactionDraftScope: DraftScope {
        .compaction(profileID: viewModel.contextID, sessionID: viewModel.session.id)
    }

    var goalDraftScope: DraftScope {
        .goal(profileID: viewModel.contextID, sessionID: viewModel.session.id)
    }

    /// A free-typed answer belongs to the one question it answers, and a request can carry several
    /// — so the row's own identity carries the question's place inside it. Both survive a relaunch
    /// because both are read back off the transcript rather than held in memory.
    func answerDraftScope(for request: QuestionRequest, questionIndex: Int) -> DraftScope {
        .answer(
            profileID: viewModel.contextID, sessionID: viewModel.session.id,
            questionID: "\(request.id)#\(questionIndex)")
    }

    /// Every keystroke is already recorded, so this only closes the store's coalescing window by
    /// hand where the process is about to stop being asked.
    @objc func flushDraft() { DraftStore.flush() }
}

extension ChatViewController {
    /// A conversation on screen when the app comes back is a conversation being looked at, which
    /// is the only thing that answers a notice about it — a banner raised while the phone was in a
    /// pocket must not still be waiting in Missed under the chat it is about.
    @objc func sceneDidActivate() {
        suppressBannerUntil = Date().addingTimeInterval(3)
        if view.window != nil {
            NotificationManager.clearNotices(sessionID: viewModel.session.id)
            AppActivityController.shared.seen(viewModel.session.id)
        }
        viewModel.resync()
        viewModel.serviceResume()
    }
}

extension ChatViewController {
    func loadModels() async {
        availableModels = await viewModel.availableModels()
        updateNavControls()
    }

    /// A warm catalog is answered from the cache and refreshed behind it, so the models this chat
    /// can offer are settled a round trip after the read. Taking the landing is what puts a model
    /// the server gained since the last launch into the picker in this run rather than the next.
    /// Turning the strip on is a change to what the transcript is made of, not to how a row draws,
    /// so the rows are built again rather than reconfigured — a chat left open behind the settings
    /// screen must not have to wait for the next turn to answer the switch that was just flipped.
    @objc func responseStatsDidChange() {
        render(viewModel.state)
    }

    /// The cards are part of what the transcript is made of, so flipping the switch rebuilds the
    /// rows — a chat left open behind the settings screen answers the switch at once, not on its
    /// next turn.
    @objc func linkEmbedsDidChange() {
        render(viewModel.state)
    }

    /// Density is every gap and every plate in the transcript, so a chat left open behind the
    /// settings screen answers the choice at once: the rows are built again and every cell is
    /// drawn from scratch rather than patched.
    @objc func chatDensityDidChange() {
        render(viewModel.state)
        var snapshot = dataSource.snapshot()
        snapshot.reloadItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Brain or lines is what every turn's work is made of, so a chat left open behind the settings
    /// screen is built again at once, the same way a switch on the response strip is.
    @objc func activityStyleDidChange() {
        render(viewModel.state)
    }

    @objc func catalogDidChange(_ note: Notification) {
        guard note.userInfo?["profileID"] as? String == viewModel.contextID,
            viewModel.supportsModelSelection || viewModel.supportsReasoningEffort
        else { return }
        availableModels = ModelCatalog.cached(for: viewModel.contextID)
        viewModel.adoptCatalog(availableModels)
        updateNavControls()
    }
}

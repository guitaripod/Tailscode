import MidgarCore
import TailscodeCore
import CodingAgentKit
import UIKit

extension ChatViewController {
    /// Everything true about the turn right now, read once per state and shared by the nav status
    /// and the brains, so the two cannot be in different phases.
    func makeFacts(_ state: ConversationState) -> StatusFacts {
        var facts = StatusFacts.from(
            state: state, agents: viewModel.trackedSubagents,
            usage: nil, attachments: pendingAttachments.count, context: contextFill,
            quotas: rangeQuotas, queued: viewModel.queued.count,
            model: viewModel.displayedModel?.modelID, selection: viewModel.displayedModel,
            trail: RangeStore.trail)
        #if DEBUG
            if ProcessInfo.processInfo.environment["TAILSCODE_DEMO_AGENTS"] == "background" {
                facts.phase = .background(tasks: 2)
                facts.activity = .inBackground(tasks: 2)
            }
        #endif
        return facts
    }
}

extension ChatViewController {
    /// How full the model's window is, always visible above the composer once the transcript can
    /// say — the same share, count and ring the desktop bands wear, one tap from the whole window.
    func configureContextChip() {
        contextChip.reserveIcon(symbols: ["cylinder.split.1x2"], minimum: 12)
        contextChip.accessibilityHint = String(localized: "Opens the range.")
        contextChip.addAction(
            UIAction { [weak self] _ in self?.presentRange() }, for: .touchUpInside)
    }

    /// The conversation's price, once the server can account for it. It opens the whole account —
    /// what each turn cost, where the money went between fresh tokens and cache, which model spent
    /// it — because a number with no story behind it is a number nobody trusts.
    func configureSpendChip() {
        spendChip.setSymbol("creditcard")
        spendChip.accessibilityHint = String(
            localized: "What this conversation has cost. Opens the breakdown.")
        spendChip.addAction(
            UIAction { [weak self] _ in self?.presentSpend() }, for: .touchUpInside)
    }

    /// Which branch the agent's work is landing on, once the server can say. It opens the whole
    /// repository — the working tree, what each file's change is, the commits behind it — and
    /// offers nothing that writes: this app reads a repository, it does not operate one.
    func configureGitChip() {
        gitChip.setSymbol("arrow.trianglehead.branch")
        gitChip.accessibilityHint = String(
            localized: "The repository this conversation is working in. Opens its state.")
        gitChip.addAction(
            UIAction { [weak self] _ in self?.presentGit() }, for: .touchUpInside)
    }

    /// Opens the app this conversation is building, running on the Mac's simulator, full screen.
    func configurePreviewChip() {
        previewChip.setSymbol("iphone")
        previewChip.text = Localized.text("Preview")
        previewChip.accessibilityLabel = Localized.text("Preview")
        previewChip.accessibilityHint = Localized.text("Opens the app running on your Mac.")
        previewChip.addAction(
            UIAction { [weak self] _ in self?.presentPreview() }, for: .touchUpInside)
        NotificationCenter.default.addObserver(
            self, selector: #selector(previewHostsChanged), name: PreviewAccessStore.didChange,
            object: nil)
    }

    @objc private func previewHostsChanged() { updatePreviewChip() }

    func updatePreviewChip() {
        defer { factsRow.refresh(); syncFactsScrim() }
        previewChip.isHidden = viewModel.previewTarget == nil
    }

    private func presentPreview() {
        guard let target = viewModel.previewTarget else { return }
        Theme.Haptics.tap()
        MidgarLog.info(
            "preview: open \(target.address) from session=\(viewModel.session.id)", category: .ui)
        let viewer = PreviewViewController(target: target)
        viewer.onAskAgent = { [weak self] words in self?.offerToAgent(words) }
        present(viewer, animated: true)
    }

    /// The words the viewer composed go into this conversation's own box, after whatever is
    /// already there, and are left for the person to read and send: nothing leaves on their behalf.
    private func offerToAgent(_ words: String) {
        let held = composer.currentText
        composer.setDraft(held.isEmpty ? words : held + "\n\n" + words, focus: true, cursorAtEnd: true)
        MidgarLog.info(
            "preview: composed a fix request for session=\(viewModel.session.id)", category: .chat)
    }

    private func updateGitChip() {
        defer { factsRow.refresh(); syncFactsScrim() }
        guard let git, git.isRepository else {
            gitChip.isHidden = true
            return
        }
        let line = git.badgeParts.map(\.text).joined(separator: " ")
        gitChip.text = line
        gitChip.accessibilityLabel = git.spokenBadge
        gitChip.isHidden = false
    }

    func presentGit() {
        guard let backend = viewModel.backend as? any GitObservingBackend else { return }
        Theme.Haptics.tap()
        let panel = GitStatusViewController(
            backend: backend, directory: viewModel.session.directory,
            sessionID: viewModel.session.id)
        if let inspector = workspace?.inspector, inspector.isInstalled {
            panel.isBesideConversation = true
            inspector.show(panel)
            return
        }
        let nav = UINavigationController(rootViewController: panel)
        nav.modalPresentationStyle = .pageSheet
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        nav.sheetPresentationController?.prefersGrabberVisible = true
        present(nav, animated: true)
    }

    /// Read on the same slow beat as the price, and again the moment a turn ends: an agent that
    /// just finished editing has changed exactly what this chip is counting.
    func refreshGit() {
        guard let backend = viewModel.backend as? any GitObservingBackend else { return }
        let sessionID = viewModel.session.id
        let directory = viewModel.session.directory
        Task { [weak self] in
            guard let self else { return }
            let snapshot = try? await backend.gitSnapshot(
                directory: directory, sessionID: sessionID)
            guard self.viewModel.session.id == sessionID else { return }
            self.git = snapshot.map { GitState(snapshot: $0) }
            self.updateGitChip()
            self.workspace?.inspectorMayShowRepository(of: self)
        }
    }

    /// A chip is reconfigured only when what it says has changed. A transcript state arrives for
    /// every token of an answer, and writing a button's configuration — which UIKit answers with a
    /// full update and a layout pass — to say the same words again is a cost per token for nothing.
    func updateSpendChip() {
        defer { factsRow.refresh(); syncFactsScrim() }
        guard let spend = spendReading.value, !spend.isEmpty else {
            spendChip.isHidden = true
            shownSpendBadge = nil
            return
        }
        spendChip.isHidden = false
        guard shownSpendBadge != spend.badge else { return }
        shownSpendBadge = spend.badge
        spendChip.text = spend.badge
        spendChip.accessibilityLabel =
            spend.estimated
            ? String(localized: "Spent \(spend.badge), an estimate")
            : String(localized: "Spent \(spend.badge)")
    }

    private func presentSpend() {
        guard let spend = spendReading.value, !spend.isEmpty else { return }
        Theme.Haptics.tap()
        let panel = SpendViewController(spend: spend, title: title ?? viewModel.session.title)
        let nav = UINavigationController(rootViewController: panel)
        nav.modalPresentationStyle = .pageSheet
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        nav.sheetPresentationController?.prefersGrabberVisible = true
        present(nav, animated: true)
    }

    /// Asked of the server when the chat opens, when a turn lands and when the transcript finally
    /// arrives. A request that came back with nothing is not news that the money is gone, so it
    /// leaves whatever the transcript itself already worked out standing.
    func refreshSpend() {
        let sessionID = viewModel.session.id
        Task { [weak self] in
            guard let self else { return }
            let report = try? await self.viewModel.backend.sessionSpend(sessionID)
            guard self.viewModel.session.id == sessionID else { return }
            if self.spendReading.note(report: report, for: sessionID) { self.updateSpendChip() }
        }
    }

    func updateContextChip(range: RangeGlance?) {
        defer { factsRow.refresh(); syncFactsScrim() }
        guard let contextFill else {
            contextChip.isHidden = true
            shownContext = nil
            return
        }
        contextChip.isHidden = false
        let words = range?.contextWords
        let tone = max(contextFill.tone, range?.burn?.tone ?? .quiet)
        if let shownContext, shownContext.fill == contextFill, shownContext.words == words,
            shownContext.tone == tone
        {
            return
        }
        shownContext = (contextFill, words, tone)
        let ink: UIColor
        switch tone {
        case .quiet: ink = Theme.Color.secondaryLabel
        case .attention: ink = Theme.Color.warning
        case .danger: ink = Theme.Color.danger
        }
        contextChip.text = words ?? contextFill.badge
        if let fraction = contextFill.fraction {
            let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
            if shownRing?.percent != percent || shownRing?.ink != ink {
                shownRing = (percent, ink)
                contextChip.setImage(
                    ContextRing.image(
                        fraction: Double(percent) / 100, ink: ink, diameter: 12, stroke: 2))
            }
        } else {
            shownRing = nil
            contextChip.setSymbol("cylinder.split.1x2")
        }
        contextChip.accessibilityLabel =
            words.map { "\(contextFill.accessibilityLabel), \($0)" } ?? contextFill.accessibilityLabel
    }

    /// The two readings the range adds beside the context's own: the clock a quota window that
    /// governs this chat will run out at, only while that is news, and the cache gone cold. Each
    /// opens the same sheet the context chip does.
    func configureRangeChips() {
        wallChip.setSymbol("clock", tone: .attention)
        wallChip.accessibilityHint = String(localized: "Opens the range.")
        wallChip.addAction(
            UIAction { [weak self] _ in self?.presentRange() }, for: .touchUpInside)
        cacheChip.setSymbol("snowflake")
        cacheChip.accessibilityHint = String(localized: "Opens the range.")
        cacheChip.addAction(
            UIAction { [weak self] _ in self?.presentRange() }, for: .touchUpInside)
    }

    func updateRangeChips(_ range: RangeGlance?) {
        defer { factsRow.refresh(); syncFactsScrim() }
        if let wall = range?.wallWords() {
            wallChip.text = wall
            wallChip.accessibilityLabel = String(localized: "Runs out \(wall)")
            wallChip.isHidden = false
        } else {
            wallChip.isHidden = true
        }
        if let cold = range?.coldWords {
            cacheChip.text = cold
            cacheChip.accessibilityLabel = cold
            cacheChip.isHidden = false
        } else {
            cacheChip.isHidden = true
        }
    }

    /// The quotas this chat spends against, as the app last landed them. Read from the shared
    /// snapshot on a beat of its own rather than on every state, which arrives for every token.
    private func refreshRangeQuotas() {
        rangeQuotas = QuotaSurface.relevantQuotas(
            for: viewModel.backend.agentType, among: UsageWidgetStore.cachedQuotas())
    }

    /// The countdowns the range holds — a wall's clock, the cache's lifetime — move with the
    /// time and not with the transcript, so an idle chat reads them again once in a while.
    func startRangeClock() {
        rangeClock?.cancel()
        refreshRangeQuotas()
        rangeClock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                self.refreshRangeQuotas()
                self.updateNavStatus(for: self.viewModel.state, messagesMoved: false)
            }
        }
    }

    /// The range behind the chips — which tank runs out first, the windows that govern this chat,
    /// the cache, what is in the window, how it has grown — as a sheet, with Compact as the one
    /// thing it offers to do through the chat's ordinary preflight.
    func presentRange() {
        guard contextFill != nil || !rangeQuotas.isEmpty else { return }
        Theme.Haptics.tap()
        refreshRangeQuotas()
        let panel = RangeViewController(
            title: title ?? viewModel.session.title,
            read: { [weak self] in self?.rangeReading() },
            compact: viewModel.supportsCompaction
                ? { [weak self] in
                    self?.dismiss(animated: true) { self?.presentCompactPreflight() }
                } : nil,
            reveal: { [weak self] item in
                self?.dismiss(animated: true) {
                    self?.revealInTranscript(id: item.id, messageID: item.messageID)
                }
            })
        rangeSheet = panel
        let nav = UINavigationController(rootViewController: panel)
        nav.modalPresentationStyle = .pageSheet
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        nav.sheetPresentationController?.prefersGrabberVisible = true
        #if DEBUG
            if ["large", "bottom"].contains(ProcessInfo.processInfo.environment["TAILSCODE_OPEN_RANGE"]) {
                nav.sheetPresentationController?.selectedDetentIdentifier = .large
            }
        #endif
        present(nav, animated: true)
    }

    private func rangeReading() -> RangeViewController.Reading {
        let selection = viewModel.displayedModel
        let state = viewModel.state
        let board = RangeBoard.read(
            messages: state.messages, fill: contextFill, quotas: rangeQuotas,
            model: selection?.modelID, selection: selection, isRunning: state.status == .running,
            trail: RangeStore.trail)
        return RangeViewController.Reading(board: board, billing: contextFill)
    }
}

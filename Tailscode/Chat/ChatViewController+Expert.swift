import CodingAgentKit
import MidgarCore
import TailscodeCore
import UIKit

/// A chat that is an expert's task: the expert's mark in the title, Finish task in the menu, and
/// the card at the end of the transcript that finishes the task and holds its debrief. Any chat
/// on a machine that keeps experts can also be handed to one, or made into one.
extension ChatViewController {
    var expertRow: ExpertRow? { ExpertDesk.shared.row(for: viewModel.session, profileID: viewModel.contextID) }

    private var expertsBackend: (any MachineExperts)? {
        if let direct = viewModel.backend as? any MachineExperts, viewModel.backend.capabilities.supportsExperts {
            return direct
        }
        guard ExpertDesk.shared.board.machines.contains(where: { $0.profileID == viewModel.contextID }) else {
            return nil
        }
        return ExpertDesk.shared.experts(forProfileID: viewModel.contextID)
    }

    func bindExpert() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(expertDeskChanged), name: ExpertDesk.didChange, object: nil)
        if viewModel.session.expertID != nil, ExpertDesk.shared.board.isEmpty { ExpertDesk.shared.refresh() }
        showExpertMark()
    }

    func expertAppeared() {
        guard viewModel.session.expertID != nil else { return }
        loadExpertDebrief()
    }

    @objc private func expertDeskLoaded() {
        guard viewModel.session.expertID != nil, expertDebrief == nil else { return }
        loadExpertDebrief()
    }

    func expertGone() {
        expertPoll?.cancel()
        expertPoll = nil
    }

    @objc private func expertDeskChanged() {
        showExpertMark()
        guard viewModel.session.expertID != nil else { return }
        if expertDebrief == nil { expertDeskLoaded() }
        renderPending()
    }

    /// The expert's mark beside the title, so a task never reads as an ordinary chat.
    private func showExpertMark() {
        guard let row = expertRow else {
            expertMarkView?.isHidden = true
            return
        }
        if expertMarkView == nil {
            let mark = ExpertMarkView(side: 20)
            let line = UIStackView(arrangedSubviews: [mark])
            line.axis = .horizontal
            line.spacing = 6
            line.alignment = .center
            if let index = navTitleStack.arrangedSubviews.firstIndex(of: navTitleLabel) {
                navTitleStack.removeArrangedSubview(navTitleLabel)
                line.addArrangedSubview(navTitleLabel)
                navTitleStack.insertArrangedSubview(line, at: index)
            }
            expertMarkView = mark
        }
        expertMarkView?.isHidden = false
        expertMarkView?.show(row)
        navTitleStack.accessibilityHint = Localized.text("A task of %@", row.expert.name)
    }

    // MARK: The card

    /// What the card at the end says, or nil while a turn runs, for a chat that is not a task, and
    /// for a debrief the person put off until later.
    func expertCardFace(_ state: ConversationState) -> ExpertCardFace? {
        guard viewModel.session.expertID != nil, let row = expertRow, !viewModel.isBusy,
            state.pendingPermissions.isEmpty, state.pendingQuestions.isEmpty, interrupted == nil,
            !ExpertDesk.shared.isHeld(viewModel.session.id)
        else { return nil }
        let turns = state.messages.filter { $0.role == .user }.count
        guard turns > 0 else { return nil }
        guard let debrief = expertDebrief else { return .finish(row) }
        let wentOn = debrief.coveredTurns < turns
        if wentOn, debrief.state == .settled || debrief.state == .failed { return .finish(row) }
        return .debrief(debrief, row, pressing: expertPressing, wentOn: wentOn && debrief.state == .open)
    }

    func expertCardCell(_ collectionView: UICollectionView, _ indexPath: IndexPath, face: ExpertCardFace)
        -> UICollectionViewCell
    {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ExpertDebriefCell.reuseID, for: indexPath) as! ExpertDebriefCell
        cell.configure(face)
        cell.onFinish = { [weak self] in self?.finishExpertTask() }
        cell.onRetry = { [weak self] in self?.finishExpertTask() }
        cell.onAccept = { [weak self] proposal in self?.decide(accepted: [proposal.id], skipped: [], pressing: [proposal.id]) }
        cell.onSkip = { [weak self] proposal in self?.decide(accepted: [], skipped: [proposal.id], pressing: [proposal.id]) }
        cell.onAcceptAll = { [weak self] in
            guard let self, let debrief = self.expertDebrief else { return }
            let pending = debrief.pending.map(\.id)
            self.decide(accepted: pending, skipped: nil, pressing: Set(pending))
        }
        cell.onLater = { [weak self] in
            guard let self else { return }
            ExpertDesk.shared.holdDebrief(self.viewModel.session.id)
            self.renderPending()
        }
        return cell
    }

    func loadExpertDebrief() {
        guard let backend = expertsBackend else { return }
        let session = viewModel.session.id
        Task { [weak self] in
            do {
                let debrief = try await backend.expertDebrief(sessionID: session)
                self?.adoptDebrief(debrief)
            } catch {
                MidgarLog.info("expert debrief read failed session=\(session): \(error)", category: .session)
            }
        }
    }

    private func adoptDebrief(_ debrief: ExpertDebrief?) {
        guard debrief != expertDebrief else { return keepPolling(debrief) }
        expertDebrief = debrief
        renderPending()
        keepPolling(debrief)
    }

    /// A debrief being written is asked after every few seconds until it is open, settled or failed.
    private func keepPolling(_ debrief: ExpertDebrief?) {
        guard debrief?.state == .drafting else {
            expertPoll?.cancel()
            expertPoll = nil
            return
        }
        guard expertPoll == nil, let backend = expertsBackend else { return }
        let session = viewModel.session.id
        expertPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                let fresh: ExpertDebrief?
                do {
                    fresh = try await backend.expertDebrief(sessionID: session)
                } catch {
                    continue
                }
                guard let self else { return }
                if fresh != self.expertDebrief {
                    self.expertDebrief = fresh
                    self.renderPending()
                }
                if fresh?.state != .drafting {
                    self.expertPoll = nil
                    ExpertDesk.shared.refresh(force: true)
                    if fresh?.state == .open { Theme.Haptics.success() }
                    return
                }
            }
        }
    }

    func finishExpertTask() {
        guard let backend = expertsBackend else { return }
        let session = viewModel.session.id
        ExpertDesk.shared.releaseDebrief(session)
        Theme.Haptics.tap()
        Task { [weak self] in
            do {
                let debrief = try await backend.finishExpertTask(sessionID: session)
                MidgarLog.info("expert task finished session=\(session) state=\(debrief.state.rawValue)", category: .session)
                self?.adoptDebrief(debrief)
                ExpertDesk.shared.refresh(force: true)
            } catch {
                guard let self else { return }
                ExpertRouter.report(error, title: ExpertWords.finishTask, from: self)
            }
        }
    }

    private func decide(accepted: [String], skipped: [String]?, pressing: Set<String>) {
        guard let backend = expertsBackend, !accepted.isEmpty || !(skipped ?? []).isEmpty else { return }
        let session = viewModel.session.id
        expertPressing.formUnion(pressing)
        renderPending()
        Task { [weak self] in
            do {
                let debrief = try await backend.decideExpertDebrief(
                    sessionID: session, ExpertDebriefDecision(accepted: accepted, skipped: skipped))
                guard let self else { return }
                self.expertPressing.subtract(pressing)
                if debrief.state == .settled { Theme.Haptics.success() }
                self.adoptDebrief(debrief)
                if let row = self.expertRow, let fresh = try? await ExpertDesk.shared
                    .experts(forProfileID: row.profileID)?.machineExpert(row.expert.id, prove: false)
                {
                    ExpertDesk.shared.adopt(fresh, profileID: row.profileID)
                }
            } catch {
                guard let self else { return }
                self.expertPressing.subtract(pressing)
                self.renderPending()
                ExpertRouter.report(error, title: ExpertWords.acceptAll, from: self)
            }
        }
    }

    // MARK: The menu

    /// Finish task for a task; Hand to an expert… and Make an expert from this chat… for any chat
    /// on a machine that keeps experts.
    func expertMenuElement() -> UIMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, self.expertsBackend != nil else { return completion([]) }
            var items: [UIMenuElement] = []
            if self.viewModel.session.expertID != nil, !self.viewModel.isBusy {
                items.append(
                    UIAction(
                        title: ExpertWords.finishTask, subtitle: ExpertWords.finishTaskDetail,
                        image: UIImage(systemName: "checkmark.seal")
                    ) { [weak self] _ in self?.finishExpertTask() })
            }
            let experts = ExpertDesk.shared.board.rows
            if !experts.isEmpty {
                items.append(
                    UIMenu(
                        title: ExpertWords.handToExpert, image: UIImage(systemName: ExpertStyle.symbol),
                        children: experts.map { row in
                            UIAction(
                                title: row.expert.name, subtitle: row.machine,
                                image: ExpertStyle.mark(row, side: 22, traits: self.traitCollection)
                            ) { [weak self] _ in self?.handOver(to: row) }
                        }))
            }
            items.append(
                UIAction(title: ExpertWords.makeFromChat, image: UIImage(systemName: "person.crop.rectangle.badge.plus")) {
                    [weak self] _ in
                    guard let self else { return }
                    ExpertEditorViewController.presentDraft(
                        profileID: self.viewModel.contextID, sessionID: self.viewModel.session.id, from: self)
                })
            completion([UIMenu(options: .displayInline, children: items)])
        }
    }

    /// A new task for an expert carrying this conversation as a brief. This chat stays as it is.
    func handOver(to row: ExpertRow) {
        let brief = ConversationBrief.make(
            title: viewModel.session.title, messages: viewModel.state.messages, window: nil)
        ExpertRouter.newTask(row, carrying: brief, from: self)
    }
}

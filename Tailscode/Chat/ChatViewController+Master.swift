import CodingAgentKit
import MidgarCore
import TailscodeCore
import UIKit

/// A chat that is a master's task: the master's mark in the title, Finish task in the menu, and
/// the card at the end of the transcript that finishes the task and holds its debrief. Any chat
/// on a machine that keeps masters can also be handed to one, or made into one.
extension ChatViewController {
    var masterRow: MasterRow? { MasterDesk.shared.row(for: viewModel.session, profileID: viewModel.contextID) }

    private var mastersBackend: (any MachineExperts)? {
        if let direct = viewModel.backend as? any MachineExperts, viewModel.backend.capabilities.supportsExperts {
            return direct
        }
        guard MasterDesk.shared.board.machines.contains(where: { $0.profileID == viewModel.contextID }) else {
            return nil
        }
        return MasterDesk.shared.masters(forProfileID: viewModel.contextID)
    }

    func bindMaster() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(masterDeskChanged), name: MasterDesk.didChange, object: nil)
        if viewModel.session.expertID != nil, MasterDesk.shared.board.isEmpty { MasterDesk.shared.refresh() }
        showMasterMark()
    }

    func masterAppeared() {
        guard viewModel.session.expertID != nil else { return }
        loadMasterDebrief()
    }

    @objc private func masterDeskLoaded() {
        guard viewModel.session.expertID != nil, expertDebrief == nil else { return }
        loadMasterDebrief()
    }

    func masterGone() {
        masterPoll?.cancel()
        masterPoll = nil
    }

    @objc private func masterDeskChanged() {
        showMasterMark()
        guard viewModel.session.expertID != nil else { return }
        if expertDebrief == nil { masterDeskLoaded() }
        renderPending()
    }

    /// The master's mark beside the title, so a task never reads as an ordinary chat.
    private func showMasterMark() {
        guard let row = masterRow else {
            masterMarkView?.isHidden = true
            return
        }
        if masterMarkView == nil {
            let mark = MasterMarkView(side: 20)
            let line = UIStackView(arrangedSubviews: [mark])
            line.axis = .horizontal
            line.spacing = 6
            line.alignment = .center
            if let index = navTitleStack.arrangedSubviews.firstIndex(of: navTitleLabel) {
                navTitleStack.removeArrangedSubview(navTitleLabel)
                line.addArrangedSubview(navTitleLabel)
                navTitleStack.insertArrangedSubview(line, at: index)
            }
            masterMarkView = mark
        }
        masterMarkView?.isHidden = false
        masterMarkView?.show(row)
        navTitleStack.accessibilityHint = Localized.text("A task of %@", row.master.name)
    }

    // MARK: The card

    /// What the card at the end says, or nil while a turn runs, for a chat that is not a task, and
    /// for a debrief the person put off until later.
    func masterCardFace(_ state: ConversationState) -> MasterCardFace? {
        guard viewModel.session.expertID != nil, let row = masterRow, !viewModel.isBusy,
            state.pendingPermissions.isEmpty, state.pendingQuestions.isEmpty, interrupted == nil,
            !MasterDesk.shared.isHeld(viewModel.session.id)
        else { return nil }
        let turns = state.messages.filter { $0.role == .user }.count
        guard turns > 0 else { return nil }
        guard let debrief = expertDebrief else { return .finish(row) }
        let wentOn = debrief.coveredTurns < turns
        if wentOn, debrief.state == .settled || debrief.state == .failed { return .finish(row) }
        return .debrief(debrief, row, pressing: masterPressing, wentOn: wentOn && debrief.state == .open)
    }

    func masterCardCell(_ collectionView: UICollectionView, _ indexPath: IndexPath, face: MasterCardFace)
        -> UICollectionViewCell
    {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: MasterDebriefCell.reuseID, for: indexPath) as! MasterDebriefCell
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
            MasterDesk.shared.holdDebrief(self.viewModel.session.id)
            self.renderPending()
        }
        return cell
    }

    func loadMasterDebrief() {
        guard let backend = mastersBackend else { return }
        let session = viewModel.session.id
        Task { [weak self] in
            do {
                let debrief = try await backend.expertDebrief(sessionID: session)
                self?.adoptDebrief(debrief)
            } catch {
                MidgarLog.info("master debrief read failed session=\(session): \(error)", category: .session)
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
            masterPoll?.cancel()
            masterPoll = nil
            return
        }
        guard masterPoll == nil, let backend = mastersBackend else { return }
        let session = viewModel.session.id
        masterPoll = Task { [weak self] in
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
                    self.masterPoll = nil
                    MasterDesk.shared.refresh(force: true)
                    if fresh?.state == .open { Theme.Haptics.success() }
                    return
                }
            }
        }
    }

    func finishExpertTask() {
        guard let backend = mastersBackend else { return }
        let session = viewModel.session.id
        MasterDesk.shared.releaseDebrief(session)
        Theme.Haptics.tap()
        Task { [weak self] in
            do {
                let debrief = try await backend.finishExpertTask(sessionID: session)
                MidgarLog.info("master task finished session=\(session) state=\(debrief.state.rawValue)", category: .session)
                self?.adoptDebrief(debrief)
                MasterDesk.shared.refresh(force: true)
            } catch {
                guard let self else { return }
                MasterRouter.report(error, title: MasterWords.finishTask, from: self)
            }
        }
    }

    private func decide(accepted: [String], skipped: [String]?, pressing: Set<String>) {
        guard let backend = mastersBackend, !accepted.isEmpty || !(skipped ?? []).isEmpty else { return }
        let session = viewModel.session.id
        masterPressing.formUnion(pressing)
        renderPending()
        Task { [weak self] in
            do {
                let debrief = try await backend.decideExpertDebrief(
                    sessionID: session, ExpertDebriefDecision(accepted: accepted, skipped: skipped))
                guard let self else { return }
                self.masterPressing.subtract(pressing)
                if debrief.state == .settled { Theme.Haptics.success() }
                self.adoptDebrief(debrief)
                if let row = self.masterRow, let fresh = try? await MasterDesk.shared
                    .masters(forProfileID: row.profileID)?.machineExpert(row.master.id, prove: false)
                {
                    MasterDesk.shared.adopt(fresh, profileID: row.profileID)
                }
            } catch {
                guard let self else { return }
                self.masterPressing.subtract(pressing)
                self.renderPending()
                MasterRouter.report(error, title: MasterWords.acceptAll, from: self)
            }
        }
    }

    // MARK: The menu

    /// Finish task for a task; Hand to a master… and Make a master from this chat… for any chat
    /// on a machine that keeps masters.
    func masterMenuElement() -> UIMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, self.mastersBackend != nil else { return completion([]) }
            var items: [UIMenuElement] = []
            if self.viewModel.session.expertID != nil, !self.viewModel.isBusy {
                items.append(
                    UIAction(
                        title: MasterWords.finishTask, subtitle: MasterWords.finishTaskDetail,
                        image: UIImage(systemName: "checkmark.seal")
                    ) { [weak self] _ in self?.finishExpertTask() })
            }
            let masters = MasterDesk.shared.board.rows
            if !masters.isEmpty {
                items.append(
                    UIMenu(
                        title: MasterWords.handToMaster, image: UIImage(systemName: MasterStyle.symbol),
                        children: masters.map { row in
                            UIAction(
                                title: row.master.name, subtitle: row.machine,
                                image: MasterStyle.mark(row, side: 22, traits: self.traitCollection)
                            ) { [weak self] _ in self?.handOver(to: row) }
                        }))
            }
            items.append(
                UIAction(title: MasterWords.makeFromChat, image: UIImage(systemName: "person.crop.rectangle.badge.plus")) {
                    [weak self] _ in
                    guard let self else { return }
                    MasterEditorViewController.presentDraft(
                        profileID: self.viewModel.contextID, sessionID: self.viewModel.session.id, from: self)
                })
            completion([UIMenu(options: .displayInline, children: items)])
        }
    }

    /// A new task for a master carrying this conversation as a brief. This chat stays as it is.
    func handOver(to row: MasterRow) {
        let brief = ConversationBrief.make(
            title: viewModel.session.title, messages: viewModel.state.messages, window: nil)
        MasterRouter.newTask(row, carrying: brief, from: self)
    }
}

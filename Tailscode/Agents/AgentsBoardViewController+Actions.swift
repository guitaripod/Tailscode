import MidgarCore
import TailscodeCore
import UIKit

extension AgentsBoardViewController {
    func toggleChildren(_ id: String) {
        if !expanded.insert(id).inserted { expanded.remove(id) }
        reconfigure([.row(id)])
    }

    private func setState(_ state: AgentsActionState?, for card: AgentAskCard) {
        actionStates[card.ask.id] = state
        reconfigure([.ask(card.id)])
    }

    private func isBusy(_ card: AgentAskCard) -> Bool {
        if case .busy? = actionStates[card.ask.id] { return true }
        return false
    }

    func decide(_ card: AgentAskCard, allow: Bool) {
        guard !isBusy(card), !card.isAway else { return }
        let kind: AgentsActionState.Kind = allow ? .approve : .deny
        setState(.busy(kind), for: card)
        Task { [weak self] in
            guard let self else { return }
            if allow, !(await self.confirmApproval(of: card)) { return }
            let reply = await self.hub.approve(card.id, allow: allow)
            self.settle(reply, kind: kind, card: card)
        }
    }

    func choose(_ card: AgentAskCard, option: String) {
        guard !isBusy(card), !card.isAway else { return }
        let kind = AgentsActionState.Kind.option(option)
        setState(.busy(kind), for: card)
        Task { [weak self] in
            guard let self else { return }
            let reply = await self.hub.answer(card.id, option: option)
            self.settle(reply, kind: kind, card: card)
        }
    }

    private func confirmApproval(of card: AgentAskCard) async -> Bool {
        gateInFlight = true
        let outcome = await AgentsApprovalGate.confirm(
            reason: String(localized: "Approve a command for “\(card.title)”"))
        gateInFlight = false
        switch outcome {
        case .allowed:
            return true
        case .cancelled:
            setState(nil, for: card)
            return false
        case .refused(let why):
            Theme.Haptics.error()
            setState(.failed(why), for: card)
            return false
        }
    }

    private func settle(_ reply: AgentTower.Reply, kind: AgentsActionState.Kind, card: AgentAskCard) {
        switch reply {
        case .sent:
            Theme.Haptics.success()
            setState(.done(kind), for: card)
            forgetDone(card)
        case .needsChat:
            setState(nil, for: card)
            openChat(profileID: card.profileID, sessionID: card.sessionID)
        case .failed(let why):
            Theme.Haptics.error()
            MidgarLog.error("agents answer failed", category: .session)
            setState(.failed(why), for: card)
        }
    }

    /// A settled answer only stands in for the card until the next publish removes it; if the card
    /// is still there a few seconds on, the answer did not take and the buttons are offered again.
    private func forgetDone(_ card: AgentAskCard) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, case .done? = self.actionStates[card.ask.id] else { return }
            self.setState(nil, for: card)
        }
    }

    func openChat(profileID: String, sessionID: String) {
        guard let url = SceneRouting.sessionURL(sessionID) else { return }
        Theme.Haptics.tap()
        MidgarLog.info("agents board opens chat", category: .session)
        PendingRoute.deliver(url)
    }

    func presentPeek(_ target: AgentsPeekTarget, from anchor: (view: UIView, rect: CGRect)? = nil) {
        guard peek == nil, presentedViewController == nil else { return }
        let sheet = AgentPeekViewController(target: target, hub: hub)
        sheet.onOpenChat = { [weak self] profileID, sessionID in
            self?.openChat(profileID: profileID, sessionID: sessionID)
        }
        if let anchor, traitCollection.userInterfaceIdiom == .pad,
            traitCollection.horizontalSizeClass == .regular
        {
            sheet.modalPresentationStyle = .popover
            sheet.preferredContentSize = CGSize(width: 420, height: 640)
            sheet.popoverPresentationController?.sourceView = anchor.view
            sheet.popoverPresentationController?.sourceRect = anchor.rect
            sheet.popoverPresentationController?.permittedArrowDirections = [.left, .right, .up, .down]
        } else {
            sheet.modalPresentationStyle = .pageSheet
            if let presentation = sheet.sheetPresentationController {
                presentation.detents = [.medium(), .large()]
                presentation.prefersGrabberVisible = true
                presentation.prefersScrollingExpandsWhenScrolledToEdge = true
            }
        }
        sheet.onDismiss = { [weak self] in self?.hourPane.hourView.clearSelection() }
        peek = sheet
        present(sheet, animated: true)
    }
}

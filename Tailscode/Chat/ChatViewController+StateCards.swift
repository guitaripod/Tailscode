import TailscodeCore
import CodingAgentKit
import UIKit

extension ChatViewController {
    @objc func bannerTapped() {
        Theme.Haptics.tap()
        if viewModel.isSignedOut {
            presentSignIn()
            return
        }
        viewModel.acknowledgeFailure()
        banner.hide()
        viewModel.refresh()
    }
}

extension ChatViewController {
    /// Told to a screen reader once per event, and only while this conversation is the one in
    /// front of the person: a turn ending in a chat nobody is looking at is a notification's job.
    func announce(_ words: String) {
        guard viewIfLoaded?.window != nil, UIApplication.shared.applicationState == .active
        else { return }
        UIAccessibility.post(notification: .announcement, argument: words)
    }

    func announceTurnEnd() {
        announce(Localized.text("Your agent finished."))
    }

    /// Distinguishes "history is still on its way" from "genuinely empty":
    /// until the transcript has actually loaded (or failed to), an empty
    /// conversation shows a spinner, not the suggestion chips — a session
    /// started on another machine must never flash the empty state while its
    /// history is in flight.
    func updatePlaceholders(hasRows: Bool, for state: ConversationState) {
        let settled =
            state.hasLoadedTranscript || state.lastFailure != nil
            || state.connection == .offline
        loadingState.isHidden = !(hasRevealed && !hasRows && !settled)
        setEmptyStateVisible(hasRevealed && !hasRows && settled)
    }

    /// The suggestion chips fade rather than hard-cut, so a first send reads
    /// as the empty state yielding to the conversation.
    private func setEmptyStateVisible(_ visible: Bool) {
        if visible {
            if emptyState.isHidden {
                emptyState.alpha = 0
                emptyState.isHidden = false
            }
            UIView.animate(withDuration: 0.2) { self.emptyState.alpha = 1 }
        } else {
            guard !emptyState.isHidden else { return }
            if deferEmptyStateHide { return }
            UIView.animate(
                withDuration: 0.18,
                animations: { self.emptyState.alpha = 0 },
                completion: { _ in self.emptyState.isHidden = true })
        }
    }

    /// Lifts the suggestion chips out in the same beat the first message springs
    /// up from the composer, so the empty state yielding to the conversation
    /// reads as one motion instead of a fade racing the entrance and a scroll snap.
    func animateEmptyStateHandoff() {
        guard !emptyState.isHidden else { return }
        UIView.animate(
            withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.85,
            initialSpringVelocity: 0.4, options: [.curveEaseIn, .allowUserInteraction]
        ) {
            self.emptyState.alpha = 0
            self.emptyState.transform =
                CGAffineTransform(translationX: 0, y: -16).scaledBy(x: 0.98, y: 0.98)
        } completion: { _ in
            self.emptyState.isHidden = true
            self.emptyState.alpha = 1
            self.emptyState.transform = .identity
        }
    }

    /// A sent message springs up from the composer into place, then the
    /// thinking indicator rises in just behind it — the bubble should feel
    /// like it physically leaves the input field.
    func animateSendEntrance(bubbleIDs: [String], includeThinking: Bool) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let snapshot = dataSource.snapshot()
        var targets: [(cell: UICollectionViewCell, delay: TimeInterval, rise: CGFloat)] = []
        for id in bubbleIDs {
            guard let index = snapshot.indexOfItem(id),
                let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
            else { continue }
            targets.append((cell, 0, 44))
        }
        if includeThinking, let index = snapshot.indexOfItem("thinking"),
            let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
        {
            targets.append((cell, targets.isEmpty ? 0 : 0.12, 18))
        }
        for target in targets {
            let content = target.cell.contentView
            let finalAlpha = content.alpha
            let isBubble = target.rise > 20
            content.alpha = 0
            content.transform = isBubble
                ? CGAffineTransform(translationX: 0, y: target.rise).scaledBy(x: 0.96, y: 0.96)
                : CGAffineTransform(translationX: 0, y: target.rise)
            UIView.animate(
                withDuration: 0.55, delay: target.delay, usingSpringWithDamping: 0.8,
                initialSpringVelocity: 0.4, options: [.allowUserInteraction]
            ) {
                content.alpha = finalAlpha
                content.transform = .identity
            }
        }
    }

    /// The cut-off turn's card, docked with the other cards about the turn — above a question or
    /// an approval, because what blocks the turn belongs nearest the composer.
    ///
    /// It is the server's record wearing a press this device is still waiting on an answer to. The
    /// press is dropped the moment the server's own account says anything, which is what stops a
    /// button sitting in flight after the thing it asked for has happened.
    func interruptedCard(_ state: ConversationState) -> InterruptedTurn? {
        guard let card = InterruptedTurnReading.read(state.interruption) else { return nil }
        guard let press = viewModel.interruptionPress, card.acceptsPress else { return card }
        return InterruptedTurnReading.pressed(card, press)
    }

    /// Puts the wound-back message's words back into an empty composer once per revert this device
    /// asked for, and never twice while the same revert still stands.
    ///
    /// Words already sitting in the composer that are exactly the wound-back message count as the
    /// offer too: the draft store keeps them across a relaunch, and a Restore after one should
    /// take them back just as it would have before it.
    func fillComposerAfterRevert(_ state: ConversationState) {
        guard let revert = state.revert else {
            lastRevertMessageID = nil
            return
        }
        guard revert.messageID != lastRevertMessageID else { return }
        lastRevertMessageID = revert.messageID
        revertComposerFill = nil
        guard let prompt = RevertReading.prompt(in: state.revertedMessages) else { return }
        if composer.currentText == prompt {
            revertComposerFill = prompt
            return
        }
        guard revert.messageID == requestedRevertID, composer.currentText.isEmpty else { return }
        requestedRevertID = nil
        composer.setDraft(prompt, focus: false, cursorAtEnd: true)
        revertComposerFill = prompt
    }

    /// The message a transcript row stands for, read back from the server's own account rather
    /// than the row's text: Undo from here has to name a real message id, and a row's words alone
    /// cannot tell a sent message from a queued one that has none yet.
    func chatMessage(for rowID: String) -> ChatMessage? {
        guard let messageID = rowsByID[rowID]?.messageID else { return nil }
        return viewModel.state.messages.first { $0.id == messageID }
    }

    func confirmRevert(to message: ChatMessage) {
        guard !viewModel.isReverting else { return }
        let alert = UIAlertController(
            title: RevertReading.confirmTitle,
            message: RevertReading.confirmMessage(stopping: viewModel.state.status == .running),
            preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: RevertReading.confirmAction, style: .destructive) {
                [weak self] _ in
                self?.performRevert(to: message)
            })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(alert, animated: true)
    }

    func performRevert(to message: ChatMessage) {
        Theme.Haptics.warning()
        presentToast(RevertReading.undoingTitle)
        requestedRevertID = message.id
        viewModel.revert(to: message.id)
    }

    /// A question or an approval ends this turn's wait for the person, and the background wait
    /// armed for the session may have announced that same ending already; whichever witness claims
    /// it first is the one that speaks.
    func claimsNeedsYouBanner() -> Bool {
        TurnEndGate.claim(profileID: viewModel.contextID, sessionID: viewModel.session.id)
    }

    func updateBanner(for state: ConversationState) {
        guard UIApplication.shared.applicationState == .active else {
            banner.hide()
            return
        }
        viewModel.noteSignedOutIfHinted(state)
        if viewModel.isSignedOut {
            banner.show(
                String(localized: "Claude is signed out on this machine — tap to sign in"),
                color: Theme.Color.warning, symbol: "person.badge.key",
                hint: String(localized: "Opens sign-in."))
            return
        }
        switch state.connection {
        case .reconnecting:
            banner.hide()
        case .offline:
            if Date() > suppressBannerUntil {
                banner.show(
                    String(localized: "Offline — tap to retry"), color: Theme.Color.danger,
                    symbol: "wifi.slash", hint: String(localized: "Dismisses this and tries again."))
            }
        case .connecting, .live:
            if applyQuotaExhaustion(for: state) { return }
            if let failure = state.lastFailure, failure != viewModel.dismissedFailure,
                state.status != .running, Date() > suppressBannerUntil
            {
                banner.show(
                    failure.message, color: Theme.Color.danger,
                    symbol: "exclamationmark.triangle.fill",
                    hint: String(localized: "Dismisses this and tries again."))
                if lastHapticFailure != failure.message {
                    lastHapticFailure = failure.message
                    Theme.Haptics.error()
                }
            } else {
                banner.hide()
            }
        }
    }

    /// A used-up quota is a state, not a generic failure: name the window, say when it resets,
    /// and leave the raw rate-limit string behind. Pre-emptive when gauges are already full, and
    /// after a turn dies of a rate limit — and only ever about a wall standing in front of the
    /// model this chat would send with, because a window scoped to a model nobody here is using is
    /// a fact for the picker, not a banner over the conversation.
    @discardableResult
    private func applyQuotaExhaustion(for state: ConversationState) -> Bool {
        guard Date() > suppressBannerUntil, state.status != .running else { return false }
        if let waiting = viewModel.soonestResume {
            banner.show(
                ResumeReading.short(waiting), color: Theme.Color.warning,
                symbol: ResumeReading.symbol, hint: String(localized: "Dismisses this and tries again."))
            return true
        }
        let quotas = QuotaSurface.relevantQuotas(
            for: viewModel.backend.agentType, among: UsageWidgetStore.cachedQuotas())
        let selection = viewModel.displayedModel
        let model = selection?.modelID
        let exhaustion: QuotaExhaustion?
        if let failure = state.lastFailure, failure != viewModel.dismissedFailure {
            switch QuotaSurface.read(
                failure: failure.message, quotas: quotas, model: model, selection: selection,
                failedOn: ActiveModel.failedTurn(in: state.messages))
            {
            case .wall(let wall): exhaustion = wall
            case .moved:
                banner.hide()
                return true
            case .words: return false
            }
        } else {
            exhaustion = QuotaSurface.resolve(
                failureMessage: nil, quotas: quotas, model: model, selection: selection)
        }
        guard let exhaustion else { return false }
        banner.show(
            QuotaSurface.bannerBody(exhaustion), color: Theme.Color.danger,
            symbol: "gauge.with.dots.needle.100percent",
            hint: String(localized: "Dismisses this and tries again."))
        let key = "\(exhaustion.provider)|\(exhaustion.window)|\(exhaustion.source)"
        if lastHapticFailure != key {
            lastHapticFailure = key
            Theme.Haptics.warning()
        }
        return true
    }
}

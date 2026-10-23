import TailscodeCore
import CodingAgentKit
import Foundation

extension ChatViewModel {
    func reconcileOptimisticState(with state: ConversationState) {
        if state.status == .running { optimisticThinking = false }
        pending.reconcile(userMessages: state.messages.count { $0.role == .user })
        retireDeliveredFailures(in: state)
        dropQueueSentElsewhere()
        armResumeForWalledTurn(state)
        if optimisticThinking, !pending.hasInFlight,
            let last = state.messages.last, last.role == .assistant, !last.text.isEmpty
        {
            optimisticThinking = false
        }
    }

    /// Drives the conversation's Live Activity once one exists. Only a send from this device opens
    /// one (`deliver`): merely observing a session that is live on the server must not, since such
    /// sessions can run for hours on another machine's behalf. A card that does exist follows every
    /// turn of its conversation — the next one takes it back wherever it was started — and a turn
    /// that ends settles it rather than taking it down, because the ending is the news. A send still
    /// on its way is not an ending, whatever the server's last state said.
    func syncLiveActivity(with state: ConversationState) {
        let cards = AppActivityController.shared
        guard cards.isTracking(session.id) else { return }
        if state.status == .running {
            turnSawRunning = true
            cardSettled = false
            cards.update(
                sessionID: session.id, reading: LiveActivityReading.live(in: state),
                title: cardTitle)
            return
        }
        guard state.status == .idle || state.status == .stable, !optimisticThinking, !cardSettled
        else { return }
        cardSettled = true
        turnSawRunning = false
        cards.settle(
            sessionID: session.id, reading: LiveActivityReading.settled(from: state),
            title: cardTitle)
    }

    /// Settles the card on an outcome this device decided rather than one the server reported.
    func settleCard(_ detail: LiveActivityDetail) {
        cardSettled = true
        AppActivityController.shared.settle(
            sessionID: session.id, reading: LiveActivityReading(detail: detail), title: cardTitle)
    }

    private var cardTitle: String? {
        AgentSession.isPlaceholderTitle(displayTitle) ? nil : displayTitle
    }

    /// Where the card's push token goes: to the server, which keeps the card current while this
    /// process is asleep. A simulator build is unsigned, and asking for a token there refuses the
    /// card outright rather than starting one without it.
    func cardPushSink(title: String) -> AppActivityController.PushTokenSink? {
        #if targetEnvironment(simulator)
            return nil
        #else
            let backend = self.backend
            let sessionID = session.id
            return { token, startedAt in
                #if DEBUG
                    let environment = "development"
                #else
                    let environment = "production"
                #endif
                try? await backend.registerLiveActivity(
                    LiveActivityRegistration(
                        token: token, environment: environment, startedAt: startedAt, title: title),
                    for: sessionID)
            }
        #endif
    }
}

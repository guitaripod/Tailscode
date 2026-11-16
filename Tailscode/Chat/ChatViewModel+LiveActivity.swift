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
        guard cards.follows(session.id) else { return }
        if state.status == .running {
            turnSawRunning = true
            cardSettled = false
            let now = Date()
            cardPulse.note(now)
            cards.update(
                sessionID: session.id, reading: LiveActivityReading.live(in: state),
                title: cardTitle, brief: cardBrief(for: state, now: now))
            return
        }
        guard state.status == .idle || state.status == .stable, !optimisticThinking, !cardSettled
        else { return }
        cardSettled = true
        turnSawRunning = false
        let brief = readCardBrief(state, now: Date(), settled: true)
        cardPulse.reset()
        heldCardBrief = nil
        cards.settle(
            sessionID: session.id, reading: LiveActivityReading.settled(from: state),
            title: cardTitle, brief: brief)
    }

    /// Settles the card on an outcome this device decided rather than one the server reported.
    func settleCard(_ detail: LiveActivityDetail) {
        cardSettled = true
        cardPulse.reset()
        heldCardBrief = nil
        AppActivityController.shared.settle(
            sessionID: session.id, reading: LiveActivityReading(detail: detail), title: cardTitle)
    }

    /// The card's brief for a running turn. The parts that read the turn are read again only when
    /// the turn changed shape — a message, a part, a tool coming back, an ask — or a second has
    /// passed, never per streamed token; the pulse and the moment it last moved are always fresh.
    private func cardBrief(for state: ConversationState, now: Date) -> LiveActivityBrief {
        let shape = CardBriefing.Shape(state)
        guard let held = heldCardBrief, held.shape == shape,
            now.timeIntervalSince(held.readAt) < CardBriefing.rereadAfter
        else { return readCardBrief(state, now: now) }
        var brief = held.brief
        brief.beat = LiveActivityBrief.beatDigits(stamps: cardPulse.stamps, now: now)
        brief.moved = cardPulse.stamps.last ?? brief.moved
        return brief.fitted()
    }

    private func readCardBrief(
        _ state: ConversationState, now: Date, settled: Bool = false
    ) -> LiveActivityBrief {
        let shape = CardBriefing.Shape(state)
        let held = heldCardBrief
        let plan =
            held?.shape.messages == shape.messages && held?.shape.parts == shape.parts
            ? held?.plan : LiveActivityBrief.plan(in: state)
        let fill: Double?
        if cardServerAlerts {
            fill = nil
        } else if let held, held.shape.messages == shape.messages,
            now.timeIntervalSince(held.fillAt) < CardBriefing.refillAfter
        {
            fill = held.fill
        } else {
            fill = LiveActivityBrief.fill(in: state, catalog: knownModels)
        }
        let brief = LiveActivityBrief.read(
            state, stamps: cardPulse.stamps, now: now, effort: currentEffort, settled: settled,
            plan: plan, fill: fill)
        if !settled {
            let fillAt = held.flatMap { $0.fill == fill && $0.shape.messages == shape.messages ? $0.fillAt : nil } ?? now
            heldCardBrief = CardBriefing(
                brief: brief, shape: shape, readAt: now, plan: plan, fill: fill, fillAt: fillAt)
        }
        return brief
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
                let endAlert = await Self.cardEndAlert(sessionID: sessionID)
                try? await backend.registerLiveActivity(
                    LiveActivityRegistration(
                        token: token, environment: environment, startedAt: startedAt, title: title,
                        endAlert: endAlert),
                    for: sessionID)
            }
        #endif
    }

    /// What the server that pushes the card is asked to do at the ending, read when the token is
    /// handed over so a change in Settings, a mute or the app coming forward reaches it with the
    /// next hand-over: nothing for a chat the person muted, or while the app is in front.
    @MainActor
    private static func cardEndAlert(sessionID: String) -> String? {
        guard !AppPreferences.noticeRules.isMuted(sessionID), !AppActivityController.shared.inFront
        else { return nil }
        return LiveActivitySettings.ending.wire
    }

    /// Whether the server this chat talks to pushes the card's ending itself, alert included.
    var cardServerAlerts: Bool {
        #if targetEnvironment(simulator)
            return false
        #else
            return PushRegistrar.covers(profileID: contextID)
        #endif
    }
}

/// The card's brief as last read and what it was read from.
struct CardBriefing {
    /// What a turn looks like to its brief: a streamed word changes none of it.
    struct Shape: Equatable {
        let messages: Int
        let parts: Int
        let running: Int
        let ended: Int
        let asks: Int

        init(_ state: ConversationState) {
            messages = state.messages.count
            parts = state.messages.last?.parts.count ?? 0
            var running = 0
            var ended = 0
            for call in LiveActivityReading.turnCalls(in: state) {
                if call.status == .running || call.status == .pending { running += 1 } else { ended += 1 }
            }
            self.running = running
            self.ended = ended
            asks = state.pendingPermissions.count + state.pendingQuestions.count
        }
    }

    static let rereadAfter: TimeInterval = 1
    /// How long a context fill read from the transcript is trusted while the conversation keeps
    /// its message count: counting it walks every message when no server reported the figure.
    static let refillAfter: TimeInterval = 15

    let brief: LiveActivityBrief
    let shape: Shape
    let readAt: Date
    /// The plan as last folded, read again only when a message or a part arrives, since it reaches
    /// back past the turn.
    let plan: LiveActivityPlan?
    let fill: Double?
    let fillAt: Date
}

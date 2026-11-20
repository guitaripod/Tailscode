import TailscodeCore
import CodingAgentKit
import Foundation
import MidgarCore

extension ChatViewModel {
    func reconcileOptimisticState(with state: ConversationState) {
        if state.status == .running { optimisticThinking = false }
        let echoed = pending.sends.filter(\.isInFlight)
        if pending.reconcile(userMessages: state.messages.count { $0.role == .user }) {
            handPicturesToEcho(of: echoed.filter { pending.send(id: $0.id) == nil }, in: state)
        }
        retireDeliveredFailures(in: state)
        dropQueueSentElsewhere()
        armResumeForWalledTurn(state)
        if optimisticThinking, !pending.hasInFlight,
            let last = state.messages.last, last.role == .assistant, !last.text.isEmpty
        {
            optimisticThinking = false
        }
    }

    /// Drives the conversation's Live Activity. A send from this device opens one (`deliver`), and
    /// so does a turn running when the person has the chat on screen — sent from a desktop, a
    /// queue or the machine itself — unless they turned that off or muted the chat. A card that
    /// exists follows every turn of its conversation — the next one takes it back wherever it was
    /// started — and a turn that ends settles it rather than taking it down, because the ending is
    /// the news. A send still on its way is not an ending, whatever the server's last state said.
    func syncLiveActivity(with state: ConversationState) {
        let cards = AppActivityController.shared
        if state.status == .idle || state.status == .stable { cardFollowTried = false }
        if state.status == .running, !cards.follows(session.id), !cardFollowTried, followsHere {
            cardFollowTried = true
            MidgarLog.info("Live Activity opened for a turn running in the chat on screen \(session.id)", category: .chat)
            openCard(startedAt: LiveActivityReading.live(in: state).startedAt)
        }
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
        if cardFollowed, !turnSawRunning {
            MidgarLog.info("Live Activity withdrawn: the turn it was opened for was not running \(session.id)", category: .chat)
            cardFollowed = false
            cards.withdraw(session.id)
            cards.decline(session.id)
            return
        }
        cardSettled = true
        cardFollowed = false
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
    /// process is asleep.
    func cardPushSink(title: String) -> AppActivityController.PushTokenSink? {
        AppActivityController.tokenSink(backend: backend, sessionID: session.id, title: title)
    }

    /// Whether the server this chat talks to pushes the card's ending itself, alert included.
    var cardServerAlerts: Bool { AppActivityController.serverAlerts(profileID: contextID) }

    /// Whether a turn running in this chat, sent from anywhere, gets a card here: the chat is on
    /// screen in the app in front, cards are on, turns started elsewhere are followed, and the
    /// chat is not muted.
    private var followsHere: Bool {
        isBound && !optimisticThinking && AppPreferences.liveActivitiesEnabled
            && AppActivityController.allowed
            && LiveActivitySettings.followsElsewhere
            && !AppPreferences.noticeRules.isMuted(session.id)
            && !AppActivityController.shared.declined.contains(session.id)
            && AppActivityController.shared.isBeingRead(session.id)
    }

    /// Opens the conversation's card for a turn this device did not send, its clock from when the
    /// turn began.
    func openCard(startedAt: Date?) {
        let title =
            AgentSession.isPlaceholderTitle(displayTitle)
            ? String(localized: "Agent session") : displayTitle
        AppActivityController.shared.start(
            sessionID: session.id, sessionTitle: title, serverName: serverName,
            profileID: contextID, startedAt: startedAt, onPushToken: cardPushSink(title: title),
            serverAlerts: cardServerAlerts)
        turnSawRunning = false
        cardSettled = false
        cardFollowed = true
        cardPulse.reset()
        heldCardBrief = nil
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

extension ChatViewModel {
    /// The pictures of a send whose echo has just landed are given to the files the server named
    /// them as, in order, so the server's rows draw what the pending rows drew.
    func handPicturesToEcho(of retired: [PendingSend], in state: ConversationState) {
        let pictures = retired.flatMap(\.pictures)
        guard !pictures.isEmpty,
            let echo = state.messages.last(where: { $0.role == .user })
        else { return }
        let files: [FileReference] = echo.parts.compactMap { part in
            if case .file(let file) = part.kind, file.mime?.hasPrefix("image/") ?? true {
                return file
            }
            return nil
        }
        var pendingIndex: [UUID: Int] = [:]
        let sent: [(file: FileReference, data: Data)] = retired.flatMap { send in
            send.pictures.compactMap { attachment -> (FileReference, Data)? in
                let index = pendingIndex[send.id, default: 0]
                pendingIndex[send.id] = index + 1
                guard let data = attachment.data else { return nil }
                return (
                    FileReference(
                        path: nil, mime: attachment.mime,
                        url: "pending:\(send.id.uuidString):\(index)",
                        filename: attachment.filename), data
                )
            }
        }
        for (picture, file) in zip(sent, files.suffix(sent.count)) {
            AttachmentImageStore.shared.hand(picture.data, from: picture.file, to: file)
        }
    }
}


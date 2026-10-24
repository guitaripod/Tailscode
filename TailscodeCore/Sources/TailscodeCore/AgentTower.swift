import CodingAgentKit
import Foundation

/// What the board is built from and how it reaches a machine: a client says which backend answers
/// for a profile and what its catalog holds, and the tower does the rest.
public struct AgentTowerSetup: Sendable {
    public let backend: @Sendable (String) -> (any CodingAgentBackend)?
    public let catalog: @Sendable (String) -> [ModelInfo]

    public init(
        backend: @escaping @Sendable (String) -> (any CodingAgentBackend)?,
        catalog: @escaping @Sendable (String) -> [ModelInfo]
    ) {
        self.backend = backend
        self.catalog = catalog
    }
}

/// Keeps the agents board true while it is open: it watches the running sessions the cap allows,
/// each over its own conversation at the lowest refresh priority, reads them into facts, and
/// publishes the board at most once a second. Closed, it holds nothing.
///
/// A device that is not looking costs the machines nothing: watching is the board's, opened and
/// closed with it, never a standing subscription. A tower is not on the main actor and its
/// streams are plain `AsyncStream`s, so a client with an event loop of its own can consume them.
public actor AgentTower {
    private struct Watch {
        var conversation: AgentConversation
        var consumer: Task<Void, Never>
        var agentsTask: Task<Void, Never>?
        var stamps: [Date] = []
        var seen: [String: Date] = [:]
        var agents: [SubagentSummary] = []
        var signature = 0
        var endedAt: Date?
    }

    public static let linger: TimeInterval = 8
    public static let agentPoll: Duration = .seconds(4)

    private let setup: AgentTowerSetup
    private var entries: [SessionEntry] = []
    private var reachability: [String: Bool] = [:]
    private var unread: Set<String> = []
    private var pinned: Set<String> = []
    private var watches: [String: Watch] = [:]
    private var facts: [String: AgentFacts] = [:]
    private var finished: [AgentFinish] = []
    private var log = AgentHourLog()
    private var board: AgentBoard = .empty
    private var subscribers: [UUID: AsyncStream<AgentBoard>.Continuation] = [:]
    private var isOpen = false
    private var dirty = false
    private var publisher: Task<Void, Never>?
    private var clock: @Sendable () -> Date
    private let poll: Duration

    public init(
        setup: AgentTowerSetup, poll: Duration = AgentTower.agentPoll,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.setup = setup
        self.poll = poll
        self.clock = clock
    }

    public var current: AgentBoard { board }

    /// How an action on an agent ended. `needsChat` means this agent's backend takes it only through
    /// its chat's own paths — a Claude question is answered by the chat's send, a queue the server
    /// does not keep is the chat's own — so the client opens the chat rather than going round it.
    public enum Reply: Sendable, Equatable {
        case sent
        case needsChat
        case failed(String)
    }

    /// Approves or denies the tool an agent is waiting on, through the same shared answer a
    /// notification's button uses, so whoever answers first settles it for both.
    public func approve(_ id: String, allow: Bool) async -> Reply {
        guard let watch = watches[id], let ask = facts[id]?.ask, case .approval(let request) = ask.kind
        else { return .needsChat }
        do {
            _ = try await PermissionAnswer.answer(
                request, decision: allow ? .once : .reject, through: watch.conversation,
                backend: nil)
            return .sent
        } catch {
            return .failed(Self.said(error))
        }
    }

    /// Picks one of the options of a question, where the backend has a side channel for it.
    public func answer(_ id: String, option: String) async -> Reply {
        guard let watch = watches[id], let ask = facts[id]?.ask, case .question(let request) = ask.kind,
            request.questions.count == 1,
            let entry = entries.first(where: { key($0) == id }),
            setup.backend(entry.profileID)?.capabilities.supportsQuestions == true
        else { return .needsChat }
        do {
            try await watch.conversation.answer(request, answers: [[option]])
            return .sent
        } catch {
            return .failed(Self.said(error))
        }
    }

    /// Ends the turn an agent is on.
    public func stop(_ id: String) async -> Reply {
        guard let watch = watches[id] else { return .needsChat }
        do {
            try await watch.conversation.cancelCurrentTurn()
            return .sent
        } catch {
            return .failed(Self.said(error))
        }
    }

    /// Puts a message in an agent's queue, where the server keeps one; it is read when the turn
    /// yields.
    public func nudge(_ id: String, text: String) async -> Reply {
        guard let watch = watches[id], let entry = entries.first(where: { key($0) == id }),
            setup.backend(entry.profileID)?.capabilities.supportsServerQueue == true
        else { return .needsChat }
        do {
            _ = try await watch.conversation.enqueue(text)
            return .sent
        } catch {
            return .failed(Self.said(error))
        }
    }

    private static func said(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    public func hour() -> AgentHour { log.hour(now: clock()) }

    public func boards() -> AsyncStream<AgentBoard> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: AgentBoard.self, bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.yield(board)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
        factSubscribers[id] = nil
    }

    private var factSubscribers: [UUID: (key: String, continuation: AsyncStream<AgentFacts?>.Continuation)] = [:]

    /// What the tower knows of one agent, now and every time it learns more: the peek's own
    /// stream. Nil while nothing is watching it.
    public func facts(for key: String) -> AsyncStream<AgentFacts?> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: AgentFacts?.self, bufferingPolicy: .bufferingNewest(1))
        factSubscribers[id] = (key, continuation)
        continuation.yield(facts[key])
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func tell(_ key: String) {
        for subscriber in factSubscribers.values where subscriber.key == key {
            subscriber.continuation.yield(facts[key])
        }
    }

    /// The board is on screen: watch what is running.
    public func open() {
        guard !isOpen else { return }
        isOpen = true
        log.beginObserving(at: clock())
        rebalance()
        publish()
    }

    /// A row the cap left as listed asks to be watched: it takes the slot of the least recent
    /// watched session that is not waiting on the person.
    public func watch(_ key: String) {
        guard isOpen else { return }
        pinned.insert(key)
        rebalance()
        publish()
    }

    /// The board is gone: let every watch go.
    public func close() {
        guard isOpen else { return }
        isOpen = false
        pinned.removeAll()
        log.endObserving(at: clock())
        for key in Array(watches.keys) { release(key) }
        facts.removeAll()
        lastState.removeAll()
        publish()
    }

    /// A fresh listing: the sessions every machine reported, which of those answered, which the
    /// person has not read. Called by a client whenever its own list refreshes.
    public func update(
        entries: [SessionEntry], reachability: [String: Bool], unread: Set<String>
    ) {
        self.entries = entries
        self.reachability = reachability
        self.unread = unread
        if isOpen { rebalance() }
        publish()
    }

    private func key(_ entry: SessionEntry) -> String {
        entry.profileID + "/" + entry.session.id
    }

    private func rebalance() {
        let now = clock()
        let live = entries.filter { !$0.session.isSubagent && $0.session.archived != true }
        let candidates = live.map { entry -> AgentWatch.Candidate in
            let id = key(entry)
            let held = watches[id] != nil
            let known = facts[id]
            let lingering = held && (watches[id]?.endedAt.map { now.timeIntervalSince($0) < Self.linger } ?? false)
            return AgentWatch.Candidate(
                key: id, isRunning: entry.session.isWorking || known?.isRunning == true,
                waiting: known?.ask != nil, updatedAt: entry.session.updatedAt, held: held,
                pinned: pinned.contains(id), lingering: lingering)
        }
        let plan = AgentWatch.plan(candidates: candidates)
        for id in plan.release { release(id) }
        for id in plan.attach {
            if let entry = live.first(where: { key($0) == id }) { attach(id, entry) }
        }
        let valid = Set(live.map(key))
        for id in Array(watches.keys) where !valid.contains(id) { release(id) }
    }

    private func attach(_ id: String, _ entry: SessionEntry) {
        guard watches[id] == nil, let backend = setup.backend(entry.profileID) else { return }
        let conversation = AgentConversation(backend: backend, sessionID: entry.session.id)
        let consumer = Task { [weak self] in
            await conversation.setRefreshPriority(.background)
            let stream = await conversation.states()
            for await state in stream {
                if Task.isCancelled { break }
                await self?.absorb(id, state)
            }
        }
        let sessionID = entry.session.id
        let pollEvery = poll
        let agentsTask = Task { [weak self] in
            while !Task.isCancelled {
                if let agents = try? await backend.subagents(for: sessionID) {
                    await self?.hear(id, agents: agents)
                }
                try? await Task.sleep(for: pollEvery)
            }
        }
        watches[id] = Watch(conversation: conversation, consumer: consumer, agentsTask: agentsTask)
    }

    private func release(_ id: String) {
        guard let watch = watches[id] else { return }
        watch.consumer.cancel()
        watch.agentsTask?.cancel()
        watches[id] = nil
        facts[id] = nil
        lastState[id] = nil
        tell(id)
    }

    /// The poll is also the board's clock: a session that has gone quiet sends no events, so its
    /// heartbeat is read again here, which is how a stall draws as a flat strip.
    private func hear(_ id: String, agents: [SubagentSummary]) {
        guard var watch = watches[id] else { return }
        if watch.agents != agents {
            watch.agents = agents
            watches[id] = watch
        }
        if let state = lastState[id] { absorb(id, state, quiet: true) }
    }

    private var lastState: [String: ConversationState] = [:]

    private func absorb(_ id: String, _ state: ConversationState, quiet: Bool = false) {
        guard var watch = watches[id], let entry = entries.first(where: { key($0) == id }) else {
            return
        }
        let now = clock()
        lastState[id] = state
        let signature = Self.signature(of: state)
        if signature != watch.signature, !quiet {
            watch.signature = signature
            watch.stamps = AgentBeat.pruned(watch.stamps + [now], now: now)
        }
        for call in LiveActivityReading.turnCalls(in: state) where watch.seen[call.id] == nil {
            watch.seen[call.id] = now
        }
        for ask in state.pendingPermissions.map(\.id) + state.pendingQuestions.map(\.id)
        where watch.seen[ask] == nil {
            watch.seen[ask] = now
        }
        let before = facts[id]
        let after = AgentFacts.read(
            state: state, agents: watch.agents, seen: watch.seen, stamps: watch.stamps, now: now,
            catalog: setup.catalog(entry.profileID))
        if let before, before.isRunning, !after.isRunning {
            watch.endedAt = now
            record(ending: entry, before: before, state: state, at: now)
        } else if after.isRunning {
            watch.endedAt = nil
        }
        facts[id] = after
        watches[id] = watch
        tell(id)
        note(entry, facts: after, at: now)
        if before?.isRunning != after.isRunning || before?.ask != after.ask { rebalance() }
        publish()
    }

    private static func signature(of state: ConversationState) -> Int {
        var hasher = Hasher()
        hasher.combine(state.messages.count)
        hasher.combine(state.status)
        hasher.combine(state.pendingPermissions.count)
        hasher.combine(state.pendingQuestions.count)
        if let last = state.messages.last {
            hasher.combine(last.id)
            hasher.combine(last.parts.count)
            if let part = last.parts.last, case .tool(let call) = part.kind {
                hasher.combine(call.status)
            }
        }
        return hasher.finalize()
    }

    private func record(
        ending entry: SessionEntry, before: AgentFacts, state: ConversationState, at now: Date
    ) {
        let outcome: AgentFinish.Outcome =
            state.lastFailure != nil ? .failed : (state.interruption != nil ? .stopped : .done)
        let id = key(entry)
        finished.removeAll { $0.id == id }
        finished.append(
            AgentFinish(
                id: id, profileID: entry.profileID, sessionID: entry.session.id,
                title: AgentSession.isPlaceholderTitle(entry.session.title)
                    ? Localized.text("New chat") : entry.session.title,
                machine: entry.profileName, outcome: outcome,
                line: AgentFinish.line(
                    outcome: outcome, duration: before.startedAt.map { now.timeIntervalSince($0) },
                    tools: before.toolCount, files: before.touched.count,
                    failure: state.lastFailure?.message),
                endedAt: now, unread: true))
        finished = Array(
            finished.filter { now.timeIntervalSince($0.endedAt) < AgentBoard.finishedWindow }
                .suffix(30))
        log.end(id: id, outcome: outcome, at: now)
    }

    private func note(_ entry: SessionEntry, facts: AgentFacts, at now: Date) {
        let id = key(entry)
        let phase: AgentHourPhase?
        switch facts.phase {
        case .working, .retrying: phase = .working
        case .needsYou: phase = .needsYou
        case .background: phase = .background
        case .idle: phase = nil
        }
        let title =
            AgentSession.isPlaceholderTitle(entry.session.title)
            ? Localized.text("New chat") : entry.session.title
        log.note(
            id: id, profileID: entry.profileID, sessionID: entry.session.id, title: title,
            machine: entry.profileName, phase: phase, at: now)
        for child in facts.children {
            log.note(
                id: id + "#" + child.id, parentID: id, profileID: entry.profileID,
                sessionID: entry.session.id, title: child.title, machine: entry.profileName,
                phase: child.isActive ? (child.kind == .background ? .background : .working) : nil,
                at: now)
        }
    }

    private func publish() {
        dirty = true
        guard publisher == nil else { return }
        publisher = Task { [weak self] in
            while let self, await self.flush() {
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }

    private func flush() -> Bool {
        guard dirty else {
            publisher = nil
            return false
        }
        dirty = false
        let now = clock()
        let sources = entries.map { entry in
            AgentSource(
                entry: entry, facts: facts[key(entry)], reachable: reachability[entry.profileID],
                unread: unread.contains(key(entry)))
        }
        let next = AgentBoard.read(sources: sources, finished: finished, now: now)
        if next != board {
            board = next
            for continuation in subscribers.values { continuation.yield(next) }
        }
        return true
    }
}

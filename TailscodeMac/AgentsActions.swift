import AppKit
import CodingAgentKit
import TailscodeCore

/// What a press on a verb has come to, held per session so the card in the list and the peek in the
/// inspector say the same thing: a button in flight is off, one that was answered says so until the
/// next publish takes the card away, and one that failed says why and stays live.
@MainActor
final class AgentsActions {
    enum Verb: Equatable {
        case approve
        case deny
        case option(String)
        case stop
    }

    enum Phase: Equatable {
        case idle
        case inFlight(Verb)
        case sent(Verb)
        case failed(String)
    }

    private struct Held {
        var askID: String
        var phase: Phase
    }

    private var held: [String: Held] = [:]
    private var stops: [String: Phase] = [:]
    private var observers: [@MainActor (String) -> Void] = []
    var feed: any AgentsFeed
    var openChat: (String) -> Void = { _ in }
    var confirmStop: (String, @escaping () -> Void) -> Void = { _, proceed in proceed() }

    init(feed: any AgentsFeed) {
        self.feed = feed
    }

    func observe(_ handler: @escaping @MainActor (String) -> Void) {
        observers.append(handler)
    }

    /// The state of one session's pending answer. A new ask on the same session starts clean.
    func phase(for key: String, askID: String) -> Phase {
        guard let entry = held[key], entry.askID == askID else { return .idle }
        return entry.phase
    }

    func stopPhase(for key: String) -> Phase { stops[key] ?? .idle }

    func forget(keepingOnly live: Set<String>) {
        for key in held.keys where !live.contains(key) { held[key] = nil }
        for key in stops.keys where !live.contains(key) { stops[key] = nil }
    }

    func decide(_ key: String, ask: AgentAsk, allow: Bool) {
        let verb: Verb = allow ? .approve : .deny
        begin(key, askID: ask.id, verb: verb) { [feed] in await feed.approve(key, allow: allow) }
    }

    func choose(_ key: String, ask: AgentAsk, option: String) {
        begin(key, askID: ask.id, verb: .option(option)) { [feed] in
            await feed.answer(key, option: option)
        }
    }

    /// Stop always asks first, naming the chat; nothing is sent until the answer is yes.
    func requestStop(_ key: String, title: String) {
        if case .inFlight = stopPhase(for: key) { return }
        confirmStop(title) { [weak self] in self?.stop(key) }
    }

    func nudge(_ key: String, text: String) async -> AgentTower.Reply {
        let reply = await feed.nudge(key, text: text)
        if reply == .needsChat {
            let scope = DraftScope.chat(profileID: Self.profile(of: key), sessionID: Self.session(of: key))
            let existing = DraftStore.text(for: scope)
            DraftStore.record(existing.isEmpty ? text : existing + "\n" + text, for: scope)
            openChat(key)
        }
        return reply
    }

    private func stop(_ key: String) {
        if case .inFlight = stopPhase(for: key) { return }
        setStop(key, .inFlight(.stop))
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reply = await self.feed.stop(key)
            switch reply {
            case .sent: self.setStop(key, .sent(.stop))
            case .failed(let why): self.setStop(key, .failed(why))
            case .needsChat:
                self.setStop(key, .idle)
                self.openChat(key)
            }
        }
    }

    private func begin(
        _ key: String, askID: String, verb: Verb,
        send: @escaping @MainActor () async -> AgentTower.Reply
    ) {
        switch phase(for: key, askID: askID) {
        case .inFlight, .sent: return
        case .idle, .failed: break
        }
        set(key, Held(askID: askID, phase: .inFlight(verb)))
        Task { @MainActor [weak self] in
            let reply = await send()
            guard let self else { return }
            switch reply {
            case .sent:
                self.set(key, Held(askID: askID, phase: .sent(verb)))
            case .failed(let why):
                self.set(key, Held(askID: askID, phase: .failed(why)))
            case .needsChat:
                self.set(key, Held(askID: askID, phase: .idle))
                self.openChat(key)
            }
        }
    }

    private func set(_ key: String, _ next: Held) {
        held[key] = next
        for observer in observers { observer(key) }
    }

    private func setStop(_ key: String, _ next: Phase) {
        stops[key] = next
        for observer in observers { observer(key) }
    }

    static func profile(of key: String) -> String {
        String(key.prefix { $0 != "/" })
    }

    static func session(of key: String) -> String {
        guard let slash = key.firstIndex(of: "/") else { return key }
        return String(key[key.index(after: slash)...])
    }
}

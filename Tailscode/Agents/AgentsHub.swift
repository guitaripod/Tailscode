import CodingAgentKit
import MidgarCore
import TailscodeCore
import UIKit

/// What a screen that lists sessions hands the tower each time its listing moves: every entry of
/// every machine, which machines answered, which sessions are unread, and the live backends the
/// tower must watch through, so it never opens a second connection of its own.
struct AgentsSnapshot {
    let entries: [SessionEntry]
    let reachability: [String: Bool]
    let unread: Set<String>
    let backends: [String: any CodingAgentBackend]
    let heard: [String: Date]
}

@MainActor
protocol AgentsListSource: AnyObject {
    func agentsSnapshot() -> AgentsSnapshot
}

private final class AgentsBackendBook: @unchecked Sendable {
    private let lock = NSLock()
    private var backends: [String: any CodingAgentBackend] = [:]

    func replace(with backends: [String: any CodingAgentBackend]) {
        lock.withLock { self.backends = backends }
    }

    func backend(_ profileID: String) -> (any CodingAgentBackend)? {
        lock.withLock { backends[profileID] }
    }
}

private enum AgentsCommand: Sendable {
    case open
    case close
    case update(entries: [SessionEntry], reachability: [String: Bool], unread: Set<String>)
    case watch(String)
}

/// The one tower of this process and the road to it. Every command goes through a single queue, so
/// an open, an update and a close land in the order they were given however quickly a board is
/// shown and hidden; nothing is held while no board is on screen. In the demo world there is no
/// tower and no network: the same words come from `AgentDemo`.
@MainActor
final class AgentsHub {
    static let shared = AgentsHub()

    private let tower: AgentTower
    private let book = AgentsBackendBook()
    private let commands: AsyncStream<AgentsCommand>.Continuation
    private weak var source: AgentsListSource?
    private var viewers = 0
    private var demoBase = Date()
    private(set) var heard: [String: Date] = [:]

    private init() {
        let book = book
        let tower = AgentTower(
            setup: AgentTowerSetup(
                backend: { book.backend($0) }, catalog: { ModelCatalogStore.cached($0) }))
        self.tower = tower
        let (stream, continuation) = AsyncStream.makeStream(of: AgentsCommand.self)
        commands = continuation
        Task {
            for await command in stream {
                switch command {
                case .open: await tower.open()
                case .close: await tower.close()
                case .update(let entries, let reachability, let unread):
                    await tower.update(entries: entries, reachability: reachability, unread: unread)
                case .watch(let key): await tower.watch(key)
                }
            }
        }
    }

    var isDemo: Bool { ConnectionController.shared.isDemoMode }

    func register(_ source: AgentsListSource) { self.source = source }

    func listingChanged() {
        guard viewers > 0, !isDemo, let snapshot = source?.agentsSnapshot() else { return }
        push(snapshot)
    }

    private func push(_ snapshot: AgentsSnapshot) {
        book.replace(with: snapshot.backends)
        heard = snapshot.heard
        commands.yield(
            .update(
                entries: snapshot.entries, reachability: snapshot.reachability,
                unread: snapshot.unread))
    }

    /// A board is on screen: the tower opens with the first one and lets go with the last.
    func acquire() {
        viewers += 1
        guard viewers == 1 else { return }
        MidgarLog.info("agents tower open", category: .lifecycle)
        guard !isDemo else {
            demoBase = Date()
            return
        }
        if let snapshot = source?.agentsSnapshot() { push(snapshot) }
        commands.yield(.open)
    }

    func release() {
        guard viewers > 0 else { return }
        viewers -= 1
        guard viewers == 0 else { return }
        MidgarLog.info("agents tower closed", category: .lifecycle)
        if !isDemo { commands.yield(.close) }
    }

    func lastHeard(_ profileID: String) -> Date? { heard[profileID] }

    func boards() async -> AsyncStream<AgentBoard> {
        guard isDemo else { return await tower.boards() }
        return Self.once(AgentDemo.board(now: demoBase))
    }

    func facts(for key: String) async -> AsyncStream<AgentFacts?> {
        guard isDemo else { return await tower.facts(for: key) }
        let working = key.hasSuffix("/w")
        return Self.once(working ? Optional(AgentDemo.facts(now: demoBase)) : nil)
    }

    func hour() async -> AgentHour {
        guard isDemo else { return await tower.hour() }
        return AgentDemo.hour(now: demoBase)
    }

    func watch(_ key: String) {
        guard !isDemo else { return }
        commands.yield(.watch(key))
    }

    func approve(_ key: String, allow: Bool) async -> AgentTower.Reply {
        guard !isDemo else { return await Self.demoReply() }
        return await tower.approve(key, allow: allow)
    }

    func answer(_ key: String, option: String) async -> AgentTower.Reply {
        guard !isDemo else { return await Self.demoReply() }
        return await tower.answer(key, option: option)
    }

    func stop(_ key: String) async -> AgentTower.Reply {
        guard !isDemo else { return await Self.demoReply() }
        return await tower.stop(key)
    }

    func nudge(_ key: String, text: String) async -> AgentTower.Reply {
        guard !isDemo else { return await Self.demoReply() }
        return await tower.nudge(key, text: text)
    }

    private static func demoReply() async -> AgentTower.Reply {
        try? await Task.sleep(for: .milliseconds(450))
        return .sent
    }

    private static func once<Element: Sendable>(_ element: Element) -> AsyncStream<Element> {
        AsyncStream { continuation in
            continuation.yield(element)
            continuation.finish()
        }
    }
}

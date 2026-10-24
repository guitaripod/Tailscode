import AppKit
import CodingAgentKit
import TailscodeCore

/// What the Agents window reads and does, whoever answers it: the live tower, or the fictional
/// board a screenshot, a tour and a self-test stand on. The window is written against this and
/// never against a tower, so the same views are proved with no server.
@MainActor
protocol AgentsFeed: AnyObject {
    var board: AgentBoard { get }
    func open(onBoard: @escaping @MainActor (AgentBoard) -> Void)
    func close()
    func follow(_ key: String, onFacts: @escaping @MainActor (AgentFacts?) -> Void) -> Task<Void, Never>
    func hour() async -> AgentHour
    func watch(_ key: String)
    func approve(_ key: String, allow: Bool) async -> AgentTower.Reply
    func answer(_ key: String, option: String) async -> AgentTower.Reply
    func stop(_ key: String) async -> AgentTower.Reply
    func nudge(_ key: String, text: String) async -> AgentTower.Reply
}

/// Runs async work one piece after another, so a close sent right after an open reaches the tower
/// after it rather than racing it.
@MainActor
final class AgentsSerial {
    private var chain: Task<Void, Never>?

    func run(_ work: @escaping @Sendable () async -> Void) {
        let previous = chain
        chain = Task {
            await previous?.value
            await work()
        }
    }
}

/// The feed that is the tower: opened and closed with the window, consumed by one task.
@MainActor
final class TowerFeed: AgentsFeed {
    private let tower: AgentTower
    private let serial: AgentsSerial
    private var consumer: Task<Void, Never>?
    private(set) var board: AgentBoard = .empty

    init(tower: AgentTower, serial: AgentsSerial) {
        self.tower = tower
        self.serial = serial
    }

    func open(onBoard: @escaping @MainActor (AgentBoard) -> Void) {
        guard consumer == nil else { return }
        let tower = self.tower
        serial.run { await tower.open() }
        consumer = Task { @MainActor [weak self] in
            let seed = await tower.current
            self?.board = seed
            onBoard(seed)
            for await next in await tower.boards() {
                if Task.isCancelled { break }
                self?.board = next
                onBoard(next)
            }
        }
    }

    func close() {
        guard let running = consumer else { return }
        running.cancel()
        consumer = nil
        let tower = self.tower
        serial.run { await tower.close() }
    }

    func follow(_ key: String, onFacts: @escaping @MainActor (AgentFacts?) -> Void) -> Task<Void, Never> {
        let tower = self.tower
        return Task { @MainActor in
            for await facts in await tower.facts(for: key) {
                if Task.isCancelled { break }
                onFacts(facts)
            }
        }
    }

    func hour() async -> AgentHour { await tower.hour() }

    func watch(_ key: String) {
        let tower = self.tower
        serial.run { await tower.watch(key) }
    }

    func approve(_ key: String, allow: Bool) async -> AgentTower.Reply {
        await tower.approve(key, allow: allow)
    }

    func answer(_ key: String, option: String) async -> AgentTower.Reply {
        await tower.answer(key, option: option)
    }

    func stop(_ key: String) async -> AgentTower.Reply { await tower.stop(key) }

    func nudge(_ key: String, text: String) async -> AgentTower.Reply {
        await tower.nudge(key, text: text)
    }
}

/// The fictional board of `AgentDemo`: no tower, no network. Every reply takes `replyDelay`, so a
/// button is seen in flight, and what was asked is kept for a harness to read.
@MainActor
final class DemoFeed: AgentsFeed {
    private(set) var board: AgentBoard
    private let epoch: Date
    var replyDelay: Duration = .milliseconds(450)
    var reply: AgentTower.Reply = .sent
    private(set) var asked: [String] = []
    private(set) var watched: [String] = []
    private(set) var isOpen = false
    private var onBoard: (@MainActor (AgentBoard) -> Void)?

    init(now: Date = Date()) {
        epoch = now
        board = AgentDemo.board(now: now)
    }

    func open(onBoard: @escaping @MainActor (AgentBoard) -> Void) {
        isOpen = true
        self.onBoard = onBoard
        onBoard(board)
    }

    func close() {
        isOpen = false
        onBoard = nil
    }

    func replace(_ next: AgentBoard) {
        board = next
        onBoard?(next)
    }

    func follow(_ key: String, onFacts: @escaping @MainActor (AgentFacts?) -> Void) -> Task<Void, Never> {
        let facts = key.hasSuffix("/w") ? AgentDemo.facts(now: epoch) : nil
        return Task { @MainActor in onFacts(facts) }
    }

    func hour() async -> AgentHour { AgentDemo.hour(now: Date()) }

    func watch(_ key: String) { watched.append(key) }

    func approve(_ key: String, allow: Bool) async -> AgentTower.Reply {
        await answered("approve:\(allow):\(key)")
    }

    func answer(_ key: String, option: String) async -> AgentTower.Reply {
        await answered("answer:\(option):\(key)")
    }

    func stop(_ key: String) async -> AgentTower.Reply { await answered("stop:\(key)") }

    func nudge(_ key: String, text: String) async -> AgentTower.Reply {
        await answered("nudge:\(key)")
    }

    private func answered(_ what: String) async -> AgentTower.Reply {
        asked.append(what)
        try? await Task.sleep(for: replyDelay)
        return reply
    }
}

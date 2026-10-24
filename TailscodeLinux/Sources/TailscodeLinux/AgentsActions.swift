import CodingAgentKit
import Foundation
import TailscodeCore

/// What a press on the board asks of an agent.
enum AgentsAction: Hashable, Sendable {
    case approve
    case deny
    case answer(String)
    case stop
    case nudge
    case watch
}

/// Where a press has got to. A card never loses its buttons on a guess: a sent answer says so
/// until the board's next publish takes the card away, and a failed one says why and stays live.
enum AgentsActionState: Equatable, Sendable {
    case idle
    case inFlight(AgentsAction)
    case sent(AgentsAction, Date)
    case failed(AgentsAction, String)

    var isBusy: Bool {
        switch self {
        case .inFlight, .sent: return true
        case .idle, .failed: return false
        }
    }

    /// Whether a press of this action has to wait: anything on its way blocks everything, and a
    /// sent answer blocks only what belongs with it — an approval that went out is no reason to
    /// refuse a stop.
    func blocks(_ action: AgentsAction) -> Bool {
        switch self {
        case .idle, .failed: return false
        case .inFlight: return true
        case .sent(let sent, _): return sent.group == action.group
        }
    }
}

extension AgentsAction {
    /// What a press is called in the log: never the option picked or the words nudged, which can
    /// hold anything.
    fileprivate var logName: String {
        switch self {
        case .approve: return "approve"
        case .deny: return "deny"
        case .answer: return "answer"
        case .stop: return "stop"
        case .nudge: return "nudge"
        case .watch: return "watch"
        }
    }

    fileprivate var group: Int {
        switch self {
        case .approve, .deny, .answer: return 0
        case .stop: return 1
        case .nudge: return 2
        case .watch: return 3
        }
    }
}

/// How the board reaches the rest of the app: the chat a press opens, and the question asked
/// before a stop. Handed in by whoever presents the window, so a check can answer for both.
struct AgentsHooks: @unchecked Sendable {
    var openChat: @Sendable (_ key: String, _ draft: String?) -> Void
    var confirmStop: @Sendable (_ title: String, _ proceed: @escaping @Sendable () -> Void) -> Void
}

/// Every press the board answers, on the GTK thread. It guards the one rule all of them share: a
/// button that is waiting for the machine cannot be pressed again, so a double click is one send.
final class AgentsActions: @unchecked Sendable {
    static let sentLinger: TimeInterval = 8

    private let source: any AgentsSource
    private let hooks: AgentsHooks
    private var states: [String: AgentsActionState] = [:]
    private(set) var sends = 0
    var changed: (String) -> Void = { _ in }

    init(source: any AgentsSource, hooks: AgentsHooks) {
        self.source = source
        self.hooks = hooks
    }

    func state(_ key: String) -> AgentsActionState { states[key] ?? .idle }

    var inFlightKeys: [String] { states.compactMap { $0.value.isBusy ? $0.key : nil } }

    /// Drops what a key was doing when its card is no longer on the board, and lets a sent answer
    /// that the board never acted on be pressed again.
    func reconcile(live: Set<String>, now: Date) {
        for (key, state) in states {
            if !live.contains(key) {
                states[key] = nil
                continue
            }
            if case .sent(_, let at) = state, now.timeIntervalSince(at) >= Self.sentLinger {
                states[key] = nil
                changed(key)
            }
        }
    }

    func perform(_ action: AgentsAction, key: String, title: String, text: String? = nil) {
        guard !state(key).blocks(action) else { return }
        switch action {
        case .stop:
            hooks.confirmStop(title) { [weak self] in
                Gtk.onMain { [weak self] in self?.run(action, key: key, text: nil) }
            }
        case .nudge:
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return }
            run(action, key: key, text: text)
        default:
            run(action, key: key, text: text)
        }
    }

    private func run(_ action: AgentsAction, key: String, text: String?) {
        guard !state(key).blocks(action) else { return }
        states[key] = .inFlight(action)
        sends += 1
        changed(key)
        let source = source
        Task { [weak self] in
            let reply = await Self.send(source, action, key: key, text: text)
            Gtk.onMain { [weak self] in self?.settle(reply, action: action, key: key, text: text) }
        }
    }

    private static func send(
        _ source: any AgentsSource, _ action: AgentsAction, key: String, text: String?
    ) async -> AgentTower.Reply {
        switch action {
        case .approve: return await source.approve(key, allow: true)
        case .deny: return await source.approve(key, allow: false)
        case .answer(let option): return await source.answer(key, option: option)
        case .stop: return await source.stop(key)
        case .nudge: return await source.nudge(key, text: text ?? "")
        case .watch:
            await source.watch(key)
            return .sent
        }
    }

    private func settle(_ reply: AgentTower.Reply, action: AgentsAction, key: String, text: String?) {
        AppLog.write(.session, "agents \(action.logName) on \(key): \(reply.logName)")
        switch reply {
        case .sent:
            states[key] = action == .watch ? nil : .sent(action, Date())
        case .failed(let why):
            states[key] = .failed(action, why)
        case .needsChat:
            states[key] = nil
            hooks.openChat(key, action == .nudge ? text : nil)
        }
        changed(key)
    }

    func openChat(_ key: String) { hooks.openChat(key, nil) }
}

extension AgentTower.Reply {
    fileprivate var logName: String {
        switch self {
        case .sent: return "sent"
        case .needsChat: return "needs the chat"
        case .failed: return "failed"
        }
    }
}

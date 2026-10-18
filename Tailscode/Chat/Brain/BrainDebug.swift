import CodingAgentKit
import Foundation
import TailscodeCore
import UIKit

/// What a debug launch can force on a brain so every state can be photographed without a turn to
/// wait for and without a tap, which `simctl` cannot send: `TAILSCODE_NEURAL_STATE` names an
/// `ActivityKind` (`thinking`, `usingTool`, `delegating`, `needsApproval`, `needsAnswer`, `failed`,
/// `stalled`, `compacting`, `inBackground`, `offline`), `TAILSCODE_NEURAL_OPEN` is `1`, `0` or
/// `first`, and `TAILSCODE_NEURAL_WALK` drives a brain on a clock (see `BrainWalk`). A release
/// build reads none of it.
enum BrainDebug {
    #if DEBUG
        private static let environment = ProcessInfo.processInfo.environment
    #endif

    /// `TAILSCODE_NEURAL_SLOWMO=<n>` stretches the move n times so a still screenshot can read it
    /// frame by frame; 1 everywhere else.
    static var slowMotion: Double {
        #if DEBUG
            return environment["TAILSCODE_NEURAL_SLOWMO"].flatMap(Double.init).map { max($0, 1) } ?? 1
        #else
            return 1
        #endif
    }

    static var forcedActivity: ActivityKind? {
        #if DEBUG
            guard let name = environment["TAILSCODE_NEURAL_STATE"] else { return nil }
            switch name {
            case "thinking": return .thinking
            case "working": return .working
            case "writing": return .writing
            case "usingTool", "reading": return .usingTool(name: "Read", kind: .fileRead)
            case "editing": return .usingTool(name: "Edit", kind: .fileEdit)
            case "shell": return .usingTool(name: "Bash", kind: .shell)
            case "delegating": return .delegating(active: 1)
            case "needsApproval": return .needsApproval
            case "needsAnswer": return .needsAnswer
            case "failed": return .failed
            case "stalled": return .stalled(tasks: 1)
            case "compacting": return .compacting
            case "retrying": return .retrying(attempt: 1)
            case "inBackground": return .inBackground(tasks: 2)
            case "offline": return .offline
            case "queued": return .queued(1)
            default: return nil
            }
        #else
            return nil
        #endif
    }

    /// The open brain the launch asked for, as a turn id: `""` closes every brain, `first` opens
    /// the oldest one. Nil leaves the policy's answer.
    static func openOverride(policy: NeuralOpenPolicy, turns: [NeuralTurn]) -> String? {
        #if DEBUG
            switch environment["TAILSCODE_NEURAL_OPEN"] {
            case "0": return ""
            case "first": return turns.first { NeuralOpenPolicy.isBrain(turn: $0) }?.id
            case "1": return policy.latest
            default: return nil
            }
        #else
            return nil
        #endif
    }

    /// `TAILSCODE_NEURAL_WALK`: steps on a clock, `seconds:verb=value` separated by `;`, in place of
    /// the touches `simctl` cannot make. Verbs: `open` and `close` (the brain of the open or the
    /// latest turn), `openturn` (the nth brain, from one), `click` and `hover` (a step number),
    /// `key` (characters sent through the browse reducer, `esc`, `enter`, `up`, `down` and `space`
    /// by name), `chip` (a zone's filter by its key digit), `dive` (a zone name: think, sense,
    /// act, shell, delegate, say), `replay` (a fraction to hold the playhead at), `prov` (the nth
    /// chip), `rows`, `share`, `scroll` (points to scroll the account) and `unfold` (the nth work
    /// line).
    static var walk: [(delay: Double, verb: String, value: String)] {
        #if DEBUG
            guard let script = environment["TAILSCODE_NEURAL_WALK"] else { return [] }
            return script.split(separator: ";").compactMap { step in
                let halves = step.split(separator: ":", maxSplits: 1)
                guard halves.count == 2, let delay = Double(halves[0]) else { return nil }
                let parts = halves[1].split(separator: "=", maxSplits: 1)
                return (delay, String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
            }
        #else
            return []
        #endif
    }

    #if DEBUG
        @MainActor
        static func dumpTree(_ view: UIView, depth: Int, max: Int) {
            let pad = String(repeating: " ", count: max - depth)
            var extra = ""
            if let label = view as? UILabel { extra = " text=\(label.attributedText?.string ?? "")" }
            AppLogger.ui.info("dump \(pad)\(type(of: view)) f=\(NSCoder.string(for: view.frame)) a=\(view.alpha) h=\(view.isHidden)\(extra)")
            guard depth > 0 else { return }
            for child in view.subviews { dumpTree(child, depth: depth - 1, max: max) }
        }
    #endif

    /// One line of the log per move: how many frames it drew and the longest gap between two of
    /// them, which is what a dropped frame is.
    static func logMove(turn: String, direction: String, frames: Int, maxGap: Double, duration: Double) {
        AppLogger.performance.info(
            "brain move turn=\(turn) direction=\(direction) frames=\(frames) maxGapMs=\(String(format: "%.1f", maxGap * 1000)) durationMs=\(String(format: "%.0f", duration * 1000))"
        )
    }

    /// The conversation with its last turn put into the forced state: the answer taken away, and
    /// the last tool call left running, failed or waiting as the state needs. Everything the row
    /// builder and the brains read is read from this, so the transcript and the head agree.
    static func staged(
        _ messages: [ChatMessage]
    ) -> (messages: [ChatMessage], running: Bool, awaiting: NeuralAwaiting) {
        #if DEBUG
            guard let activity = forcedActivity else { return (messages, false, .none) }
            var staged = messages
            while let last = staged.last, last.role == .assistant, isAnswerOnly(last) {
                staged.removeLast()
            }
            guard let index = staged.lastIndex(where: { $0.role == .assistant }) else {
                return (staged, false, .none)
            }
            var message = staged[index]
            var awaiting = NeuralAwaiting()
            if let partIndex = message.parts.lastIndex(where: { part in
                if case .tool = part.kind { return true }
                return false
            }), case .tool(var call) = message.parts[partIndex].kind {
                switch activity {
                case .failed:
                    call.status = .error
                case .needsApproval, .usingTool, .delegating, .stalled, .needsAnswer:
                    call.status = .running
                    let id = "\(message.id):\(message.parts[partIndex].id)"
                    if case .needsApproval = activity { awaiting.approvals.insert(id) }
                    if case .needsAnswer = activity { awaiting.answers.insert(id) }
                    if case .stalled = activity { awaiting.stalled.insert(id) }
                default:
                    break
                }
                message.parts[partIndex].kind = .tool(call)
                staged[index] = message
            }
            let running: Bool
            switch activity {
            case .failed, .offline, .queued: running = false
            default: running = true
            }
            return (staged, running, awaiting)
        #else
            return (messages, false, .none)
        #endif
    }

    #if DEBUG
        private static func isAnswerOnly(_ message: ChatMessage) -> Bool {
            let kinds = message.parts.map(\.kind)
            return !kinds.isEmpty
                && kinds.allSatisfy {
                    if case .text = $0 { return true }
                    return false
                }
        }
    #endif
}

#if DEBUG
    /// What a walk step does to the brains on screen.
    @MainActor
    enum BrainWalk {
        static func run(
            verb: String, value: String, store: BrainStore, collection: UICollectionView,
            toggle: (String) -> Void, rows: (String) -> Void, share: (String) -> Void,
            refresh: () -> Void
        ) {
            AppLogger.ui.info("brain walk verb=\(verb) value=\(value) open=\(store.openTurnID ?? "-")")
            let cells = collection.visibleCells.compactMap { $0 as? NeuralBrainCell }
            let openCell = cells.first { $0.brainRow.openView != nil }
            let turnID = store.openTurnID ?? store.latestTurnID
            switch verb {
            case "open":
                if let id = Int(value).flatMap({ store.turnID(atBrain: $0) }) ?? turnID, !store.isOpen(id) { toggle(id) }
            case "close":
                if let id = store.openTurnID { toggle(id) }
            case "openturn":
                if let number = Int(value), let id = store.turnID(atBrain: number) { toggle(id) }
            case "top":
                guard let cell = openCell ?? cells.first else { return }
                let extra = Double(value) ?? 8
                let target = cell.frame.minY - collection.adjustedContentInset.top - CGFloat(extra)
                collection.setContentOffset(CGPoint(x: 0, y: max(-collection.adjustedContentInset.top, target)), animated: false)
            case "bottom":
                let target = collection.contentSize.height - collection.bounds.height + collection.adjustedContentInset.bottom
                collection.setContentOffset(CGPoint(x: 0, y: max(0, target)), animated: false)
            case "carddump":
                let depth = Int(value) ?? 4
                for cell in cells { BrainDebug.dumpTree(cell.brainRow.card, depth: depth, max: depth) }
            case "rows": if let turnID { rows(turnID) }
            case "share": if let turnID { share(turnID) }
            case "replay":
                guard let turnID else { return }
                store.mutate(turnID) { $0.scrub(to: Double(value) ?? 0.5) }
                openCell?.brainRow.openView?.refreshAll(fromBrowse: true)
            case "prov":
                guard let turnID, let model = store.model(for: turnID) else { return }
                let tokens = model.answerTokens(in: store.answerText(for: turnID)).map(\.text)
                if let index = Int(value), tokens.indices.contains(index) {
                    store.mutate(turnID) { $0.setProvenance(token: tokens[index]) }
                    openCell?.brainRow.openView?.refreshAll(fromBrowse: true)
                }
            default:
                openCell?.brainRow.openView?.walk(verb: verb, value: value)
            }
        }
    }
#endif

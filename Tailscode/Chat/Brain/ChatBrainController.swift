import CodingAgentKit
import TailscodeCore
import UIKit

/// Everything a chat screen needs to hold brains without holding any of their logic: it reads the
/// conversation into a layout for the row builder, tells which calls are waiting on the person,
/// carries the actions a cell asks for, and feels a node fire.
///
/// One lives per chat screen. The screen stays the owner of rows and the data source; this object
/// owns the `BrainStore`, and answers only in values.
@MainActor
final class ChatBrainController {
    let store = BrainStore()

    private var lastStatuses: [String: NeuralStatus] = [:]
    private var feltTurn: String?

    /// Whether the transcript draws brains at all right now: the person's style, and a machine that
    /// can draw the head.
    var isActive: Bool { BrainStore.isActive }

    /// What the builder and the brains are to read of a conversation. A debug launch may stage the
    /// last turn into a state; a release build hands the conversation back as it is.
    struct Reading {
        let messages: [ChatMessage]
        let running: Bool
        let awaiting: NeuralAwaiting
    }

    func reading(of state: ConversationState, stalled: Bool) -> Reading {
        guard BrainDebug.forcedActivity != nil else {
            return Reading(
                messages: state.messages, running: state.status == .running,
                awaiting: Self.awaiting(in: state, messages: state.messages, stalled: stalled))
        }
        let staged = BrainDebug.staged(state.messages)
        return Reading(
            messages: staged.messages, running: staged.running, awaiting: staged.awaiting)
    }

    /// Reads the conversation into brains. `facts` says what the conversation is doing now, which
    /// only the latest turn wears; every turn knows who answered it, and wears the level the chat
    /// is on (`effort`, what the composer's pill shows) when its own messages recorded none.
    func layout(
        reading: Reading, facts: StatusFacts, call: VoiceCallFace?, providerID: String?,
        effortOptions: [String], effort: String?
    ) -> BrainLayout {
        guard isActive else {
            if store.count > 0 { store.forgetEverything() }
            return .none
        }
        let activity = BrainDebug.forcedActivity ?? facts.activity
        let layout = store.prepare(
            messages: reading.messages, running: reading.running, awaiting: reading.awaiting
        ) { _, isLatest in
            guard isLatest else {
                return NeuralBrainContext(
                    providerID: providerID, effortOptions: effortOptions, effort: effort)
            }
            return NeuralBrainContext(
                activity: activity, fill: facts.context, call: call, providerID: providerID,
                effortOptions: effortOptions, effort: effort)
        }
        feel()
        return layout
    }

    /// A turn's work as the lines an exported transcript carries: each thought and note in its own
    /// words, each tool call as its name and argument in brackets.
    func markdown(for turnID: String) -> String {
        guard let model = store.model(for: turnID) else { return "" }
        return model.steps.map { step in
            if NeuralReading.isThought(step) || NeuralReading.isNote(step) { return step.text }
            let title = NeuralReading.title(of: step)
            return step.detail.isEmpty ? "[\(title)]" : "[\(title) \(step.detail)]"
        }.joined(separator: "\n")
    }

    /// A node of the live turn firing is a step of the work landing while the person waits, and
    /// the cue is the one the activity rows have always played; repeats inside its gap are the
    /// engine's to drop.
    private func feel() {
        guard let id = store.openTurnID ?? store.latestTurnID, let model = store.model(for: id)
        else { return }
        guard model.turn.outcome == .running else {
            lastStatuses = [:]
            feltTurn = nil
            return
        }
        if feltTurn != id {
            feltTurn = id
            lastStatuses = [:]
        }
        var fired = false
        var next: [String: NeuralStatus] = [:]
        for step in model.steps {
            next[step.id] = step.status
            let before = lastStatuses[step.id]
            if before != step.status, step.status == .ok || step.status == .running {
                fired = true
            }
        }
        let first = lastStatuses.isEmpty
        lastStatuses = next
        if fired, !first { Theme.Haptics.step() }
    }

    /// The calls that are stopped on the person. A permission or a question names no call of its
    /// own on every backend, so the last call that is still running stands for it, and the ids
    /// the requests carry are offered as they are.
    static func awaiting(
        in state: ConversationState, messages: [ChatMessage], stalled: Bool
    ) -> NeuralAwaiting {
        var awaiting = NeuralAwaiting()
        if !state.pendingPermissions.isEmpty {
            for request in state.pendingPermissions { awaiting.approvals.insert(request.id) }
            if let call = lastRunningCall(
                in: messages, named: state.pendingPermissions.first?.toolName, kind: nil)
            {
                awaiting.approvals.insert(call)
            }
        }
        if !state.pendingQuestions.isEmpty {
            for request in state.pendingQuestions { awaiting.answers.insert(request.id) }
            if let call = lastRunningCall(in: messages, named: nil, kind: .question) {
                awaiting.answers.insert(call)
            }
        }
        if stalled, let call = lastRunningCall(in: messages, named: nil, kind: nil) {
            awaiting.stalled.insert(call)
        }
        if state.interruption != nil, let last = messages.last(where: { $0.role == .assistant }) {
            awaiting.interrupted.insert(last.id)
        }
        return awaiting
    }

    private static func lastRunningCall(
        in messages: [ChatMessage], named name: String?, kind: ToolCallSummary.Kind?
    ) -> String? {
        guard let last = messages.last(where: { $0.role == .assistant }) else { return nil }
        for part in last.parts.reversed() {
            guard case .tool(let call) = part.kind,
                call.status == .running || call.status == .pending
            else { continue }
            if let name, call.name.caseInsensitiveCompare(name) != .orderedSame { continue }
            if let kind, call.summaryKind != kind { continue }
            return call.id
        }
        return nil
    }
}

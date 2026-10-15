import CodingAgentKit
import Foundation

/// What the call tells the gateway about the agent: whether it is working, a short ASCII account
/// of it for the model to say, and a number that rises whenever that account means something new.
public struct VoiceAgentSnapshot: Sendable, Equatable {
    public var busy: Bool
    public var digest: String
    public var turn: Int

    public init(busy: Bool, digest: String, turn: Int) {
        self.busy = busy
        self.digest = digest
        self.turn = turn
    }

    public static let idle = VoiceAgentSnapshot(busy: false, digest: SpokenDigest.idle, turn: 0)

    public var wire: VoiceClientMessage.AgentState {
        VoiceClientMessage.AgentState(busy: busy, digest: digest, turn: turn)
    }

    public func sameMeaning(as other: VoiceAgentSnapshot) -> Bool {
        busy == other.busy && digest == other.digest
    }
}

/// The agent's state read down to a sentence or two a voice can say, by rule and with no model.
///
/// The words are English and ASCII on purpose: they are a tool result for a model that speaks only
/// English, so they are not localised. A digest never carries code, markup, addresses or long
/// paths, because a voice reading those aloud is worse than saying nothing.
public enum SpokenDigest {
    public static let idle = "The agent is idle."

    private static let freshPrompt: TimeInterval = 20

    public static func snapshot(
        from state: ConversationState, after previous: VoiceAgentSnapshot? = nil, now: Date = Date()
    ) -> VoiceAgentSnapshot {
        let reading = read(state, now: now)
        let candidate = VoiceAgentSnapshot(busy: reading.busy, digest: reading.digest, turn: previous?.turn ?? 0)
        guard let previous else {
            return VoiceAgentSnapshot(busy: candidate.busy, digest: candidate.digest, turn: 1)
        }
        let changed = !candidate.sameMeaning(as: previous)
        return VoiceAgentSnapshot(busy: candidate.busy, digest: candidate.digest, turn: previous.turn + (changed ? 1 : 0))
    }

    public static func read(_ state: ConversationState, now: Date = Date()) -> (busy: Bool, digest: String) {
        if state.connection == .offline {
            return (false, ascii("The agent is not reachable right now."))
        }
        if let waiting = waiting(in: state) { return (false, waiting) }
        if let activity = working(in: state) { return (true, ascii("Working. \(activity)")) }
        if let failure = failure(in: state) { return (false, failure) }
        if let done = finished(in: state) { return (false, done) }
        if let last = state.messages.last, last.role == .user,
            now.timeIntervalSince(last.createdAt) < freshPrompt
        {
            return (true, ascii("Working. Starting on it."))
        }
        return (false, idle)
    }

    private static func waiting(in state: ConversationState) -> String? {
        if let question = state.pendingQuestions.first {
            let asked = question.questions.first?.question ?? ""
            let sentence = firstSentences(of: asked, count: 1, limit: 160)
            return ascii("Waiting for you. " + (sentence.isEmpty ? "The agent has a question." : sentence))
        }
        if let permission = state.pendingPermissions.first {
            let subject = firstSentences(of: permission.title ?? "", count: 1, limit: 100)
            if !subject.isEmpty { return ascii("Waiting for you. It needs your approval: \(subject)") }
            guard let tool = permission.toolName, !tool.isEmpty else {
                return ascii("Waiting for you. It needs your approval.")
            }
            return ascii("Waiting for you. It needs your approval to use \(tool).")
        }
        return nil
    }

    private static func working(in state: ConversationState) -> String? {
        if let activity = ActivityKind.inFlight(in: state), !activity.wantsYou {
            return phrase(for: activity)
        }
        if let work = state.backgroundWork {
            return phrase(for: work.stalled ? .stalled(tasks: work.tasks) : .inBackground(tasks: work.tasks))
        }
        return nil
    }

    static func phrase(for activity: ActivityKind) -> String {
        switch activity {
        case .working, .thinking, .queued, .connecting, .reconnecting, .failed, .offline:
            return "Thinking."
        case .writing:
            return "Writing the answer."
        case .usingTool(_, let kind):
            return phrase(forTool: kind)
        case .delegating(let active):
            return active == 1 ? "Running one helper agent." : "Running \(active) helper agents."
        case .inBackground(let tasks):
            return tasks == 1 ? "A background task is running." : "\(tasks) background tasks are running."
        case .stalled:
            return "A background task looks stuck."
        case .retrying:
            return "Waiting on the model provider, which is retrying."
        case .compacting:
            return "Compacting the conversation."
        case .needsApproval, .needsAnswer:
            return "Waiting for you."
        }
    }

    private static func phrase(forTool kind: ToolCallSummary.Kind) -> String {
        switch kind {
        case .shell: return "Running a command."
        case .fileRead: return "Reading files."
        case .fileEdit, .fileWrite: return "Editing files."
        case .fileSearch: return "Searching the code."
        case .webSearch: return "Searching the web."
        case .webFetch: return "Reading a web page."
        case .taskTracking: return "Updating its plan."
        case .subagent, .workflow: return "Running helper agents."
        case .skill: return "Using a skill."
        case .question: return "Asking a question."
        case .other: return "Using a tool."
        }
    }

    private static func failure(in state: ConversationState) -> String? {
        var reason: String?
        if let failure = state.lastFailure {
            reason = failure.message
        } else if let last = state.messages.last, last.role == .assistant, !last.isStreaming,
            let error = last.error
        {
            reason = error
        }
        guard let reason else { return nil }
        let short = firstSentences(of: reason, count: 1, limit: 120)
        return ascii("That failed. " + (short.isEmpty ? "The turn stopped with an error." : short))
    }

    private static func finished(in state: ConversationState) -> String? {
        guard let last = state.messages.last, last.role == .assistant else { return nil }
        let answer = lastAnswer(in: state.messages)
        let body = firstSentences(of: answer, count: 2, limit: 240)
        return ascii("Done. " + (body.isEmpty ? "It finished without a written answer." : body))
    }

    private static func lastAnswer(in messages: [ChatMessage]) -> String {
        for message in messages.reversed() {
            if message.role == .user { return "" }
            guard message.role == .assistant else { continue }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return ""
    }

    private static func ascii(_ text: String) -> String {
        VoiceText.ascii(text, limit: VoiceWire.digestLimit)
    }
}

import CodingAgentKit
import Foundation

/// What a turn's Live Activity is saying, named rather than written.
///
/// The card on the Lock Screen and in the Dynamic Island is drawn from whatever reached it last:
/// an update this device made, or a push the server sent while the phone sat in a pocket. A server
/// speaks no language but its own, so the card carries which thing it is saying and the widget
/// writes the words in the reader's language. claude-bridge stamps these same raw values, which
/// makes them a wire contract: a case may be added, never renamed. A card with no key at all —
/// written before the key existed — is drawn from the sentence its sender wrote instead.
public enum LiveActivityDetail: String, Sendable, CaseIterable {
    case thinking
    case writing
    case tool
    case compacting
    case question
    case approval
    case finished
    case answerless
    case failed
    case noResponse
    case sendFailed
    case interrupted
    case cancelled
    case lost

    /// The coarse phase the card's content state carries beside the detail — the vocabulary an
    /// activity started by an older process decodes, and so the only one a server may rely on.
    public var phase: String {
        switch self {
        case .thinking: return "thinking"
        case .writing: return "responding"
        case .tool, .compacting: return "tool"
        case .question, .approval: return "approval"
        case .finished, .answerless, .cancelled, .lost: return "done"
        case .failed, .noResponse, .sendFailed, .interrupted: return "error"
        }
    }

    /// Whether the turn is standing still until the person answers it. Such a card outranks every
    /// other, live or settled, because it is the only one that is waiting on somebody.
    public var wantsYou: Bool { self == .question || self == .approval }

    /// The one line under the conversation's name.
    ///
    /// A finished turn is counted rather than timed: the card draws how long it ran beside this
    /// line, and how long ago it ended under it, so the sentence carries only what neither clock
    /// can — how much work it did, and whether the machine is still doing some for it.
    public func line(tool: String?, toolCount: Int = 0, background: Int = 0) -> String {
        switch self {
        case .thinking: return Localized.text("Thinking…")
        case .writing: return Localized.text("Writing…")
        case .tool:
            guard let tool, !tool.isEmpty else { return Localized.text("Running tool") }
            return Localized.text("Running %@", tool)
        case .compacting: return Localized.text("Compacting…")
        case .question: return Localized.text("Waiting for your answer")
        case .approval: return Localized.text("Awaiting your approval")
        case .finished:
            var parts = [Localized.text("Done")]
            if toolCount > 0 { parts.append(Localized.text("%lld tools", toolCount)) }
            if background > 0 { parts.append(Localized.text("%lld tasks still running", background)) }
            return parts.joined(separator: " · ")
        case .answerless: return Localized.text("Nothing came back")
        case .failed: return Localized.text("Something went wrong")
        case .noResponse: return Localized.text("No response")
        case .sendFailed: return Localized.text("Couldn't send")
        case .interrupted: return Localized.text("The server stopped mid-answer")
        case .cancelled: return Localized.text("Cancelled")
        case .lost: return Localized.text("Open the chat to see how it ended")
        }
    }

    /// The face the card wears, from the same vocabulary every other surface draws: a running
    /// shell wears the terminal on the Lock Screen exactly as it does in the transcript, and an
    /// ending wears the face its notification does.
    public func face(tool: String?) -> LiveActivityFace {
        switch self {
        case .thinking: return LiveActivityFace(ActivityKind.thinking.icon)
        case .writing: return LiveActivityFace(ActivityKind.writing.icon)
        case .tool:
            guard let tool, !tool.isEmpty else {
                return LiveActivityFace(symbol: "wrench.and.screwdriver", tone: .live)
            }
            let kind = ToolCall(id: "", name: tool, status: .running).summaryKind
            return LiveActivityFace(symbol: ActivityKind.symbol(forTool: kind), tone: .live)
        case .compacting: return LiveActivityFace(ActivityKind.compacting.icon)
        case .question: return LiveActivityFace(ActivityKind.needsAnswer.icon)
        case .approval: return LiveActivityFace(ActivityKind.needsApproval.icon)
        case .finished: return LiveActivityFace(symbol: AlertFace.turnEnded.symbol, tone: .live)
        case .answerless:
            return LiveActivityFace(symbol: AnswerlessTurn.symbol, tone: AnswerlessTurn.tone)
        case .failed, .noResponse, .sendFailed:
            return LiveActivityFace(symbol: AlertFace.turnFailed.symbol, tone: .danger)
        case .interrupted:
            return LiveActivityFace(symbol: InterruptedTurn.symbol, tone: InterruptedTurn.tone)
        case .cancelled: return LiveActivityFace(ActivityIcon.stopped)
        case .lost: return LiveActivityFace(symbol: "questionmark.circle", tone: .quiet)
        }
    }

    /// Which card the Dynamic Island shows, and which leads the Lock Screen, when a person is
    /// following several conversations at once: whatever is waiting on them, then whatever is
    /// still moving, then what went wrong, and only then what simply finished.
    public var relevance: Double {
        switch self {
        case .question, .approval: return 100
        case .thinking, .writing, .tool, .compacting: return 50
        case .answerless, .failed, .noResponse, .sendFailed, .interrupted: return 20
        case .finished, .cancelled, .lost: return 10
        }
    }
}

/// A card's symbol and the meaning its colour comes from.
public struct LiveActivityFace: Sendable, Equatable {
    public let symbol: String
    public let tone: ActivityTone

    public init(symbol: String, tone: ActivityTone) {
        self.symbol = symbol
        self.tone = tone
    }

    public init(_ icon: ActivityIcon) {
        self.init(symbol: icon.symbol, tone: icon.tone)
    }
}

/// A conversation read down to what its Live Activity says: the detail, and the facts the words
/// and the face are made from.
public struct LiveActivityReading: Sendable, Equatable {
    public let detail: LiveActivityDetail
    public let tool: String?
    public let toolCount: Int
    public let background: Int
    /// When the running turn began, as the transcript records it: the answer the machine opened for
    /// it, or the prompt when none is open yet. A card taken back for a turn this device did not
    /// send starts its clock here rather than at the moment somebody happened to look.
    public let startedAt: Date?
    /// When the turn's answer was finished, as the transcript records it. A phone that was
    /// suspended while the turn ended learns of it minutes later, and a card that said it ended
    /// then would be a clock lying about the work.
    public let endedAt: Date?

    public init(
        detail: LiveActivityDetail, tool: String? = nil, toolCount: Int = 0, background: Int = 0,
        startedAt: Date? = nil, endedAt: Date? = nil
    ) {
        self.detail = detail
        self.tool = tool
        self.toolCount = toolCount
        self.background = background
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public var line: String { detail.line(tool: tool, toolCount: toolCount, background: background) }
    public var face: LiveActivityFace { detail.face(tool: tool) }

    /// What a running turn is doing. What it *is* is decided once, in `ActivityKind.inFlight`, so
    /// the badge in the chat, the row in the list and the card on the Lock Screen can never
    /// disagree about the same second.
    public static func live(in state: ConversationState) -> LiveActivityReading {
        let calls = turnCalls(in: state)
        let detail: LiveActivityDetail
        switch ActivityKind.inFlight(in: state) {
        case .needsAnswer?: detail = .question
        case .needsApproval?: detail = .approval
        case .usingTool?: detail = .tool
        case .compacting?: detail = .compacting
        case .writing?: detail = .writing
        default: detail = .thinking
        }
        let tool = (calls.last { $0.status == .running } ?? calls.last)?.name
        return LiveActivityReading(
            detail: detail, tool: tool, toolCount: calls.count, startedAt: turnStart(in: state))
    }

    /// How a turn that has just ended is remembered. A question it left waiting outranks
    /// everything, because the turn ended in order to ask it; then a failure, a turn the machine
    /// cut off, and a turn that came back with nothing — each of which reads as a finished one if
    /// nobody says otherwise.
    public static func settled(from state: ConversationState) -> LiveActivityReading {
        let answer = turnAnswer(in: state)
        let detail: LiveActivityDetail
        if !state.pendingQuestions.isEmpty {
            detail = .question
        } else if !state.pendingPermissions.isEmpty {
            detail = .approval
        } else if state.lastFailure != nil {
            detail = .failed
        } else if state.interruption != nil {
            detail = .interrupted
        } else if answer?.isAnswerless == true {
            detail = .answerless
        } else {
            detail = .finished
        }
        return LiveActivityReading(
            detail: detail, toolCount: turnCalls(in: state).count,
            background: state.backgroundWork?.tasks ?? 0, endedAt: answer?.completedAt)
    }

    /// Every tool call the latest turn made, searched back only as far as the last thing the
    /// person said.
    private static func turnCalls(in state: ConversationState) -> [ToolCall] {
        var calls: [ToolCall] = []
        for message in state.messages.reversed() {
            if message.role == .user { break }
            guard message.role == .assistant else { continue }
            for part in message.parts.reversed() {
                if case .tool(let call) = part.kind { calls.append(call) }
            }
        }
        return calls.reversed()
    }

    /// Where the running turn began. An answer the machine opened on its own — background work
    /// ending, with nothing typed — is a turn of its own, so an open answer outranks the prompt.
    private static func turnStart(in state: ConversationState) -> Date? {
        var opened: Date?
        for message in state.messages.reversed() {
            if message.role == .user { return opened ?? message.createdAt }
            if message.role == .assistant, message.completedAt == nil { opened = message.createdAt }
        }
        return opened
    }

    /// The latest turn's answer, or nil when the person spoke last.
    private static func turnAnswer(in state: ConversationState) -> ChatMessage? {
        for message in state.messages.reversed() {
            if message.role == .user { return nil }
            if message.role == .assistant { return message }
        }
        return nil
    }
}

/// How long a turn that has ended keeps its card.
///
/// An ending is news until it has been read, so the card stays exactly where the turn left it —
/// in the Dynamic Island and on the Lock Screen — rather than vanishing the moment the work stops.
/// Opening the conversation reads it; the conversation's next turn takes the same card back; and a
/// card nobody came for leaves the Dynamic Island after `island` and the Lock Screen after
/// `lockScreen`, which is the platform's own ceiling for a card that has ended. claude-bridge keeps
/// the same two clocks for the pushes it sends while the phone is asleep.
public enum LiveActivityLinger {
    public static let island: TimeInterval = 60 * 60
    public static let lockScreen: TimeInterval = 4 * 60 * 60

    public static func islandEnds(settledAt: Date) -> Date {
        settledAt.addingTimeInterval(island)
    }

    public static func lockScreenEnds(settledAt: Date) -> Date {
        settledAt.addingTimeInterval(lockScreen)
    }
}

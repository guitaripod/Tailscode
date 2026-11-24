import CodingAgentKit
import Foundation

/// What a turn's card says beyond its line, the way a wall tile with room does: its latest steps,
/// the agent's own plan, what it last said, the files it changed, the last minute of its pulse,
/// who is answering and what it is waiting on the person for.
///
/// Facts cross the wire and the words are written on the phone, exactly as `LiveActivityDetail`
/// does it: a step is the tool's name and the few input fields its plain reading needs, never a
/// sentence, so a card claude-bridge pushed while the phone slept reads in the reader's language
/// and in the same words as the wall. claude-bridge builds the same shape by hand, which makes
/// every key here a wire contract: added, never renamed. Every field is optional, because a card
/// written before the brief existed — or by a server that never sends one — draws its line alone.
public struct LiveActivityBrief: Codable, Sendable, Hashable {
    /// The latest steps of the turn, oldest first, at most `LiveActivityStep.limit`.
    public var steps: [LiveActivityStep]?
    public var plan: LiveActivityPlan?
    /// What the agent said last in the turn, plain, at most `saidLimit` characters.
    public var said: String?
    /// How many files the turn changed, and the lines its finished edits added and removed.
    public var files: Int?
    public var added: Int?
    public var removed: Int?
    /// The last minute of the pulse as `AgentBeat.buckets` digits, oldest first, each
    /// `0...AgentBeat.ceiling`.
    public var beat: String?
    /// When the turn was last seen to move: a step, a word, a tool coming back.
    public var moved: Date?
    /// The model answering, as the id the server reported; the phone names it.
    public var model: String?
    /// The turn runs at ultracode, by the chat's effort or by the word.
    public var ultra: Bool?
    /// How full the context window is, `0...1`.
    public var fill: Double?
    /// What the turn is waiting on the person for: the whole command an approval would run, or
    /// the question, bounded to `askLimit`.
    public var ask: String?

    public init(
        steps: [LiveActivityStep]? = nil, plan: LiveActivityPlan? = nil, said: String? = nil,
        files: Int? = nil, added: Int? = nil, removed: Int? = nil, beat: String? = nil,
        moved: Date? = nil, model: String? = nil, ultra: Bool? = nil, fill: Double? = nil,
        ask: String? = nil
    ) {
        self.steps = steps
        self.plan = plan
        self.said = said
        self.files = files
        self.added = added
        self.removed = removed
        self.beat = beat
        self.moved = moved
        self.model = model
        self.ultra = ultra
        self.fill = fill
        self.ask = ask
    }

    public static let saidLimit = 160
    public static let askLimit = 280
    /// The most a brief may take once encoded. ActivityKit refuses a content state over 4 KB, and
    /// the rest of the card — its line, clocks, title and head — is given the remainder.
    public static let byteBudget = 2_400

    public var isEmpty: Bool { self == LiveActivityBrief() }

    /// The pulse as heights, oldest first; empty when the sender gave none that reads.
    public var beats: [Int] {
        guard let beat, beat.count == AgentBeat.buckets else { return [] }
        let heights = beat.compactMap(\.wholeNumberValue)
        guard heights.count == AgentBeat.buckets else { return [] }
        return heights.map { min(max($0, 0), AgentBeat.ceiling) }
    }

    /// "38 tools · edited 4 files +120 −35", or nil when the work has nothing to count yet.
    public func countsLine(toolCount: Int) -> String? {
        var parts: [String] = []
        if toolCount > 0 { parts.append(Localized.text("%lld tools", toolCount)) }
        if let files, files > 0 {
            var changed =
                files == 1
                ? Localized.text("edited 1 file") : Localized.text("edited %lld files", files)
            let counts = WallFile.counts(added: added ?? 0, removed: removed ?? 0)
            if !counts.isEmpty { changed += " " + counts }
            parts.append(changed)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The model's word, as every pill says it.
    public var modelWord: String? {
        guard let model, !model.isEmpty else { return nil }
        return ModelBadge.shortName(model)
    }

    /// The brief at most `budget` bytes once encoded, giving up first what the card can most
    /// easily do without: the agent's words, then the oldest steps, then each step's input, then
    /// the plan's next item, and the ask cut shorter last.
    public func fitted(budget: Int = LiveActivityBrief.byteBudget) -> LiveActivityBrief {
        var brief = self
        let shrinks: [(inout LiveActivityBrief) -> Bool] = [
            { brief in
                guard let said = brief.said, said.count > 60 else { return false }
                brief.said = Self.cut(said, to: 60)
                return true
            },
            { brief in
                guard brief.said != nil else { return false }
                brief.said = nil
                return true
            },
            { brief in
                guard let steps = brief.steps, steps.count > 2 else { return false }
                brief.steps = Array(steps.suffix(2))
                return true
            },
            { brief in
                guard let steps = brief.steps, steps.contains(where: { $0.input != nil }) else {
                    return false
                }
                brief.steps = steps.map { LiveActivityStep(id: $0.id, tool: $0.tool, state: $0.state) }
                return true
            },
            { brief in
                guard brief.plan?.next != nil else { return false }
                brief.plan?.next = nil
                return true
            },
            { brief in
                guard let ask = brief.ask, ask.count > 80 else { return false }
                brief.ask = Self.cut(ask, to: 80)
                return true
            },
            { brief in
                guard brief.steps != nil || brief.plan != nil else { return false }
                brief.steps = nil
                brief.plan = nil
                return true
            },
        ]
        for shrink in shrinks {
            guard brief.encodedSize > budget else { return brief }
            _ = shrink(&brief)
        }
        return brief.encodedSize > budget ? LiveActivityBrief(moved: moved) : brief
    }

    public var encodedSize: Int {
        (try? JSONEncoder().encode(self).count) ?? .max
    }

    static func cut(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(max(limit - 1, 1))).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// One step of a turn on a card: the tool's name and the input fields its plain reading needs.
public struct LiveActivityStep: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable {
        case running, done, failed, stopped
    }

    /// The call's id cut to its tail, enough to tell one step from the next across updates so a
    /// step that lands slides in rather than every row being redrawn.
    public var id: String
    public var tool: String
    /// The fields a plain reading uses — the command, the path, the pattern — each bounded.
    public var input: [String: String]?
    public var state: State

    public init(id: String, tool: String, input: [String: String]? = nil, state: State) {
        self.id = id
        self.tool = tool
        self.input = input
        self.state = state
    }

    public static let limit = 4
    /// The input fields a call's plain reading reads, and no other: an edit's old and new text,
    /// a write's content and a prompt's body never travel.
    public static let inputKeys: [String] = [
        "command", "description", "file_path", "path", "notebook_path", "pattern", "query", "url",
        "subject", "status", "subagent_type", "name", "skill", "question",
    ]
    public static let inputLimit = 160
    /// The fields that name a file, kept from their end when cut: the file's own name is what a
    /// plain reading says, and it is at the end of the path.
    public static let pathKeys: Set<String> = ["file_path", "path", "notebook_path"]
    static let idLimit = 12

    /// A call as a card carries it.
    public init(_ call: ToolCall) {
        id = String(call.id.suffix(Self.idLimit))
        tool = call.name
        var fields = Self.fields(of: call.input)
        if fields["name"] == nil, call.cachedKind == .workflow,
            let script = call.input?["script"]?.stringValue,
            let name = WorkflowMeta.scriptName(script)
        {
            fields["name"] = String(name.prefix(Self.inputLimit))
        }
        input = fields.isEmpty ? nil : fields
        switch call.status {
        case .pending, .running: state = .running
        case .completed: state = .done
        case .error: state = .failed
        case .stopped: state = .stopped
        }
    }

    /// The step in the words a wall's tile says it: "Running the tests", "Changed Backoff.swift".
    public var words: String {
        AgentPlain.words(for: call).text
    }

    public var isRunning: Bool { state == .running }

    /// The call rebuilt from what travelled, which reads exactly as the call it came from for
    /// every field a plain reading looks at.
    var call: ToolCall {
        let status: ToolStatus
        switch state {
        case .running: status = .running
        case .done: status = .completed
        case .failed: status = .error
        case .stopped: status = .stopped
        }
        let object = input.map { fields in JSONValue.object(fields.mapValues { JSONValue.string($0) }) }
        return ToolCall(id: id, name: tool, status: status, input: object)
    }

    static func fields(of input: JSONValue?) -> [String: String] {
        guard case .object(let object)? = input else { return [:] }
        var fields: [String: String] = [:]
        for key in inputKeys {
            guard case .string(let value)? = object[key] else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            fields[key] = pathKeys.contains(key)
                ? String(trimmed.suffix(inputLimit)) : String(trimmed.prefix(inputLimit))
        }
        return fields
    }
}

/// The agent's own to-do list on a card: how far through, the item in hand and the one after.
public struct LiveActivityPlan: Codable, Sendable, Hashable {
    public var done: Int
    public var total: Int
    public var current: String?
    public var next: String?

    public init(done: Int, total: Int, current: String? = nil, next: String? = nil) {
        self.done = done
        self.total = total
        self.current = current
        self.next = next
    }

    static let itemLimit = 90

    /// Nil for a board with nothing left on it, which is a plan no longer being worked through.
    public init?(_ plan: WallPlan) {
        guard plan.total > 0, plan.done < plan.total else { return nil }
        self.init(
            done: plan.done, total: plan.total,
            current: plan.current.map { LiveActivityBrief.cut($0, to: Self.itemLimit) },
            next: plan.next.first.map { LiveActivityBrief.cut($0, to: Self.itemLimit) })
    }

    public var fraction: Double { total > 0 ? min(max(Double(done) / Double(total), 0), 1) : 0 }

    /// "Plan · 4 of 7".
    public var headline: String {
        Localized.text("Plan") + " · " + Localized.text("%d of %d", done, total)
    }
}

extension LiveActivityBrief {
    /// The brief of a conversation this device is streaming, read from the latest turn — and from
    /// the plan, which reaches back at most `window` messages — so a token costs the turn and never
    /// the conversation. `stamps` are the moments this device saw it move.
    ///
    /// A running card carries no words, which only an ending shows; a settled one carries no pulse,
    /// plan or ask, which belong to a turn still going; and a card a server also pushes carries no
    /// context fill, which a server cannot know (`withFill`). Each is left out before the brief is
    /// fitted, so a card written here and one claude-bridge pushes give up the same parts.
    ///
    /// The plan and the context fill reach past the turn — the plan back up to `window` messages,
    /// the fill through the whole conversation when no server reported it — so they are the
    /// caller's to read, on its own schedule (`plan(in:)`, `fill(in:catalog:)`), and handed in.
    public static func read(
        _ state: ConversationState, stamps: [Date], now: Date, effort: String? = nil,
        settled: Bool = false, plan: LiveActivityPlan? = nil, fill: Double? = nil
    ) -> LiveActivityBrief {
        let calls = LiveActivityReading.turnCalls(in: state)
        let steps = calls.suffix(LiveActivityStep.limit).map(LiveActivityStep.init)
        let edits = AgentLine.edits(in: state)
        let added = edits.reduce(0) { $0 + $1.added }
        let removed = edits.reduce(0) { $0 + $1.removed }
        let assistant = state.messages.last { $0.role == .assistant }
        let ultra =
            Ultracode.turnInvoked(state) || (effort ?? assistant?.reasoningEffort) == Ultracode.effortLevel
        let brief = LiveActivityBrief(
            steps: steps.isEmpty ? nil : Array(steps),
            plan: settled ? nil : plan,
            said: settled ? AgentLine.said(in: state, limit: saidLimit) : nil,
            files: edits.isEmpty ? nil : edits.count, added: added > 0 ? added : nil,
            removed: removed > 0 ? removed : nil,
            beat: settled ? nil : beatDigits(stamps: stamps, now: now),
            moved: settled ? nil : stamps.max(), model: assistant?.modelID,
            ultra: ultra && !settled ? true : nil,
            fill: settled ? nil : fill.map { min(max($0, 0), 1) },
            ask: ask(in: state))
        return brief.fitted()
    }

    /// The agent's own plan, folded from the board calls in at most the last `window` messages.
    public static func plan(in state: ConversationState, window: Int = 400) -> LiveActivityPlan? {
        AgentLine.plan(in: state, window: window).flatMap(WallPlan.init(board:)).flatMap(LiveActivityPlan.init)
    }

    /// How full the context window is, `0...1`: the server's own figure where it reported one,
    /// counted from the whole transcript otherwise.
    public static func fill(in state: ConversationState, catalog: [ModelInfo]) -> Double? {
        ContextFill.read(messages: state.messages, catalog: catalog)?.fraction.map { min(max($0, 0), 1) }
    }

    /// The pulse as the digits a card carries, or nil when nothing moved in the last minute and
    /// nothing ever will be seen to: a flat line is said by the digits, an unknown one by nothing.
    public static func beatDigits(stamps: [Date], now: Date) -> String? {
        guard !stamps.isEmpty else { return nil }
        return AgentBeat.read(stamps: stamps, now: now).map(String.init).joined()
    }

    private static func ask(in state: ConversationState) -> String? {
        guard let ask = AgentAsk.reading(in: state), let object = ask.object, !object.isEmpty
        else { return nil }
        return cut(object, to: askLimit)
    }
}

/// The moments a conversation was seen to move, kept for its card's pulse: at most one a quarter
/// second, and none older than the pulse's minute, so a turn streaming tokens for an hour keeps a
/// few hundred stamps rather than every token it ever saw.
public struct LiveActivityPulse: Sendable, Equatable {
    public private(set) var stamps: [Date] = []
    public static let spacing: TimeInterval = 0.25

    public init() {}

    public mutating func note(_ now: Date) {
        if let last = stamps.last, now.timeIntervalSince(last) < Self.spacing, now >= last { return }
        stamps.append(now)
        stamps = AgentBeat.pruned(stamps, now: now)
    }

    public mutating func reset() { stamps = [] }
}

extension LiveActivityBrief {
    /// "+120 −35", only the side that moved, or nil when the turn's edits moved no line.
    public var linesChanged: String? {
        let counts = WallFile.counts(added: added ?? 0, removed: removed ?? 0)
        return counts.isEmpty ? nil : counts
    }
}

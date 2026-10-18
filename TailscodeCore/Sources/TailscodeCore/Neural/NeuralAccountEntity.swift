import CodingAgentKit
import Foundation

/// The entity's window: what the account says besides the story. A header with the vitals, the
/// person's prompt, the agent's own plan, what came of the turn, and the step in flight. Every
/// part is read from the transcript's own facts and omitted when it has nothing to say; nothing
/// is guessed.
extension NeuralAccount {
    /// The entity and how it is getting on. The words that depend on the clock are `vitals(now:)`,
    /// so the account itself stays the same between two ticks.
    public struct Header: Sendable, Equatable {
        public let speaker: String
        public let family: ModelTint.Family?
        /// The effort the turn ran at, as the model reported it; nil when it did not say.
        public let effort: String?
        /// The family hue and effort bars the head's eye wears.
        public let face: NeuralFace
        public let verdict: NeuralVerdict.Turn
        /// "Done", "Done, fixed 1 error", "Working", "Needs you", ...
        public let verdictWord: String
        /// The pill: "Done" for a turn that fixed errors too, and its quiet tone.
        public let pillWord: String
        /// The amber clause beside the pill: "fixed 1 error on the way"; nil when none.
        public let clause: String?
        /// The pill's tone (quiet for a done turn, whatever it fixed).
        public let tone: NeuralTone
        public let isRunning: Bool
        public let startedAt: Date?
        public let endedAt: Date?
        /// When the last step's message was written: where silence is counted from unless the
        /// client says it saw output since.
        public let lastStepAt: Date?
        public let stepCount: Int
        public let saidCount: Int
        public let thoughtCount: Int
        public let fixedCount: Int
        public let unfixedCount: Int
        /// "Fixed 1 error on the way"; nil when none.
        public let fixedWords: String?
        /// The plain title of the step in flight, while the turn runs.
        public let nowTitle: String?
    }

    /// The header's words for a moment: the status line, the time, the counts, the silence.
    public struct Vitals: Sendable, Equatable {
        /// "Finished, 6m 29s ago", "Working on: Ran the tests", "Waiting for you", "Stuck for 40s".
        public let statusLine: String
        /// The header's sentence: "in 6m 29s · fixed 1 error on the way" once settled, the status
        /// line while it runs.
        public let sentence: String
        /// "last output 4s ago", while the turn runs and something has been heard.
        public let lastOutputWords: String?
        public let elapsed: TimeInterval?
        /// "6m 29s".
        public let elapsedWords: String?
        /// "12 steps, 3 said, 1 fixed": the counts, short.
        public let counts: String
        /// How long nothing has arrived, while the turn runs.
        public let silentFor: TimeInterval?
        /// Nothing has arrived for `NeuralAccount.silentAfter`: the Now line says so in attention.
        public let isSilent: Bool
        /// "silent for 40 s"; nil unless silent.
        public let silentWords: String?
    }

    /// The person's prompt that started the turn.
    public struct Asked: Identifiable, Sendable, Equatable {
        public let id: String
        /// Whole.
        public let text: String
        /// The first two lines, which the quiet ink shows before "Show all".
        public let lines: [String]
        public let lineCount: Int
        public var hasMore: Bool { lineCount > lines.count }
    }

    public enum PlanState: Sendable, Equatable {
        case pending
        case inProgress
        case done
    }

    public struct PlanItem: Sendable, Equatable {
        public let text: String
        /// The present-tense wording the agent gave for while it runs.
        public let activeForm: String?
        public let state: PlanState
        /// The one in progress: flagged.
        public var isCurrent: Bool { state == .inProgress }
    }

    /// The agent's own task list, as its latest call to the task tool left it.
    public struct Plan: Sendable, Equatable {
        public let items: [PlanItem]
        /// The step that wrote this list, and its number.
        public let stepID: String
        public let number: Int

        public var done: Int { items.filter { $0.state == .done }.count }
        public var total: Int { items.count }
        /// "3 of 7 done".
        public var label: String { Localized.text("%1$lld of %2$lld done", done, total) }
        public var current: PlanItem? { items.first { $0.isCurrent } }
    }

    /// A build, a test run or a lint, by command, with how it ended.
    public struct Check: Sendable, Equatable {
        public let kind: NeuralHuman.CheckKind
        /// "Built the project", "Ran the tests".
        public let title: String
        /// The last run of the command: the step whose result stands.
        public let stepID: String
        public let number: Int
        /// The tool's own verdict on that last run: done, fixed, failed, running...
        public let verdict: NeuralVerdict.Step
        /// How many runs failed before it: "after 2 retries" is said when this is above zero and
        /// the command ended well.
        public let retries: Int
        public let stepIDs: [String]
        /// The command as the agent ran it.
        public let command: String
        /// One-based numbers of every run, which chips set the cursor to.
        public let numbers: [Int]

        /// "Build", "Tests", "Lint".
        public var label: String {
            switch kind {
            case .build: return Localized.text("Build")
            case .test: return Localized.text("Tests")
            case .lint: return Localized.text("Lint")
            }
        }

        /// "passed", "passed after 1 retry", "failed", "running": the tool's own word for it.
        public var verdictWords: String {
            switch verdict {
            case .done: return Localized.text("passed")
            case .fixed:
                return retries == 1
                    ? Localized.text("passed after 1 retry") : Localized.text("passed after %lld retries", retries)
            case .failed, .tryingAgain: return NeuralReading.statusWord(.failed)
            case .running: return NeuralReading.statusWord(.running)
            default: return verdict.word.lowercased()
            }
        }

        public var retriesWords: String? {
            guard retries > 0, verdict == .fixed || verdict == .done else { return nil }
            return retries == 1
                ? Localized.text("after 1 retry") : Localized.text("after %lld retries", retries)
        }
    }

    /// A step that stayed failed.
    public struct Unfixed: Sendable, Equatable {
        public let stepID: String
        public let number: Int
        public let title: String
        /// The first line of its output that names the error.
        public let firstLine: String
    }

    /// What came of a settled turn, from the transcript's own facts.
    public struct Result: Sendable, Equatable {
        public let changes: [Change]
        public let added: Int
        public let removed: Int
        public let tally: String?
        public let checks: [Check]
        public let unfixed: [Unfixed]
        /// The first line of the final message.
        public let answer: String?
        /// What to say where there is nothing changed: "It changed no files.", or "It only looked:
        /// read 4 files, changed nothing."; nil when files changed.
        public let changedWords: String?
        /// "It ended without an answer." for a turn that said nothing at its end; nil otherwise.
        public let answerWords: String?

        /// Nothing to report: a settled turn that changed nothing, ran no check, left nothing
        /// unfixed and gave no answer text.
        public var isEmpty: Bool {
            changes.isEmpty && checks.isEmpty && unfixed.isEmpty && answer == nil
        }

        /// The headings over the groups, in the order they are drawn.
        public static var headings: [String] {
            [NeuralReading.changedLabel, Localized.text("Checks"), Localized.text("Still failing"), NeuralReading.thenItAnswered]
        }
    }

    /// The step in flight.
    public struct LiveStep: Sendable, Equatable {
        public let stepID: String
        public let number: Int
        /// "Ran the tests".
        public let title: String
        public let rawTitle: String
        /// The command, path or pattern, on one line.
        public let argument: String
        public let verdict: NeuralVerdict.Step
        /// The last lines it printed, oldest first.
        public let tail: [NeuralReadout.OutputLine]
        /// The last line it printed.
        public var lastLine: String? { tail.last?.text }
    }

    /// How long nothing may arrive before the Now line says so.
    public static let silentAfter: TimeInterval = 40

    // MARK: Vitals

    /// The header's words at `now`. `lastActivity` is when the client last saw anything arrive;
    /// without it silence is counted from the last step's message.
    public func vitals(now: Date, lastActivity: Date? = nil) -> Vitals {
        let started = header.startedAt
        let elapsed: TimeInterval? =
            started.flatMap { start in
                let end = header.endedAt ?? (header.isRunning ? now : nil)
                return end.flatMap { $0 >= start ? $0.timeIntervalSince(start) : nil }
            }
        let counts = Self.countsWords(header)
        var silent: TimeInterval?
        if header.isRunning, let since = lastActivity ?? header.lastStepAt {
            silent = max(0, now.timeIntervalSince(since))
        }
        let isSilent = (silent ?? 0) >= Self.silentAfter
        let line: String
        switch header.verdict {
        case .working:
            line = header.nowTitle.map { Localized.text("Working on: %@", $0) }
                ?? NeuralReading.verdictWorking
        case .needsYou: line = NeuralReading.verdictWaiting
        case .stuck:
            line = Localized.text("Stuck for %@", NeuralReading.duration(silent ?? 0))
        case .done, .doneAfterRetries, .failed, .stopped, .didntAnswer:
            let word =
                header.verdict == .done || header.isFinishedWell
                ? Localized.text("Finished") : header.verdict.word
            if let ended = header.endedAt {
                line = Localized.text(
                    "%1$@, %2$@ ago", word,
                    NeuralReading.duration(max(0, now.timeIntervalSince(ended))))
            } else {
                line = word
            }
        }
        var sentence = line
        if !header.isRunning, header.verdict != .failed || elapsed != nil {
            let inTime = elapsed.map { Localized.text("in %@", NeuralReading.duration($0)) }
            sentence = [inTime, header.clause].compactMap { $0 }.joined(separator: " \u{00B7} ")
            if sentence.isEmpty { sentence = line }
        }
        return Vitals(
            statusLine: line, sentence: sentence,
            lastOutputWords: silent.map { Localized.text("last output %@ ago", NeuralReading.duration($0)) },
            elapsed: elapsed, elapsedWords: elapsed.map(NeuralReading.duration),
            counts: counts, silentFor: silent, isSilent: isSilent,
            silentWords: isSilent ? silent.map { Localized.text("silent for %@", NeuralReading.duration($0)) } : nil)
    }

    /// "3 said \u{00B7} 18 steps \u{00B7} 1 error fixed": the header's counts.
    static func countsWords(_ header: Header) -> String {
        var parts: [String] = []
        if header.saidCount > 0 { parts.append(Localized.text("%lld said", header.saidCount)) }
        parts.append(NeuralNoticeLine.countText(tools: 0, steps: header.stepCount))
        if header.fixedCount > 0 {
            parts.append(
                header.fixedCount == 1
                    ? Localized.text("1 error fixed") : Localized.text("%lld errors fixed", header.fixedCount))
        }
        return parts.dropFirst().reduce(parts[0]) { Localized.text("%1$@ · %2$@", $0, $1) }
    }

    // MARK: Building

    static func makeHeader(
        model: NeuralBrainModel, readings: NeuralVerdict.TurnReading, said: Int, thoughts: Int,
        speaker: String, family: ModelTint.Family?, titles: [NeuralHuman.Title]
    ) -> Header {
        let turn = model.turn
        let running = turn.outcome == .running
        var nowTitle: String?
        if running, let at = liveIndex(in: turn.steps) { nowTitle = titles[at].text }
        return Header(
            speaker: speaker, family: family, effort: turn.effort, face: model.face,
            verdict: readings.verdict, verdictWord: readings.verdict.word,
            pillWord: readings.verdict.pillWord,
            clause: readings.fixed > 0 ? NeuralReading.fixedOnTheWayClause(readings.fixed) : nil,
            tone: readings.verdict.pillTone, isRunning: running, startedAt: turn.startedAt,
            endedAt: turn.endedAt, lastStepAt: turn.steps.last?.at, stepCount: turn.steps.count,
            saidCount: said, thoughtCount: thoughts, fixedCount: readings.fixed,
            unfixedCount: readings.unfixed, fixedWords: readings.onTheWay, nowTitle: nowTitle)
    }

    /// The step in flight: the last one running or waiting, else the last step.
    static func liveIndex(in steps: [NeuralStep]) -> Int? {
        steps.lastIndex {
            switch $0.status {
            case .running, .waitingApproval, .waitingAnswer, .stalled: return true
            case .ok, .failed, .stopped: return false
            }
        } ?? (steps.isEmpty ? nil : steps.count - 1)
    }

    static func makeLive(
        model: NeuralBrainModel, readings: NeuralVerdict.TurnReading, titles: [NeuralHuman.Title]
    ) -> LiveStep? {
        guard model.turn.outcome == .running, let at = liveIndex(in: model.steps) else { return nil }
        let step = model.steps[at]
        let subject = NeuralReadoutBuilder.subject(of: step, title: titles[at].text)
        let tail = NeuralReading.isTool(step) ? NeuralReadoutBuilder.tail(of: step).lines : []
        return LiveStep(
            stepID: step.id, number: at + 1, title: titles[at].text, rawTitle: titles[at].raw,
            argument: NeuralReadoutText.oneLine(subject.primary, limit: 160),
            verdict: readings.steps[at].verdict, tail: tail)
    }

    static func makeAsked(turn: NeuralTurn, prompt: String?) -> Asked? {
        guard let prompt else { return nil }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Asked(
            id: "asked:" + turn.id, text: text, lines: NeuralReadoutText.firstLines(text, 2),
            lineCount: max(NeuralReadoutText.rawLineCount(text), 1))
    }

    /// The files the steps at `indices` changed, merged by path in order of first change, with the
    /// lines added and removed and the numbers of the steps that did it.
    static func changes(in indices: [Int], steps: [NeuralStep]) -> [Change] {
        var order: [String] = []
        var changed: [String: (id: String, added: Int, removed: Int, numbers: [Int])] = [:]
        for index in indices {
            let step = steps[index]
            guard step.zone == .act, step.status == .ok,
                let path = step.tieKey ?? (step.detail.isEmpty ? nil : step.detail)
            else { continue }
            var entry = changed[path] ?? (step.id, 0, 0, [])
            if changed[path] == nil { order.append(path) }
            entry.added += step.added ?? 0
            entry.removed += step.removed ?? 0
            entry.numbers.append(index + 1)
            changed[path] = entry
        }
        return order.compactMap { path -> Change? in
            guard let entry = changed[path] else { return nil }
            let parts = NeuralReadoutText.split(path: path)
            return Change(
                stepID: entry.id, path: path, directory: parts.directory, fileName: parts.file,
                shortDirectory: NeuralReadoutText.shortDirectory(parts.directory),
                added: entry.added, removed: entry.removed,
                tally: NeuralReading.tally(entry.added, entry.removed), numbers: entry.numbers)
        }
    }

    // MARK: Plan

    /// The agent's task list: the latest snapshot a task tool wrote, folded with the incremental
    /// create and update calls after it. Tolerant of the shapes the tools use: `todos`, `plan`
    /// or `tasks` arrays whose items carry `content`, `subject`, `step`, `title` or `text` and a
    /// `status` of pending, in progress or completed in any of their spellings.
    static func makePlan(steps: [NeuralStep]) -> Plan? {
        var items: [PlanItem] = []
        var source: (id: String, number: Int)?
        var ids: [String] = []
        for (index, step) in steps.enumerated() {
            guard let call = step.call?.call, let input = call.input else { continue }
            let name = call.name.lowercased()
            guard call.summaryKind == .taskTracking || planTools.contains(name) else { continue }
            if name == "taskcreate" {
                guard let subject = input["subject"]?.stringValue, !subject.isEmpty else { continue }
                items.append(
                    PlanItem(text: subject, activeForm: input["activeForm"]?.stringValue, state: .pending))
                ids.append(call.output.flatMap(TaskBoard.createdID) ?? String(items.count))
                source = (step.id, index + 1)
            } else if name == "taskupdate" {
                guard let target = identifier(input["taskId"]), let at = ids.firstIndex(of: target)
                else { continue }
                if input["status"]?.stringValue == "deleted" {
                    items.remove(at: at)
                    ids.remove(at: at)
                } else {
                    let old = items[at]
                    items[at] = PlanItem(
                        text: input["subject"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? old.text,
                        activeForm: input["activeForm"]?.stringValue ?? old.activeForm,
                        state: planState(input["status"]?.stringValue) ?? old.state)
                }
                source = (step.id, index + 1)
            } else if let list = snapshot(input) {
                items = list
                ids = list.indices.map(String.init)
                source = (step.id, index + 1)
            }
        }
        guard let source, !items.isEmpty else { return nil }
        return Plan(items: items, stepID: source.id, number: source.number)
    }

    private static let planTools: Set<String> = ["update_plan", "updateplan", "plan", "set_plan", "todo_write"]

    private static func identifier(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let text)?: return text
        case .integer(let number)?: return String(number)
        default: return nil
        }
    }

    private static func snapshot(_ input: JSONValue) -> [PlanItem]? {
        for key in ["todos", "plan", "tasks", "items"] {
            guard case .array(let list)? = input[key] else { continue }
            let items = list.compactMap { entry -> PlanItem? in
                let words = ["content", "subject", "step", "title", "text", "activeForm"]
                    .lazy.compactMap { entry[$0]?.stringValue }.first { !$0.isEmpty }
                guard let words else { return nil }
                return PlanItem(
                    text: words, activeForm: entry["activeForm"]?.stringValue,
                    state: planState(entry["status"]?.stringValue) ?? .pending)
            }
            return items
        }
        return nil
    }

    private static func planState(_ raw: String?) -> PlanState? {
        guard let raw else { return nil }
        switch raw.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_") {
        case "pending", "todo", "not_started", "open", "queued": return .pending
        case "in_progress", "inprogress", "active", "doing", "started", "running": return .inProgress
        case "completed", "complete", "done", "finished", "resolved": return .done
        default: return nil
        }
    }

    // MARK: Result

    static func makeResult(
        steps: [NeuralStep], readings: NeuralVerdict.TurnReading, titles: [NeuralHuman.Title],
        answer: String?, outcome: NeuralOutcome = .settled
    ) -> Result {
        let changes = changes(in: Array(steps.indices), steps: steps)
        let added = changes.reduce(0) { $0 + $1.added }
        let removed = changes.reduce(0) { $0 + $1.removed }

        var chains: [String: [Int]] = [:]
        var chainOrder: [String] = []
        for (index, step) in steps.enumerated() where step.tieIsCommand {
            let command = step.call.flatMap { $0.call.input?["command"]?.stringValue } ?? step.detail
            guard let key = step.tieKey, NeuralHuman.classify(command).checkKind != nil else { continue }
            if chains[key] == nil { chainOrder.append(key) }
            chains[key, default: []].append(index)
        }
        let checks = chainOrder.compactMap { key -> Check? in
            guard let chain = chains[key], let last = chain.last else { return nil }
            let command = steps[last].call.flatMap { $0.call.input?["command"]?.stringValue } ?? steps[last].detail
            guard let kind = NeuralHuman.classify(command).checkKind else { return nil }
            let failedBefore = chain.dropLast().filter { steps[$0].status == .failed }.count
            var verdict = readings.steps[last].verdict
            if verdict == .done, failedBefore > 0 { verdict = .fixed }
            return Check(
                kind: kind, title: kind.title, stepID: steps[last].id, number: last + 1,
                verdict: verdict, retries: failedBefore, stepIDs: chain.map { steps[$0].id },
                command: command, numbers: chain.map { $0 + 1 })
        }

        let unfixed = steps.enumerated().compactMap { index, step -> Unfixed? in
            guard readings.steps[index].verdict == .failed else { return nil }
            return Unfixed(
                stepID: step.id, number: index + 1, title: titles[index].text,
                firstLine: NeuralReadoutBuilder.errorLine(of: step))
        }
        let first = answer.map { NeuralReadoutText.firstLine($0) }.flatMap {
            $0.isEmpty ? nil : NeuralReadoutText.capped($0, limit: 200).text
        }
        var changedWords: String?
        if changes.isEmpty {
            let reads = steps.filter { $0.call?.call.summaryKind == .fileRead }.count
            let onlyLooked = !steps.isEmpty && steps.allSatisfy { $0.zone == .sense || $0.zone == .think || $0.zone == .say }
            changedWords = onlyLooked && reads > 0
                ? (reads == 1
                    ? Localized.text("It only looked: read 1 file, changed nothing.")
                    : Localized.text("It only looked: read %lld files, changed nothing.", reads))
                : Localized.text("It changed no files.")
        }
        return Result(
            changes: changes, added: added, removed: removed,
            tally: NeuralReading.tally(added, removed), checks: checks, unfixed: unfixed, answer: first,
            changedWords: changedWords,
            answerWords: outcome == .answerless ? Localized.text("It ended without an answer.") : nil)
    }
}

extension NeuralAccount.Header {
    /// Done, or done after fixing errors: a turn that got there.
    var isFinishedWell: Bool {
        if case .doneAfterRetries = verdict { return true }
        return false
    }
}

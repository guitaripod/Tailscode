import CodingAgentKit
import Foundation

/// Reads one brain into the readout's content. A value of a turn's steps and the few facts a
/// readout needs from the model; it reaches into a step's call only for the text it must show, and
/// only the first or last lines of it.
struct NeuralReadoutBuilder {
    typealias R = NeuralReadout

    let model: NeuralBrainModel
    let steps: [NeuralStep]
    let now: Date
    let tz: TimeZone
    let answer: String?
    let outputShown: Int

    init(
        model: NeuralBrainModel, now: Date, tz: TimeZone, answer: String?,
        outputShown: Int = NeuralReadout.outputShown
    ) {
        self.outputShown = outputShown
        self.model = model
        steps = model.steps
        self.now = now
        self.tz = tz
        self.answer = answer
    }

    func step(at index: Int) -> R.Step {
        let step = steps[index]
        return R.Step(
            stepID: step.id, header: header(at: index), subject: Self.subject(of: step),
            relations: relations(at: index), why: why(at: index),
            result: Self.result(for: step, shown: outputShown), facts: facts(of: step),
            gathered: model.ganglionMembers[step.id] ?? [])
    }

    func header(at index: Int) -> R.Header {
        let step = steps[index]
        return R.Header(
            zone: step.zone, label: step.zone.label, chip: Self.chip(for: step),
            counter: NeuralReading.counter(index + 1, of: steps.count), number: index + 1,
            total: steps.count, isPinned: model.pinnedStep == step.id, mark: step.mark)
    }

    static func chip(for step: NeuralStep) -> R.Chip {
        let kind = chipKind(of: step)
        return R.Chip(kind: kind, word: NeuralReading.chipWord(kind), tone: tone(of: kind))
    }

    static func chipKind(of step: NeuralStep) -> R.ChipKind {
        switch step.status {
        case .ok: return .done
        case .failed: return step.recovered ? .retried : .failed
        case .running: return .running
        case .stopped: return .stopped
        case .waitingApproval, .waitingAnswer: return .waiting
        case .stalled: return .stalled
        }
    }

    static func tone(of kind: R.ChipKind) -> NeuralTone {
        switch kind {
        case .done, .running: return .live
        case .failed: return .danger
        case .waiting, .stalled: return .attention
        case .stopped, .retried: return .quiet
        }
    }

    static func tone(of step: NeuralStep) -> NeuralTone { tone(of: chipKind(of: step)) }

    func facts(of step: NeuralStep) -> R.Facts {
        let clock = step.at.map { NeuralReading.clock($0, timeZone: tz) }
        let began = (model.turn.startedAt ?? steps.compactMap(\.at).min()).map {
            NeuralReading.turnBegan(NeuralReading.clock($0, timeZone: tz))
        }
        return R.Facts(
            message: NeuralReading.messageFact(of: step, in: steps), clock: clock,
            started: clock.map(NeuralReading.started), turnBegan: began)
    }

    private func input(_ call: ToolCall?, _ keys: String...) -> String? {
        Self.field(call, keys)
    }

    private static func field(_ call: ToolCall?, _ keys: [String]) -> String? {
        guard let input = call?.input else { return nil }
        for key in keys {
            if let value = input[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    private static func path(of call: ToolCall?) -> String? {
        field(call, ["file_path", "filePath", "path", "notebook_path"])
    }

    static func subjectKind(of step: NeuralStep) -> R.Subject.Kind {
        if NeuralReading.isThought(step) { return .thought }
        if NeuralReading.isNote(step) { return .note }
        if let call = step.call?.call {
            switch call.summaryKind {
            case .shell: return .command
            case .fileRead, .fileEdit, .fileWrite: return .path
            case .fileSearch, .webSearch: return .pattern
            case .webFetch: return .url
            case .subagent, .workflow, .skill: return .agent
            case .taskTracking, .question, .other: return .other
            }
        }
        switch step.zone {
        case .shell: return .command
        case .act: return .path
        case .delegate: return .agent
        case .sense:
            let title = step.title.lowercased()
            if title.contains("fetch") { return .url }
            return title == "read" ? .path : .pattern
        case .think, .say: return .other
        }
    }

    static func subject(of step: NeuralStep) -> R.Subject {
        let title = NeuralReading.title(of: step)
        let kind = subjectKind(of: step)
        let call = step.call?.call
        var primary = ""
        var secondary: String?
        switch kind {
        case .thought, .note:
            primary = NeuralReadoutText.capped(
                NeuralReadoutText.firstLine(step.text), limit: R.argumentLimit
            ).text
        case .command:
            primary = field(call, ["command"]) ?? step.detail
            let described = field(call, ["description"])
            if described != primary { secondary = described }
        case .path:
            primary = path(of: call) ?? step.detail
        case .pattern:
            primary = field(call, ["pattern", "query"]) ?? path(of: call) ?? step.detail
            if field(call, ["pattern", "query"]) != nil { secondary = field(call, ["path"]) }
        case .url:
            primary = field(call, ["url"]) ?? step.detail
        case .agent:
            primary = field(call, ["description", "prompt", "name", "skill"]) ?? step.detail
            let type = field(call, ["subagent_type"])
            if let type, type != "general-purpose" {
                secondary = type
            } else {
                secondary = field(call, ["args"])
            }
        case .other:
            primary = step.detail
        }
        primary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        var directory: String?
        var fileName: String?
        if kind == .path {
            let parts = NeuralReadoutText.split(path: primary)
            directory = parts.directory
            fileName = parts.file
        }
        let copyable: Bool
        switch kind {
        case .command, .path, .url, .pattern: copyable = !primary.isEmpty
        case .agent, .thought, .note, .other: copyable = false
        }
        return R.Subject(
            kind: kind, title: title, primary: primary, secondary: secondary, directory: directory,
            fileName: fileName,
            lineCount: kind == .thought || kind == .note
                ? 1 : max(NeuralReadoutText.rawLineCount(primary), primary.isEmpty ? 0 : 1),
            collapsedLines: kind == .path ? 1 : R.commandLines, copyText: copyable ? primary : nil)
    }

    /// The narration that came immediately before the call: walking back, the calls made in the
    /// same message are passed over, because parallel calls share one reason; the first thought or
    /// note with words is the reason; a call of another message stops the search with nothing.
    func why(at index: Int) -> R.Why? {
        let step = steps[index]
        guard NeuralReading.isTool(step) else { return nil }
        var cursor = index - 1
        while cursor >= 0 {
            let earlier = steps[cursor]
            if NeuralReading.isThought(earlier) || NeuralReading.isNote(earlier) {
                let cut = NeuralReadoutText.capped(earlier.text, limit: R.whyLimit)
                return R.Why(
                    label: NeuralReading.whyLabel, text: cut.text, full: earlier.text,
                    isTruncated: cut.isCut, sourceStepID: earlier.id)
            }
            if earlier.group != step.group { return nil }
            cursor -= 1
        }
        return nil
    }

    static func result(for step: NeuralStep, shown: Int = R.outputShown) -> R.Result? {
        if NeuralReading.isThought(step) || NeuralReading.isNote(step) {
            return .text(
                R.Text(
                    text: step.text, lineCount: max(NeuralReadoutText.rawLineCount(step.text), 1)))
        }
        let hasOutput = hasOutput(step)
        if step.status == .failed && hasOutput { return .shell(output(of: step, shown: shown)) }
        switch subjectKind(of: step) {
        case .command, .url, .other:
            return hasOutput ? .shell(output(of: step, shown: shown)) : nil
        case .path:
            if step.zone == .act {
                let edit = edit(of: step)
                if !edit.lines.isEmpty || edit.tally != nil { return .edit(edit) }
                return hasOutput ? .shell(output(of: step, shown: shown)) : nil
            }
            return .read(read(of: step))
        case .pattern:
            return hasOutput ? .search(search(of: step)) : nil
        case .agent:
            return hasOutput ? .subagent(subagent(of: step)) : nil
        case .thought, .note:
            return nil
        }
    }

    private static func hasOutput(_ step: NeuralStep) -> Bool {
        if let output = step.call?.call.output, !output.isEmpty { return true }
        return !step.outputLines.isEmpty
    }

    private static func totalLines(of step: NeuralStep) -> Int {
        if let output = step.call?.call.output, !output.isEmpty {
            return NeuralReadoutText.lineCount(output)
        }
        return step.outputLines.count
    }

    static func output(of step: NeuralStep, shown: Int = R.outputShown) -> R.Output {
        let lines = outputLines(of: step, limit: shown)
        let total = max(totalLines(of: step), lines.count)
        return R.Output(
            lines: lines, total: total,
            moreLabel: total > lines.count ? NeuralReading.moreLines(total - lines.count) : nil)
    }

    static func outputLines(of step: NeuralStep, limit: Int) -> [R.OutputLine] {
        let texts: [String]
        if let output = step.call?.call.output, !output.isEmpty {
            texts = NeuralReadoutText.firstLines(output, limit)
        } else {
            texts = Array(step.outputLines.prefix(limit))
        }
        return outputLines(texts, failed: step.status == .failed)
    }

    private static func outputLines(_ texts: [String], failed: Bool) -> [R.OutputLine] {
        texts.map { text in
            R.OutputLine(
                text: text,
                tone: NeuralReadoutText.isErrorLine(text) ? .emphasis : failed ? .danger : .dim)
        }
    }

    static func tail(of step: NeuralStep) -> R.Tail {
        if let output = step.call?.call.output, !output.isEmpty {
            return R.Tail(
                lines: outputLines(
                    NeuralReadoutText.lastLines(output, R.tailShown), failed: step.status == .failed),
                total: NeuralReadoutText.lineCount(output))
        }
        let lines = Array(step.outputLines.suffix(R.tailShown))
        return R.Tail(
            lines: outputLines(lines, failed: step.status == .failed), total: step.outputLines.count)
    }

    private static func edit(of step: NeuralStep) -> R.Edit {
        let path = path(of: step.call?.call) ?? step.tieKey ?? step.detail
        let parts = NeuralReadoutText.split(path: path)
        let built = diffLines(of: step, limit: R.diffShown)
        let added = step.added ?? built.added
        let removed = step.removed ?? built.removed
        return R.Edit(
            path: path, directory: parts.directory, fileName: parts.file, added: added,
            removed: removed, tally: NeuralReading.tally(added, removed), lines: built.lines,
            total: built.total,
            moreLabel: built.total > built.lines.count
                ? NeuralReading.moreLines(built.total - built.lines.count) : nil)
    }

    /// The lines of an edit's old and new strings, the removed ones first, taken from the call's
    /// own input the way `ToolDiff` reads it. With a `limit` the two sides share it so a long
    /// removal never hides what replaced it.
    static func diffLines(
        of step: NeuralStep, limit: Int
    ) -> (lines: [R.DiffLine], total: Int, added: Int, removed: Int) {
        guard let input = step.call?.call.input?.objectValue else { return ([], 0, 0, 0) }
        let old = input["old_string"]?.stringValue
        var new = input["new_string"]?.stringValue
        if old == nil, new == nil { new = input["content"]?.stringValue }
        let removed = old.map(NeuralReadoutText.rawLineCount) ?? 0
        let added = new.map(NeuralReadoutText.rawLineCount) ?? 0
        let total = removed + added
        var removedShown = removed
        var addedShown = added
        if total > limit {
            let half = limit / 2
            removedShown = min(removed, max(half, limit - min(added, half)))
            addedShown = min(added, limit - removedShown)
        }
        var lines: [R.DiffLine] = []
        if let old, removedShown > 0 {
            lines += NeuralReadoutText.firstLines(old, removedShown, keepBlank: true).map {
                R.DiffLine(kind: .remove, text: $0)
            }
        }
        if let new, addedShown > 0 {
            lines += NeuralReadoutText.firstLines(new, addedShown, keepBlank: true).map {
                R.DiffLine(kind: .add, text: $0)
            }
        }
        return (lines, total, added, removed)
    }

    private static func read(of step: NeuralStep) -> R.Read {
        let path = path(of: step.call?.call) ?? step.tieKey ?? step.detail
        let parts = NeuralReadoutText.split(path: path)
        var lines: Int?
        if step.status == .ok, hasOutput(step) {
            lines = totalLines(of: step)
        }
        return R.Read(path: path, directory: parts.directory, fileName: parts.file, lines: lines)
    }

    private static func search(of step: NeuralStep) -> R.Search {
        let subject = subject(of: step)
        let matches: [String]
        let total: Int
        if let output = step.call?.call.output, !output.isEmpty {
            matches = NeuralReadoutText.firstLines(output, R.matchesShown)
            total = NeuralReadoutText.lineCount(output)
        } else {
            matches = Array(step.outputLines.prefix(R.matchesShown))
            total = step.outputLines.count
        }
        return R.Search(
            pattern: subject.primary, scope: subject.secondary, matches: matches,
            total: max(total, matches.count),
            moreLabel: total > matches.count
                ? NeuralReading.moreLines(total - matches.count) : nil)
    }

    private static func subagent(of step: NeuralStep) -> R.Subagent {
        let summary: [String]
        let total: Int
        if let output = step.call?.call.output, !output.isEmpty {
            summary = NeuralReadoutText.firstLines(output, R.summaryShown)
            total = NeuralReadoutText.lineCount(output)
        } else {
            summary = Array(step.outputLines.prefix(R.summaryShown))
            total = step.outputLines.count
        }
        return R.Subagent(
            summary: summary, total: max(total, summary.count), canOpen: step.isCard,
            openLabel: NeuralReading.openAgentLabel)
    }

    func relations(at index: Int) -> [R.Relation] {
        let step = steps[index]
        var retriedID: String?
        if step.status == .failed, step.recovered, step.tieIsCommand, let key = step.tieKey {
            retriedID = steps[(index + 1)...].first {
                $0.tieIsCommand && $0.tieKey == key && $0.status == .ok
            }?.id
        }
        var out: [R.Relation] = []
        if let key = step.tieKey {
            let others = steps.filter {
                $0.id != step.id && $0.tieKey == key && $0.tieIsCommand == step.tieIsCommand
                    && $0.id != retriedID
            }
            if !others.isEmpty {
                let numbers = others.map { $0.index + 1 }
                out.append(
                    R.Relation(
                        kind: step.tieIsCommand ? .sameCommand : .sameFile,
                        label: step.tieIsCommand
                            ? NeuralReading.sameCommand(numbers) : NeuralReading.sameFile(numbers),
                        stepIDs: others.map(\.id), numbers: numbers))
            }
        }
        if let retriedID, let later = model.indexOf(retriedID) {
            out.append(
                R.Relation(
                    kind: .retriedAt, label: NeuralReading.retriedAt(later + 1),
                    stepIDs: [retriedID], numbers: [later + 1]))
        }
        return out
    }

    func digest() -> R.Digest {
        let headline = NeuralReading.headline(for: model.turn, now: now)
        var counts = [Int](repeating: 0, count: NeuralZone.allCases.count)
        for step in steps { counts[step.zone.rawValue] += 1 }
        let busiest = max(counts.max() ?? 0, 1)
        let bars = NeuralZone.allCases.compactMap { zone -> R.ZoneBar? in
            let count = counts[zone.rawValue]
            guard count > 0 else { return nil }
            return R.ZoneBar(
                zone: zone, label: zone.displayLabel, count: count, fraction: Double(count) / Double(busiest))
        }
        let firstAnswerLine = answer.map { NeuralReadoutText.firstLine($0) }.flatMap {
            $0.isEmpty ? nil : NeuralReadoutText.capped($0, limit: 200).text
        }
        let hasAnswer = !model.turn.answerPartIDs.isEmpty || firstAnswerLine != nil
        return R.Digest(
            headline: headline, zoneBars: bars, ticks: ticks(hasAnswer: hasAnswer),
            answerBegins: hasAnswer ? steps.count : nil, failures: failures(), changed: changed(),
            answer: firstAnswerLine)
    }

    func soFar() -> R.SoFar {
        R.SoFar(
            headline: NeuralReading.headline(for: model.turn, now: now),
            chips: NeuralBrainCard.makeChips(steps))
    }

    private func ticks(hasAnswer: Bool) -> [R.Tick] {
        steps.enumerated().map { index, step in
            R.Tick(
                index: index, stepID: step.id, zone: step.zone, status: step.status,
                isFailure: step.status == .failed, isRecovered: step.recovered,
                answerFollows: hasAnswer && index == steps.count - 1)
        }
    }

    private func changed() -> [R.Changed] {
        var order: [String] = []
        var found: [String: (ids: [String], added: Int, removed: Int)] = [:]
        for step in steps where step.zone == .act && step.status == .ok {
            guard let path = step.tieKey ?? (step.detail.isEmpty ? nil : step.detail) else {
                continue
            }
            var entry = found[path] ?? ([], 0, 0)
            if entry.ids.isEmpty { order.append(path) }
            entry.ids.append(step.id)
            entry.added += step.added ?? 0
            entry.removed += step.removed ?? 0
            found[path] = entry
        }
        return order.compactMap { path in
            guard let entry = found[path], let first = entry.ids.first else { return nil }
            let parts = NeuralReadoutText.split(path: path)
            return R.Changed(
                stepID: first, stepIDs: entry.ids, path: path, directory: parts.directory,
                fileName: parts.file, shortDirectory: NeuralReadoutText.shortDirectory(parts.directory),
                added: entry.added, removed: entry.removed,
                tally: NeuralReading.tally(entry.added, entry.removed))
        }
    }

    private func failures() -> [R.Failure] {
        steps.enumerated().compactMap { index, step in
            guard step.status == .failed else { return nil }
            var retried: (id: String, number: Int)?
            if step.recovered, step.tieIsCommand, let key = step.tieKey {
                if let later = steps[(index + 1)...].first(where: {
                    $0.tieIsCommand && $0.tieKey == key && $0.status == .ok
                }) {
                    retried = (later.id, later.index + 1)
                }
            }
            return R.Failure(
                stepID: step.id, number: index + 1, title: NeuralReading.title(of: step),
                firstLine: Self.errorLine(of: step), retriedAt: retried?.id,
                retriedNumber: retried?.number,
                label: retried.map { NeuralReading.retriedAt($0.number) }
                    ?? NeuralReading.neverRetried)
        }
    }

    /// The first line of a failed step's output that says what went wrong, or its first line.
    static func errorLine(of step: NeuralStep) -> String {
        let lines: [String]
        if let output = step.call?.call.output, !output.isEmpty {
            lines = NeuralReadoutText.firstLines(output, 40)
        } else {
            lines = step.outputLines
        }
        return lines.first(where: NeuralReadoutText.isErrorLine) ?? lines.first ?? ""
    }

    func now(tone: NeuralTone) -> R.Now {
        let current = steps.lastIndex {
            switch $0.status {
            case .running, .waitingApproval, .waitingAnswer, .stalled: return true
            case .ok, .failed, .stopped: return false
            }
        } ?? (steps.isEmpty ? nil : steps.count - 1)
        let tail: R.Tail
        if let current, NeuralReading.isTool(steps[current]) {
            tail = Self.tail(of: steps[current])
        } else {
            tail = R.Tail(lines: [], total: 0)
        }
        return R.Now(
            label: NeuralReading.nowLabel, tone: tone == .identity ? .live : tone,
            step: current.map(step(at:)), tail: tail, soFar: soFar())
    }

    func ask(at index: Int) -> R.Ask? {
        let step = steps[index]
        guard step.status == .waitingApproval || step.status == .waitingAnswer else { return nil }
        let approval = step.status == .waitingApproval
        return R.Ask(
            step: self.step(at: index), sentence: NeuralReading.ask(for: step.status),
            actionLabel: approval ? NeuralReading.goToApprovalLabel : NeuralReading.goToQuestionLabel,
            isApproval: approval, tone: .attention)
    }

    func row(at index: Int) -> R.ZoneRow {
        let step = steps[index]
        let words = NeuralReading.isThought(step) || NeuralReading.isNote(step) ? step.text : step.detail
        return R.ZoneRow(
            number: index + 1, stepID: step.id, title: NeuralReading.title(of: step),
            argument: NeuralReadoutText.oneLine(words, limit: R.argumentLimit), status: step.status,
            tone: Self.tone(of: step))
    }

    func zone(_ zone: NeuralZone) -> R.ZoneList {
        R.ZoneList(
            zone: zone, label: zone.displayLabel,
            rows: steps.indices.filter { steps[$0].zone == zone }.map(row(at:)))
    }

    func replay(clock: Double) -> R.Replay {
        let timeline = model.timeline
        let time = model.replayTime(now: clock) ?? timeline.duration
        let active = timeline.activeStep(at: time)
        var log: [R.ZoneRow] = []
        var hidden = 0
        if let active {
            let earlier = Array((0..<active).reversed())
            log = earlier.prefix(R.replayLogLimit).map(row(at:))
            hidden = max(0, earlier.count - R.replayLogLimit)
        }
        return R.Replay(
            current: active.map(step(at:)), log: log, hiddenBefore: hidden,
            fraction: timeline.fraction(forTime: time))
    }
}

import CodingAgentKit
import Foundation

/// How loud a line about an expert is, which each client turns into its own colour.
public enum ExpertTone: String, Sendable, Hashable {
    /// Plain secondary text.
    case quiet
    /// Something is moving: a task running, a device held by a task, a guard checking.
    case active
    /// It wants the person: notes to review, a locked device.
    case attention
    /// Something broke: a failing guard, a debrief that could not be written.
    case failing
    /// All is well and worth saying so: guards passing, a device ready.
    case good
}

/// One line with its tone.
public struct ExpertLine: Sendable, Hashable {
    public let text: String
    public let tone: ExpertTone

    public init(_ text: String, _ tone: ExpertTone = .quiet) {
        self.text = text
        self.tone = tone
    }
}

/// A row a client draws as it is: a title, the line under it, and the few words at its trailing edge.
public struct ExpertRowReading: Sendable, Hashable {
    public let title: String
    public let detail: ExpertLine
    public let trailing: String?
    /// A small tag beside the title, such as a note that has not been confirmed for a while.
    public let tag: ExpertLine?

    public init(title: String, detail: ExpertLine, trailing: String? = nil, tag: ExpertLine? = nil) {
        self.title = title
        self.detail = detail
        self.trailing = trailing
        self.tag = tag
    }

    public var accessibilityLabel: String {
        [title, tag?.text, detail.text, trailing].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Every reading of an expert a client shows, written once.
public enum ExpertReading {
    // MARK: The shelf

    /// The one state line a shelf row says, in order of what matters most: a task running, notes
    /// waiting, a guard failing, a debrief being written, guards checking, then at rest. Only the
    /// last says it is idle: a row that wants the person leads with what it wants.
    public static func state(_ expert: MachineExpert, calendar: Calendar = .current, now: Date = Date()) -> ExpertLine {
        if let task = expert.task {
            return ExpertLine(
                Localized.text("Working on “%@” · %@", task.title, SessionRowModel.age(of: task.updatedAt, asOf: now)),
                .active)
        }
        if expert.pending > 0 {
            return ExpertLine(ExpertWords.toReview(expert.pending), .attention)
        }
        if let failing = expert.failingGuards.first {
            var text = Localized.text("Guard failing · %@", failing.name)
            if let since = failing.failingSince {
                text += " · " + Localized.text(
                    "since %@", ScheduleWords.lowered(ScheduleWords.moment(since, calendar: calendar, now: now)))
            }
            return ExpertLine(text, .failing)
        }
        if expert.tasks.contains(where: { $0.debrief == .drafting }) {
            return ExpertLine(ExpertWords.debriefDrafting, .active)
        }
        if expert.runningGuards { return ExpertLine(ExpertWords.checking, .active) }
        var parts = [Localized.text("Idle")]
        if expert.notebook.notes > 0 { parts.append(ExpertWords.notes(expert.notebook.notes)) }
        if !expert.guards.isEmpty, expert.guards.allSatisfy({ $0.last?.passed == true }) {
            parts.append(Localized.text("guards passing"))
        }
        return ExpertLine(parts.joined(separator: " · "))
    }

    /// The count a shelf row wears at its trailing edge: notes waiting for the person.
    public static func badge(_ expert: MachineExpert) -> Int? { expert.pending > 0 ? expert.pending : nil }

    // MARK: The page

    public static func meta(_ expert: MachineExpert, machine: String, modelWord: String?) -> [String] {
        var parts: [String] = []
        let place = expert.directory.map { Self.shortPath($0) }
        parts.append(place.map { "\(machine) · \($0)" } ?? machine)
        if let modelWord {
            parts.append(expert.effort.map { "\(modelWord) · \($0)" } ?? modelWord)
        }
        return parts
    }

    /// The bench row: the item's name and what the machine found.
    public static func bench(_ item: ExpertBenchItem, machine: String) -> ExpertRowReading {
        ExpertRowReading(title: item.name, detail: benchLine(item, machine: machine))
    }

    public static func benchLine(_ item: ExpertBenchItem, machine: String) -> ExpertLine {
        switch item.state {
        case .ready:
            var parts: [String] = []
            switch item.facts?["transport"] {
            case "wired": parts.append(Localized.text("By cable"))
            case "network": parts.append(Localized.text("Over the network"))
            case "usb": parts.append(Localized.text("Over USB"))
            default: parts.append(Localized.text("Connected"))
            }
            if let version = item.facts?["osVersion"] { parts.append(osWord(item.facts?["os"], version: version)) }
            if let output = item.facts?["output"], item.kind == .command { parts = [output] }
            if item.kind == .port { parts = [Localized.text("Listening")] }
            if item.lock != nil { parts.append(Localized.text("free")) }
            return ExpertLine(parts.joined(separator: " · "), .good)
        case .held:
            if let title = item.holder?.title {
                return ExpertLine(Localized.text("Held by “%@”", title), .active)
            }
            return ExpertLine(Localized.text("Held by another program"), .active)
        case .locked:
            return ExpertLine(Localized.text("Locked · unlock it to test on it"), .attention)
        case .absent:
            switch item.kind {
            case .appleDevice: return ExpertLine(Localized.text("Not reachable from %@", machine), .quiet)
            case .port: return ExpertLine(Localized.text("Nothing listening on port %d", item.port ?? 0), .quiet)
            case .command:
                if let output = item.facts?["output"], !output.isEmpty {
                    return ExpertLine(Localized.text("Not there · %@", output), .quiet)
                }
                return ExpertLine(Localized.text("Not there"), .quiet)
            }
        case .unknown, .none:
            return ExpertLine(Localized.text("Not checked yet"), .quiet)
        }
    }

    private static func osWord(_ os: String?, version: String) -> String {
        guard let os, !os.isEmpty else { return version }
        return "\(os) \(version)"
    }

    /// The guards' one line: how many pass and when they were last checked, or what is wrong.
    public static func guardsLine(_ expert: MachineExpert, calendar: Calendar = .current, now: Date = Date())
        -> ExpertLine
    {
        guard !expert.guards.isEmpty else { return ExpertLine(Localized.text("None")) }
        if expert.runningGuards { return ExpertLine(ExpertWords.checking, .active) }
        let ran = expert.guards.compactMap(\.last)
        guard !ran.isEmpty else { return ExpertLine(Localized.text("Not checked yet")) }
        let failing = expert.failingGuards.count
        let checked = ran.map(\.at).max() ?? now
        let when = ScheduleWords.lowered(ScheduleWords.moment(checked, calendar: calendar, now: now))
        if failing > 0 {
            return ExpertLine(Localized.text("%d of %d failing · checked %@", failing, expert.guards.count, when), .failing)
        }
        let passed = expert.guards.filter { $0.last?.passed == true }.count
        return ExpertLine(Localized.text("%d of %d passing · checked %@", passed, expert.guards.count, when), .good)
    }

    /// When the guards run on their own.
    public static func guardRule(_ expert: MachineExpert, calendar: Calendar = .current, now: Date = Date()) -> String {
        guard let rule = expert.guardRule else { return ExpertWords.guardsOnDemand }
        var zoned = calendar
        zoned.timeZone = TimeZone(identifier: expert.timeZone) ?? calendar.timeZone
        return Localized.text(
            "Checked %@. Quiet while everything passes; a guard that starts failing is news.",
            ScheduleWords.lowered(ScheduleWords.when(rule, calendar: zoned, now: now)))
    }

    public static func guardRow(_ item: ExpertGuard, calendar: Calendar = .current, now: Date = Date())
        -> ExpertRowReading
    {
        let trailing = item.last.map { duration($0.seconds) }
        if item.running == true { return ExpertRowReading(title: item.name, detail: ExpertLine(ExpertWords.checking, .active), trailing: trailing) }
        guard let run = item.last else {
            return ExpertRowReading(title: item.name, detail: ExpertLine(Localized.text("Not checked yet")))
        }
        let measured = run.value.map { number($0) + (item.metric?.unit.map { " \($0)" } ?? "") }
        if run.passed {
            var text = Localized.text("Passed")
            if let measured {
                text = measured
                if let most = item.metric?.atMost {
                    text += " · " + Localized.text("at most %@", number(most) + (item.metric?.unit.map { " \($0)" } ?? ""))
                }
                if let least = item.metric?.atLeast {
                    text += " · " + Localized.text("at least %@", number(least) + (item.metric?.unit.map { " \($0)" } ?? ""))
                }
            }
            return ExpertRowReading(title: item.name, detail: ExpertLine(text, .quiet), trailing: trailing)
        }
        var text: String
        switch run.failure {
        case .metric:
            let unit = item.metric?.unit.map { " \($0)" } ?? ""
            let line = item.metric?.atMost.map { Localized.text("over its %@ line", number($0) + unit) }
                ?? item.metric?.atLeast.map { Localized.text("under its %@ line", number($0) + unit) } ?? ""
            text = [measured, line].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .timeout:
            text = Localized.text("Stopped after %@", duration(run.seconds))
        case .missing:
            text = Localized.text("Its number was not in the output")
        case .exit, .none:
            text = run.exitCode.map { Localized.text("Failed · exit %d", Int($0)) } ?? Localized.text("Failed")
        }
        if let since = item.failingSince {
            text += " · " + Localized.text(
                "since %@", ScheduleWords.lowered(ScheduleWords.moment(since, calendar: calendar, now: now)))
        }
        return ExpertRowReading(title: item.name, detail: ExpertLine(text, .failing), trailing: trailing)
    }

    /// The notebook's one line: how many notes, and how many have not been confirmed for a while.
    public static func notebookLine(_ expert: MachineExpert) -> ExpertLine {
        let facts = expert.notebook
        guard facts.notes > 0 || facts.adopted else { return ExpertLine(ExpertWords.noNotesShort) }
        var text = ExpertWords.notes(facts.notes)
        if facts.stale > 0 {
            text += " · " + (facts.stale == 1
                ? Localized.text("1 not confirmed for two months")
                : Localized.text("%d not confirmed for two months", facts.stale))
        }
        if facts.adopted { text += " · " + Localized.text("adopted") }
        return ExpertLine(text, facts.stale > 0 ? .attention : .quiet)
    }

    public static func noteRow(
        _ note: ExpertNote, taskTitles: [String: String] = [:], calendar: Calendar = .current, now: Date = Date()
    ) -> ExpertRowReading {
        if let retired = note.retired {
            var parts: [String] = []
            if let reason = retired.reason, !reason.isEmpty { parts.append(reason) }
            if let at = retired.at { parts.append(day(at, calendar: calendar, now: now)) }
            return ExpertRowReading(title: note.title, detail: ExpertLine(parts.joined(separator: " · ")))
        }
        let source = note.sourceSession.flatMap { taskTitles[$0] }
        let when = note.lastTouched.map { day($0, calendar: calendar, now: now) }
        let trailing = [when, source].compactMap { $0 }.joined(separator: "\n")
        let tag =
            note.stale
            ? ExpertLine(
                Localized.text(
                    "Not confirmed since %@", note.lastTouched.map { month($0, calendar: calendar) } ?? "—"),
                .attention)
            : nil
        return ExpertRowReading(
            title: note.title, detail: ExpertLine(note.summary), trailing: trailing.isEmpty ? nil : trailing, tag: tag)
    }

    public static func journalRow(_ entry: ExpertJournalEntry, calendar: Calendar = .current, now: Date = Date())
        -> ExpertRowReading
    {
        var detail = entry.outcome
        if !entry.measured.isEmpty { detail += "\n" + entry.measured.joined(separator: " · ") }
        return ExpertRowReading(
            title: entry.title, detail: ExpertLine(detail), trailing: day(entry.at, calendar: calendar, now: now))
    }

    /// The journal's one line on the page: the latest tasks by name.
    public static func journalLine(_ expert: MachineExpert) -> ExpertLine {
        let titles = expert.journal.prefix(3).map(\.title)
        guard !titles.isEmpty else { return ExpertLine(ExpertWords.noJournal) }
        return ExpertLine(titles.joined(separator: " · "))
    }

    public static func taskRow(_ task: ExpertTaskRef, now: Date = Date()) -> ExpertRowReading {
        let age = SessionRowModel.age(of: task.updatedAt, asOf: now)
        let line: ExpertLine
        if task.active {
            line = ExpertLine(Localized.text("Working · %@", age), .active)
        } else {
            switch task.debrief {
            case .drafting: line = ExpertLine(ExpertWords.debriefDrafting, .active)
            case .open: line = ExpertLine(Localized.text("Notes to review · %@", age), .attention)
            case .settled: line = ExpertLine(Localized.text("Finished · %@", age))
            case .failed: line = ExpertLine(Localized.text("Debrief failed · %@", age), .failing)
            case .none: line = ExpertLine(Localized.text("Not finished · %@", age))
            }
        }
        return ExpertRowReading(title: task.title, detail: line)
    }

    // MARK: What a task starts with

    /// The chips over an empty task composer: facts about the brief, never settings.
    public static func startsWith(_ expert: MachineExpert) -> [ExpertLine] {
        var chips: [ExpertLine] = []
        if !expert.charter.isEmpty { chips.append(ExpertLine(Localized.text("Its charter"))) }
        chips += expert.skills.map { ExpertLine(ExpertWords.skill($0)) }
        chips.append(ExpertLine(ExpertWords.notes(expert.notebook.notes)))
        if !expert.journal.isEmpty { chips.append(ExpertLine(ExpertWords.lastTasks(min(expert.journal.count, 5)))) }
        for item in expert.bench {
            switch item.state {
            case .ready: chips.append(ExpertLine(Localized.text("%@ free", item.name), .good))
            case .held: chips.append(ExpertLine(Localized.text("%@ held", item.name), .active))
            case .locked: chips.append(ExpertLine(Localized.text("%@ locked", item.name), .attention))
            case .absent: chips.append(ExpertLine(Localized.text("%@ away", item.name)))
            case .unknown, .none: break
            }
        }
        if !expert.guards.isEmpty {
            let failing = expert.failingGuards.count
            if failing > 0 {
                chips.append(
                    ExpertLine(
                        failing == 1 ? Localized.text("1 guard failing") : Localized.text("%d guards failing", failing),
                        .failing))
            } else if expert.guards.allSatisfy({ $0.last?.passed == true }) {
                chips.append(ExpertLine(Localized.text("Guards passing"), .good))
            }
        }
        return chips
    }

    // MARK: The debrief

    /// The card's headline: what the expert learned, changed and wants to retire.
    public static func debriefHeadline(_ debrief: ExpertDebrief, name: String) -> ExpertLine {
        switch debrief.state {
        case .drafting: return ExpertLine(ExpertWords.debriefDrafting, .active)
        case .failed: return ExpertLine(ExpertWords.debriefFailed, .failing)
        case .settled:
            let accepted = debrief.proposals.contains { $0.state == .accepted }
            return ExpertLine(accepted ? ExpertWords.debriefSettled : ExpertWords.debriefNothing)
        case .open:
            let adds = debrief.proposals.filter { $0.op == .add }.count
            let changes = debrief.proposals.filter { $0.op == .change }.count
            let retires = debrief.proposals.filter { $0.op == .retire }.count
            var clauses: [String] = []
            if adds > 0 { clauses.append(adds == 1 ? Localized.text("learned 1 thing") : Localized.text("learned %d things", adds)) }
            if changes > 0 { clauses.append(changes == 1 ? Localized.text("corrected 1 note") : Localized.text("corrected %d notes", changes)) }
            if retires > 0 { clauses.append(retires == 1 ? Localized.text("wants to retire 1") : Localized.text("wants to retire %d", retires)) }
            let joined: String
            switch clauses.count {
            case 0: joined = Localized.text("has nothing for the notebook")
            case 1: joined = clauses[0]
            default:
                joined = Localized.text(
                    "%@ and %@", clauses.dropLast().joined(separator: ", "), clauses[clauses.count - 1])
            }
            return ExpertLine(Localized.text("%@ %@", name, joined), .attention)
        }
    }

    public static func debriefDetail(_ debrief: ExpertDebrief) -> String {
        switch debrief.state {
        case .drafting: return ExpertWords.debriefDraftingDetail
        case .failed: return debrief.failure ?? ""
        case .open: return ExpertWords.debriefNothingChanged
        case .settled:
            let accepted = debrief.proposals.filter { $0.state == .accepted }.count
            let skipped = debrief.proposals.filter { $0.state == .skipped }.count
            guard !debrief.proposals.isEmpty else { return "" }
            return Localized.text("%d accepted · %d skipped", accepted, skipped)
        }
    }

    public static func journalPreview(_ entry: ExpertJournalEntry) -> String {
        var text = entry.outcome
        var extras = entry.measured
        if !entry.commits.isEmpty {
            extras.append(entry.commits.count == 1 ? Localized.text("1 commit") : Localized.text("%d commits", entry.commits.count))
        }
        if !extras.isEmpty { text += "\n" + extras.joined(separator: " · ") }
        return text
    }

    // MARK: Words for times and numbers

    /// A day said the short way: "today", "yesterday", "19 Nov".
    public static func day(_ date: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return Localized.text("today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return Localized.text("yesterday")
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: date)
    }

    static func month(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter.string(from: date)
    }

    public static func duration(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return Localized.text("%d s", whole) }
        if whole < 3_570 { return Localized.text("%d min", (whole + 30) / 60) }
        return Localized.text("%d h", max(1, (whole + 1_800) / 3_600))
    }

    /// A measured number with no more digits than it has: 2.4, 46, 0.05.
    static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e9 { return String(Int(value)) }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// A path with the home folder said as `~`.
    public static func shortPath(_ path: String) -> String {
        for prefix in ["/Users/", "/home/"] where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            guard let slash = rest.firstIndex(of: "/") else { return "~" }
            return "~" + rest[slash...]
        }
        return path
    }
}

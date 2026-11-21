import CodingAgentKit
import Foundation

/// How loud a line about a master is, which each client turns into its own colour.
public enum MasterTone: String, Sendable, Hashable {
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
public struct MasterLine: Sendable, Hashable {
    public let text: String
    public let tone: MasterTone

    public init(_ text: String, _ tone: MasterTone = .quiet) {
        self.text = text
        self.tone = tone
    }
}

/// A row a client draws as it is: a title, the line under it, and the few words at its trailing edge.
public struct MasterRowReading: Sendable, Hashable {
    public let title: String
    public let detail: MasterLine
    public let trailing: String?
    /// A small tag beside the title, such as a note that has not been confirmed for a while.
    public let tag: MasterLine?

    public init(title: String, detail: MasterLine, trailing: String? = nil, tag: MasterLine? = nil) {
        self.title = title
        self.detail = detail
        self.trailing = trailing
        self.tag = tag
    }

    public var accessibilityLabel: String {
        [title, tag?.text, detail.text, trailing].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Every reading of a master a client shows, written once.
public enum MasterReading {
    // MARK: The shelf

    /// The one state line a shelf row says, in order of what matters most: a task running, notes
    /// waiting, a guard failing, a debrief being written, guards checking, then at rest. Only the
    /// last says it is idle: a row that wants the person leads with what it wants.
    public static func state(_ master: MachineExpert, calendar: Calendar = .current, now: Date = Date()) -> MasterLine {
        if let task = master.task {
            return MasterLine(
                Localized.text("Working on “%@” · %@", task.title, SessionRowModel.age(of: task.updatedAt, asOf: now)),
                .active)
        }
        if master.pending > 0 {
            return MasterLine(MasterWords.toReview(master.pending), .attention)
        }
        if let failing = master.failingGuards.first {
            var text = Localized.text("Guard failing · %@", failing.name)
            if let since = failing.failingSince {
                text += " · " + Localized.text(
                    "since %@", ScheduleWords.lowered(ScheduleWords.moment(since, calendar: calendar, now: now)))
            }
            return MasterLine(text, .failing)
        }
        if master.tasks.contains(where: { $0.debrief == .drafting }) {
            return MasterLine(MasterWords.debriefDrafting, .active)
        }
        if master.runningGuards { return MasterLine(MasterWords.checking, .active) }
        var parts = [Localized.text("Idle")]
        if master.notebook.notes > 0 { parts.append(MasterWords.notes(master.notebook.notes)) }
        if !master.guards.isEmpty, master.guards.allSatisfy({ $0.last?.passed == true }) {
            parts.append(Localized.text("guards passing"))
        }
        return MasterLine(parts.joined(separator: " · "))
    }

    /// The count a shelf row wears at its trailing edge: notes waiting for the person.
    public static func badge(_ master: MachineExpert) -> Int? { master.pending > 0 ? master.pending : nil }

    // MARK: The page

    public static func meta(_ master: MachineExpert, machine: String, modelWord: String?) -> [String] {
        var parts: [String] = []
        let place = master.directory.map { Self.shortPath($0) }
        parts.append(place.map { "\(machine) · \($0)" } ?? machine)
        if let modelWord {
            parts.append(master.effort.map { "\(modelWord) · \($0)" } ?? modelWord)
        }
        return parts
    }

    /// The bench row: the item's name and what the machine found.
    public static func bench(_ item: ExpertBenchItem, machine: String) -> MasterRowReading {
        MasterRowReading(title: item.name, detail: benchLine(item, machine: machine))
    }

    public static func benchLine(_ item: ExpertBenchItem, machine: String) -> MasterLine {
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
            return MasterLine(parts.joined(separator: " · "), .good)
        case .held:
            if let title = item.holder?.title {
                return MasterLine(Localized.text("Held by “%@”", title), .active)
            }
            return MasterLine(Localized.text("Held by another program"), .active)
        case .locked:
            return MasterLine(Localized.text("Locked · unlock it to test on it"), .attention)
        case .absent:
            switch item.kind {
            case .appleDevice: return MasterLine(Localized.text("Not reachable from %@", machine), .quiet)
            case .port: return MasterLine(Localized.text("Nothing listening on port %d", item.port ?? 0), .quiet)
            case .command:
                if let output = item.facts?["output"], !output.isEmpty {
                    return MasterLine(Localized.text("Not there · %@", output), .quiet)
                }
                return MasterLine(Localized.text("Not there"), .quiet)
            }
        case .unknown, .none:
            return MasterLine(Localized.text("Not checked yet"), .quiet)
        }
    }

    private static func osWord(_ os: String?, version: String) -> String {
        guard let os, !os.isEmpty else { return version }
        return "\(os) \(version)"
    }

    /// The guards' one line: how many pass and when they were last checked, or what is wrong.
    public static func guardsLine(_ master: MachineExpert, calendar: Calendar = .current, now: Date = Date())
        -> MasterLine
    {
        guard !master.guards.isEmpty else { return MasterLine(Localized.text("None")) }
        if master.runningGuards { return MasterLine(MasterWords.checking, .active) }
        let ran = master.guards.compactMap(\.last)
        guard !ran.isEmpty else { return MasterLine(Localized.text("Not checked yet")) }
        let failing = master.failingGuards.count
        let checked = ran.map(\.at).max() ?? now
        let when = ScheduleWords.lowered(ScheduleWords.moment(checked, calendar: calendar, now: now))
        if failing > 0 {
            return MasterLine(Localized.text("%d of %d failing · checked %@", failing, master.guards.count, when), .failing)
        }
        let passed = master.guards.filter { $0.last?.passed == true }.count
        return MasterLine(Localized.text("%d of %d passing · checked %@", passed, master.guards.count, when), .good)
    }

    /// When the guards run on their own.
    public static func guardRule(_ master: MachineExpert, calendar: Calendar = .current, now: Date = Date()) -> String {
        guard let rule = master.guardRule else { return MasterWords.guardsOnDemand }
        var zoned = calendar
        zoned.timeZone = TimeZone(identifier: master.timeZone) ?? calendar.timeZone
        return Localized.text(
            "Checked %@. Quiet while everything passes; a guard that starts failing is news.",
            ScheduleWords.lowered(ScheduleWords.when(rule, calendar: zoned, now: now)))
    }

    public static func guardRow(_ item: ExpertGuard, calendar: Calendar = .current, now: Date = Date())
        -> MasterRowReading
    {
        let trailing = item.last.map { duration($0.seconds) }
        if item.running == true { return MasterRowReading(title: item.name, detail: MasterLine(MasterWords.checking, .active), trailing: trailing) }
        guard let run = item.last else {
            return MasterRowReading(title: item.name, detail: MasterLine(Localized.text("Not checked yet")))
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
            return MasterRowReading(title: item.name, detail: MasterLine(text, .quiet), trailing: trailing)
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
        return MasterRowReading(title: item.name, detail: MasterLine(text, .failing), trailing: trailing)
    }

    /// The notebook's one line: how many notes, and how many have not been confirmed for a while.
    public static func notebookLine(_ master: MachineExpert) -> MasterLine {
        let facts = master.notebook
        guard facts.notes > 0 || facts.adopted else { return MasterLine(MasterWords.noNotesShort) }
        var text = MasterWords.notes(facts.notes)
        if facts.stale > 0 {
            text += " · " + (facts.stale == 1
                ? Localized.text("1 not confirmed for two months")
                : Localized.text("%d not confirmed for two months", facts.stale))
        }
        if facts.adopted { text += " · " + Localized.text("adopted") }
        return MasterLine(text, facts.stale > 0 ? .attention : .quiet)
    }

    public static func noteRow(
        _ note: ExpertNote, taskTitles: [String: String] = [:], calendar: Calendar = .current, now: Date = Date()
    ) -> MasterRowReading {
        if let retired = note.retired {
            var parts: [String] = []
            if let reason = retired.reason, !reason.isEmpty { parts.append(reason) }
            if let at = retired.at { parts.append(day(at, calendar: calendar, now: now)) }
            return MasterRowReading(title: note.title, detail: MasterLine(parts.joined(separator: " · ")))
        }
        let source = note.sourceSession.flatMap { taskTitles[$0] }
        let when = note.lastTouched.map { day($0, calendar: calendar, now: now) }
        let trailing = [when, source].compactMap { $0 }.joined(separator: "\n")
        let tag =
            note.stale
            ? MasterLine(
                Localized.text(
                    "Not confirmed since %@", note.lastTouched.map { month($0, calendar: calendar) } ?? "—"),
                .attention)
            : nil
        return MasterRowReading(
            title: note.title, detail: MasterLine(note.summary), trailing: trailing.isEmpty ? nil : trailing, tag: tag)
    }

    public static func journalRow(_ entry: ExpertJournalEntry, calendar: Calendar = .current, now: Date = Date())
        -> MasterRowReading
    {
        var detail = entry.outcome
        if !entry.measured.isEmpty { detail += "\n" + entry.measured.joined(separator: " · ") }
        return MasterRowReading(
            title: entry.title, detail: MasterLine(detail), trailing: day(entry.at, calendar: calendar, now: now))
    }

    /// The journal's one line on the page: the latest tasks by name.
    public static func journalLine(_ master: MachineExpert) -> MasterLine {
        let titles = master.journal.prefix(3).map(\.title)
        guard !titles.isEmpty else { return MasterLine(MasterWords.noJournal) }
        return MasterLine(titles.joined(separator: " · "))
    }

    public static func taskRow(_ task: ExpertTaskRef, now: Date = Date()) -> MasterRowReading {
        let age = SessionRowModel.age(of: task.updatedAt, asOf: now)
        let line: MasterLine
        if task.active {
            line = MasterLine(Localized.text("Working · %@", age), .active)
        } else {
            switch task.debrief {
            case .drafting: line = MasterLine(MasterWords.debriefDrafting, .active)
            case .open: line = MasterLine(Localized.text("Notes to review · %@", age), .attention)
            case .settled: line = MasterLine(Localized.text("Finished · %@", age))
            case .failed: line = MasterLine(Localized.text("Debrief failed · %@", age), .failing)
            case .none: line = MasterLine(Localized.text("Not finished · %@", age))
            }
        }
        return MasterRowReading(title: task.title, detail: line)
    }

    // MARK: What a task starts with

    /// The chips over an empty task composer: facts about the brief, never settings.
    public static func startsWith(_ master: MachineExpert) -> [MasterLine] {
        var chips: [MasterLine] = []
        if !master.charter.isEmpty { chips.append(MasterLine(Localized.text("Its charter"))) }
        chips += master.skills.map { MasterLine(MasterWords.skill($0)) }
        chips.append(MasterLine(MasterWords.notes(master.notebook.notes)))
        if !master.journal.isEmpty { chips.append(MasterLine(MasterWords.lastTasks(min(master.journal.count, 5)))) }
        for item in master.bench {
            switch item.state {
            case .ready: chips.append(MasterLine(Localized.text("%@ free", item.name), .good))
            case .held: chips.append(MasterLine(Localized.text("%@ held", item.name), .active))
            case .locked: chips.append(MasterLine(Localized.text("%@ locked", item.name), .attention))
            case .absent: chips.append(MasterLine(Localized.text("%@ away", item.name)))
            case .unknown, .none: break
            }
        }
        if !master.guards.isEmpty {
            let failing = master.failingGuards.count
            if failing > 0 {
                chips.append(
                    MasterLine(
                        failing == 1 ? Localized.text("1 guard failing") : Localized.text("%d guards failing", failing),
                        .failing))
            } else if master.guards.allSatisfy({ $0.last?.passed == true }) {
                chips.append(MasterLine(Localized.text("Guards passing"), .good))
            }
        }
        return chips
    }

    // MARK: The debrief

    /// The card's headline: what the master learned, changed and wants to retire.
    public static func debriefHeadline(_ debrief: ExpertDebrief, name: String) -> MasterLine {
        switch debrief.state {
        case .drafting: return MasterLine(MasterWords.debriefDrafting, .active)
        case .failed: return MasterLine(MasterWords.debriefFailed, .failing)
        case .settled:
            let accepted = debrief.proposals.contains { $0.state == .accepted }
            return MasterLine(accepted ? MasterWords.debriefSettled : MasterWords.debriefNothing)
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
            return MasterLine(Localized.text("%@ %@", name, joined), .attention)
        }
    }

    public static func debriefDetail(_ debrief: ExpertDebrief) -> String {
        switch debrief.state {
        case .drafting: return MasterWords.debriefDraftingDetail
        case .failed: return debrief.failure ?? ""
        case .open: return MasterWords.debriefNothingChanged
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

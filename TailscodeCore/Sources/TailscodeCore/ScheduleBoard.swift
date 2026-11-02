import CodingAgentKit
import CodingAgentKitApple
import Foundation

/// One schedule as a list shows it, with the machine that keeps it.
public struct ScheduleRow: Sendable, Hashable, Identifiable {
    public let profileID: String
    public let machine: String
    public let schedule: MachineSchedule
    public let title: String
    public let subtitle: String
    public let mark: ScheduleMark
    /// The few words the trailing mark carries: "quiet", "03:00", "failed".
    public let markWords: String?

    public var id: String { "\(profileID)·\(schedule.id)" }
}

/// Every machine's schedules as one list, soonest first, and the one line Home wears for them.
public struct ScheduleBoard: Sendable, Hashable {
    public struct Source: Sendable {
        public let profileID: String
        public let machine: String
        public let schedules: [MachineSchedule]

        public init(profileID: String, machine: String, schedules: [MachineSchedule]) {
            self.profileID = profileID
            self.machine = machine
            self.schedules = schedules
        }
    }

    public let rows: [ScheduleRow]

    public init(rows: [ScheduleRow]) { self.rows = rows }

    public static let empty = ScheduleBoard(rows: [])

    public var isEmpty: Bool { rows.isEmpty }

    public static func make(_ sources: [Source], calendar: Calendar = .current, now: Date = Date())
        -> ScheduleBoard
    {
        let rows = sources.flatMap { source in
            source.schedules.map { row($0, profileID: source.profileID, machine: source.machine, calendar: calendar, now: now) }
        }
        return ScheduleBoard(rows: rows.sorted(by: order))
    }

    /// Waiting schedules by when they ask; paused after them; one-offs that are done last.
    private static func order(_ lhs: ScheduleRow, _ rhs: ScheduleRow) -> Bool {
        func bucket(_ row: ScheduleRow) -> Int {
            if row.schedule.isFinished { return 2 }
            return row.schedule.paused ? 1 : 0
        }
        if bucket(lhs) != bucket(rhs) { return bucket(lhs) < bucket(rhs) }
        let left = lhs.schedule.next ?? .distantFuture
        let right = rhs.schedule.next ?? .distantFuture
        if left != right { return left < right }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    static func row(_ schedule: MachineSchedule, profileID: String, machine: String, calendar: Calendar, now: Date)
        -> ScheduleRow
    {
        var zoned = calendar
        zoned.timeZone = TimeZone(identifier: schedule.timeZone) ?? calendar.timeZone
        let when: String
        let mark: ScheduleMark
        var words: String?
        if schedule.isFinished {
            when = ScheduleWords.done
            mark = .done
        } else if schedule.paused {
            when = ScheduleWords.paused
            mark = .paused
        } else {
            when = ScheduleWords.when(schedule.rule, calendar: zoned, now: now)
            mark = .waiting
        }
        var lastMark = mark
        if let last = schedule.runs.first {
            let reading = ScheduleWords.run(last, machine: machine, calendar: zoned, now: now)
            lastMark = reading.mark
            switch reading.mark {
            case .quiet: words = Localized.text("quiet")
            case .failed: words = Localized.text("failed")
            case .missed: words = Localized.text("missed")
            case .running: words = Localized.text("asking")
            default:
                words = ScheduleWords.timeText(last.endedAt ?? last.startedAt ?? last.scheduledFor, calendar: zoned)
            }
        }
        return ScheduleRow(
            profileID: profileID, machine: machine, schedule: schedule, title: schedule.title,
            subtitle: Localized.text("%@ · %@", when, machine),
            mark: schedule.runs.isEmpty ? mark : lastMark, markWords: words)
    }

    /// The schedule that asks next, anywhere.
    public var next: ScheduleRow? {
        rows.first { !$0.schedule.paused && !$0.schedule.isFinished && $0.schedule.next != nil }
    }

    /// Home's line while anything is scheduled: "Next: “AI news” at 07:30 on arch".
    public func homeLine(calendar: Calendar = .current, now: Date = Date()) -> String? {
        guard let next, let date = next.schedule.next else {
            return rows.isEmpty ? nil : Localized.text("%d scheduled, all paused", rows.count)
        }
        var zoned = calendar
        zoned.timeZone = TimeZone(identifier: next.schedule.timeZone) ?? calendar.timeZone
        return Localized.text(
            "Next: \u{201C}%@\u{201D} %@ on %@", next.title,
            ScheduleWords.lowered(ScheduleWords.moment(date, calendar: zoned, now: now)), next.machine)
    }

    /// The schedules every machine that keeps them keeps, read together. A machine that does not
    /// answer is left out rather than shown empty.
    public static func load(
        _ servers: [(profile: ConnectionProfile, backend: any CodingAgentBackend)]
    ) async -> ScheduleBoard {
        let sources = await withTaskGroup(of: (Int, Source?).self) { group in
            for (index, server) in servers.enumerated() {
                group.addTask {
                    guard let scheduling = server.backend as? any MachineScheduling,
                        let schedules = try? await scheduling.machineSchedules()
                    else { return (index, nil) }
                    return (index, Source(profileID: server.profile.id, machine: server.profile.name, schedules: schedules))
                }
            }
            var found: [(Int, Source)] = []
            for await (index, source) in group {
                if let source { found.append((index, source)) }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return make(sources)
    }
}

/// What the "Ask later" sheet holds and says: the chip picked or the phrase typed, what that was
/// understood as, the two switches, and the schedule it would make. One state for three clients.
public struct AskLaterSheet: Sendable, Equatable {
    public enum Chip: String, Sendable, CaseIterable {
        case inAnHour, tonight, tomorrowMorning, everyMorning, everyWeek
    }

    public var text: String
    public var machine: String
    public var modelWord: String?
    public var chip: Chip?
    public var phrase: String
    public var oneConversation: Bool
    public var quiet: Bool
    /// Set by a client that knows the machine cannot keep schedules.
    public var machineKeepsSchedules: Bool

    public init(text: String, machine: String, modelWord: String? = nil, machineKeepsSchedules: Bool = true) {
        self.text = text
        self.machine = machine
        self.modelWord = modelWord
        self.chip = nil
        self.phrase = ""
        self.oneConversation = true
        self.quiet = true
        self.machineKeepsSchedules = machineKeepsSchedules
    }

    /// Picking a chip clears what was typed; typing clears the chip. Only one answer to "when".
    public mutating func pick(_ chip: Chip) {
        self.chip = chip
        phrase = ""
    }

    public mutating func type(_ phrase: String) {
        self.phrase = phrase
        if !phrase.trimmingCharacters(in: .whitespaces).isEmpty { chip = nil }
    }

    public static func words(_ chip: Chip, calendar: Calendar = .current) -> (title: String, time: String?) {
        let morning = ScheduleWords.clock(
            ScheduleRule(kind: .daily, hour: QuickAskLaterChoice.morningHour, minute: 0), calendar: calendar)
        let evening = ScheduleWords.clock(
            ScheduleRule(kind: .daily, hour: QuickAskLaterChoice.eveningHour, minute: 0), calendar: calendar)
        switch chip {
        case .inAnHour: return (Localized.text("In an hour"), nil)
        case .tonight: return (Localized.text("Tonight"), evening)
        case .tomorrowMorning: return (Localized.text("Tomorrow"), morning)
        case .everyMorning: return (Localized.text("Every morning"), morning)
        case .everyWeek:
            let today = calendar.component(.weekday, from: Date())
            return (Localized.text("Every %@", ScheduleWords.weekday(today, calendar: calendar)), morning)
        }
    }

    static func rule(_ chip: Chip, now: Date, calendar: Calendar) -> ScheduleRule? {
        let morning = QuickAskLaterChoice.morningHour
        switch chip {
        case .inAnHour: return .once(now.addingTimeInterval(3_600).rounded(to: 60, calendar: calendar))
        case .tonight:
            return ScheduleSpeech.read("tonight", now: now, calendar: calendar)?.rule
        case .tomorrowMorning:
            return ScheduleSpeech.read("tomorrow", now: now, calendar: calendar)?.rule
        case .everyMorning: return ScheduleRule(kind: .daily, hour: morning, minute: 0)
        case .everyWeek:
            return ScheduleRule(
                kind: .weekly, hour: morning, minute: 0, weekday: calendar.component(.weekday, from: now))
        }
    }

    /// What the sheet understood, or nil when nothing has been chosen yet.
    public func understanding(now: Date = Date(), calendar: Calendar = .current) -> ScheduleSpeech.Understanding? {
        if !phrase.trimmingCharacters(in: .whitespaces).isEmpty {
            return ScheduleSpeech.read(phrase, now: now, calendar: calendar)
        }
        guard let chip, let rule = Self.rule(chip, now: now, calendar: calendar),
            let next = rule.next(after: now, calendar: calendar)
        else { return nil }
        return ScheduleSpeech.Understanding(rule: rule, next: next)
    }

    /// The line under the field: what was understood, then and by whom; or that it was not.
    public func understoodLine(now: Date = Date(), calendar: Calendar = .current) -> (headline: String, detail: String)? {
        guard machineKeepsSchedules else { return nil }
        guard let understood = understanding(now: now, calendar: calendar) else {
            return phrase.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : (ScheduleWords.notUnderstood, "")
        }
        var parts: [String] = []
        if let then = ScheduleWords.then(understood.rule, calendar: calendar) { parts.append(then) }
        parts.append(Localized.text("asked by %@", machine))
        if let modelWord { parts.append(modelWord) }
        return (
            ScheduleWords.next(understood.next, calendar: calendar, now: now),
            parts.joined(separator: " · ")
        )
    }

    /// Whether the switches mean anything: a one-off has one run.
    public func showsRepeatSwitches(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        understanding(now: now, calendar: calendar)?.rule.isRepeating ?? (chip == .everyMorning || chip == .everyWeek)
    }

    public func confirmTitle(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let understood = understanding(now: now, calendar: calendar) else { return ScheduleWords.askLater }
        return ScheduleWords.confirm(understood, calendar: calendar, now: now)
    }

    public var canSave: Bool {
        machineKeepsSchedules && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The schedule this sheet makes on its machine.
    public func draft(
        model: ModelSelection?, wireModel: String?, effort: String?, directory: String?,
        sessionID: String? = nil, device: String? = nil, now: Date = Date(), calendar: Calendar = .current
    ) -> ScheduleDraft? {
        guard canSave, let understood = understanding(now: now, calendar: calendar) else { return nil }
        let repeating = understood.rule.isRepeating
        return ScheduleDraft(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines), model: wireModel ?? model?.modelID,
            effort: effort, directory: directory, rule: understood.rule,
            timeZone: calendar.timeZone.identifier,
            thread: repeating ? (oneConversation ? .continue : .fresh) : .continue,
            quiet: repeating && quiet, sessionID: oneConversation ? sessionID : nil, createdBy: device)
    }
}

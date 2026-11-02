import CodingAgentKit
import CodingAgentKitApple
import Foundation

/// A question asked at a time rather than now, once or again and again: the rumour checked every
/// morning, the price looked at every week, the benchmark started at three. It is kept on the
/// desktop that was told about it and asked by that desktop while it is running — a desktop that
/// was closed at the hour asks it the next time it opens, once, however many hours it missed.
public struct QuickAskLater: Codable, Sendable, Equatable, Identifiable {
    public enum Repeat: String, Codable, Sendable, CaseIterable {
        case once
        case daily
        case weekly
    }

    public let id: String
    public var text: String
    public var profileID: String
    public var model: String?
    public var effort: String?
    public var fireAt: Date
    public var repeats: Repeat
    public var lastAsked: Date?
    /// When a machine that did not take the question is tried again. Kept apart from `fireAt` so a
    /// retry never moves the hour a repeat keeps.
    public var retryAt: Date?

    public init(
        id: String = UUID().uuidString, text: String, profileID: String, model: String? = nil,
        effort: String? = nil, fireAt: Date, repeats: Repeat = .once, lastAsked: Date? = nil,
        retryAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.profileID = profileID
        self.model = model
        self.effort = effort
        self.fireAt = fireAt
        self.repeats = repeats
        self.lastAsked = lastAsked
        self.retryAt = retryAt
    }

    /// When it is next asked: a pending retry, or its hour.
    public var dueAt: Date { retryAt ?? fireAt }

    /// The first line, as a list row wears it.
    public var headline: String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// When it next asks, after an asking at `asked`: the same hour a day or a week on, stepped past
    /// `now` so a desktop that slept through several does not ask them all at once.
    public func next(after asked: Date, now: Date, calendar: Calendar = .current) -> Date? {
        let step: DateComponents
        switch repeats {
        case .once: return nil
        case .daily: step = DateComponents(day: 1)
        case .weekly: step = DateComponents(day: 7)
        }
        var next = fireAt
        repeat {
            guard let stepped = calendar.date(byAdding: step, to: next) else { return nil }
            next = stepped
        } while next <= max(asked, now)
        return next
    }
}

/// The handful of times a question is put off to, said the way a person says them. Picking one is
/// the whole scheduling: there is no calendar to fill in for "every morning".
public enum QuickAskLaterChoice: String, Sendable, CaseIterable {
    case inAnHour
    case tonight
    case tomorrowMorning
    case everyMorning
    case everyWeek

    public static let morningHour = 8
    public static let eveningHour = 21

    public var repeats: QuickAskLater.Repeat {
        switch self {
        case .inAnHour, .tonight, .tomorrowMorning: return .once
        case .everyMorning: return .daily
        case .everyWeek: return .weekly
        }
    }

    /// The first time this choice asks, seen from `now`.
    public func fireDate(now: Date, calendar: Calendar = .current) -> Date {
        func at(_ hour: Int, dayOffset: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: now) ?? now
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? now
        }
        switch self {
        case .inAnHour:
            return now.addingTimeInterval(3600)
        case .tonight:
            let today = at(Self.eveningHour, dayOffset: 0)
            return today > now ? today : at(Self.eveningHour, dayOffset: 1)
        case .tomorrowMorning:
            return at(Self.morningHour, dayOffset: 1)
        case .everyMorning, .everyWeek:
            let today = at(Self.morningHour, dayOffset: 0)
            return today > now ? today : at(Self.morningHour, dayOffset: 1)
        }
    }

    public func words(now: Date, calendar: Calendar = .current) -> String {
        switch self {
        case .inAnHour: return Localized.text("In an hour")
        case .tonight: return Localized.text("Tonight at %@", QuickAskLaterWords.clock(hour: Self.eveningHour))
        case .tomorrowMorning:
            return Localized.text("Tomorrow at %@", QuickAskLaterWords.clock(hour: Self.morningHour))
        case .everyMorning:
            return Localized.text("Every morning at %@", QuickAskLaterWords.clock(hour: Self.morningHour))
        case .everyWeek:
            let weekday = calendar.component(.weekday, from: fireDate(now: now, calendar: calendar))
            return Localized.text(
                "Every %@ at %@", QuickAskLaterWords.weekday(weekday, calendar: calendar),
                QuickAskLaterWords.clock(hour: Self.morningHour))
        }
    }
}

public enum QuickAskLaterWords {
    public static var section: String { Localized.text("Later") }
    public static var reach: String {
        Localized.text("Handed to the machine when it keeps schedules, so it asks whether or not this computer is on; otherwise asked by this computer while Tailscode is open.")
    }

    static func clock(hour: Int) -> String {
        let format = DateFormatter()
        format.dateStyle = .none
        format.timeStyle = .short
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return format.string(from: date)
    }

    static func weekday(_ index: Int, calendar: Calendar) -> String {
        let names = calendar.standaloneWeekdaySymbols
        return names.indices.contains(index - 1) ? names[index - 1] : ""
    }

    /// When a waiting question asks next, short: a time today, a weekday this week, a date beyond.
    public static func when(_ later: QuickAskLater, now: Date = Date(), calendar: Calendar = .current)
        -> String
    {
        let format = DateFormatter()
        if calendar.isDate(later.dueAt, inSameDayAs: now) {
            format.dateStyle = .none
            format.timeStyle = .short
        } else if let week = calendar.date(byAdding: .day, value: 6, to: now), later.dueAt < week {
            format.setLocalizedDateFormatFromTemplate("EEE j:mm")
        } else {
            format.dateStyle = .medium
            format.timeStyle = .short
        }
        let at = format.string(from: later.dueAt)
        switch later.repeats {
        case .once: return at
        case .daily: return Localized.text("%@ · every day", at)
        case .weekly: return Localized.text("%@ · every week", at)
        }
    }
}

/// The questions waiting on this device, in one small JSON file beside the actions.
public enum QuickAskLaterStore {
    public static let didChange = Notification.Name("tailscode.quickask.later.didChange")

    nonisolated(unsafe) public static var fileURL: URL =
        QuickAskActions.defaultURL.deletingLastPathComponent().appendingPathComponent("quick-later.json")

    private struct File: Codable {
        var later: [QuickAskLater]
    }

    public static func all() -> [QuickAskLater] {
        guard let data = try? Data(contentsOf: fileURL),
            let file = try? decoder.decode(File.self, from: data)
        else { return [] }
        return file.later.sorted { $0.dueAt < $1.dueAt }
    }

    public static func save(_ later: QuickAskLater) {
        var held = all().filter { $0.id != later.id }
        held.append(later)
        write(held)
    }

    public static func remove(id: String) {
        write(all().filter { $0.id != id })
    }

    /// What is due at `now`, oldest first.
    public static func due(now: Date) -> [QuickAskLater] {
        all().filter { $0.dueAt <= now }
    }

    /// Marks one asked: a single question leaves, a repeating one moves to its next hour.
    public static func asked(_ later: QuickAskLater, at now: Date, calendar: Calendar = .current) {
        guard let next = later.next(after: now, now: now, calendar: calendar) else {
            remove(id: later.id)
            return
        }
        var moved = later
        moved.fireAt = next
        moved.lastAsked = now
        moved.retryAt = nil
        save(moved)
    }

    /// A question whose machine did not take it is asked again after `seconds`, not on every beat.
    public static func postpone(_ later: QuickAskLater, by seconds: TimeInterval, now: Date = Date()) {
        var moved = later
        moved.retryAt = now.addingTimeInterval(seconds)
        save(moved)
    }

    /// Asks a waiting question now. A single one is brought forward; a repeat keeps its hour and
    /// is asked now as a single copy beside it.
    public static func askNow(id: String, now: Date = Date()) {
        guard var later = all().first(where: { $0.id == id }) else { return }
        guard later.repeats == .once else {
            save(
                QuickAskLater(
                    text: later.text, profileID: later.profileID, model: later.model,
                    effort: later.effort, fireAt: now))
            return
        }
        later.fireAt = now
        later.retryAt = nil
        save(later)
    }

    private static func write(_ later: [QuickAskLater]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(File(later: later)) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        StoreNotice.post(didChange)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Asks one waiting question with no window in front of it: a conversation is minted on its
/// machine with no project, stamped with its model and level, and the words are sent to it
/// directly, so it runs on the server and arrives in the chat list like any other.
public enum QuickAskLaterRunner {
    public static func ask(
        _ later: QuickAskLater, on profile: ConnectionProfile, using backend: any CodingAgentBackend,
        password: String?
    ) async -> Result<AgentSession, NewChatFailure> {
        let server = NewChatServer(
            profileID: profile.id, name: profile.name, backend: profile.backend,
            address: ServerLabel.address(profile))
        let minted = await NewChatAttempt.mint(
            using: backend, server: server, baseURL: profile.baseURL, password: password,
            directory: nil)
        guard case .success(let session) = minted else {
            return .failure(minted.failureValue ?? NewChatDiagnosis.noSuchServer())
        }
        let model = later.model.flatMap(ModelSelection.init(string:))
        QuickAskDefaults.stamp(
            profileID: profile.id, sessionID: session.id, model: model, effort: later.effort)
        do {
            try await backend.send(
                SendPrompt(text: later.text, model: model, reasoningEffort: later.effort),
                to: session.id)
        } catch {
            return .failure(
                NewChatFailure(
                    symbol: "clock.badge.exclamationmark", glyph: "!",
                    title: Localized.text("The question for later was not sent"),
                    detail: error.localizedDescription, fix: .retry, actionTitle: nil))
        }
        return .success(session)
    }
}

/// A question put off on this desktop, handed to its machine when the machine keeps schedules —
/// which every claude-bridge and omp-bridge does — so it is asked whether or not this computer is
/// on. The desktop keeps asking it only for a machine that cannot (opencode).
public enum QuickAskLaterHandoff {
    /// The machine's rule for a question put off here: the moment for a single one, the same hour
    /// every day or every week for a repeat, read in this device's zone.
    public static func rule(for later: QuickAskLater, calendar: Calendar = .current) -> ScheduleRule {
        let hour = calendar.component(.hour, from: later.fireAt)
        let minute = calendar.component(.minute, from: later.fireAt)
        switch later.repeats {
        case .once: return .once(later.fireAt)
        case .daily: return ScheduleRule(kind: .daily, hour: hour, minute: minute)
        case .weekly:
            return ScheduleRule(
                kind: .weekly, hour: hour, minute: minute, weekday: calendar.component(.weekday, from: later.fireAt))
        }
    }

    /// Whether this machine takes the question, so the desktop can let its own copy go.
    public static func place(
        _ later: QuickAskLater, using backend: any CodingAgentBackend, device: String? = nil,
        now: Date = Date(), calendar: Calendar = .current
    ) async -> Bool {
        guard backend.capabilities.supportsSchedules,
            let scheduling = backend as? any MachineScheduling
        else { return false }
        var rule = rule(for: later, calendar: calendar)
        if rule.kind == .once, later.fireAt <= now { rule = .once(now.addingTimeInterval(60)) }
        let model = later.model.flatMap(ModelSelection.init(string:))
        let draft = ScheduleDraft(
            text: later.text, model: model.map { wireModel($0, backend: backend) }, effort: later.effort,
            rule: rule, timeZone: calendar.timeZone.identifier, thread: .continue,
            quiet: rule.isRepeating, createdBy: device)
        return (try? await scheduling.createSchedule(draft)) != nil
    }

    /// The model as the machine names it on the wire: an agent's model carries its agent.
    public static func wireModel(_ selection: ModelSelection, backend: any CodingAgentBackend) -> String {
        guard backend.capabilities.supportsMachineAgents, !selection.providerID.isEmpty,
            selection.providerID != "anthropic", selection.providerID != "claude"
        else { return selection.modelID }
        return "\(selection.providerID)/\(selection.modelID)"
    }
}


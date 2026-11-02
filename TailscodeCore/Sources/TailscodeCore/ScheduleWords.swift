import CodingAgentKit
import Foundation

/// Every sentence a client shows about a schedule, so three clients say the same thing about it.
public enum ScheduleWords {
    public static var title: String { Localized.text("Scheduled") }
    public static var askLater: String { Localized.text("Ask later") }
    public static var askLaterMenu: String { Localized.text("Ask later…") }
    public static var askAgain: String { Localized.text("Ask this again…") }
    public static var sayWhen: String { Localized.text("Or say when: weekdays 7:30, every 2 hours, fri 17:00") }
    public static var notUnderstood: String {
        Localized.text("That time was not understood. Try \u{201C}weekdays 7:30\u{201D} or \u{201C}in 20 min\u{201D}.")
    }
    public static var oneConversation: String { Localized.text("One conversation") }
    public static var oneConversationDetail: String { Localized.text("Each run sees what it said last time.") }
    public static var quiet: String { Localized.text("Quiet when nothing changed") }
    public static var quietDetail: String { Localized.text("No ping, not unread. Failures always speak.") }
    public static var runNow: String { Localized.text("Run now") }
    public static var pause: String { Localized.text("Pause") }
    public static var resume: String { Localized.text("Resume") }
    public static var delete: String { Localized.text("Delete schedule") }
    public static var deleteDetail: String { Localized.text("Its conversations stay.") }
    public static var history: String { Localized.text("History") }
    public static var noHistory: String { Localized.text("Nothing has been asked yet.") }
    public static var empty: String { Localized.text("Nothing is scheduled") }
    public static var emptyDetail: String {
        Localized.text("Hold Send to ask later, or open any message you sent and choose Ask this again. The machine asks, whether or not this device is on.")
    }
    public static var openConversation: String { Localized.text("Open conversation") }
    public static var paused: String { Localized.text("Paused") }
    public static var done: String { Localized.text("Done") }

    /// Who does the asking, said where a schedule is made.
    public static func reach(_ machine: String) -> String {
        Localized.text("Asked by %@, whether or not this device is on.", machine)
    }

    /// For a machine that keeps no schedules: opencode runs turns but has no clock of its own.
    public static func cannotKeep(_ machine: String) -> String {
        Localized.text("%@ cannot keep a schedule. Schedules need a machine running claude-bridge or omp-bridge.", machine)
    }

    public static var limit: String { Localized.text("A machine keeps up to 50 schedules.") }

    /// When a rule asks, the way a list row says it: "Weekdays 07:30", "Every Monday 09:00",
    /// "Every 6 hours", "Tonight 21:00", "Tue 4 Nov 07:30".
    public static func when(_ rule: ScheduleRule, calendar: Calendar = .current, now: Date = Date()) -> String {
        switch rule.kind {
        case .once:
            guard let at = rule.at else { return "" }
            return moment(at, calendar: calendar, now: now)
        case .daily:
            return Localized.text("Every day %@", clock(rule, calendar: calendar))
        case .weekdays:
            return Localized.text("Weekdays %@", clock(rule, calendar: calendar))
        case .weekly:
            return Localized.text(
                "Every %@ %@", weekday(rule.weekday ?? 2, calendar: calendar), clock(rule, calendar: calendar))
        case .hours:
            let every = rule.every ?? 1
            return every == 1 ? Localized.text("Every hour") : Localized.text("Every %d hours", every)
        }
    }

    /// What follows the first time, for the line under the phrase: "then every weekday".
    public static func then(_ rule: ScheduleRule, calendar: Calendar = .current) -> String? {
        switch rule.kind {
        case .once: return nil
        case .daily: return Localized.text("then every day")
        case .weekdays: return Localized.text("then every weekday")
        case .weekly: return Localized.text("then every %@", weekday(rule.weekday ?? 2, calendar: calendar))
        case .hours:
            let every = rule.every ?? 1
            return every == 1 ? Localized.text("then every hour") : Localized.text("then every %d hours", every)
        }
    }

    /// "Next: Tue 4 Nov 07:30".
    public static func next(_ date: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        Localized.text("Next: %@", moment(date, calendar: calendar, now: now))
    }

    /// The press that saves: "Ask every weekday at 07:30", "Ask tonight at 21:00".
    public static func confirm(_ understanding: ScheduleSpeech.Understanding, calendar: Calendar = .current, now: Date = Date())
        -> String
    {
        let rule = understanding.rule
        switch rule.kind {
        case .once:
            return Localized.text("Ask %@", lowered(moment(understanding.next, calendar: calendar, now: now)))
        case .daily: return Localized.text("Ask every day at %@", clock(rule, calendar: calendar))
        case .weekdays: return Localized.text("Ask every weekday at %@", clock(rule, calendar: calendar))
        case .weekly:
            return Localized.text(
                "Ask every %@ at %@", weekday(rule.weekday ?? 2, calendar: calendar), clock(rule, calendar: calendar))
        case .hours:
            let every = rule.every ?? 1
            return every == 1 ? Localized.text("Ask every hour") : Localized.text("Ask every %d hours", every)
        }
    }

    /// A moment said the shortest way that is still exact: a time today, "Tonight 21:00",
    /// "Tomorrow 08:00", a weekday this week, a date beyond.
    public static func moment(_ date: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        let time = timeText(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) {
            let hour = calendar.component(.hour, from: date)
            return hour >= 18 ? Localized.text("Tonight %@", time) : Localized.text("Today %@", time)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
            calendar.isDate(date, inSameDayAs: tomorrow)
        {
            return Localized.text("Tomorrow %@", time)
        }
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = Locale.current
        format.setLocalizedDateFormatFromTemplate("EEE d MMM j:mm")
        return format.string(from: date)
    }

    static func lowered(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        return first.lowercased() + text.dropFirst()
    }

    static func clock(_ rule: ScheduleRule, calendar: Calendar) -> String {
        var components = DateComponents()
        components.hour = rule.hour ?? 0
        components.minute = rule.minute ?? 0
        let date = calendar.date(from: components) ?? Date()
        return timeText(date, calendar: calendar)
    }

    static func timeText(_ date: Date, calendar: Calendar) -> String {
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = Locale.current
        format.dateStyle = .none
        format.timeStyle = .short
        return format.string(from: date)
    }

    static func weekday(_ index: Int, calendar: Calendar) -> String {
        let names = calendar.standaloneWeekdaySymbols
        return names.indices.contains(index - 1) ? names[index - 1] : ""
    }

    /// How one run went, as a history row says it.
    public static func run(_ run: ScheduleRun, machine: String, calendar: Calendar = .current, now: Date = Date())
        -> (title: String, detail: String?, mark: ScheduleMark)
    {
        let when = moment(run.startedAt ?? run.scheduledFor, calendar: calendar, now: now)
        switch run.outcome {
        case .running:
            return (Localized.text("Asking"), when, .running)
        case .answered:
            return (Localized.text("Answered"), when, .answered)
        case .quiet:
            return (Localized.text("Quiet"), Localized.text("nothing new · %@", when), .quiet)
        case .failed:
            return (Localized.text("Failed"), failure(run.failure, machine: machine, when: when), .failed)
        case .missed:
            let detail: String
            if run.failure == "busy" {
                detail = Localized.text("the last run was still going · %@", when)
            } else if run.missed > 1 {
                detail = Localized.text("%@ was off · missed %d times", machine, run.missed)
            } else {
                detail = Localized.text("%@ was off · %@", machine, when)
            }
            return (Localized.text("Missed"), detail, .missed)
        case .caughtUp:
            let late = timeText(run.startedAt ?? run.scheduledFor, calendar: calendar)
            let owed = timeText(run.scheduledFor, calendar: calendar)
            let title = Localized.text("Caught up at %@", late)
            let missed = run.missed > 1
                ? Localized.text("missed %d times while %@ was off", run.missed, machine)
                : Localized.text("missed %@ while %@ was off", owed, machine)
            switch run.ending {
            case .failed?: return (title, missed + " · " + Localized.text("then failed"), .failed)
            case .quiet?: return (title, missed + " · " + Localized.text("nothing new"), .quiet)
            default: return (title, missed, .caughtUp)
            }
        }
    }

    private static func failure(_ text: String?, machine: String, when: String) -> String {
        guard let text, !text.isEmpty else { return when }
        if text == "stopped" { return Localized.text("stopped · %@", when) }
        return Localized.text("%@ said: %@", machine, text)
    }
}

/// The mark a schedule's last run leaves on its row and on each history row: a meaning, which each
/// client draws in its own colours.
public enum ScheduleMark: String, Sendable, Hashable {
    case running, answered, quiet, failed, missed, caughtUp, waiting, paused, done

    /// The SF Symbol for the clients that draw them.
    public var symbol: String {
        switch self {
        case .running: return "ellipsis.circle"
        case .answered: return "checkmark.circle.fill"
        case .quiet: return "circle"
        case .failed: return "exclamationmark.circle.fill"
        case .missed: return "moon.zzz"
        case .caughtUp: return "clock.arrow.circlepath"
        case .waiting: return "clock"
        case .paused: return "pause.circle"
        case .done: return "checkmark"
        }
    }

    /// The same meaning as one character, for the client that draws text.
    public var glyph: String {
        switch self {
        case .running: return "…"
        case .answered: return "●"
        case .quiet: return "○"
        case .failed: return "!"
        case .missed: return "◌"
        case .caughtUp: return "◐"
        case .waiting: return "◷"
        case .paused: return "‖"
        case .done: return "✓"
        }
    }

    /// Whether the mark asks for attention: a failure does, nothing else.
    public var isAlarm: Bool { self == .failed }
}

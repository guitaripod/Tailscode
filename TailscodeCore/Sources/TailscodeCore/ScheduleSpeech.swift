import CodingAgentKit
import Foundation

/// When a typed phrase says to ask: "weekdays 7:30", "every 2 hours", "fri 17:00", "in 20 min",
/// "every morning at 6", "tonight", "tomorrow 9am". Read in English and in the device's own weekday
/// names and clock, and always answered with a rule the machine keeps and the first moment it will
/// ask — or with nothing, so a phrase that was not understood is said to be so rather than guessed.
public enum ScheduleSpeech {
    public struct Understanding: Sendable, Equatable {
        public let rule: ScheduleRule
        public let next: Date
    }

    public static let morningHour = QuickAskLaterChoice.morningHour
    public static let eveningHour = QuickAskLaterChoice.eveningHour

    public static func read(_ phrase: String, now: Date = Date(), calendar: Calendar = .current)
        -> Understanding?
    {
        let words = tokens(phrase)
        guard !words.isEmpty, let rule = rule(words, now: now, calendar: calendar),
            let next = rule.next(after: now, calendar: calendar)
        else { return nil }
        return Understanding(rule: rule, next: next)
    }

    static func tokens(_ phrase: String) -> [String] {
        var text = phrase.lowercased()
        for (from, to) in [("a.m.", "am"), ("p.m.", "pm"), (",", " "), ("@", " at ")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        var words: [String] = []
        for raw in text.split(whereSeparator: \.isWhitespace) {
            var word = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            if word.hasSuffix("am") || word.hasSuffix("pm"), word.count > 2,
                word.dropLast(2).allSatisfy({ $0.isNumber || $0 == ":" || $0 == "." })
            {
                words.append(String(word.dropLast(2)))
                word = String(word.suffix(2))
            }
            if word == "each" { word = "every" }
            if !word.isEmpty { words.append(word) }
        }
        return words.filter { !["the", "on", "please", "and"].contains($0) }
    }

    private static func rule(_ words: [String], now: Date, calendar: Calendar) -> ScheduleRule? {
        if let relative = relative(words, now: now, calendar: calendar) { return relative }
        let clock = time(in: words)
        let joined = " " + words.joined(separator: " ") + " "
        let repeating =
            words.contains("every") || words.contains("daily") || words.contains("weekdays")
            || words.contains("weekday") || words.contains("workdays") || words.contains("hourly")
            || words.contains { plural($0) != nil }
        if let hours = everyHours(words) {
            let anchor = (calendar.component(.hour, from: now) + 1) % 24
            return ScheduleRule(kind: .hours, hour: anchor, minute: 0, every: hours)
        }
        if words.contains("weekdays") || words.contains("weekday") || words.contains("workdays")
            || joined.contains(" work day")
        {
            let at = clock ?? (morningHour, 0)
            return ScheduleRule(kind: .weekdays, hour: at.0, minute: at.1)
        }
        if let day = weekday(in: words, calendar: calendar) {
            let at = clock ?? (morningHour, 0)
            if repeating {
                return ScheduleRule(kind: .weekly, hour: at.0, minute: at.1, weekday: day)
            }
            return once(onWeekday: day, at: at, now: now, calendar: calendar)
        }
        let partOfDay = self.partOfDay(words)
        if repeating {
            let at = clock ?? (partOfDay ?? morningHour, 0)
            return ScheduleRule(kind: .daily, hour: at.0, minute: at.1)
        }
        if words.contains("tonight") {
            let at = clock.map { $0.0 < 12 ? ($0.0 + 12, $0.1) : $0 } ?? (eveningHour, 0)
            return once(dayOffset: 0, at: at, now: now, calendar: calendar, rollPast: true)
        }
        if words.contains("tomorrow") || words.contains("tmrw") || words.contains("tmr") {
            let at = clock ?? (partOfDay ?? morningHour, 0)
            return once(dayOffset: 1, at: at, now: now, calendar: calendar, rollPast: false)
        }
        if let partOfDay, clock == nil {
            return once(dayOffset: 0, at: (partOfDay, 0), now: now, calendar: calendar, rollPast: true)
        }
        if let clock {
            return once(dayOffset: 0, at: clock, now: now, calendar: calendar, rollPast: true)
        }
        return nil
    }

    /// "in 20 min", "in an hour", "in 2 days", "in half an hour".
    private static func relative(_ words: [String], now: Date, calendar: Calendar) -> ScheduleRule? {
        guard let start = words.firstIndex(of: "in"), start + 1 < words.count else { return nil }
        var index = start + 1
        var amount: Double
        if words[index] == "half", index + 2 < words.count, words[index + 1] == "an" || words[index + 1] == "a" {
            amount = 0.5
            index += 2
        } else if words[index] == "an" || words[index] == "a" {
            amount = 1
            index += 1
        } else if let value = Double(words[index]) {
            amount = value
            index += 1
        } else if let glued = gluedAmount(words[index]) {
            return ScheduleRule.once(now.addingTimeInterval(glued))
        } else {
            return nil
        }
        guard index < words.count, let unit = seconds(of: words[index]) else { return nil }
        let interval = amount * unit
        guard interval >= 60, interval <= 60 * 24 * 3_600 else { return nil }
        return ScheduleRule.once(now.addingTimeInterval(interval).rounded(to: 60, calendar: calendar))
    }

    /// "20m", "2h", "3d".
    private static func gluedAmount(_ word: String) -> TimeInterval? {
        guard let last = word.last, let value = Double(word.dropLast()) else { return nil }
        switch last {
        case "m": return value * 60
        case "h": return value * 3_600
        case "d": return value * 86_400
        default: return nil
        }
    }

    private static func seconds(of unit: String) -> TimeInterval? {
        switch unit {
        case "min", "mins", "minute", "minutes", "m": return 60
        case "hour", "hours", "hr", "hrs", "h": return 3_600
        case "day", "days", "d": return 86_400
        case "week", "weeks", "w": return 7 * 86_400
        default: return nil
        }
    }

    /// "every 2 hours", "every hour", "hourly", "every 6h".
    private static func everyHours(_ words: [String]) -> Int? {
        if words.contains("hourly") { return 1 }
        guard let every = words.firstIndex(of: "every"), every + 1 < words.count else { return nil }
        let next = words[every + 1]
        if next == "hour" || next == "hr" { return 1 }
        if let glued = gluedAmount(next), glued.truncatingRemainder(dividingBy: 3_600) == 0, glued >= 3_600,
            next.hasSuffix("h")
        {
            return Int(glued / 3_600)
        }
        guard let value = Int(next), every + 2 < words.count,
            ["hours", "hour", "hrs", "hr", "h"].contains(words[every + 2]),
            (1...24).contains(value)
        else { return nil }
        return value
    }

    private static func partOfDay(_ words: [String]) -> Int? {
        if words.contains("morning") || words.contains("mornings") { return morningHour }
        if words.contains("noon") || words.contains("midday") || words.contains("lunch") { return 12 }
        if words.contains("afternoon") || words.contains("afternoons") { return 15 }
        if words.contains("evening") || words.contains("evenings") || words.contains("night")
            || words.contains("nights")
        {
            return eveningHour
        }
        if words.contains("midnight") { return 0 }
        return nil
    }

    /// The clock a phrase names: "7", "7:30", "07.30", "1930", "7 pm", "noon".
    static func time(in words: [String]) -> (Int, Int)? {
        for (index, word) in words.enumerated() {
            if word == "noon" || word == "midday" { return (12, 0) }
            if word == "midnight" { return (0, 0) }
            guard let parsed = clock(word) else { continue }
            let suffix = index + 1 < words.count ? words[index + 1] : ""
            if index > 0, ["in", "every"].contains(words[index - 1]) { continue }
            if index + 1 < words.count,
                seconds(of: suffix) != nil || ["hours", "hour"].contains(suffix)
            {
                continue
            }
            var hour = parsed.0
            if suffix == "pm", hour < 12 { hour += 12 }
            if suffix == "am", hour == 12 { hour = 0 }
            guard (0...23).contains(hour), (0...59).contains(parsed.1) else { continue }
            let named = word.contains(":") || word.contains(".") || word.count == 4
                || suffix == "am" || suffix == "pm"
                || (index > 0 && words[index - 1] == "at")
                || words.count == 1 || index == words.count - 1
            guard named else { continue }
            return (hour, parsed.1)
        }
        return nil
    }

    private static func clock(_ word: String) -> (Int, Int)? {
        let separators = CharacterSet(charactersIn: ":.h")
        let parts = word.components(separatedBy: separators).filter { !$0.isEmpty }
        if parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), parts[1].count == 2 {
            return (hour, minute)
        }
        guard parts.count == 1, word.allSatisfy(\.isNumber), let value = Int(word) else { return nil }
        if word.count == 4 { return (value / 100, value % 100) }
        if word.count <= 2 { return (value, 0) }
        return nil
    }

    /// The weekday a phrase names, in English or in the device's own words, 1 being Sunday.
    private static func weekday(in words: [String], calendar: Calendar) -> Int? {
        for word in words {
            if let day = plural(word) ?? singular(word, calendar: calendar) { return day }
        }
        return nil
    }

    private static let english = [
        ["sunday", "sun"], ["monday", "mon"], ["tuesday", "tue", "tues"], ["wednesday", "wed"],
        ["thursday", "thu", "thurs"], ["friday", "fri"], ["saturday", "sat"],
    ]

    /// "mondays" — a weekday said as a habit, which makes the phrase repeat.
    private static func plural(_ word: String) -> Int? {
        guard word.hasSuffix("s"), word.count > 4 else { return nil }
        let stem = String(word.dropLast())
        return english.firstIndex { $0.first == stem }.map { $0 + 1 }
    }

    private static func singular(_ word: String, calendar: Calendar) -> Int? {
        if let index = english.firstIndex(where: { $0.contains(word) }) { return index + 1 }
        let local = calendar.weekdaySymbols.map { $0.lowercased() }
        if let index = local.firstIndex(of: word) { return index + 1 }
        let short = calendar.shortWeekdaySymbols.map {
            $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        if let index = short.firstIndex(of: word) { return index + 1 }
        return nil
    }

    private static func once(
        dayOffset: Int, at: (Int, Int), now: Date, calendar: Calendar, rollPast: Bool
    ) -> ScheduleRule? {
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)),
            var moment = calendar.date(bySettingHour: at.0, minute: at.1, second: 0, of: day)
        else { return nil }
        if moment <= now {
            guard rollPast, let tomorrow = calendar.date(byAdding: .day, value: 1, to: moment) else {
                return nil
            }
            moment = tomorrow
        }
        return .once(moment)
    }

    private static func once(onWeekday weekday: Int, at: (Int, Int), now: Date, calendar: Calendar)
        -> ScheduleRule?
    {
        let probe = ScheduleRule(kind: .weekly, hour: at.0, minute: at.1, weekday: weekday)
        return probe.next(after: now, calendar: calendar).map(ScheduleRule.once)
    }
}

extension Date {
    /// The next whole `step` seconds at or after this moment, so "in 20 min" asked at 09:41:17
    /// asks at 10:02 rather than at a time nobody would say.
    func rounded(to step: TimeInterval, calendar: Calendar) -> Date {
        let seconds = timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / step).rounded(.up) * step)
    }
}

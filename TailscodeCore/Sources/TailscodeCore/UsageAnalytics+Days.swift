import CodingAgentKit
import Foundation

extension UsageAnalytics {
    static func add(
        _ lhs: SessionSpendReport.Tokens, _ rhs: SessionSpendReport.Tokens
    ) -> SessionSpendReport.Tokens {
        SessionSpendReport.Tokens(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h)
    }

    /// The busiest day is left out here on purpose: it is recomputed from the merged day
    /// buckets, because the peak of one machine is not the peak of the account.
    static func merge(
        _ lhs: UsageAnalyticsReport.Records, _ rhs: UsageAnalyticsReport.Records
    ) -> UsageAnalyticsReport.Records {
        UsageAnalyticsReport.Records(
            busiestDay: nil,
            priciestSession: [lhs.priciestSession, rhs.priciestSession].compactMap { $0 }
                .max { $0.costUSD < $1.costUSD },
            priciestTurn: [lhs.priciestTurn, rhs.priciestTurn].compactMap { $0 }
                .max { $0.costUSD < $1.costUSD },
            longestTurn: [lhs.longestTurn, rhs.longestTurn].compactMap { $0 }
                .max { ($0.seconds ?? 0) < ($1.seconds ?? 0) },
            streakDays: max(lhs.streakDays, rhs.streakDays))
    }

    static func dayFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// One bar's worth of days, with the words that name it. A day names itself by weekday and
    /// date with its month — thirty days always straddle two, and a `Sun 9` is one of two Sundays
    /// — a week by the dates it spans, a month by its own name; a reader should never have to
    /// work out what a column is from how many there are.
    struct Group {
        let key: String
        let title: String
        let days: [String]
        let holdsToday: Bool
    }

    static func group(
        days: [String], grain: UsageWindow.Grain, now: Date, calendar: Calendar
    ) -> [Group] {
        let formatter = dayFormatter(calendar)
        let todayKey = formatter.string(from: now)
        guard grain != .day else {
            let display = DateFormatter()
            display.calendar = calendar
            display.timeZone = calendar.timeZone
            display.dateFormat = "MMM d"
            return days.map { key in
                let date = formatter.date(from: key)
                let title =
                    date.map { "\(weekdayName($0, calendar: calendar)) \(display.string(from: $0))" }
                    ?? key
                return Group(key: key, title: title, days: [key], holdsToday: key == todayKey)
            }
        }
        let component: Calendar.Component = grain == .week ? .weekOfYear : .month
        var order: [String] = []
        var members: [String: [String]] = [:]
        var starts: [String: Date] = [:]
        for key in days {
            guard let date = formatter.date(from: key),
                let interval = calendar.dateInterval(of: component, for: date)
            else { continue }
            let bucket = formatter.string(from: interval.start)
            if members[bucket] == nil {
                order.append(bucket)
                starts[bucket] = interval.start
            }
            members[bucket, default: []].append(key)
        }
        return order.map { bucket in
            let held = members[bucket] ?? []
            return Group(
                key: bucket,
                title: title(
                    grain: grain, start: starts[bucket], days: held, calendar: calendar),
                days: held, holdsToday: held.contains(todayKey))
        }
    }

    private static func title(
        grain: UsageWindow.Grain, start: Date?, days: [String], calendar: Calendar
    ) -> String {
        let formatter = dayFormatter(calendar)
        let display = DateFormatter()
        display.calendar = calendar
        display.timeZone = calendar.timeZone
        guard grain == .week else {
            display.dateFormat = "LLLL"
            return start.map(display.string(from:)) ?? days.first ?? ""
        }
        display.dateFormat = "MMM d"
        // A week that the window only partly holds is named by the days it actually covers, not by
        // the calendar week it belongs to: a bar cannot claim a Monday nobody counted.
        guard let first = days.first.flatMap(formatter.date(from:)),
            let last = days.last.flatMap(formatter.date(from:))
        else { return start.map(display.string(from:)) ?? "" }
        guard first != last else { return display.string(from: first) }
        let tail = DateFormatter()
        tail.calendar = calendar
        tail.timeZone = calendar.timeZone
        tail.dateFormat =
            calendar.component(.month, from: first) == calendar.component(.month, from: last)
            ? "d" : "MMM d"
        return "\(display.string(from: first))–\(tail.string(from: last))"
    }

    static func windowKeys(window: Int, now: Date, calendar: Calendar) -> [String] {
        let formatter = dayFormatter(calendar)
        let today = calendar.startOfDay(for: now)
        return (0..<window).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map(formatter.string(from:))
        }
    }

    private static func weekdayName(_ date: Date, calendar: Calendar) -> String {
        let index = calendar.component(.weekday, from: date) - 1
        let symbols = calendar.shortWeekdaySymbols
        guard symbols.indices.contains(index) else { return "" }
        return symbols[index]
    }

    /// Monday first regardless of locale: the chart reads as a work week, and the weekend
    /// belongs together at its end.
    static func weekdayInitials(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { index in
            let weekdayIndex = (index + 1) % 7
            return symbols.indices.contains(weekdayIndex) ? symbols[weekdayIndex] : ""
        }
    }

    static func perDay(rate: String, activeDays: Int, today: String?) -> String? {
        guard activeDays > 0 else { return nil }
        var line =
            activeDays == 1
            ? Localized.text("%@ a day, over 1 active day", rate)
            : Localized.text("%@ a day, over %d active days", rate, activeDays)
        if let today { line += Localized.text(" · today %@", today) }
        return line
    }

    static func weekdayMeters(
        dayCost: [String: Double], dayTokens: [String: Int], priced: Bool, prefix: String,
        calendar: Calendar
    ) -> [Meter] {
        let formatter = dayFormatter(calendar)
        var weight = [Double](repeating: 0, count: 7)
        var cost = [Double](repeating: 0, count: 7)
        var tokens = [Int](repeating: 0, count: 7)
        // Always from the days themselves, never from the bars: a quarter drawn as thirteen weekly
        // columns still has a Tuesday in it, and folding a week's bar into one weekday would put
        // the whole quarter on whichever day each bar happened to start.
        for key in Set(dayCost.keys).union(dayTokens.keys) {
            guard let date = formatter.date(from: key) else { continue }
            let index = (calendar.component(.weekday, from: date) + 5) % 7
            cost[index] += dayCost[key] ?? 0
            tokens[index] += dayTokens[key] ?? 0
            weight[index] += priced ? (dayCost[key] ?? 0) : Double(dayTokens[key] ?? 0)
        }
        let peak = weight.max() ?? 0
        let symbols = calendar.shortWeekdaySymbols
        return (0..<7).map { index in
            let weekdayIndex = (index + 1) % 7
            let label = symbols.indices.contains(weekdayIndex) ? symbols[weekdayIndex] : ""
            return Meter(
                label: label, detail: "",
                money: priced
                    ? prefix + SessionSpend.money(cost[index])
                    : StatusFacts.tokens(tokens[index]),
                share: peak > 0 ? weight[index] / peak : 0)
        }
    }

    /// The most recent quarter of the window against the quarter before it, with a deadband so
    /// ordinary noise reads as steady. It is measured on the days rather than the bars, so the
    /// comparison is the same length of time whatever grain the chart happens to be drawn at, and
    /// it is named in days so a quarter's trend never claims to be a week's.
    static func delta(
        days: [String], dayCost: [String: Double], dayTokens: [String: Int], priced: Bool,
        window: UsageWindow
    ) -> (String?, Trend) {
        let span = min(window.trendSpan, days.count / 2)
        guard span >= 2 else { return (nil, .flat) }
        let weigh = { (keys: ArraySlice<String>) -> Double in
            keys.reduce(0) { $0 + (priced ? (dayCost[$1] ?? 0) : Double(dayTokens[$1] ?? 0)) }
        }
        let recent = weigh(days.suffix(span))
        let before = weigh(days.dropLast(span).suffix(span))
        guard before > 0 else {
            return recent > 0
                ? (Localized.text("All of it in the last %d days", span), .up) : (nil, .flat)
        }
        let change = (recent - before) / before
        let percent = Int((abs(change) * 100).rounded())
        if abs(change) < 0.05 {
            return (Localized.text("Steady over the last %d days", span), .flat)
        }
        if change > 0 {
            return (Localized.text("Up %d%% on the %d days before", percent, span), .up)
        }
        return (Localized.text("Down %d%% on the %d days before", percent, span), .down)
    }

    static func weekendTurns(dayTurns: [String: Int], calendar: Calendar) -> Int {
        let formatter = dayFormatter(calendar)
        return dayTurns.reduce(0) { sum, entry in
            guard let date = formatter.date(from: entry.key), calendar.isDateInWeekend(date)
            else { return sum }
            return sum + entry.value
        }
    }

    static func streak(days: Set<String>, calendar: Calendar) -> Int {
        let formatter = dayFormatter(calendar)
        guard let latest = days.max(), var cursor = formatter.date(from: latest) else { return 0 }
        var run = 0
        while days.contains(formatter.string(from: cursor)) {
            run += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                break
            }
            cursor = previous
        }
        return run
    }
}

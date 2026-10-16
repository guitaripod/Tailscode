import CodingAgentKit
import Foundation

/// The sheet behind the chip, as data: one day laid out as a line, a lane for every place the
/// person watches, a moment they can move along it, and everything that moment means — what the
/// clocks say, who is awake, what to copy, what to be told about. A client draws the lanes and
/// the line and decides nothing else, so the two desks cannot disagree about a time.
///
/// The axis is the viewer's own local day, in real minutes. A day with a clock change in it has
/// 23 or 25 hours of them, and a lane in another zone is placed by the instants it covers rather
/// than by its own midnight, which is the whole reason a lane can start in the middle of the
/// axis: Tokyo's morning is the viewer's previous evening.
public struct MeridianBoard: Sendable, Equatable {
    public struct Mark: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable {
            case reset
            case alarm
        }

        public let id: String
        public let kind: Kind
        public let position: Double
        public let label: String
        public let instant: Date
    }

    public struct Lane: Sendable, Equatable, Identifiable {
        public enum Role: String, Sendable {
            case viewer
            case city
        }

        public let id: String
        public let role: Role
        public let name: String
        public let subtitle: String
        public let time: String
        public let dayWord: String
        public let isUp: Bool?
        public let bar: DaylightBar
        public let marks: [Mark]

        public var isRemovable: Bool { role == .city }
    }

    public struct Tick: Sendable, Equatable {
        public let position: Double
        public let label: String
    }

    public struct Copy: Sendable, Equatable {
        public let iso: String
        public let utc: String
        public let epoch: String
    }

    public struct Golden: Sendable, Equatable {
        public let start: Double
        public let end: Double
        public let label: String
    }

    public struct AlarmRow: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String
    }

    public let axis: DayAxis
    public let minutes: Int
    public let scrubMinute: Int
    public let nowMinute: Int
    public let isFollowingNow: Bool
    public let scrubInstant: Date
    public let head: String
    public let delta: String
    public let linePosition: Double
    public let nowPosition: Double
    public let dateLine: String
    public let ticks: [Tick]
    public let lanes: [Lane]
    public let golden: Golden?
    public let insight: String?
    public let copy: Copy
    public let notifyLabel: String
    public let canNotify: Bool
    public let alarms: [AlarmRow]
    public let machines: [MachineClockReading]
    public let skewWarning: String?
    public let style: ClockStyle

    public static func make(
        now: Date, scrubMinute: Int? = nil, preferences: WorldClockPreferences = .default,
        viewer: TimeZone = .current, machines: [MachineClock] = [],
        holdings: [QuotaHolding] = [], alarms book: ClockAlarmBook = ClockAlarmBook(),
        locale: Locale = .current
    ) -> MeridianBoard {
        let style = preferences.style
        let axis = DayAxis(zone: viewer, containing: now)
        let nowMinute = axis.minute(of: now)
        let scrub = min(max(scrubMinute ?? nowMinute, 0), axis.minutes - 1)
        let instant = axis.instant(atMinute: scrub)
        let home = WorldCities.home(for: viewer)
        let resets = ClockResets.upcoming(holdings: holdings, now: now, limit: 4)
            .filter { axis.contains($0.instant) }

        var marks: [Mark] = resets.map { reset in
            Mark(
                id: "reset.\(reset.id)", kind: .reset, position: axis.fraction(of: reset.instant),
                label: String(
                    format: Localized.text("%@ resets %@"), reset.provider,
                    ClockFormat.time(reset.instant, in: viewer, style: style)),
                instant: reset.instant)
        }
        for alarm in book.alarms where axis.contains(alarm.fireAt) {
            marks.append(
                Mark(
                    id: "alarm.\(alarm.id)", kind: .alarm, position: axis.fraction(of: alarm.fireAt),
                    label: ClockFormat.time(alarm.fireAt, in: viewer, style: style),
                    instant: alarm.fireAt))
        }

        var lanes = [
            lane(
                for: home, role: .viewer, axis: axis, instant: instant, viewer: viewer,
                style: style, marks: marks)
        ]
        let pinned = preferences.cities
        for city in pinned {
            lanes.append(
                lane(
                    for: city, role: .city, axis: axis, instant: instant, viewer: viewer,
                    style: style, marks: []))
        }

        let people = ([home] + pinned).filter { $0.hasSun }
        let golden = goldenWindow(people: people, axis: axis, style: style)
        let insight = insightLine(
            home: home, others: pinned.filter { $0.hasSun }, axis: axis, golden: golden,
            style: style)
        let machineReadings = MachineClocks.readings(
            machines, now: now, viewer: viewer, style: style)
        let head = ClockFormat.time(instant, in: viewer, style: style)
        let isNow = scrub == nowMinute
        let canNotify = instant > now

        return MeridianBoard(
            axis: axis, minutes: axis.minutes, scrubMinute: scrub, nowMinute: nowMinute,
            isFollowingNow: scrubMinute == nil || isNow, scrubInstant: instant, head: head,
            delta: deltaWords(minutes: scrub - nowMinute),
            linePosition: axis.fraction(of: instant), nowPosition: axis.fraction(of: now),
            dateLine: ClockFormat.dateLine(instant, in: viewer, locale: locale),
            ticks: ticks(axis: axis), lanes: lanes, golden: golden, insight: insight,
            copy: Copy(
                iso: ClockFormat.isoString(instant, in: viewer),
                utc: ClockFormat.utcString(instant),
                epoch: String(Int(instant.timeIntervalSince1970))),
            notifyLabel: String(format: Localized.text("Notify me at %@"), head),
            canNotify: canNotify,
            alarms: book.alarms.map { alarm in
                AlarmRow(
                    id: alarm.id,
                    title: ClockFormat.time(alarm.fireAt, in: alarm.timeZone, style: style),
                    detail: alarm.note
                        ?? ClockFormat.dayWord(alarm.fireAt, in: alarm.timeZone, relativeTo: viewer))
            },
            machines: machineReadings, skewWarning: MachineClocks.warning(for: machineReadings),
            style: style)
    }

    /// The minute the person means by a position along the line, 0...1, so a click or drag on the
    /// track needs no arithmetic of its own.
    public func minute(atFraction fraction: Double) -> Int {
        min(max(Int((fraction * Double(minutes)).rounded()), 0), minutes - 1)
    }

    public func instant(atMinute minute: Int) -> Date { axis.instant(atMinute: minute) }

    private static func lane(
        for city: WorldCity, role: Lane.Role, axis: DayAxis, instant: Date, viewer: TimeZone,
        style: ClockStyle, marks: [Mark]
    ) -> Lane {
        let zone = city.timeZone ?? .gmt
        let bar = Daylight.bar(for: city, on: axis)
        let fraction = axis.fraction(of: instant)
        let utc = ClockFormat.utc(zone.secondsFromGMT(for: instant))
        let subtitle: String
        switch role {
        case .viewer: subtitle = "\(Localized.text("You")) \u{00B7} \(utc)"
        case .city:
            let country = city.country.isEmpty ? Localized.text("Universal time") : city.country
            subtitle = "\(country) \u{00B7} \(utc)"
        }
        return Lane(
            id: role == .viewer ? "you" : city.id, role: role, name: city.name,
            subtitle: subtitle, time: ClockFormat.time(instant, in: zone, style: style),
            dayWord: ClockFormat.dayWord(instant, in: zone, relativeTo: viewer),
            isUp: bar.hasSun ? bar.isUp(at: fraction) : nil, bar: bar, marks: marks)
    }

    private static func ticks(axis: DayAxis) -> [Tick] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = axis.zone
        var result: [Tick] = []
        for hour in stride(from: 0, to: 24, by: 3) {
            guard let instant = calendar.date(
                bySettingHour: hour, minute: 0, second: 0, of: axis.start)
            else { continue }
            result.append(
                Tick(position: axis.fraction(of: instant), label: String(format: "%02d", hour)))
        }
        result.append(Tick(position: 1, label: "24"))
        return result
    }

    private static func deltaWords(minutes: Int) -> String {
        guard minutes != 0 else { return Localized.text("Right now") }
        let span = ClockFormat.span(Double(abs(minutes) * 60))
        return minutes > 0
            ? String(format: Localized.text("In %@"), span)
            : String(format: Localized.text("%@ ago"), span)
    }

    private static func goldenWindow(people: [WorldCity], axis: DayAxis, style: ClockStyle)
        -> Golden?
    {
        guard people.count > 1 else { return nil }
        var common: [DateInterval]?
        for person in people {
            let hours = Awake.intervals(in: person.timeZone ?? .gmt, within: axis)
            common = common.map { Awake.overlap($0, hours) } ?? hours
        }
        guard let best = common?.max(by: { $0.duration < $1.duration }), best.duration >= 1_800
        else { return nil }
        return Golden(
            start: axis.fraction(of: best.start), end: axis.fraction(of: best.end),
            label: ClockFormat.range(best, in: axis.zone, style: style))
    }

    private static func insightLine(
        home: WorldCity, others: [WorldCity], axis: DayAxis, golden: Golden?, style: ClockStyle
    ) -> String? {
        guard !others.isEmpty else { return nil }
        let mine = Awake.intervals(in: axis.zone, within: axis)
        var parts: [String] = []
        for city in others {
            let windows = Awake.overlap(mine, Awake.intervals(in: city.timeZone ?? .gmt, within: axis))
                .filter { $0.duration >= 1_800 }
            if windows.isEmpty {
                parts.append(String(format: Localized.text("%@ is asleep when you are awake"), city.name))
            } else {
                let text = windows.map { ClockFormat.range($0, in: axis.zone, style: style) }
                    .joined(separator: " \(Localized.text("and")) ")
                parts.append("\(city.name) \(text)")
            }
        }
        let overlap = String(
            format: Localized.text("Awake with you: %@."), parts.joined(separator: " \u{00B7} "))
        guard let golden else {
            return others.count > 1
                ? Localized.text("There is no hour today when everyone is awake.") + " " + overlap
                : overlap
        }
        return String(format: Localized.text("Everyone is awake %@."), golden.label) + " " + overlap
    }
}

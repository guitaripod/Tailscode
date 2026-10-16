import CodingAgentKit
import Foundation

/// How a time of day is written. `system` follows the locale, which is what a person who never
/// opened a setting expects; the other two are the choice of somebody who did.
public enum ClockStyle: String, Codable, Sendable, CaseIterable {
    case system
    case h24
    case h12

    public var is24Hour: Bool {
        switch self {
        case .h24: return true
        case .h12: return false
        case .system:
            let template = DateFormatter.dateFormat(
                fromTemplate: "j", options: 0, locale: Locale.current) ?? "HH"
            return !template.contains("a")
        }
    }

    public var title: String {
        switch self {
        case .system: return Localized.text("Follow system")
        case .h24: return Localized.text("24-hour")
        case .h12: return Localized.text("12-hour")
        }
    }
}

/// Every clock word in one place, so the chip, the glance and the sheet cannot spell the same
/// moment three ways.
public enum ClockFormat {
    public static func time(_ instant: Date, in zone: TimeZone, style: ClockStyle) -> String {
        let parts = components(instant, zone, [.hour, .minute])
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        if style.is24Hour { return String(format: "%02d:%02d", hour, minute) }
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        let meridiem = hour < 12 ? Localized.text("AM") : Localized.text("PM")
        return String(format: "%d:%02d %@", twelve, minute, meridiem)
    }

    public static func range(_ interval: DateInterval, in zone: TimeZone, style: ClockStyle)
        -> String
    {
        "\(time(interval.start, in: zone, style: style))\u{2013}\(time(interval.end, in: zone, style: style))"
    }

    /// `+6 h`, `\u{2212}10 h`, `+5 h 30 m`: how far a place is from here. A true minus sign, because
    /// a hyphen at 12 px reads as a dash between two numbers.
    public static func offset(_ seconds: Int) -> String {
        guard seconds != 0 else { return Localized.text("same time") }
        let sign = seconds > 0 ? "+" : "\u{2212}"
        let total = abs(seconds) / 60
        let hours = total / 60
        let minutes = total % 60
        return minutes == 0
            ? "\(sign)\(hours) h" : hours == 0 ? "\(sign)\(minutes) m" : "\(sign)\(hours) h \(minutes) m"
    }

    /// `UTC+3`, `UTC+5:30`, `UTC`.
    public static func utc(_ seconds: Int) -> String {
        guard seconds != 0 else { return "UTC" }
        let sign = seconds > 0 ? "+" : "\u{2212}"
        let total = abs(seconds) / 60
        let minutes = total % 60
        return minutes == 0
            ? "UTC\(sign)\(total / 60)" : "UTC\(sign)\(total / 60):\(String(format: "%02d", minutes))"
    }

    /// `2 h 45 m`, `12 m`, `1 d 3 h`: how long until something, in the two units that matter.
    public static func span(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 86_400 {
            let hours = (total % 86_400) / 3600
            return hours == 0 ? "\(total / 86_400) d" : "\(total / 86_400) d \(hours) h"
        }
        if total >= 3600 {
            let minutes = (total % 3600) / 60
            return minutes == 0 ? "\(total / 3600) h" : "\(total / 3600) h \(minutes) m"
        }
        if total >= 60 { return "\(total / 60) m" }
        return "\(total) s"
    }

    /// How far a clock is from true, to the second: `+8 s`, `47 s`.
    public static func skewSpan(_ seconds: TimeInterval) -> String {
        let total = Int(abs(seconds).rounded())
        if total >= 3600 { return span(Double(total)) }
        if total >= 60 {
            let remainder = total % 60
            return remainder == 0 ? "\(total / 60) m" : "\(total / 60) m \(remainder) s"
        }
        return "\(total) s"
    }

    public static func dayWord(_ instant: Date, in zone: TimeZone, relativeTo viewer: TimeZone)
        -> String
    {
        let delta = dayNumber(instant, zone) - dayNumber(instant, viewer)
        if delta < 0 { return Localized.text("yesterday") }
        if delta > 0 { return Localized.text("tomorrow") }
        return Localized.text("today")
    }

    public static func dateLine(_ instant: Date, in zone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter.string(from: instant)
    }

    public static func weekLine(_ instant: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = zone
        let week = calendar.component(.weekOfYear, from: instant)
        return String(format: Localized.text("Week %d"), week)
    }

    public static func isoString(_ instant: Date, in zone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: instant)
    }

    public static func utcString(_ instant: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
        return String(
            format: "%04d-%02d-%02d %02d:%02d UTC", parts.year ?? 0, parts.month ?? 0,
            parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }

    private static func components(_ instant: Date, _ zone: TimeZone, _ set: Set<Calendar.Component>)
        -> DateComponents
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateComponents(set, from: instant)
    }

    private static func dayNumber(_ instant: Date, _ zone: TimeZone) -> Int {
        let parts = components(instant, zone, [.year, .month, .day])
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let date = utc.date(from: parts) ?? instant
        return Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }
}

/// The cities the person pinned, in the order they put them, and how they like the time written.
/// The first row is always *here*, so the preferences hold only what was chosen.
public struct WorldClockPreferences: Codable, Sendable, Equatable {
    public var pins: [String]
    public var style: ClockStyle

    public init(pins: [String] = [], style: ClockStyle = .system) {
        self.pins = pins
        self.style = style
    }

    public static let `default` = WorldClockPreferences()

    public static let maxPins = 8

    public var cities: [WorldCity] { pins.compactMap(WorldCities.city) }

    public mutating func pin(_ id: String) {
        guard WorldCities.city(id) != nil, !pins.contains(id), pins.count < Self.maxPins else {
            return
        }
        pins.append(id)
    }

    public mutating func unpin(_ id: String) { pins.removeAll { $0 == id } }

    public mutating func move(_ id: String, by offset: Int) {
        guard let index = pins.firstIndex(of: id) else { return }
        let target = min(max(index + offset, 0), pins.count - 1)
        guard target != index else { return }
        pins.remove(at: index)
        pins.insert(id, at: target)
    }
}

public enum WorldClockStore {
    public static let defaultsKey = "tailscode.worldClock"
    public static let didChange = Notification.Name("tailscode.worldClock.didChange")

    public static var current: WorldClockPreferences {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
            let stored = try? JSONDecoder().decode(WorldClockPreferences.self, from: data)
        else { return .default }
        return stored
    }

    public static func save(_ preferences: WorldClockPreferences) {
        if preferences == .default {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func update(_ change: (inout WorldClockPreferences) -> Void) {
        var preferences = current
        change(&preferences)
        guard preferences != current else { return }
        save(preferences)
    }
}

public enum ClockTone: String, Sendable {
    case ok
    case warn
    case quiet
}

/// A machine and how far its clock is from this one, as measured by the Date header on its own
/// answers (`ServerClockLedger` in the Kit). Nil is a machine nobody has heard from yet.
public struct MachineClock: Sendable, Equatable {
    public let name: String
    public let skew: TimeInterval?

    public init(name: String, skew: TimeInterval?) {
        self.name = name
        self.skew = skew
    }
}

public struct MachineClockReading: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let status: String
    public let time: String?
    public let tone: ClockTone
    public let skew: TimeInterval?
}

public enum MachineClocks {
    /// Under this a clock is in sync: the Date header carries whole seconds and a request takes a
    /// moment, so a few seconds either way is the measurement and not the machine.
    public static let syncedWithin: TimeInterval = 3
    /// Past this a machine's clock is a fact worth a sentence, because it dates the chats it holds.
    public static let warnAt: TimeInterval = 15

    public static func readings(
        _ machines: [MachineClock], now: Date, viewer: TimeZone, style: ClockStyle
    ) -> [MachineClockReading] {
        machines.map { machine in
            guard let skew = machine.skew else {
                return MachineClockReading(
                    name: machine.name, status: Localized.text("no reading"), time: nil,
                    tone: .quiet, skew: nil)
            }
            let time = ClockFormat.time(now.addingTimeInterval(skew), in: viewer, style: style)
            let size = abs(skew)
            if size < syncedWithin {
                return MachineClockReading(
                    name: machine.name, status: Localized.text("in sync"), time: time, tone: .ok,
                    skew: skew)
            }
            if size < warnAt {
                let sign = skew > 0 ? "+" : "\u{2212}"
                return MachineClockReading(
                    name: machine.name, status: "\(sign)\(ClockFormat.skewSpan(skew))", time: time,
                    tone: .ok, skew: skew)
            }
            let status = String(
                format: Localized.text(skew < 0 ? "%@ behind" : "%@ ahead"),
                ClockFormat.skewSpan(skew))
            return MachineClockReading(
                name: machine.name, status: status, time: time, tone: .warn, skew: skew)
        }
    }

    /// What the ledger has learned about each server so far, from the answers the app already
    /// received. A server nothing has been heard from yet reads as no reading and not as in sync.
    public static func measured(
        _ servers: [(name: String, url: URL)], ledger: ServerClockLedger = .shared,
        now: Date = Date()
    ) -> [MachineClock] {
        servers.map { server in
            MachineClock(name: server.name, skew: ledger.reading(for: server.url, now: now)?.skew)
        }
    }

    /// The sentence under the machines when one of them is far enough off to matter. The cost is
    /// stated in terms of what the person will see: a clock behind dates a chat early and one ahead
    /// dates it in the future, and both reorder a list that sorts by time.
    public static func warning(for readings: [MachineClockReading]) -> String? {
        let off = readings.filter { $0.tone == .warn }
        guard let worst = off.max(by: { abs($0.skew ?? 0) < abs($1.skew ?? 0) }),
            let skew = worst.skew
        else { return nil }
        let lead = String(
            format: Localized.text(skew < 0 ? "%@ runs %@ behind." : "%@ runs %@ ahead."),
            worst.name, ClockFormat.skewSpan(skew))
        let cost = Localized.text(
            skew < 0
                ? "Chats dated by that machine will read early."
                : "Chats dated by that machine will read as if from the future.")
        guard off.count > 1 else { return "\(lead) \(cost)" }
        let others = String(format: Localized.text("%d more are off too."), off.count - 1)
        return "\(lead) \(others) \(cost)"
    }
}

/// A quota window about to reopen, which is the other reason to look at a clock: it is when the
/// next send unlocks.
public struct ClockReset: Sendable, Equatable, Identifiable {
    public let id: String
    public let provider: String
    public let window: String
    public let instant: Date
    public let fraction: Double

    public var isWall: Bool { fraction >= 1 }

    public var note: String {
        isWall
            ? Localized.text("The next send unlocks then") : Localized.text("This window starts over then")
    }

    public var alarmNote: String { String(format: Localized.text("%@ window reopens"), provider) }

    public func title(viewer: TimeZone, style: ClockStyle) -> String {
        String(
            format: Localized.text("%@ %@ resets at %@"), provider, window,
            ClockFormat.time(instant, in: viewer, style: style))
    }

    public func countdown(now: Date) -> String { ClockFormat.span(instant.timeIntervalSince(now)) }
}

public enum ClockResets {
    /// Windows that are walls or warm, soonest first; with none of those, the tightest window on
    /// the account, because a reset is only news when somebody is waiting on it.
    public static func upcoming(holdings: [QuotaHolding], now: Date, limit: Int = 3)
        -> [ClockReset]
    {
        var all: [ClockReset] = []
        for holding in holdings {
            for gauge in holding.gauges {
                guard let instant = gauge.resetsAt, instant > now else { continue }
                all.append(
                    ClockReset(
                        id: "\(holding.quota.providerName).\(gauge.key)",
                        provider: holding.quota.providerName, window: gauge.label, instant: instant,
                        fraction: gauge.fraction))
            }
        }
        let warm = all.filter { $0.fraction >= QuotaGlance.warmFloor }
            .sorted { $0.instant < $1.instant }
        if !warm.isEmpty { return Array(warm.prefix(limit)) }
        guard let tightest = all.max(by: { $0.fraction < $1.fraction }) else { return [] }
        return [tightest]
    }
}

/// The sky at this desk, as a glyph the chip draws: which body is up and how far along its arc.
public struct SkyGlyph: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case night
        case twilight
        case day
    }

    public let phase: Phase
    public let progress: Double

    public static func read(at now: Date, in city: WorldCity) -> SkyGlyph {
        guard let latitude = city.latitude, let longitude = city.longitude,
            let zone = city.timeZone
        else { return SkyGlyph(phase: .night, progress: 0.5) }
        func day(_ offset: TimeInterval) -> SolarDay {
            Solar.day(
                latitude: latitude, longitude: longitude,
                containing: now.addingTimeInterval(offset), in: zone)
        }
        let today = day(0)
        switch today.sky {
        case .alwaysUp:
            let noon = today.solarNoon
            let progress = 0.5 + now.timeIntervalSince(noon) / 86_400
            return SkyGlyph(phase: .day, progress: min(max(progress, 0), 1))
        case .neverUp:
            let axis = DayAxis(zone: zone, containing: now)
            return SkyGlyph(phase: .night, progress: min(max(axis.fraction(of: now), 0), 1))
        case .rises(let sunrise, let sunset):
            let twilight: TimeInterval = 1_800
            if now >= sunrise, now <= sunset {
                let progress = now.timeIntervalSince(sunrise) / sunset.timeIntervalSince(sunrise)
                let edge = min(now.timeIntervalSince(sunrise), sunset.timeIntervalSince(now))
                return SkyGlyph(phase: edge < twilight ? .twilight : .day, progress: progress)
            }
            let previousSet: Date
            let nextRise: Date
            if now < sunrise {
                if case .rises(_, let set) = day(-86_400).sky { previousSet = set } else {
                    previousSet = sunrise.addingTimeInterval(-43_200)
                }
                nextRise = sunrise
            } else {
                previousSet = sunset
                if case .rises(let rise, _) = day(86_400).sky { nextRise = rise } else {
                    nextRise = sunset.addingTimeInterval(43_200)
                }
            }
            let span = max(1, nextRise.timeIntervalSince(previousSet))
            let progress = min(max(now.timeIntervalSince(previousSet) / span, 0), 1)
            let edge = min(now.timeIntervalSince(previousSet), nextRise.timeIntervalSince(now))
            return SkyGlyph(phase: edge < twilight ? .twilight : .night, progress: progress)
        }
    }
}

/// What the chip says, what its hover shows and what the sheet's lanes start from, assembled once
/// so the Linux and Mac clients draw the same facts.
public struct WorldClockReading: Sendable, Equatable {
    public struct Zone: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let detail: String
        public let time: String
        public let isViewer: Bool
        public let isUp: Bool?
        public let bar: DaylightBar
        public let marker: Double
    }

    public let chipTime: String
    public let sky: SkyGlyph
    public let dateLine: String
    public let weekLine: String
    public let zoneLine: String
    public let zones: [Zone]
    public let suggestions: [WorldCity]
    public let machines: [MachineClockReading]
    public let skewWarning: String?
    public let resets: [ClockReset]
    public let hint: String
    public let spoken: String
    public let nextTick: Date

    public static func make(
        now: Date, preferences: WorldClockPreferences = .default, viewer: TimeZone = .current,
        machines: [MachineClock] = [], holdings: [QuotaHolding] = [], locale: Locale = .current
    ) -> WorldClockReading {
        let style = preferences.style
        let home = WorldCities.home(for: viewer)
        var zones: [Zone] = [
            zone(for: home, now: now, viewer: viewer, style: style, isViewer: true)
        ]
        let pinned = preferences.cities
        for city in pinned {
            zones.append(zone(for: city, now: now, viewer: viewer, style: style, isViewer: false))
        }
        let readings = MachineClocks.readings(machines, now: now, viewer: viewer, style: style)
        let chipTime = ClockFormat.time(now, in: viewer, style: style)
        let offset = viewer.secondsFromGMT(for: now)
        let zoneLine = "\(home.name) \u{00B7} \(ClockFormat.utc(offset))"
        let suggestions =
            pinned.isEmpty
            ? WorldCities.suggestedIDs.compactMap(WorldCities.city).filter {
                $0.zoneID != viewer.identifier
            }
            : []
        return WorldClockReading(
            chipTime: chipTime,
            sky: SkyGlyph.read(at: now, in: home),
            dateLine: ClockFormat.dateLine(now, in: viewer, locale: locale),
            weekLine: ClockFormat.weekLine(now, in: viewer),
            zoneLine: zoneLine,
            zones: zones,
            suggestions: suggestions,
            machines: readings,
            skewWarning: MachineClocks.warning(for: readings),
            resets: ClockResets.upcoming(holdings: holdings, now: now, limit: 2),
            hint: Localized.text("Click to open Meridian"),
            spoken: spokenLine(chipTime: chipTime, home: home, zones: zones),
            nextTick: nextMinute(after: now))
    }

    public static func nextMinute(after now: Date) -> Date {
        let seconds = now.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / 60).rounded(.down) * 60 + 60)
    }

    private static func zone(
        for city: WorldCity, now: Date, viewer: TimeZone, style: ClockStyle, isViewer: Bool
    ) -> Zone {
        let zone = city.timeZone ?? .gmt
        let axis = DayAxis(zone: zone, containing: now)
        let bar = Daylight.bar(for: city, on: axis)
        let marker = min(max(axis.fraction(of: now), 0), 1)
        let detail: String
        if isViewer {
            detail = Localized.text("You")
        } else {
            let delta = zone.secondsFromGMT(for: now) - viewer.secondsFromGMT(for: now)
            detail =
                "\(ClockFormat.offset(delta)) \u{00B7} \(ClockFormat.dayWord(now, in: zone, relativeTo: viewer))"
        }
        return Zone(
            id: city.id, name: city.name, detail: detail,
            time: ClockFormat.time(now, in: zone, style: style), isViewer: isViewer,
            isUp: bar.hasSun ? bar.isUp(at: marker) : nil, bar: bar, marker: marker)
    }

    private static func spokenLine(chipTime: String, home: WorldCity, zones: [Zone]) -> String {
        let others = zones.dropFirst().map { "\($0.name) \($0.time)" }
        let head = String(format: Localized.text("%@ in %@"), chipTime, home.name)
        return others.isEmpty ? head : head + ". " + others.joined(separator: ", ")
    }
}

import Foundation

/// A time the person asked to be told about: the moment a window reopens, or a minute picked on the
/// sheet's line. It is kept as an instant and a zone, so it fires when it should whichever zone
/// the desk is in by then, and reads in the zone it was set in.
public struct ClockAlarm: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let fireAt: Date
    public let zoneID: String
    public let note: String?

    public init(id: String = UUID().uuidString, fireAt: Date, zoneID: String, note: String? = nil) {
        self.id = id
        self.fireAt = fireAt
        self.zoneID = zoneID
        self.note = note
    }

    public var timeZone: TimeZone { TimeZone(identifier: zoneID) ?? .current }

    /// What the notification says. An alarm that fires well after its time (the app was closed
    /// across it) says how late rather than pretending to be on time.
    public func notice(now: Date, style: ClockStyle) -> (title: String, body: String) {
        let time = ClockFormat.time(fireAt, in: timeZone, style: style)
        let place = WorldCities.displayName(forZone: zoneID)
        let title = String(format: Localized.text("It’s %@ in %@"), time, place)
        let late = now.timeIntervalSince(fireAt)
        let body =
            late > ClockAlarmBook.onTimeWithin
            ? String(
                format: Localized.text("%@ ago — the app was closed at the time."),
                ClockFormat.span(late))
            : (note ?? Localized.text("The time you asked to be told."))
        return (title, body)
    }
}

public struct ClockAlarmBook: Codable, Sendable, Equatable {
    public private(set) var alarms: [ClockAlarm]

    public static let maxAlarms = 12
    public static let onTimeWithin: TimeInterval = 120
    public static let forgetAfter: TimeInterval = 3_600

    public init(alarms: [ClockAlarm] = []) { self.alarms = alarms }

    public var next: ClockAlarm? { alarms.min { $0.fireAt < $1.fireAt } }

    /// Adds one alarm. A time already past, a minute that already has an alarm, and a book that is
    /// full are refused by returning nil, so a double press never leaves two notifications.
    @discardableResult
    public mutating func add(at instant: Date, zoneID: String, note: String? = nil, now: Date)
        -> ClockAlarm?
    {
        let minute = (instant.timeIntervalSince1970 / 60).rounded(.down)
        guard instant > now, alarms.count < Self.maxAlarms,
            !alarms.contains(where: { ($0.fireAt.timeIntervalSince1970 / 60).rounded(.down) == minute })
        else { return nil }
        let alarm = ClockAlarm(fireAt: instant, zoneID: zoneID, note: note)
        alarms.append(alarm)
        alarms.sort { $0.fireAt < $1.fireAt }
        return alarm
    }

    public mutating func remove(_ id: String) { alarms.removeAll { $0.id == id } }

    /// Takes every alarm whose time has come out of the book and returns it. One that is more than
    /// an hour stale is dropped without a word: telling somebody about a time that passed
    /// yesterday is noise.
    public mutating func collectDue(now: Date) -> [ClockAlarm] {
        let due = alarms.filter { $0.fireAt <= now }
        alarms.removeAll { $0.fireAt <= now }
        return due.filter { now.timeIntervalSince($0.fireAt) <= Self.forgetAfter }
    }
}

public enum ClockAlarmStore {
    public static let defaultsKey = "tailscode.worldClock.alarms"
    public static let didChange = Notification.Name("tailscode.worldClock.alarms.didChange")

    public static var current: ClockAlarmBook {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
            let stored = try? JSONDecoder().decode(ClockAlarmBook.self, from: data)
        else { return ClockAlarmBook() }
        return stored
    }

    public static func save(_ book: ClockAlarmBook) {
        if book.alarms.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(book) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Takes whatever has come due out of the stored book and returns it, writing the book back
    /// only if something left it.
    public static func collectDue(now: Date = Date()) -> [ClockAlarm] {
        var book = current
        let due = book.collectDue(now: now)
        if book != current { save(book) }
        return due
    }

    @discardableResult
    public static func add(at instant: Date, zoneID: String, note: String? = nil, now: Date = Date())
        -> ClockAlarm?
    {
        var book = current
        guard let alarm = book.add(at: instant, zoneID: zoneID, note: note, now: now) else {
            return nil
        }
        save(book)
        return alarm
    }

    public static func update(_ change: (inout ClockAlarmBook) -> Void) {
        var book = current
        change(&book)
        guard book != current else { return }
        save(book)
    }
}

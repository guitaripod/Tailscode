import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension SelfTest {
    /// What the world clock promises that does not need a person looking: the chip's words and the
    /// minute it wakes on, the glance's zones and machines, the sheet's lanes and the moment it is
    /// read at, a daylight bar for every lane, the alarm book round-tripping through its store and
    /// firing on time, the palette reaching the drawing as eleven inks, the chip and the sheet
    /// drawing and the parity answer.
    static func checkClock() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("clock: \(label)") }
            checks += 1
        }
        let defaults = UserDefaults.standard
        let keys = [WorldClockStore.defaultsKey, ClockAlarmStore.defaultsKey]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        let usedFixtures = ClockWatch.shared.usesFixtures
        defer {
            for (key, value) in previous { SettingsFile.set(value, forKey: key) }
            SettingsFile.flush()
            ClockWatch.shared.clock = { Date() }
            ClockWatch.shared.usesFixtures = usedFixtures
        }
        ClockWatch.shared.usesFixtures = false
        let helsinki = TimeZone(identifier: "Europe/Helsinki") ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = helsinki
        guard let now = calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 16, hour: 14, minute: 7, second: 20))
        else { throw SelfTestFailure("clock: the fixed moment does not exist") }
        let locale = Locale(identifier: "en_US_POSIX")

        try checkClockReading(expect, now: now, zone: helsinki, locale: locale)
        try checkClockBoard(expect, now: now, zone: helsinki, locale: locale)
        try checkClockAlarms(expect, now: now)
        try checkClockInks(expect)
        try checkClockWatch(expect, now: now)
        try checkClockParity(expect)
        guard gtk_init_check() != 0 else { return checks }
        try checkClockWidgets(expect, now: now)
        return checks
    }

    private static func checkClockReading(
        _ expect: (Bool, String) throws -> Void, now: Date, zone: TimeZone, locale: Locale
    ) throws {
        let reading = WorldClockReading.make(
            now: now, preferences: WorldClockFixtures.preferences, viewer: zone,
            machines: WorldClockFixtures.machines, holdings: WorldClockFixtures.holdings(now: now),
            locale: locale)
        try expect(reading.chipTime == "14:07", "the chip reads 14:07 at 14:07 Helsinki time, not \(reading.chipTime)")
        try expect(reading.zones.count == 3, "the glance has here and the two pinned places")
        try expect(reading.zones.first?.isViewer == true, "the first zone is here")
        try expect(reading.zones.allSatisfy { !$0.bar.stops.isEmpty }, "every zone has a daylight strip")
        try expect(reading.machines.count == 3, "three machines are read")
        try expect(reading.skewWarning != nil, "a machine 47 s off is warned about")
        try expect(reading.resets.count == 1, "the quota window about to reopen is read")
        let minute = (reading.nextTick.timeIntervalSince1970).truncatingRemainder(dividingBy: 60)
        try expect(minute == 0 && reading.nextTick > now, "the chip wakes on the next minute boundary")
        try expect(
            reading.nextTick.timeIntervalSince(now) <= 60, "and never more than a minute away")
        try expect(!reading.spoken.isEmpty, "the chip has a spoken line")
    }

    private static func checkClockBoard(
        _ expect: (Bool, String) throws -> Void, now: Date, zone: TimeZone, locale: Locale
    ) throws {
        let board = MeridianBoard.make(
            now: now, preferences: WorldClockFixtures.preferences, viewer: zone,
            machines: WorldClockFixtures.machines, holdings: WorldClockFixtures.holdings(now: now),
            locale: locale)
        try expect(board.lanes.count == 3, "the sheet has a lane for here and each pinned place")
        try expect(board.head == "14:07", "the head reads the moment")
        try expect(board.isFollowingNow, "a board with no scrub follows the clock")
        try expect(board.lanes.allSatisfy { !$0.bar.stops.isEmpty }, "every lane has gradient stops")
        try expect(board.golden != nil, "somebody is awake together today")
        try expect(
            board.lanes.first?.marks.contains { $0.kind == .reset } == true,
            "the reset is marked on this desk's lane")
        let scrubbed = MeridianBoard.make(
            now: now, scrubMinute: 1260, preferences: WorldClockFixtures.preferences, viewer: zone,
            machines: [], holdings: [], locale: locale)
        try expect(scrubbed.head == "21:00", "a scrubbed board reads the minute it was put on")
        try expect(!scrubbed.isFollowingNow && scrubbed.canNotify, "a later moment can be notified")
        try expect(
            scrubbed.minute(atFraction: scrubbed.linePosition) == 1260,
            "a position on the track gives back its minute")
        try expect(scrubbed.nowMinute != scrubbed.scrubMinute, "now stays where the clock is")
    }

    private static func checkClockAlarms(_ expect: (Bool, String) throws -> Void, now: Date) throws {
        ClockAlarmStore.save(ClockAlarmBook())
        try expect(ClockAlarmStore.current.alarms.isEmpty, "the book starts empty")
        let added = ClockAlarmStore.add(
            at: now.addingTimeInterval(120), zoneID: "Europe/Helsinki", note: "window reopens", now: now)
        try expect(added != nil, "an alarm in the future is added")
        try expect(ClockAlarmStore.current.alarms.count == 1, "it round-trips through the store")
        try expect(
            ClockAlarmStore.add(
                at: now.addingTimeInterval(120), zoneID: "Europe/Helsinki", now: now) == nil,
            "a second alarm for the same minute is refused")
        try expect(ClockAlarmStore.collectDue(now: now).isEmpty, "nothing fires before its minute")
        let due = ClockAlarmStore.collectDue(now: now.addingTimeInterval(121))
        try expect(due.count == 1 && due.first?.note == "window reopens", "it fires once its minute has come")
        try expect(ClockAlarmStore.current.alarms.isEmpty, "and leaves the book")
        let notice = due.first?.notice(now: now.addingTimeInterval(121), style: .h24)
        try expect(notice?.title.contains("14:09") == true, "the notice names the alarm's own time")
        ClockAlarmStore.add(at: now.addingTimeInterval(60), zoneID: "Europe/Helsinki", now: now)
        try expect(
            ClockAlarmStore.collectDue(now: now.addingTimeInterval(7_200)).isEmpty,
            "an alarm two hours stale is dropped without a word")
        try expect(ClockAlarmStore.current.alarms.isEmpty, "and is gone from the book")
    }

    private static func checkClockInks(_ expect: (Bool, String) throws -> Void) throws {
        let values = MeridianInk.values
        try expect(values.count == Int(TAILSCODE_MERIDIAN_INKS) * 3, "the palette reaches the drawing as eleven inks")
        try expect(values.allSatisfy { (0...1).contains($0) }, "every ink is a colour")
        let palette = MatrixTheme.palette
        try expect(
            MeridianInk.night(palette) != MeridianInk.day(palette), "night and day are two colours")
    }

    private static func checkClockWatch(_ expect: (Bool, String) throws -> Void, now: Date) throws {
        WorldClockStore.save(WorldClockPreferences(pins: ["tokyo"], style: .h24))
        ClockWatch.shared.clock = { now }
        let reading = ClockWatch.shared.reading()
        try expect(
            reading.chipTime == ClockFormat.time(now, in: .current, style: .h24),
            "the watch reads the chip through the stored style")
        try expect(reading.zones.count == 2, "a stored pin becomes a zone")
        let board = ClockWatch.shared.board(scrubMinute: nil)
        try expect(board.lanes.count == 2, "and a lane")
        ClockWatch.shared.updatePreferences { $0.unpin("tokyo") }
        try expect(ClockWatch.shared.preferences.pins.isEmpty, "unpinning removes it")
        ClockWatch.shared.updatePreferences { $0.pin("nowhere-at-all") }
        try expect(!ClockWatch.shared.preferences.pins.contains("nowhere-at-all"), "a city nobody knows is not pinned")
    }

    private static func checkClockParity(_ expect: (Bool, String) throws -> Void) throws {
        var anchor: String?
        if case .implemented(let named) = ParityManifest.evidence(for: .worldClock) { anchor = named }
        try expect(anchor == "ClockChip", "the manifest answers the world clock with ClockChip")
    }

    private static func checkClockWidgets(_ expect: (Bool, String) throws -> Void, now: Date) throws {
        func pump(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                while g_main_context_iteration(nil, 0) != 0 {}
                usleep(4000)
            }
        }
        WorldClockStore.save(WorldClockPreferences(pins: ["tokyo", "san-francisco"], style: .h24))
        ClockWatch.shared.clock = { now }
        let chip = ClockChip {}
        let host = gtk_window_new()!
        gtk_window_set_child(ptr(host), chip.widget)
        gtk_window_present(ptr(host))
        pump(0.3)
        try expect(chip.line.contains("chip="), "the chip shows a time")
        chip.showGlance()
        pump(0.3)
        try expect(chip.isShown, "the glance opens")
        try expect(chip.glanceText?.isEmpty == false, "and has words")
        chip.hideGlance()
        pump(0.2)
        try expect(!chip.isShown, "and closes")
        MeridianSheet.present(parent: host)
        pump(0.4)
        try expect(MeridianSheet.current != nil, "the sheet opens as a window of its own")
        let summary = MeridianSheet.current?.summary ?? ""
        try expect(summary.contains("lanes=3"), "with a lane for here and each pinned place")
        MeridianSheet.current?.driveScrub(minute: 600)
        pump(0.2)
        try expect(MeridianSheet.current?.summary.contains("head=10:00") == true, "scrubbing moves every desk to that moment")
        MeridianSheet.current?.driveFollow()
        pump(0.6)
        try expect(MeridianSheet.current?.summary.contains("following=true") == true, "Now follows the clock again")
        MeridianSheet.close()
        pump(0.3)
        try expect(MeridianSheet.current == nil, "closing leaves no sheet behind")
        chip.tearDown()
        gtk_window_destroy(ptr(host))
    }
}

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

    private static func checkClockControls(
        _ expect: (Bool, String) throws -> Void, pump: (Double) -> Void
    ) throws {
        guard let sheet = MeridianSheet.current else { return }
        let controls = sheet.controlsReading
        try expect(controls.count == 2, "each pinned lane has move and remove controls, here has none")
        try expect(controls.first?.up == false && controls.first?.down == true, "the first place cannot move up")
        try expect(controls.last?.up == true && controls.last?.down == false, "the last place cannot move down")
        ClockWatch.shared.updatePreferences { $0.move("san-francisco", by: -1) }
        pump(0.3)
        try expect(
            ClockWatch.shared.preferences.pins == ["san-francisco", "tokyo"], "move up reorders the places")
        ClockWatch.shared.updatePreferences { $0.move("san-francisco", by: 1) }
        pump(0.2)
    }

    private static func checkClockPlaces(
        _ expect: (Bool, String) throws -> Void, pump: (Double) -> Void
    ) throws {
        guard let sheet = MeridianSheet.current else { return }
        let now = ClockWatch.shared.now
        let preferences = ClockWatch.shared.preferences
        let status = MeridianPlaces.status(preferences)
        sheet.driveAdd(open: true)
        pump(0.3)
        let opened = sheet.placesReading
        try expect(opened.open, "Add a place expands in place")
        try expect(opened.invitation == status.invitation && opened.summary == status.summary, "it says Core's invitation and count")
        let suggested = MeridianPlaces.suggestions(preferences: preferences, viewer: .current, now: now)
        try expect(opened.rows == suggested && !suggested.isEmpty, "an empty field lists the suggestions")
        sheet.driveSearch("to")
        pump(0.3)
        let typed = MeridianPlaces.results(for: "to", preferences: preferences, viewer: .current, now: now)
        try expect(sheet.placesReading.rows == typed && !typed.isEmpty, "typing lists the matches by their clocks")
        sheet.driveSearch("zzzzzz")
        pump(0.2)
        try expect(sheet.placesReading.rows.isEmpty, "no match lists nothing and says so")
        sheet.driveSearch("to")
        pump(0.2)
        sheet.driveKey("down")
        pump(0.1)
        sheet.driveKey("esc")
        pump(0.1)
        try expect(sheet.searchText.isEmpty && sheet.placesReading.open, "Esc clears the field first")
        sheet.driveKey("esc")
        pump(0.1)
        try expect(!sheet.placesReading.open, "and collapses second")
        try expect(MeridianSheet.current != nil, "without closing the sheet")
        sheet.driveSearch("lon")
        pump(0.2)
        let before = ClockWatch.shared.preferences.pins.count
        sheet.driveKey("enter")
        pump(0.4)
        try expect(ClockWatch.shared.preferences.pins.count == before + 1, "Return pins the highlighted place")
        try expect(!sheet.placesReading.open && sheet.searchText.isEmpty, "and the row collapses with the field clear")
        try expect(sheet.summary.contains("lanes=4"), "the new lane appears")
        ClockWatch.shared.updatePreferences { $0 = WorldClockPreferences(pins: Array(WorldCities.popularIDs.prefix(8)), style: .h24) }
        pump(0.4)
        let full = sheet.placesReading
        try expect(!full.sensitive, "a full list disables the row")
        try expect(full.invitation == MeridianPlaces.status(ClockWatch.shared.preferences).invitation, "and says why")
        ClockWatch.shared.updatePreferences { $0 = WorldClockPreferences(pins: ["tokyo", "san-francisco"], style: .h24) }
        pump(0.3)
    }

    private static func checkClockFormats(
        _ expect: (Bool, String) throws -> Void, pump: (Double) -> Void
    ) throws {
        guard let sheet = MeridianSheet.current else { return }
        let reading = sheet.segmentReading
        try expect(reading.map(\.style) == ClockStyle.allCases, "the time format is a three-way control")
        try expect(reading.filter(\.selected).map(\.style) == [.h24], "the current format is the selected one")
        try expect(reading.allSatisfy { !$0.example.isEmpty }, "each segment shows what it writes now")
        sheet.driveStyle(.h12)
        pump(0.3)
        try expect(ClockWatch.shared.preferences.style == .h12, "pressing a segment writes the style")
        try expect(sheet.segmentReading.filter(\.selected).map(\.style) == [.h12], "and the selection follows it")
        try expect(sheet.summary.contains(" AM ") || sheet.summary.contains(" PM "), "everything on the sheet re-renders in place")
        sheet.driveStyle(.h24)
        pump(0.2)
    }

    private static func checkClockAudit(
        _ expect: (Bool, String) throws -> Void, pump: (Double) -> Void, chip: ClockChip
    ) throws {
        guard let sheet = MeridianSheet.current else { return }
        sheet.driveAdd(open: true)
        pump(0.4)
        let open = ClockAudit.run(on: sheet.root)
        try expect(open.audited > 40, "the audit reaches the sheet's labels (\(open.audited))")
        try expect(open.cut == 0, "no label on the sheet is cut short: \(open.line)")
        sheet.driveAdd(open: false)
        pump(0.3)
        sheet.driveSize(width: 800, height: 600)
        pump(0.5)
        let narrow = ClockAudit.run(on: sheet.root)
        try expect(narrow.cut == 0, "none at 800x600 either: \(narrow.line)")
        chip.showGlance()
        pump(0.4)
        if let glance = chip.glanceRoot {
            let result = ClockAudit.run(on: glance)
            try expect(result.audited > 10 && result.cut == 0, "none in the glance: \(result.line)")
        }
        chip.hideGlance()
        pump(0.2)
        let control = gtk_window_new()!
        let cut = Gtk.label("A label that is given less room than its words", css: nil, selectable: false)
        gtk_label_set_ellipsize(op(cut), PANGO_ELLIPSIZE_END)
        gtk_widget_set_size_request(cut, 60, -1)
        gtk_window_set_child(ptr(control), cut)
        gtk_window_present(ptr(control))
        pump(0.3)
        let negative = ClockAudit.run(on: control)
        try expect(negative.audited == 1 && negative.cut == 1, "the audit does count a label that is cut short")
        gtk_window_destroy(ptr(control))
        pump(0.1)
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
        ClockWatch.shared.start()
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
        pump(0.5)
        try expect(MeridianSheet.current != nil, "the sheet opens as a window of its own")
        let summary = MeridianSheet.current?.summary ?? ""
        try expect(summary.contains("lanes=3"), "with a lane for here and each pinned place")
        MeridianSheet.current?.driveScrub(minute: 600)
        pump(0.2)
        try expect(MeridianSheet.current?.summary.contains("head=10:00") == true, "scrubbing moves every desk to that moment")
        MeridianSheet.current?.driveFollow()
        pump(0.6)
        try expect(MeridianSheet.current?.summary.contains("following=true") == true, "Now follows the clock again")
        try checkClockControls(expect, pump: pump)
        try checkClockPlaces(expect, pump: pump)
        try checkClockFormats(expect, pump: pump)
        try checkClockAudit(expect, pump: pump, chip: chip)
        MeridianSheet.close()
        pump(0.3)
        try expect(MeridianSheet.current == nil, "closing leaves no sheet behind")
        chip.tearDown()
        gtk_window_destroy(ptr(host))
    }
}

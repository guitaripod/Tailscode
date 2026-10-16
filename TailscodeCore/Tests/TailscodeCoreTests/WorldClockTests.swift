import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("World clock")
struct WorldClockTests {
    private static let helsinki = TimeZone(identifier: "Europe/Helsinki")!
    private static let posix = Locale(identifier: "en_US_POSIX")

    private func instant(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func minutesOfDay(_ date: Date, _ zone: TimeZone) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    @Test("Helsinki in mid October has a short, plausible day")
    func helsinkiDay() {
        let day = Solar.day(
            latitude: 60.17, longitude: 24.94, containing: instant("2026-10-16T12:00:00+03:00"),
            in: Self.helsinki)
        guard case .rises(let sunrise, let sunset) = day.sky else {
            Issue.record("expected a sunrise")
            return
        }
        let rise = minutesOfDay(sunrise, Self.helsinki)
        let set = minutesOfDay(sunset, Self.helsinki)
        #expect(rise > 7 * 60 + 30 && rise < 8 * 60 + 20, "sunrise \(rise)")
        #expect(set > 17 * 60 + 20 && set < 18 * 60 + 20, "sunset \(set)")
        let length = sunset.timeIntervalSince(sunrise) / 3600
        #expect(length > 9.5 && length < 10.5)
    }

    @Test("At the equinox Greenwich has twelve hours of day")
    func equinoxGreenwich() {
        let utc = TimeZone(identifier: "UTC")!
        let day = Solar.day(
            latitude: 51.48, longitude: 0, containing: instant("2026-03-20T12:00:00Z"), in: utc)
        guard case .rises(let sunrise, let sunset) = day.sky else {
            Issue.record("expected a sunrise")
            return
        }
        #expect(abs(minutesOfDay(sunrise, utc) - 6 * 60) < 15)
        #expect(abs(minutesOfDay(sunset, utc) - (18 * 60 + 5)) < 15)
    }

    @Test("Above the arctic circle the sun can stay down or stay up")
    func polar() {
        let zone = TimeZone(identifier: "Europe/Oslo")!
        let winter = Solar.day(
            latitude: 69.65, longitude: 18.96, containing: instant("2026-12-21T12:00:00+01:00"),
            in: zone)
        let summer = Solar.day(
            latitude: 69.65, longitude: 18.96, containing: instant("2026-06-21T12:00:00+02:00"),
            in: zone)
        #expect(winter.sky == .neverUp)
        #expect(summer.sky == .alwaysUp)
    }

    @Test("A day with a clock change in it is 25 or 23 hours long")
    func daylightSavingAxis() {
        let autumn = DayAxis(zone: Self.helsinki, containing: instant("2026-10-25T12:00:00+02:00"))
        let spring = DayAxis(zone: Self.helsinki, containing: instant("2026-03-29T12:00:00+03:00"))
        let plain = DayAxis(zone: Self.helsinki, containing: instant("2026-10-16T12:00:00+03:00"))
        #expect(autumn.minutes == 1500)
        #expect(spring.minutes == 1380)
        #expect(plain.minutes == 1440)
        #expect(plain.minute(of: instant("2026-10-16T14:07:30+03:00")) == 847)
        #expect(plain.instant(atMinute: 847) == instant("2026-10-16T14:07:00+03:00"))
    }

    @Test("A lane's gradient runs night, twilight, day, with noon where the sun is highest")
    func daylightBar() throws {
        let helsinki = try #require(WorldCities.city("helsinki"))
        let axis = DayAxis(zone: Self.helsinki, containing: instant("2026-10-16T12:00:00+03:00"))
        let bar = Daylight.bar(for: helsinki, on: axis)
        #expect(bar.hasSun)
        #expect(bar.stops.first?.position == 0)
        #expect(bar.stops.last?.position == 1)
        #expect(bar.stops.allSatisfy { (0...1).contains($0.light) })
        #expect(zip(bar.stops, bar.stops.dropFirst()).allSatisfy { $0.position < $1.position })
        #expect(bar.light(at: 0.02) == 0)
        #expect(bar.light(at: 0.55) > 0.999)
        let noon = try #require(bar.noon)
        #expect(abs(noon - 0.546) < 0.01)
        #expect(bar.isUp(at: 0.55))
        #expect(!bar.isUp(at: 0.95))
    }

    @Test("Another zone's day lands where its instants fall on the viewer's axis")
    func tokyoOnHelsinkiAxis() throws {
        let tokyo = try #require(WorldCities.city("tokyo"))
        let axis = DayAxis(zone: Self.helsinki, containing: instant("2026-10-16T12:00:00+03:00"))
        let bar = Daylight.bar(for: tokyo, on: axis)
        #expect(bar.light(at: 0.20) > 0.999)
        #expect(bar.light(at: 0.60) == 0)
        #expect(bar.light(at: 0.90) == 0)
    }

    @Test("A city with no coordinates has no sun and a flat lane")
    func utcHasNoSun() throws {
        let axis = DayAxis(zone: Self.helsinki, containing: instant("2026-10-16T12:00:00+03:00"))
        let bar = Daylight.bar(for: WorldCities.utc, on: axis)
        #expect(!bar.hasSun)
        #expect(bar == .flat)
    }

    @Test("Offsets, spans and times are written the same everywhere")
    func formats() {
        #expect(ClockFormat.offset(6 * 3600) == "+6 h")
        #expect(ClockFormat.offset(-10 * 3600) == "\u{2212}10 h")
        #expect(ClockFormat.offset(19_800) == "+5 h 30 m")
        #expect(ClockFormat.utc(3 * 3600) == "UTC+3")
        #expect(ClockFormat.utc(19_800) == "UTC+5:30")
        #expect(ClockFormat.utc(0) == "UTC")
        #expect(ClockFormat.span(2 * 3600 + 45 * 60) == "2 h 45 m")
        #expect(ClockFormat.span(12 * 60) == "12 m")
        #expect(ClockFormat.span(27 * 3600) == "1 d 3 h")
        let at = instant("2026-10-16T14:07:00+03:00")
        #expect(ClockFormat.time(at, in: Self.helsinki, style: .h24) == "14:07")
        #expect(ClockFormat.time(at, in: Self.helsinki, style: .h12) == "2:07 PM")
        let midnight = instant("2026-10-16T00:05:00+03:00")
        #expect(ClockFormat.time(midnight, in: Self.helsinki, style: .h12) == "12:05 AM")
        #expect(ClockFormat.isoString(at, in: Self.helsinki) == "2026-10-16T14:07:00+03:00")
        #expect(ClockFormat.utcString(at) == "2026-10-16 11:07 UTC")
    }

    @Test("Today, yesterday and tomorrow are the viewer's calendar, not the zone's")
    func dayWords() throws {
        let late = instant("2026-10-16T23:00:00+03:00")
        let tokyo = try #require(WorldCities.city("tokyo")?.timeZone)
        let sanFrancisco = try #require(WorldCities.city("san-francisco")?.timeZone)
        #expect(ClockFormat.dayWord(late, in: tokyo, relativeTo: Self.helsinki) == "tomorrow")
        #expect(ClockFormat.dayWord(late, in: sanFrancisco, relativeTo: Self.helsinki) == "today")
        let early = instant("2026-10-16T02:00:00+03:00")
        #expect(ClockFormat.dayWord(early, in: sanFrancisco, relativeTo: Self.helsinki) == "yesterday")
    }

    @Test("Search ignores accents and case and ranks names before countries")
    func search() {
        #expect(WorldCities.search("zur").first?.id == "zurich")
        #expect(WorldCities.search("ZÜR").first?.id == "zurich")
        #expect(WorldCities.search("san fran").first?.id == "san-francisco")
        #expect(WorldCities.search("sf").first?.id == "san-francisco")
        #expect(WorldCities.search("japan").map(\.id).contains("tokyo"))
        #expect(WorldCities.search("tok", excluding: ["tokyo", "osaka"]).isEmpty)
        #expect(WorldCities.search("   ").isEmpty)
    }

    @Test("Every catalog city names a zone this machine knows")
    func catalogZonesResolve() {
        for city in WorldCities.all {
            #expect(city.timeZone != nil, "\(city.id) \(city.zoneID)")
        }
        #expect(Set(WorldCities.all.map(\.id)).count == WorldCities.all.count)
    }

    @Test("A desk in a zone the catalog lacks still gets a day, marked approximate")
    func homeFallback() {
        let known = WorldCities.home(for: Self.helsinki)
        #expect(known.name == "Helsinki")
        #expect(known.hasSun && !known.isApproximate)
        let unknown = WorldCities.home(for: TimeZone(secondsFromGMT: 5 * 3600 + 1800)!)
        #expect(unknown.hasSun)
        #expect(unknown.isApproximate)
    }

    @Test("Pins keep the person's order, refuse repeats and stop at the limit")
    func pins() {
        var prefs = WorldClockPreferences()
        prefs.pin("tokyo")
        prefs.pin("tokyo")
        prefs.pin("nowhere")
        prefs.pin("london")
        #expect(prefs.pins == ["tokyo", "london"])
        prefs.move("london", by: -1)
        #expect(prefs.pins == ["london", "tokyo"])
        prefs.unpin("london")
        #expect(prefs.pins == ["tokyo"])
        for id in WorldCities.all.map(\.id) { prefs.pin(id) }
        #expect(prefs.pins.count == WorldClockPreferences.maxPins)
    }

    @Test("Preferences survive a round trip through the store")
    func storeRoundTrip() {
        let saved = WorldClockStore.current
        defer { WorldClockStore.save(saved) }
        WorldClockStore.save(WorldClockPreferences(pins: ["tokyo", "london"], style: .h12))
        #expect(WorldClockStore.current.pins == ["tokyo", "london"])
        #expect(WorldClockStore.current.style == .h12)
    }

    @Test("A machine is in sync, slightly off, or a sentence")
    func machineClocks() {
        let now = instant("2026-10-16T14:07:00+03:00")
        let readings = MachineClocks.readings(
            [
                MachineClock(name: "arch", skew: 0.4),
                MachineClock(name: "macbook", skew: 8),
                MachineClock(name: "box", skew: -47),
                MachineClock(name: "mini", skew: nil),
            ], now: now, viewer: Self.helsinki, style: .h24)
        #expect(readings.map(\.status) == ["in sync", "+8 s", "47 s behind", "no reading"])
        #expect(readings.map(\.tone) == [.ok, .ok, .warn, .quiet])
        #expect(readings[2].time == "14:06")
        #expect(readings[3].time == nil)
        let warning = MachineClocks.warning(for: readings)
        #expect(warning == "box runs 47 s behind. Chats dated by that machine will read early.")
        #expect(MachineClocks.warning(for: Array(readings.prefix(2))) == nil)
    }

    @Test("A machine ahead of the clock is told apart, and the worst one leads")
    func machineAhead() {
        let now = instant("2026-10-16T14:07:00+03:00")
        let readings = MachineClocks.readings(
            [MachineClock(name: "a", skew: 120), MachineClock(name: "b", skew: -20)], now: now,
            viewer: Self.helsinki, style: .h24)
        #expect(readings[0].status == "2 m ahead")
        let warning = MachineClocks.warning(for: readings) ?? ""
        #expect(warning.hasPrefix("a runs 2 m ahead."))
        #expect(warning.contains("1 more are off too."))
        #expect(warning.contains("future"))
    }

    private func holding(_ provider: String, gauges: [(String, Double, Date?)]) -> QuotaHolding {
        QuotaHolding(
            quota: UsageQuota(
                providerName: provider, subtitle: "", source: "test", live: true,
                gauges: gauges.map { key, fraction, reset in
                    UsageQuota.Gauge(
                        key: key, label: key, fraction: fraction, resetsAt: reset,
                        trustedReset: true, usedUSD: nil, limitUSD: nil)
                }, details: []),
            machines: ["arch"])
    }

    @Test("Quota resets lead with the warm windows, soonest first")
    func resets() {
        let now = instant("2026-10-16T14:07:00+03:00")
        let soon = now.addingTimeInterval(2 * 3600 + 45 * 60)
        let later = now.addingTimeInterval(30 * 3600)
        let holdings = [
            holding("Claude", gauges: [("5-hour", 0.92, soon), ("Weekly", 0.3, later)]),
            holding("Grok", gauges: [("Daily", 0.7, later)]),
        ]
        let found = ClockResets.upcoming(holdings: holdings, now: now)
        #expect(found.map(\.window) == ["5-hour", "Daily"])
        #expect(found[0].countdown(now: now) == "2 h 45 m")
        #expect(found[0].note == "This window starts over then")
        #expect(found[0].alarmNote == "Claude window reopens")
        let wall = ClockResets.upcoming(
            holdings: [holding("Claude", gauges: [("5-hour", 1.0, soon)])], now: now)
        #expect(wall[0].isWall && wall[0].note == "The next send unlocks then")
        #expect(
            found[0].title(viewer: Self.helsinki, style: .h24) == "Claude 5-hour resets at 16:52")
    }

    @Test("With nothing warm, the tightest window is the one reset worth showing")
    func quietResets() {
        let now = instant("2026-10-16T14:07:00+03:00")
        let later = now.addingTimeInterval(3600)
        let holdings = [
            holding("Claude", gauges: [("5-hour", 0.2, later), ("Weekly", 0.4, later)])
        ]
        #expect(ClockResets.upcoming(holdings: holdings, now: now).map(\.window) == ["Weekly"])
        #expect(ClockResets.upcoming(holdings: [], now: now).isEmpty)
        let past = [holding("Claude", gauges: [("5-hour", 0.95, now.addingTimeInterval(-60))])]
        #expect(ClockResets.upcoming(holdings: past, now: now).isEmpty)
    }

    @Test("The sky glyph follows the sun by day and the moon by night")
    func sky() throws {
        let helsinki = WorldCities.home(for: Self.helsinki)
        let noon = SkyGlyph.read(at: instant("2026-10-16T12:50:00+03:00"), in: helsinki)
        #expect(noon.phase == .day)
        #expect(abs(noon.progress - 0.5) < 0.1)
        let midnight = SkyGlyph.read(at: instant("2026-10-16T01:00:00+03:00"), in: helsinki)
        #expect(midnight.phase == .night)
        #expect(midnight.progress > 0 && midnight.progress < 1)
        let beforeDawn = SkyGlyph.read(at: instant("2026-10-16T07:40:00+03:00"), in: helsinki)
        #expect(beforeDawn.phase == .twilight)
        let utc = SkyGlyph.read(at: instant("2026-10-16T12:00:00Z"), in: WorldCities.utc)
        #expect(utc.phase == .night)
    }

    @Test("The glance reads here first, then each pin with its offset and day")
    func glance() {
        let now = instant("2026-10-16T14:07:30+03:00")
        let reading = WorldClockReading.make(
            now: now, preferences: WorldClockPreferences(pins: ["tokyo", "san-francisco"], style: .h24),
            viewer: Self.helsinki, locale: Self.posix)
        #expect(reading.chipTime == "14:07")
        #expect(reading.dateLine == "Friday, October 16")
        #expect(reading.weekLine == "Week 42")
        #expect(reading.zoneLine == "Helsinki \u{00B7} UTC+3")
        #expect(reading.zones.map(\.name) == ["Helsinki", "Tokyo", "San Francisco"])
        #expect(reading.zones.map(\.time) == ["14:07", "20:07", "04:07"])
        #expect(reading.zones[0].detail == "You")
        #expect(reading.zones[1].detail == "+6 h \u{00B7} today")
        #expect(reading.zones[2].detail == "\u{2212}10 h \u{00B7} today")
        #expect(reading.zones.map(\.isUp) == [true, false, false])
        #expect(reading.zones[0].marker > 0.58 && reading.zones[0].marker < 0.60)
        #expect(reading.suggestions.isEmpty)
        #expect(reading.nextTick == instant("2026-10-16T14:08:00+03:00"))
    }

    @Test("With nothing pinned the glance offers places, never here again")
    func suggestions() {
        let reading = WorldClockReading.make(
            now: instant("2026-10-16T14:07:30+03:00"), viewer: Self.helsinki, locale: Self.posix)
        #expect(reading.zones.count == 1)
        #expect(reading.suggestions.map(\.id) == WorldCities.suggestedIDs)
        let london = WorldClockReading.make(
            now: instant("2026-10-16T14:07:30+03:00"),
            viewer: TimeZone(identifier: "Europe/London")!, locale: Self.posix)
        #expect(!london.suggestions.contains { $0.id == "london" })
    }

    @Test("The sheet follows the clock until the line is moved")
    func meridianFollowsNow() {
        let now = instant("2026-10-16T14:07:30+03:00")
        let prefs = WorldClockPreferences(pins: ["tokyo", "san-francisco"], style: .h24)
        let following = MeridianBoard.make(
            now: now, preferences: prefs, viewer: Self.helsinki, locale: Self.posix)
        #expect(following.isFollowingNow)
        #expect(following.head == "14:07")
        #expect(following.delta == "Right now")
        #expect(following.scrubMinute == 847)
        #expect(!following.canNotify)
        #expect(following.lanes.map(\.id) == ["you", "tokyo", "san-francisco"])
        #expect(following.lanes.map(\.time) == ["14:07", "20:07", "04:07"])
        #expect(following.lanes.map(\.isUp) == [true, false, false])
        #expect(following.copy.iso == "2026-10-16T14:07:00+03:00")
        #expect(following.copy.utc == "2026-10-16 11:07 UTC")
        #expect(following.copy.epoch == String(Int(instant("2026-10-16T14:07:00+03:00").timeIntervalSince1970)))

        let scrubbed = MeridianBoard.make(
            now: now, scrubMinute: 17 * 60 + 30, preferences: prefs, viewer: Self.helsinki,
            locale: Self.posix)
        #expect(!scrubbed.isFollowingNow)
        #expect(scrubbed.head == "17:30")
        #expect(scrubbed.delta == "In 3 h 23 m")
        #expect(scrubbed.lanes.map(\.time) == ["17:30", "23:30", "07:30"])
        #expect(scrubbed.lanes.map(\.isUp) == [true, false, true])
        #expect(scrubbed.canNotify)
        #expect(scrubbed.notifyLabel == "Notify me at 17:30")

        let earlier = MeridianBoard.make(
            now: now, scrubMinute: 9 * 60, preferences: prefs, viewer: Self.helsinki,
            locale: Self.posix)
        #expect(earlier.delta == "5 h 7 m ago")
        #expect(!earlier.canNotify)
    }

    @Test("A fraction of the line is a minute of the day, clamped to the day")
    func fractionToMinute() {
        let board = MeridianBoard.make(
            now: instant("2026-10-16T14:07:30+03:00"), viewer: Self.helsinki, locale: Self.posix)
        #expect(board.minute(atFraction: 0) == 0)
        #expect(board.minute(atFraction: 0.5) == 720)
        #expect(board.minute(atFraction: 1) == 1439)
        #expect(board.minute(atFraction: -3) == 0)
        #expect(board.minute(atFraction: 9) == 1439)
    }

    @Test("Everyone's waking hours meet in a band, and the sentence says where")
    func goldenWindow() throws {
        let now = instant("2026-10-16T14:07:30+03:00")
        let prefs = WorldClockPreferences(pins: ["tokyo"], style: .h24)
        let board = MeridianBoard.make(
            now: now, preferences: prefs, viewer: Self.helsinki, locale: Self.posix)
        let golden = try #require(board.golden)
        #expect(golden.label == "07:00\u{2013}17:00")
        #expect(abs(golden.start - 7.0 / 24) < 0.001)
        #expect(abs(golden.end - 17.0 / 24) < 0.001)
        #expect(
            board.insight
                == "Everyone is awake 07:00\u{2013}17:00. Awake with you: Tokyo 07:00\u{2013}17:00.")
    }

    @Test("When no hour is shared the sheet says so instead of inventing one")
    func noGoldenWindow() {
        let london = TimeZone(identifier: "Europe/London")!
        let now = instant("2026-10-16T14:07:30+01:00")
        let prefs = WorldClockPreferences(pins: ["los-angeles", "tokyo"], style: .h24)
        let board = MeridianBoard.make(
            now: now, preferences: prefs, viewer: london, locale: Self.posix)
        #expect(board.golden == nil)
        #expect(board.insight?.hasPrefix("There is no hour today when everyone is awake.") == true)
        #expect(board.insight?.contains("Los Angeles") == true)
        let alone = MeridianBoard.make(now: now, viewer: london, locale: Self.posix)
        #expect(alone.golden == nil && alone.insight == nil)
    }

    @Test("Three zones can share an hour that two of them would not name")
    func sharedMorning() throws {
        let now = instant("2026-10-16T14:07:30+03:00")
        let prefs = WorldClockPreferences(pins: ["tokyo", "san-francisco"], style: .h24)
        let board = MeridianBoard.make(
            now: now, preferences: prefs, viewer: Self.helsinki, locale: Self.posix)
        #expect(try #require(board.golden).label == "07:00\u{2013}09:00")
    }

    @Test("Resets and alarms are marked on the viewer's lane only")
    func marks() {
        let now = instant("2026-10-16T14:07:30+03:00")
        let reset = instant("2026-10-16T16:52:00+03:00")
        var book = ClockAlarmBook()
        book.add(at: instant("2026-10-16T18:30:00+03:00"), zoneID: "Europe/Helsinki", now: now)
        let holdings = [holding("Claude", gauges: [("5-hour", 0.95, reset)])]
        let board = MeridianBoard.make(
            now: now, preferences: WorldClockPreferences(pins: ["tokyo"], style: .h24),
            viewer: Self.helsinki, holdings: holdings, alarms: book, locale: Self.posix)
        let marks = board.lanes[0].marks
        #expect(marks.map(\.kind) == [.reset, .alarm])
        #expect(marks[0].label == "Claude resets 16:52")
        #expect(abs(marks[0].position - (16 * 60 + 52) / 1440.0) < 0.001)
        #expect(board.lanes[1].marks.isEmpty)
        #expect(board.alarms.count == 1)
        #expect(board.alarms[0].title == "18:30")
    }

    @Test("An alarm is refused in the past or twice in a minute, and fires once")
    func alarms() {
        let now = instant("2026-10-16T14:07:30+03:00")
        var book = ClockAlarmBook()
        let at = instant("2026-10-16T16:52:00+03:00")
        #expect(book.add(at: at, zoneID: "Europe/Helsinki", note: "Claude resets", now: now) != nil)
        #expect(book.add(at: at.addingTimeInterval(20), zoneID: "Europe/Helsinki", now: now) == nil)
        #expect(book.add(at: now.addingTimeInterval(-60), zoneID: "Europe/Helsinki", now: now) == nil)
        #expect(book.alarms.count == 1)
        #expect(book.collectDue(now: at.addingTimeInterval(-1)).isEmpty)
        let due = book.collectDue(now: at.addingTimeInterval(5))
        #expect(due.count == 1)
        #expect(book.alarms.isEmpty)
        let notice = due[0].notice(now: at.addingTimeInterval(5), style: .h24)
        #expect(notice.title == "It\u{2019}s 16:52 in Helsinki")
        #expect(notice.body == "Claude resets")
    }

    @Test("An alarm the app slept through says how late it is, and an old one is dropped")
    func lateAlarms() {
        let now = instant("2026-10-16T14:07:30+03:00")
        var book = ClockAlarmBook()
        let at = instant("2026-10-16T16:52:00+03:00")
        book.add(at: at, zoneID: "Europe/Helsinki", now: now)
        let late = book.collectDue(now: at.addingTimeInterval(600))
        #expect(late[0].notice(now: at.addingTimeInterval(600), style: .h24).body.hasPrefix("10 m ago"))
        var stale = ClockAlarmBook()
        stale.add(at: at, zoneID: "Europe/Helsinki", now: now)
        #expect(stale.collectDue(now: at.addingTimeInterval(7_200)).isEmpty)
        #expect(stale.alarms.isEmpty)
    }

    @Test("The book holds a dozen alarms and no more")
    func alarmLimit() {
        let now = instant("2026-10-16T14:07:30+03:00")
        var book = ClockAlarmBook()
        for index in 1...20 {
            book.add(at: now.addingTimeInterval(Double(index) * 3600), zoneID: "UTC", now: now)
        }
        #expect(book.alarms.count == ClockAlarmBook.maxAlarms)
        #expect(book.next?.fireAt == now.addingTimeInterval(3600))
    }

    @Test("Every capability, including the clock, has a spec")
    func registered() {
        #expect(CapabilityRegistry.missingDefinitions.isEmpty)
        #expect(CapabilityRegistry.definition(for: .worldClock).title.contains("world clock"))
    }
}

import AppKit
import TailscodeCore

/// What `--selftest` holds Meridian to with no display and no server: the reading and the board for a
/// fixed moment and the fixture preferences, an alarm through its store and its collection, and the
/// half Core cannot see — that every gradient a strip or a lane hands to Core Animation has a colour
/// for each of Core's stops, that the sky glyph's body stands on its arc, and that the sheet's line
/// answers the keys it is given.
@MainActor
enum MeridianChecks {
    static func run() throws -> Int {
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure(label) }
        }
        var checks = 0
        guard let helsinki = TimeZone(identifier: "Europe/Helsinki") else {
            throw SelfTestFailure("no Helsinki")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard
            let now = calendar.date(
                from: DateComponents(year: 2026, month: 10, day: 16, hour: 11, minute: 7))
        else { throw SelfTestFailure("no fixed moment") }
        let preferences = WorldClockFixtures.preferences
        let holdings = WorldClockFixtures.holdings(now: now)

        let reading = WorldClockReading.make(
            now: now, preferences: preferences, viewer: helsinki, machines: WorldClockFixtures.machines,
            holdings: holdings, locale: Locale(identifier: "en_US"))
        try expect(reading.chipTime == "14:07", "the chip reads \(reading.chipTime), not 14:07")
        try expect(reading.zones.count == 3, "the glance has \(reading.zones.count) zones, not 3")
        try expect(reading.zones.first?.isViewer == true, "the viewer does not lead the glance")
        try expect(reading.machines.count == 3, "the glance lost a machine")
        try expect(reading.skewWarning != nil, "a clock 47 seconds off raised no warning")
        try expect(reading.resets.count == 1, "the fixture window did not reach the glance")
        try expect(
            reading.nextTick == now.addingTimeInterval(60), "the chip's next tick is not the next minute")
        checks += 7

        var book = ClockAlarmBook()
        book.add(at: now.addingTimeInterval(3_600), zoneID: helsinki.identifier, now: now)
        let board = MeridianBoard.make(
            now: now, scrubMinute: nil, preferences: preferences, viewer: helsinki,
            machines: WorldClockFixtures.machines, holdings: holdings,
            alarms: book,
            locale: Locale(identifier: "en_US"))
        try expect(board.lanes.count == 3, "the sheet has \(board.lanes.count) lanes, not 3")
        try expect(board.head == "14:07", "the head reads \(board.head)")
        try expect(board.ticks.count == 9, "the hour ticks are \(board.ticks.count), not 9")
        try expect(
            board.lanes.first?.marks.contains { $0.kind == .alarm } == true,
            "an alarm in the book left no diamond on the viewer's lane")
        try expect(
            board.lanes.first?.marks.contains { $0.kind == .reset } == true,
            "the fixture window left no reset tick on the viewer's lane")
        checks += 5

        for lane in board.lanes {
            let bar = MeridianLaneBar(frame: NSRect(x: 0, y: 0, width: 600, height: 44))
            bar.apply(lane: lane, minutes: board.minutes)
            bar.layoutSubtreeIfNeeded()
            let gradient = bar.gradientLayer
            try expect(
                gradient.colors?.count == gradient.locations?.count
                    && gradient.colors?.count == (lane.bar.hasSun ? lane.bar.stops.count : 2),
                "\(lane.name)'s lane has a colour count that is not its stop count")
            checks += 1
        }
        for zone in reading.zones {
            let strip = DaylightStripView()
            strip.apply(bar: zone.bar, marker: zone.marker, isUp: zone.isUp)
            let gradient = strip.gradientLayer
            try expect(
                gradient.colors?.count == zone.bar.stops.count
                    && gradient.locations?.count == zone.bar.stops.count,
                "\(zone.name)'s strip has a colour count that is not its stop count")
            checks += 1
        }

        let stash = ClockAlarmStore.current
        defer { ClockAlarmStore.save(stash) }
        ClockAlarmStore.save(ClockAlarmBook())
        let stored = ClockAlarmStore.add(
            at: now.addingTimeInterval(120), zoneID: helsinki.identifier, note: "round trip", now: now)
        try expect(stored != nil, "an alarm two minutes ahead was refused")
        try expect(ClockAlarmStore.current.alarms.count == 1, "the alarm did not reach the store")
        try expect(
            ClockAlarmStore.collectDue(now: now.addingTimeInterval(60)).isEmpty,
            "an alarm was collected a minute early")
        let due = ClockAlarmStore.collectDue(now: now.addingTimeInterval(121))
        try expect(due.count == 1 && due.first?.note == "round trip", "the due alarm was not collected")
        try expect(ClockAlarmStore.current.alarms.isEmpty, "a collected alarm stayed in the store")
        if let alarm = due.first {
            let notice = alarm.notice(now: now.addingTimeInterval(121), style: .h24)
            try expect(!notice.title.isEmpty && notice.body == "round trip", "the notice lost its words")
        }
        checks += 6

        let left = SkyGlyphView.position(progress: 0)
        let right = SkyGlyphView.position(progress: 1)
        let top = SkyGlyphView.position(progress: 0.5)
        try expect(abs(left.y - right.y) < 0.001 && left.x < top.x && top.x < right.x, "the sky's arc is skewed")
        try expect(top.y > left.y, "the sky's body does not rise over its horizon")
        let sky = SkyGlyphView()
        guard let tokyo = WorldCities.city("tokyo"), let london = WorldCities.city("london") else {
            throw SelfTestFailure("no cities")
        }
        var phases: Set<SkyGlyph.Phase> = []
        for city in [tokyo, london] {
            for step in 0..<144 {
                let glyph = SkyGlyph.read(at: now.addingTimeInterval(Double(step) * 600), in: city)
                phases.insert(glyph.phase)
                sky.apply(glyph)
            }
        }
        try expect(phases.count == 3, "a day of readings did not show day, dusk and night")
        checks += 3

        let content = MeridianSheetContent()
        try expect(content.lanes.laneCount == content.board.lanes.count, "the sheet drew a lane too few")
        content.scrub(to: 600, animated: false)
        try expect(content.board.scrubMinute == 600 && !content.isFollowingNow, "the line did not move")
        content.step(15)
        try expect(content.board.scrubMinute == 615, "a quarter hour did not move the line 15 minutes")
        content.goToStartOfDay()
        try expect(content.board.scrubMinute == 0, "Home did not reach the start of the day")
        content.goToEndOfDay()
        try expect(content.board.scrubMinute == content.board.minutes - 1, "End did not reach the end")
        content.step(1)
        try expect(content.board.scrubMinute == content.board.minutes - 1, "the line ran off the day")
        content.goToNow()
        try expect(content.isFollowingNow, "Now did not return the sheet to the clock")
        try expect(
            content.copyButtons.map(\.payload) == [
                content.board.copy.iso, content.board.copy.utc, content.board.copy.epoch,
            ], "a copy button holds something other than the board's value")
        checks += 7
        return checks
    }
}

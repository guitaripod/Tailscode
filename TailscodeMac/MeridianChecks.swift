import AppKit
import TailscodeCore

/// What `--selftest` holds Meridian to with no display and no server: the reading and the board for a
/// fixed moment and the fixture preferences, an alarm through its store and its collection, and the
/// half Core cannot see — that every gradient a strip or a lane hands to Core Animation has a colour
/// for each of Core's stops, that the sky glyph's body stands on its arc, and that the sheet's line
/// answers the keys it is given.
@MainActor
enum MeridianChecks {
    nonisolated static let spec = "meridian-check"

    /// The child's side of the label audit: laid out under a running application, where AppKit lays
    /// views out on the real main thread and a suspension resumes on it.
    static func runAsChild() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                let result = try labelsAreWhole()
                print("MERIDIAN_NOTES \(result.checks) layouts \(result.audited) labels")
                print("MERIDIAN_OK")
                exit(0)
            } catch {
                print("MERIDIAN_FAILED \(error)")
                exit(1)
            }
        }
        app.run()
        exit(1)
    }

    /// The selftest's side: begun at once so the audit runs beside the rest of the selftest, and
    /// read with a blocking wait, as `ChatChecks.Child` is.
    final class Child {
        private let process = Process()
        private let pipe = Pipe()
        private var startFailure: String?

        init() {
            guard let executable = Bundle.main.executablePath else {
                startFailure = "no executable path"
                return
            }
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--bench", MeridianChecks.spec]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                startFailure = "could not start the audit: \(error)"
            }
        }

        func verdict(timeout: TimeInterval = 90) -> (failure: String?, notes: String) {
            if let startFailure { return (startFailure, "") }
            let deadline = Date().addingTimeInterval(timeout)
            let pid = process.processIdentifier
            var exited = false
            while !exited, Date() < deadline {
                var status: Int32 = 0
                let reaped = waitpid(pid, &status, WNOHANG)
                exited = reaped == pid || reaped == -1
                if !exited { usleep(50_000) }
            }
            if !exited {
                kill(pid, SIGKILL)
                return ("the audit did not finish in \(Int(timeout)) s", "")
            }
            let lines = String(
                decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            ).split(separator: "\n")
            let notes = lines.last { $0.hasPrefix("MERIDIAN_NOTES ") }
                .map { String($0.dropFirst("MERIDIAN_NOTES ".count)) } ?? ""
            guard
                let verdict = lines.last(where: { $0 == "MERIDIAN_OK" || $0.hasPrefix("MERIDIAN_FAILED") })
            else { return ("the audit printed no verdict", notes) }
            return (
                verdict == "MERIDIAN_OK" ? nil : String(verdict.dropFirst("MERIDIAN_FAILED ".count)),
                notes
            )
        }
    }

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
        checks += try placesAndControls()
        return checks
    }

    /// Every label the sheet and the glance draw, walked: a one-line label must be as wide as its own
    /// words, a wrapping one as tall as its own lines, nothing may be set to truncate, and nothing may
    /// stand past the sheet's edge. Returns how many were looked at and how many fell short.
    static func audit(_ root: NSView) -> (audited: Int, cut: Int, notes: [String]) {
        var audited = 0
        var notes: [String] = []
        let truncating: Set<NSLineBreakMode> = [.byTruncatingHead, .byTruncatingTail, .byTruncatingMiddle]
        func fail(_ what: String, _ view: NSView) { notes.append("\(what): \(type(of: view))") }
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            if view is NSSearchField { return }
            if let field = view as? NSTextField, !field.stringValue.isEmpty, let cell = field.cell {
                audited += 1
                let text = String(field.stringValue.prefix(24))
                if truncating.contains(field.lineBreakMode) {
                    fail("truncates \"\(text)\"", field)
                } else if field.maximumNumberOfLines == 1 {
                    if cell.cellSize.width > field.frame.width + 0.5 {
                        fail("cut short \"\(text)\" \(field.frame.width) < \(cell.cellSize.width)", field)
                    }
                } else {
                    let needed = cell.cellSize(
                        forBounds: NSRect(x: 0, y: 0, width: field.frame.width, height: 10_000)).height
                    if needed > field.frame.height + 1 {
                        fail("clips lines of \"\(text)\" \(field.frame.height) < \(needed)", field)
                    }
                }
                let box = field.convert(field.bounds, to: root)
                if box.maxX > root.bounds.width + 0.5 || box.minX < -0.5 {
                    fail("stands outside the sheet \"\(text)\"", field)
                }
            } else if let button = view as? NSButton, !button.title.isEmpty, let cell = button.cell {
                audited += 1
                if cell.cellSize.width > button.frame.width + 1 { fail("cut short button \(button.title)", button) }
            }
            for child in view.subviews { walk(child) }
        }
        walk(root)
        return (audited, notes.count, notes)
    }

    private static func place(
        _ content: MeridianSheetContent, width: CGFloat, height: CGFloat
    ) {
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        for _ in 0..<5 {
            content.needsLayout = true
            content.layoutSubtreeIfNeeded()
        }
    }

    private static func placesAndControls() throws -> Int {
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure(label) }
        }
        var checks = 0
        let feed = MeridianFeed.shared
        let stash = WorldClockStore.current
        defer {
            WorldClockStore.save(stash)
            feed.preferencesOverride = nil
            feed.forcesFixtures = false
        }
        WorldClockStore.save(.default)
        let now = feed.now
        let status = MeridianPlaces.status(.default)
        try expect(status.count == 0 && !status.isFull, "an empty list reads as full")
        try expect(
            MeridianPlaces.status(WorldClockPreferences(pins: Array(repeating: "tokyo", count: 8))).isFull,
            "eight places do not read as full")
        let suggestions = MeridianPlaces.suggestions(preferences: .default, viewer: feed.viewer, now: now)
        let matches = MeridianPlaces.results(for: "to", preferences: .default, viewer: feed.viewer, now: now)
        try expect(!suggestions.isEmpty && !matches.isEmpty, "the add-a-place lists came back empty")
        try expect(
            matches.allSatisfy { !$0.time.isEmpty && !$0.offset.isEmpty }, "a place does not read by its clock")
        checks += 4

        let content = MeridianSheetContent()
        place(content, width: 1392, height: 796)
        try expect(content.addPlace.isExpanded, "a sheet with no places did not open Add a place")
        try expect(
            content.addPlace.rows.count == suggestions.count, "the empty state does not list the suggestions")
        try expect(!content.handleEscape(), "an Esc nobody asked for was swallowed by the empty state")
        content.addPlace.open(focusing: true)
        content.addPlace.setQuery("to")
        try expect(content.addPlace.rows.count == matches.count, "typing did not narrow the list to its matches")
        content.addPlace.moveHighlight(1)
        try expect(content.addPlace.highlight == 1, "Down did not move the highlight")
        try expect(content.handleEscape() && content.addPlace.query.isEmpty, "Esc did not clear the field first")
        try expect(content.addPlace.isExpanded, "Esc closed the list before the field was empty")
        try expect(content.handleEscape() && !content.addPlace.isExpanded, "Esc did not close the list second")
        try expect(!content.handleEscape(), "Esc was kept after nothing was open")
        content.addPlace.open(focusing: true)
        content.addPlace.setQuery("zzzzqq")
        try expect(content.addPlace.rows.isEmpty, "a query nothing matches still listed places")
        content.addPlace.setQuery("tokyo")
        content.addPlace.pinHighlighted()
        try expect(WorldClockStore.current.pins == ["tokyo"], "Return did not pin the highlighted place")
        try expect(!content.addPlace.isExpanded, "pinning left the list open")
        checks += 11

        content.rerender()
        try expect(content.lanes.laneCount == 2, "the pinned place did not become a lane")
        let tokyoRow = content.lanes.rows.last
        try expect(tokyoRow?.controlsAreShown == false, "a lane's controls show with nobody near it")
        tokyoRow?.controlButtons.first?.onFocusChange?(true)
        try expect(tokyoRow?.controlsAreShown == true, "keyboard focus did not show a lane's controls")
        try expect(
            content.lanes.rows.first?.controlButtons.allSatisfy { $0.isHidden } == true,
            "the viewer's own lane carries controls")
        try expect(
            tokyoRow?.controlButtons.map(\.isEnabled) == [false, false, true],
            "a lone place can move or the remove control is off")
        checks += 4

        for segment in content.styleSegments where segment.style == .h12 {
            segment.onSelect?(.h12)
        }
        try expect(WorldClockStore.current.style == .h12, "the 12-hour segment did not write the store")
        content.rerender()
        try expect(content.board.style == .h12, "the sheet did not redraw in the chosen format")
        try expect(
            content.styleSegments.filter(\.isChosen).map(\.style) == [.h12], "the chosen segment is not the style")
        try expect(
            content.styleSegments.allSatisfy { $0.intrinsicContentSize.width > 40 }, "a segment has no room for its words")
        checks += 4
        return checks
    }

    static func labelsAreWhole() throws -> (checks: Int, audited: Int) {
        let feed = MeridianFeed.shared
        let key = "tailscode.uiScale"
        defer {
            UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            feed.preferencesOverride = nil
            feed.forcesFixtures = false
        }
        feed.forcesFixtures = true
        var cities = WorldClockPreferences(
            pins: ["tokyo", "san-francisco", "london", "sydney", "new-york", "sao-paulo", "dubai", "singapore"],
            style: .h12)
        var checks = 0
        var audited = 0
        for zoom in [1.0, 1.5, 2.0] {
            UserDefaults.standard.setVolatileDomain([key: zoom], forName: UserDefaults.argumentDomain)
            for (width, height) in [(1392.0, 796.0), (752.0, 520.0)] {
                for crowded in [true, false] {
                    cities.style = crowded ? .h12 : .h24
                    feed.preferencesOverride = crowded ? cities : .default
                    let content = MeridianSheetContent()
                    if crowded {
                        content.addPlace.open(focusing: false)
                        content.addPlace.setQuery("to")
                    }
                    place(content, width: CGFloat(width), height: CGFloat(height))
                    let result = audit(content)
                    audited += result.audited
                    if result.cut != 0 {
                        throw SelfTestFailure(
                            "zoom \(zoom) \(Int(width))x\(Int(height)) \(crowded ? "eight places" : "none"): "
                                + "\(result.cut) of \(result.audited) cut short — \(result.notes.prefix(3).joined(separator: "; "))")
                    }
                    checks += 1
                }
            }
            for crowded in [true, false] {
                feed.preferencesOverride = crowded ? cities : .default
                let glance = ClockGlanceViewController(reading: feed.reading())
                glance.view.frame = NSRect(origin: .zero, size: glance.view.fittingSize)
                for _ in 0..<3 {
                    glance.view.needsLayout = true
                    glance.view.layoutSubtreeIfNeeded()
                }
                let result = audit(glance.view)
                audited += result.audited
                if result.cut != 0 {
                    throw SelfTestFailure(
                        "glance at zoom \(zoom): \(result.cut) of \(result.audited) cut short — \(result.notes.prefix(3).joined(separator: "; "))")
                }
                checks += 1
            }
        }
        return (checks, audited)
    }
}

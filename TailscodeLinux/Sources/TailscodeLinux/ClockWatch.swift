import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The one world clock the process keeps: what the chip, the glance and the sheet are all read
/// from, and the minute they are all redrawn on. Everything it says is Core's — this only gathers
/// the inputs a desk has (the servers it talks to, the quota windows it already holds, the stores)
/// and wakes whoever is drawing at the boundary of each minute, never faster, because a clock that
/// has nothing new to say is a clock that holds still.
///
/// Alarms fire from the same wake. They exist only while the app runs; an alarm that came due while
/// it was closed is told with how late it is by Core, or dropped when it is stale.
final class ClockWatch: @unchecked Sendable {
    static let shared = ClockWatch()

    /// The clock a harness may replace to read the surfaces at a fixed moment.
    nonisolated(unsafe) var clock: @Sendable () -> Date = ClockWatch.defaultClock

    /// `TAILSCODE_CLOCK_AT=14:07` on a fixture launch starts the day at that time and lets it run
    /// from there, so a screenshot of the surfaces is the same on every machine at every hour.
    private static let defaultClock: @Sendable () -> Date = {
        guard WorldClockFixtures.isOn,
            let text = ProcessInfo.processInfo.environment["TAILSCODE_CLOCK_AT"]
        else { return { Date() } }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return { Date() } }
        let start = Date()
        let calendar = Calendar(identifier: .gregorian)
        guard let target = calendar.date(
            bySettingHour: parts[0], minute: parts[1], second: 0, of: start)
        else { return { Date() } }
        let offset = target.timeIntervalSince(start)
        return { Date().addingTimeInterval(offset) }
    }()

    private var holdings: [QuotaHolding] = []
    private var servers: [(name: String, url: URL)] = []
    private var listeners: [Int: @Sendable () -> Void] = [:]
    private var nextToken = 0
    private var started = false

    var now: Date { clock() }

    /// Whether the surfaces show the fixtures a headless launch asks for. A harness that proves the
    /// stores turns it off for the length of its claims.
    nonisolated(unsafe) var usesFixtures = WorldClockFixtures.isOn
    private var fixturePreferences = WorldClockFixtures.preferences

    /// The preferences the surfaces show. A fixture launch shows its own pins and style, kept in
    /// memory and never written, so a headless run has cities to look at and to remove without
    /// touching what the person chose.
    var preferences: WorldClockPreferences {
        usesFixtures ? fixturePreferences : WorldClockStore.current
    }

    /// The one road every surface changes the preferences by.
    func updatePreferences(_ change: (inout WorldClockPreferences) -> Void) {
        guard usesFixtures else {
            WorldClockStore.update(change)
            return
        }
        let before = fixturePreferences
        change(&fixturePreferences)
        if fixturePreferences != before { changed() }
    }

    var machines: [MachineClock] {
        usesFixtures
            ? WorldClockFixtures.machines : MachineClocks.measured(servers, now: now)
    }

    var currentHoldings: [QuotaHolding] {
        usesFixtures ? WorldClockFixtures.holdings(now: now) : holdings
    }

    func reading() -> WorldClockReading {
        WorldClockReading.make(
            now: now, preferences: preferences, machines: machines, holdings: currentHoldings)
    }

    func board(scrubMinute: Int?) -> MeridianBoard {
        MeridianBoard.make(
            now: now, scrubMinute: scrubMinute, preferences: preferences, machines: machines,
            holdings: currentHoldings, alarms: ClockAlarmStore.current)
    }

    func setHoldings(from quotas: [(String, UsageQuota)]) {
        let next = QuotaRollup.account(from: quotas)
        guard next != holdings else { return }
        holdings = next
        changed()
    }

    func setServers(_ profiles: [ConnectionProfile]) {
        servers = profiles.map { (name: $0.name, url: $0.baseURL) }
    }

    /// Calls `listener` on the main loop whenever the minute turns or anything the surfaces read
    /// changes. The token is handed back to `stopObserving`.
    @discardableResult
    func observe(_ listener: @escaping @Sendable () -> Void) -> Int {
        nextToken += 1
        listeners[nextToken] = listener
        return nextToken
    }

    func stopObserving(_ token: Int) { listeners[token] = nil }

    func changed() {
        for listener in Array(listeners.values) { listener() }
    }

    /// Starts the minute clock and the store observers, and collects whatever came due while the
    /// app was closed. Idempotent: the sidebar may be built more than once.
    func start() {
        guard !started else { return }
        started = true
        for name in [WorldClockStore.didChange, ClockAlarmStore.didChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                Gtk.onMain {
                    ClockWatch.shared.persist()
                    ClockWatch.shared.changed()
                }
            }
        }
        fireDue()
        refreshServers()
        schedule()
    }

    /// The stores write to the defaults, which on this desk are not durable by themselves, and a
    /// store that went back to its default removes its key, which the settings file would
    /// otherwise hand back on the next launch.
    func persist() {
        for key in [WorldClockStore.defaultsKey, ClockAlarmStore.defaultsKey] {
            SettingsFile.set(UserDefaults.standard.object(forKey: key), forKey: key)
        }
        SettingsFile.capture()
    }

    /// Tells every surface the theme moved, so each repaints with the palette's new inks.
    func themeChanged() { changed() }

    private func schedule() {
        let wait = max(0.25, WorldClockReading.nextMinute(after: now).timeIntervalSince(now))
        Gtk.after(UInt32(wait * 1000) + 120) {
            Gtk.onMain { ClockWatch.shared.tick() }
        }
    }

    private func tick() {
        fireDue()
        refreshServers()
        changed()
        schedule()
    }

    /// Every alarm whose minute has come, told through the notifications the desk already raises.
    func fireDue() {
        let style = preferences.style
        for alarm in ClockAlarmStore.collectDue(now: now) {
            let words = alarm.notice(now: now, style: style)
            Notifier.shared.raiseClockAlarm(id: alarm.id, title: words.title, body: words.body)
        }
    }

    private func refreshServers() {
        Task {
            let profiles = await ServerDirectory.shared.profiles()
            Gtk.onMain { ClockWatch.shared.setServers(profiles) }
        }
    }
}

/// The inks the world clock's drawing areas paint with, resolved from the palette once per
/// repaint: the eleven colours `tailscode_meridian_set_inks` takes.
enum MeridianInk {
    static func rgb(_ hex: String) -> [Double] {
        let colour = PresenceRGB(hex: hex) ?? PresenceRGB(red: 0.5, green: 0.5, blue: 0.5)
        return [colour.red, colour.green, colour.blue]
    }

    /// Night is the canvas let down towards black (towards the ink on a light theme, where black
    /// would read as a hole); day is the theme's `info` let into the canvas.
    static func night(_ palette: Palette) -> String {
        palette.isDark
            ? Contrast.blend(palette.canvas, "#000000", 0.2) ?? palette.canvas
            : Contrast.blend(palette.canvas, palette.text, 0.32) ?? palette.canvas
    }

    static func day(_ palette: Palette) -> String {
        Contrast.blend(palette.canvas, palette.info, 0.45) ?? palette.canvas
    }

    static var values: [Double] {
        let palette = MatrixTheme.palette
        return [
            palette.canvas, palette.text, palette.textDim, palette.accent, palette.warn,
            palette.info, palette.special, night(palette), day(palette), palette.canvasRaised,
            palette.rule,
        ].flatMap(rgb)
    }

    static func apply(to widget: UnsafeMutablePointer<GtkWidget>) {
        values.withUnsafeBufferPointer { tailscode_meridian_set_inks(widget, $0.baseAddress) }
    }

    /// The pale ink a moon, an unlit dot or a night glyph is drawn in: the text colour let a little
    /// way into the canvas.
    static var pale: String {
        let palette = MatrixTheme.palette
        return Contrast.blend(palette.text, palette.canvas, 0.2) ?? palette.text
    }

    static var twilight: String {
        let palette = MatrixTheme.palette
        return Contrast.blend(palette.warn, palette.danger, 0.45) ?? palette.warn
    }

    static func glyph(
        _ widget: UnsafeMutablePointer<GtkWidget>, kind: TailscodeGlyphKind, progress: Double = 0.5,
        body: [Double], line: [Double]? = nil
    ) {
        apply(to: widget)
        let ink = line ?? rgb(MatrixTheme.palette.textDim)
        body.withUnsafeBufferPointer { bodyPointer in
            ink.withUnsafeBufferPointer { inkPointer in
                tailscode_glyph_set(
                    widget, Int32(kind.rawValue), progress, bodyPointer.baseAddress,
                    inkPointer.baseAddress)
            }
        }
    }

    static func sky(_ widget: UnsafeMutablePointer<GtkWidget>, _ sky: SkyGlyph) {
        let palette = MatrixTheme.palette
        switch sky.phase {
        case .day:
            glyph(widget, kind: TAILSCODE_GLYPH_SKY_DAY, progress: sky.progress, body: rgb(palette.warn))
        case .twilight:
            glyph(widget, kind: TAILSCODE_GLYPH_SKY_TWILIGHT, progress: sky.progress, body: rgb(twilight))
        case .night:
            glyph(widget, kind: TAILSCODE_GLYPH_SKY_NIGHT, progress: sky.progress, body: rgb(pale))
        }
    }

    /// A day's strip painted from Core's bar, for the glance and for every lane.
    static func paint(
        strip: UnsafeMutablePointer<GtkWidget>, bar: DaylightBar, hairline: Double = 0,
        grid: Int = 0, noon: Bool = false
    ) {
        apply(to: strip)
        let pairs = bar.stops.flatMap { [$0.position, $0.light] }
        pairs.withUnsafeBufferPointer { tailscode_strip_set_stops(strip, $0.baseAddress, Int32(bar.stops.count)) }
        tailscode_strip_set_finish(strip, hairline, Int32(grid), grid > 0 ? 0.06 : 0)
        tailscode_strip_set_noon(strip, noon ? (bar.noon ?? -1) : -1)
    }
}

import AppKit
import CodingAgentKit
import TailscodeCore

/// What every Meridian surface reads and the one clock they share. The chip, the glance and the
/// sheet each ask this for a reading or a board, so they cannot disagree about the inputs: the
/// preferences, the machines the app has heard from, the quota windows the usage strip is built
/// from and the alarms. A debug launch with `TAILSCODE_CLOCK_FIXTURES=1` swaps in Core's fixtures,
/// which are never persisted.
///
/// The clock is one timer scheduled for the next minute boundary and armed again each time it
/// fires, never a faster poll: nothing on the face of a clock changes between minutes. Every tick
/// also takes the alarms that have come due out of the book and raises them through the app's own
/// notifier, once at launch too, so an alarm that came due while the app was closed is told as late
/// rather than not at all. Alarms fire only while the app runs.
@MainActor
final class MeridianFeed {
    static let shared = MeridianFeed()
    static let didTick = Notification.Name("tailscode.mac.meridian.didTick")

    private(set) var quotas: [(String, UsageQuota)] = []
    private var timer: Timer?
    private var started = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// The moment every surface reads. A fixture launch may hold it still with
    /// `TAILSCODE_CLOCK_NOW=<epoch seconds>`, which is how a window about to reopen or an alarm
    /// about to ring is looked at at an hour the person is not awake for.
    var now: Date {
        guard WorldClockFixtures.isOn,
            let raw = ProcessInfo.processInfo.environment["TAILSCODE_CLOCK_NOW"],
            let epoch = TimeInterval(raw)
        else { return Date() }
        return Date(timeIntervalSince1970: epoch)
    }

    var viewer: TimeZone {
        TimeZone(identifier: TimeZone.autoupdatingCurrent.identifier) ?? .current
    }

    var preferences: WorldClockPreferences {
        WorldClockFixtures.isOn ? WorldClockFixtures.preferences : WorldClockStore.current
    }

    var machines: [MachineClock] {
        if WorldClockFixtures.isOn { return WorldClockFixtures.machines }
        return MachineClocks.measured(
            ServerDirectory.shared.profiles.map { (name: $0.name, url: $0.baseURL) })
    }

    var alarms: ClockAlarmBook {
        var book = ClockAlarmStore.current
        guard WorldClockFixtures.isOn else { return book }
        let now = self.now
        book.add(
            at: WorldClockReading.nextMinute(after: now.addingTimeInterval(95 * 60)),
            zoneID: viewer.identifier, note: "Deploy window", now: now)
        return book
    }

    func holdings(now: Date) -> [QuotaHolding] {
        WorldClockFixtures.isOn
            ? WorldClockFixtures.holdings(now: now) : QuotaRollup.account(from: quotas)
    }

    func resets(now: Date) -> [ClockReset] {
        ClockResets.upcoming(holdings: holdings(now: now), now: now, limit: 4)
    }

    func reading(now at: Date? = nil) -> WorldClockReading {
        let now = at ?? self.now
        return WorldClockReading.make(
            now: now, preferences: preferences, viewer: viewer, machines: machines,
            holdings: holdings(now: now))
    }

    func board(now at: Date? = nil, scrubMinute: Int? = nil) -> MeridianBoard {
        let now = at ?? self.now
        return MeridianBoard.make(
            now: now, scrubMinute: scrubMinute, preferences: preferences, viewer: viewer,
            machines: machines, holdings: holdings(now: now), alarms: alarms)
    }

    /// The usage poll's latest answer, handed over by the sidebar each time it draws the quota
    /// strip, so the glance's resets are the strip's own windows. The poll comes every minute, so
    /// a surface that is open is told through the same notification the clock uses.
    func update(quotas: [(String, UsageQuota)]) {
        self.quotas = quotas
        NotificationCenter.default.post(name: Self.didTick, object: nil)
    }

    func start() {
        guard !started else { return }
        started = true
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        let changes = [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange].map {
            name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.fire() }
            }
        }
        observers = [wake] + changes
        fire()
    }

    private func fire() {
        let now = Date()
        let style = preferences.style
        for alarm in ClockAlarmStore.collectDue(now: now) {
            MacNotifier.shared.raiseClockAlarm(alarm, style: style, now: now)
        }
        NotificationCenter.default.post(name: Self.didTick, object: nil)
        arm(after: now)
    }

    private func arm(after now: Date) {
        timer?.invalidate()
        let next = WorldClockReading.nextMinute(after: now)
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

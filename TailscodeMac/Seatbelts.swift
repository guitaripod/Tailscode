import AppKit
import Darwin
import Foundation
import TailscodeCore

/// The panes as the seatbelts see them: what the governor ranks, and the counts the recorder keeps.
struct SeatbeltPanes: Sendable {
    var facts: [PaneFacts] = []
    /// Panes on screen and live.
    var live = 0
    /// Panes in the tree but not on screen: zoomed away.
    var hidden = 0
    /// Chat panes holding a restored session they have not opened: parked by a safe restore or
    /// waiting their turn in a staggered one.
    var parked = 0
    /// The window is minimized or not visible at all.
    var occluded = false
}

/// What the current shed level lets the window spend on motion, read by every clock it governs.
///
/// The cascade reveal runs below loaded, becomes instant at loaded, and every other animation
/// stops at strained. The cascade's own display link is held to the level's tick cap from busy up;
/// calm leaves it at the panel's rate, because a reveal at thirty frames reads as a hand that
/// stutters (the transcript doctrine asks for up to 120 Hz on the Mac).
@MainActor
enum MotionBudget {
    private(set) static var level: ShedLevel = .calm
    static let didChange = Notification.Name("tailscode.mac.motionBudget.didChange")

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private static var budget: AnimationBudget {
        TileGovernor.animation(level: level, reducedMotion: false)
    }

    /// Whether the written-not-pasted reveal may run.
    static var cascadeAllowed: Bool { !reduceMotion && budget.cascade == .focusedOnly }

    /// Whether anything else may move: entrances, breathing marks, laps.
    static var animationAllowed: Bool { !reduceMotion && budget.pulses }

    /// The cascade link's rate at this level.
    static var cascadeRange: CAFrameRateRange {
        guard level > .calm, budget.tickCap > 0 else {
            return CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        }
        let cap = Float(budget.tickCap)
        return CAFrameRateRange(minimum: min(cap, 10), maximum: cap, preferred: cap)
    }

    /// Moves the budget to a level. When what may move changes, every clock is asked again: the
    /// cascade through `didChange`, and every repeating lap through the same workspace notice a
    /// reduced-motion switch sends, which each of them already answers by re-deciding.
    static func apply(_ next: ShedLevel) {
        guard next != level else { return }
        let animatedBefore = animationAllowed
        let cascadeBefore = cascadeAllowed
        let rangeBefore = cascadeRange
        level = next
        if cascadeBefore != cascadeAllowed || rangeBefore != cascadeRange {
            NotificationCenter.default.post(name: didChange, object: nil)
        }
        if animatedBefore != animationAllowed {
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
    }
}

/// The seatbelts: the sensors, the black box, the launch ledger and the governor, sampled once a
/// second on the main run loop.
///
/// Every second it reads the loop meter, the memory and heat, the watchdog's hint and the panes,
/// asks `TileGovernor` for a level, applies what today's panes can do with it (`MotionBudget`, and
/// `MemoryRelief` at strained and above), and writes one record to the flight ring. The watchdog
/// and the pressure source write their own records from their own threads, because a main thread
/// that has stopped is exactly when a record must still be written.
@MainActor
final class Seatbelts {
    static let shared = Seatbelts()

    let meter = LoopMeter()
    private(set) var writer: FlightWriter?
    private(set) var watchdog: Watchdog?
    private(set) var pressure = MemoryPressure()
    private var governor = TileGovernor()
    private(set) var decision: GovernorDecision?
    private(set) var level: ShedLevel = .calm
    private var forced: ShedLevel?
    private var timer: Timer?
    private var terminate: DispatchSourceSignal?
    private var ledger: LaunchLedger?
    private var ledgerURL = LaunchLedger.defaultURL()
    private var touched: [PaneID: TimeInterval] = [:]
    private(set) var isRunning = false

    /// How long after launch the first sample waits. Building the window and restoring its panes
    /// is one long slice by nature, and a governor that read it would start every launch shedding;
    /// waiting lets that slice age out of the two-second window. A launch that truly hangs is still
    /// caught: the watchdog writes its record and holds its hint until the first sample takes it.
    static let launchGrace: TimeInterval = 3

    /// The window's panes, asked once a sample.
    var panes: (() -> SeatbeltPanes)?
    /// Told every decision, so the window can park what the governor parks.
    var onDecision: ((GovernorDecision) -> Void)?

    /// Starts everything: the ring and its launch record, the loop meter, the watchdog, the
    /// pressure source, the one-second sample and the SIGTERM path to a clean quit. Called once
    /// from the app delegate, before the window restores anything.
    func start(
        ringURL: URL = FlightRing.defaultURL(), ledgerURL: URL = LaunchLedger.defaultURL()
    ) {
        guard !isRunning else { return }
        isRunning = true
        self.ledgerURL = ledgerURL
        do {
            writer = try FlightWriter(url: ringURL)
        } catch {
            AppLogger.performance.error("flight ring unavailable at \(ringURL.path): \(error)")
        }
        writer?.write(
            .launch(FlightWriter.header(), t: FlightRecord.epochMilliseconds()))
        meter.install()
        let writer = self.writer
        let watchdog = Watchdog(
            report: { event, state in
                let line = Watchdog.event(event, state)
                var record = FlightRecord(t: FlightRecord.epochMilliseconds(), ev: line)
                switch event {
                case .stall(let seconds), .deep(let seconds):
                    record.stall = Int((seconds * 1000).rounded())
                case .recovered:
                    break
                }
                writer?.write(record)
                AppLogger.performance.error("watchdog: \(line)")
            },
            onResume: { Seatbelts.shared.sample() })
        watchdog.start()
        self.watchdog = watchdog
        pressure = MemoryPressure { pressure in
            writer?.write(
                FlightRecord(
                    t: FlightRecord.epochMilliseconds(), ps: pressure.code,
                    ev: "pressure \(pressure.code)"))
        }
        pressure.start()
        let timer = Timer(
            fire: Date().addingTimeInterval(Self.launchGrace), interval: 1, repeats: true
        ) { _ in
            MainActor.assumeIsolated { Seatbelts.shared.sample() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        quitOnTerminate()
    }

    /// A `kill <pid>` asks the app to quit, and quitting is the exit path that saves drafts and
    /// marks the launch clean; left to the default, SIGTERM ends the process where it stands and
    /// the next launch reads it as a crash. The signal gets an empty handler rather than `SIG_IGN`:
    /// an ignored signal stays ignored across `exec`, so every command the terminal pane runs would
    /// inherit a deaf ear to SIGTERM, while a caught one goes back to the default in the child.
    private func quitOnTerminate() {
        signal(SIGTERM) { _ in }
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        source.resume()
        terminate = source
    }

    /// Records this launch as not yet closed and decides how the window comes back. A repeat of
    /// an unclean exit holds the governor at the plan's floor for its duration. Before `start` —
    /// a selftest building a window — there is no launch to record, and the restore is plain.
    func beginLaunch(chatPanes: Int) -> RestorePlan {
        guard isRunning else { return RestorePlan(mode: .staggered, unclean: false) }
        let started = LaunchLedger.begin(url: ledgerURL, panes: chatPanes)
        ledger = started.current
        let plan = RestorePlan.decide(ledger: started.previous, paneCount: chatPanes)
        if plan.unclean {
            var line = "restore unclean"
            if case .parked(let count) = plan.mode { line += " parked \(count)" }
            writer?.write(FlightRecord(t: FlightRecord.epochMilliseconds(), ev: line))
            AppLogger.lifecycle.info("restore: the last launch did not close normally (\(line))")
        }
        if let floor = plan.floor {
            governor.hold(atLeast: floor, until: MachClock.now() + plan.floorDuration)
            writer?.write(
                FlightRecord(
                    t: FlightRecord.epochMilliseconds(),
                    ev: "floor \(floor.rawValue) \(Int(plan.floorDuration))s"))
        }
        return plan
    }

    /// The last thing a quitting app does: the clean-exit record, synced, and the ledger flipped.
    func finish(panes: Int) {
        guard isRunning else { return }
        timer?.invalidate()
        timer = nil
        watchdog?.stop()
        writer?.writeNow(
            FlightRecord(
                t: FlightRecord.epochMilliseconds(), lv: level.rawValue, ev: "exit clean"))
        if let ledger {
            LaunchLedger.markClean(
                url: ledgerURL, launchID: ledger.launchID, panes: panes, level: level.rawValue)
        }
    }

    /// Pins the level, for the drive hook; nil hands it back to the governor.
    func force(_ level: ShedLevel?) {
        forced = level
        sample()
    }

    /// One look at everything, one decision, one record.
    func sample() {
        guard isRunning else { return }
        let now = MachClock.now()
        let loop = meter.reading()
        let memory = pressure.reading()
        let hint = watchdog?.takeHint() ?? false
        var seen = panes?() ?? SeatbeltPanes()
        for index in seen.facts.indices {
            let id = seen.facts[index].id
            if seen.facts[index].focused { touched[id] = now }
            seen.facts[index].lastTouched = touched[id] ?? 0
        }
        touched = touched.filter { entry in seen.facts.contains { $0.id == entry.key } }
        let sample = GovernorSample(
            loopBusy: loop.busy2, worstStall: loop.worst1, host: memory.host,
            ownMemory: memory.ownMemory, thermal: memory.thermal, lowPower: memory.lowPower,
            reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            occluded: seen.occluded, watchdog: hint)
        let decision = governor.evaluate(now: now, sample: sample, panes: seen.facts, setting: .auto)
        self.decision = decision
        onDecision?(decision)
        let previous = level
        let next = forced ?? decision.level
        var events: [String] = []
        if next != previous {
            if forced != nil {
                events.append("shed \(previous.rawValue)->\(next.rawValue) forced")
            } else if let transition = decision.transition {
                events.append(transition.event)
            } else {
                events.append("shed \(previous.rawValue)->\(next.rawValue) released")
            }
            AppLogger.performance.info("shed: \(events[0]) · \(decision.reasons.map(\.code).joined(separator: ", "))")
        }
        level = next
        MotionBudget.apply(next)
        if next > previous, MemoryRelief.depth(for: next) != nil {
            let relieved = MemoryRelief.shared.relieve(level: next)
            events.append("relief \(relieved.count)")
        }
        let counts = FlightWriter.processCounts()
        var record = FlightRecord(
            t: FlightRecord.epochMilliseconds(),
            rss: memory.footprintBytes.map { $0 / 1024 }, thr: counts.threads, fds: counts.fds,
            panes: FlightPanes(full: seen.live, glance: 0, parked: seen.hidden + seen.parked),
            lv: next.rawValue, busy: loop.busy1, stall: Int((loop.worst1 * 1000).rounded()),
            ps: memory.host.code, own: memory.ownMemory, ev: events.first)
        writer?.write(record)
        for extra in events.dropFirst() {
            record.ev = extra
            writer?.write(record)
        }
    }
}

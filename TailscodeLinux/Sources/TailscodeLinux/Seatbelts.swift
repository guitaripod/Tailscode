import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// What the window tells the seatbelts about its panes each second.
struct SeatbeltPanes {
    var facts: [PaneFacts]
    /// Panes laid out on screen.
    var placed: Int
    /// Panes the zoom has hidden, and chats a safe restore left paused.
    var hidden: Int
    /// Chats drawn as glance tiles.
    var glance = 0

    static let empty = SeatbeltPanes(facts: [], placed: 0, hidden: 0)
}

/// The seatbelts in one place: the loop meter, the stall watchdog, the pressure sensor, the flight
/// recorder, the launch ledger and the governor that turns their readings into a shed level.
///
/// The governor runs once a second on the main loop, because the loop meter can only be read there
/// and the level's effects land on widgets. Everything that must keep going while the loop is stuck
/// — the pings, the pressure files, the ring — runs on the watchdog thread, and the two meet only
/// in the small locked publication below. Nothing here holds a title, an id or a word.
final class Seatbelts: @unchecked Sendable {
    static let shared = Seatbelts()

    private let meter = LoopMeter()
    private var governor = TileGovernor()
    private var forced: ShedLevel?
    private(set) var level: ShedLevel = .calm
    private(set) var lastDecision: GovernorDecision?
    private var touched: [PaneID: TimeInterval] = [:]
    private var panes: (() -> SeatbeltPanes)?
    /// Told every decision on the main loop, so the window can give each pane the density the
    /// governor assigns.
    var onDecision: ((GovernorDecision) -> Void)?
    /// How many chats the person asked to keep whole: `Keep all live` is `.all`, otherwise the
    /// governor's own budget. At strained and above the governor caps it whatever it says.
    private(set) var liveBudget: LiveBudget = .auto
    private var started = false
    private var stopped = false
    private var ledger: LaunchLedger?
    private var paneCount = 0
    private var header: FlightHeader?

    private let lock = NSLock()
    private var publication = LoopPublication()
    private var events: [String] = []
    private var stallHint = false
    private var exited = false
    private var writer: FlightWriter?
    private var writerFailed = false

    let pressure = PressureSensor()
    private let watchdog = Watchdog()
    private let sampler = BusySampler()
    private var sustained = SustainedBusy()
    private var busyRising = false
    private var busyCapture: TimeInterval?
    private var lastSlowCapture: TimeInterval = -.infinity

    var isStarted: Bool { started }

    var isStopped: Bool { stopped }

    static let liveBudgetKey = "tailscode.liveBudget"

    /// Reads the person's choice back from the settings file, once, before the window is built.
    func restoreLiveBudget() {
        liveBudget = UserDefaults.standard.string(forKey: Self.liveBudgetKey) == "all" ? .all : .auto
    }

    /// `Keep all live` on or off, remembered, and applied at once rather than at the next second.
    func setLiveBudget(_ budget: LiveBudget) {
        liveBudget = budget
        SettingsFile.set(budget == .all ? "all" : nil, forKey: Self.liveBudgetKey)
        tick()
    }

    /// One divider step's relayout, in milliseconds: the worst of the second goes to the ring.
    func noteRelayout(_ milliseconds: Double) {
        let rounded = Int(milliseconds.rounded())
        lock.lock()
        publication.relayoutMs = max(publication.relayoutMs, rounded)
        lock.unlock()
    }

    /// Writes this launch's ledger as not yet closed and decides how the window comes back from
    /// what the last launch left. Main loop, before the panes are restored.
    func beginLaunch(chatPanes: Int) -> RestorePlan {
        let begun = LaunchLedger.begin(url: LaunchLedger.defaultURL(), panes: chatPanes)
        ledger = begun.current
        paneCount = chatPanes
        let plan = RestorePlan.decide(ledger: begun.previous, paneCount: chatPanes)
        if plan.unclean {
            enqueue("restore unclean \(chatPanes)")
            AppLog.write(
                .lifecycle,
                "launch after an unclean exit · \(chatPanes) chat panes · "
                    + (plan.bannerText == nil ? "staggered" : "parked"))
        }
        if let floor = plan.floor {
            governor.hold(atLeast: floor, until: Watchdog.now + plan.floorDuration)
            enqueue("floor \(floor.rawValue) \(Int(plan.floorDuration))s")
            AppLog.write(.lifecycle, "second unclean exit in a row · shed floor \(floor.code) for 10 min")
        }
        return plan
    }

    /// Starts the meter, the watchdog and the governor once the window is realised, so the launch
    /// header can name the renderer it actually got.
    func start(window: UnsafeMutablePointer<GtkWidget>, panes: @escaping () -> SeatbeltPanes) {
        guard !started else { return }
        started = true
        self.panes = panes
        header = Self.header(window: window)
        tailscode_set_picture_renderer(header?.renderer)
        if let header {
            AppLog.write(
                .lifecycle,
                "renderer \(header.renderer ?? "unknown") · gl \(header.glVendor ?? "none")")
        }
        meter.install()
        sampler.install()
        BackgroundGate.shared.watch(window: window)
        watchdog.start(
            onStall: { [weak self] event, state in self?.stalled(event, state) },
            onSlow: { [weak self] silent, state in self?.slow(silent, state) },
            onTick: { [weak self] now, poked in self?.recorderTick(now: now, poked: poked) })
        scheduleTick()
    }

    /// The person touched a pane: focused it, typed in it, pressed in it.
    func touch(_ pane: PaneID) {
        touched[pane] = Watchdog.now
    }

    /// The drive verb `shed=`: pins the level, or lets the governor decide again with nil.
    func force(_ level: ShedLevel?) {
        forced = level
        tick()
    }

    /// The drive verb `pressure=`.
    func inject(_ pressure: HostPressure) {
        self.pressure.inject(pressure)
        enqueue("pressure \(pressure.code) injected")
        tick()
    }

    /// The last `count` records of the ring, as `--flight` prints them.
    func flightText(last count: Int) -> String {
        FlightFormatter.format(FlightRing.read(url: FlightRing.defaultURL(), last: count))
    }

    /// A normal exit: the ring's last word and the ledger flipped, synchronously, because by the
    /// time this runs the process is on its way out. Every exit path calls it beside
    /// `SettingsFile.flush()`; it runs once.
    func exitClean() {
        lock.lock()
        let first = !exited
        exited = true
        let writer = self.writer
        let loop = publication
        lock.unlock()
        guard first else { return }
        writer?.write(
            FlightWriter.record(
                loop: loop, silence: 0, pressure: pressure.snapshot, counts: ProcessCounts.read(),
                event: "exit clean"))
        if let ledger {
            LaunchLedger.markClean(
                url: LaunchLedger.defaultURL(), launchID: ledger.launchID, panes: paneCount,
                level: level.rawValue)
        }
    }

    private func scheduleTick() {
        guard !stopped else { return }
        Gtk.after(1000) { [weak self] in
            guard let self, !self.stopped else { return }
            self.tick()
            self.scheduleTick()
        }
    }

    /// The window is going: the governor stops reading panes and telling them anything, and the
    /// once-a-second tick is not armed again. The watchdog thread and the ring keep going until
    /// ``exitClean()``, because they touch no widget. Safe to repeat.
    func stop() {
        stopped = true
        panes = nil
        onDecision = nil
    }

    /// One governor evaluation from this second's sensors, and its effects.
    private func tick() {
        guard started, !stopped else { return }
        let reading = meter.take()
        let snapshot = pressure.snapshot
        let watchdogHint = takeStallHint()
        let current = panes?() ?? .empty
        paneCount = current.facts.filter { $0.kind == .chat }.count
        let facts = current.facts.map { fact -> PaneFacts in
            var fact = fact
            fact.lastTouched = touched[fact.id] ?? 0
            return fact
        }
        touched = touched.filter { entry in facts.contains { $0.id == entry.key } }
        let reducedMotion = tailscode_animations_enabled() == 0
        let busyRun = sustained.record(busy: reading.loop.busy1, now: reading.now)
        let sample = GovernorSample(
            loopBusy: reading.loop.busy2, worstStall: reading.worstSinceLast, host: snapshot.host,
            ownMemory: snapshot.ownMemory, reducedMotion: reducedMotion, watchdog: watchdogHint)
        let decision = governor.evaluate(
            now: reading.now, sample: sample, panes: facts, setting: liveBudget)
        lastDecision = decision
        let effective = forced ?? decision.level
        var fresh: [String] = []
        if effective != level {
            let reason =
                forced != nil
                ? "forced" : decision.transition?.reason.code ?? ShedReason.relaxed.code
            fresh.append("shed \(level.rawValue)->\(effective.rawValue) \(reason)")
            AppLog.write(.lifecycle, "shed \(level.code) -> \(effective.code) · \(reason)")
            if effective > level, MemoryRelief.depth(for: effective) != nil {
                let relieved = MemoryRelief.shared.relieve(level: effective)
                if !relieved.isEmpty { fresh.append("relief \(relieved.count)") }
                Self.returnFreedMemory()
            }
            level = effective
        }
        BackgroundGate.shared.setLevel(effective)
        CascadeBudget.apply(
            TileGovernor.animation(level: effective, reducedMotion: reducedMotion), level: effective)
        var shown = decision
        shown.level = effective
        shown.fullBudget = governor.fullBudget(level: effective, setting: liveBudget)
        shown.animation = TileGovernor.animation(level: effective, reducedMotion: reducedMotion)
        onDecision?(shown)
        lock.lock()
        publication.busy = reading.loop.busy2
        publication.worstMs = max(publication.worstMs, Int((reading.worstSinceLast * 1000).rounded()))
        publication.level = effective.rawValue
        publication.panes = FlightPanes(
            full: current.placed, glance: current.glance, parked: current.hidden)
        let drained = LiveDrainStats.takeFlight()
        publication.mailbox = drained.ready
        publication.drainP95Ms = drained.passes > 0 ? (drained.p95 * 10_000).rounded() / 10 : nil
        events += fresh
        busyRising = sustained.isRising
        if let busyRun { busyCapture = busyRun }
        lock.unlock()
        if !fresh.isEmpty || busyRun != nil { watchdog.poke() }
    }

    /// Hands the free tails of every malloc arena back to the system once the caches that were
    /// just emptied have had a moment to free: a cache that gives its entries up to the allocator
    /// does nothing for the resident size until the allocator gives the pages up to the kernel.
    /// Off the main thread, because trimming a gigabyte heap is not instant.
    private static func returnFreedMemory() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
            _ = tailscode_heap_trim()
        }
    }

    private func enqueue(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
        if started { watchdog.poke() }
    }

    private func takeStallHint() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let hint = stallHint
        stallHint = false
        return hint
    }

    /// Watchdog thread: a stall, a deep stall or the recovery, written at once.
    private func stalled(_ event: StallWatch.Event, _ state: MainThreadState?) {
        let text: String
        switch event {
        case .stall(let silent):
            text = "stall \(Int(silent * 1000))ms \(state?.line ?? "?")"
            lock.lock()
            stallHint = true
            lock.unlock()
        case .deep(let silent):
            text = "deep \(Int(silent * 1000))ms \(state?.line ?? "?")"
            writeCapture(reason: "loop silent \(Self.seconds(silent)) s", state: state)
        case .recovered(let lasted):
            text = "stall over \(Int(lasted * 1000))ms"
        }
        AppLog.write(.lifecycle, "watchdog: \(text)")
        enqueue(text)
    }

    /// Watchdog thread: the loop has been silent for ``Watchdog/slowAfter`` and is still in
    /// whatever it is doing, which is the moment its stack means something. Once in fifteen
    /// seconds, because a loop that stalls every other second has said it already.
    private func slow(_ silent: TimeInterval, _ state: MainThreadState?) {
        let now = Watchdog.now
        guard now - lastSlowCapture >= 15 else { return }
        lastSlowCapture = now
        writeCapture(reason: "loop silent \(Self.seconds(silent)) s", state: state)
    }

    /// Watchdog thread: the busy run the governor tick saw, once the stacks and thread times are
    /// read. The summary also goes to the ring as a short event so `--flight` points at the log.
    private func busyTick(now: TimeInterval) {
        lock.lock()
        let rising = busyRising
        let owed = busyCapture
        busyCapture = nil
        lock.unlock()
        if rising { sampler.remember(now: now) } else { sampler.forget() }
        guard let owed else { return }
        writeCapture(
            reason: "sustained busy \(Self.seconds(owed)) s", state: MainThreadState.read())
    }

    private func writeCapture(reason: String, state: MainThreadState?) {
        for line in sampler.capture(reason: reason, now: Watchdog.now, main: state) {
            AppLog.write(.lifecycle, line)
        }
        enqueue("capture \(reason.prefix(24)) \(state?.line ?? "?")")
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f", value)
    }

    /// Watchdog thread, once a second and on every poke: one record per waiting event, or one
    /// plain record when nothing happened.
    private func recorderTick(now: TimeInterval, poked: Bool) {
        busyTick(now: now)
        if !poked { pressure.sample() }
        guard let writer = openWriter() else { return }
        lock.lock()
        let pending = events
        events = []
        let loop = publication
        let done = exited
        if !pending.isEmpty || !poked {
            publication.worstMs = 0
            publication.relayoutMs = 0
        }
        lock.unlock()
        guard !done, !pending.isEmpty || !poked else { return }
        let counts = ProcessCounts.read()
        let snapshot = pressure.snapshot
        let silence = now - Watchdog.lastAnswer
        let records = pending.isEmpty ? [nil] : pending.map { Optional($0) }
        for event in records {
            writer.write(
                FlightWriter.record(
                    loop: loop, silence: silence, pressure: snapshot, counts: counts, event: event))
        }
    }

    /// Opens the ring on the watchdog thread — a 675 KB read to find the newest record is not the
    /// main loop's to do — and writes the launch header first.
    private func openWriter() -> FlightWriter? {
        lock.lock()
        let existing = writer
        let failed = writerFailed
        lock.unlock()
        if let existing { return existing }
        guard !failed else { return nil }
        do {
            let opened = try FlightWriter()
            if let header { opened.writeHeader(header) }
            lock.lock()
            writer = opened
            lock.unlock()
            return opened
        } catch {
            lock.lock()
            writerFailed = true
            lock.unlock()
            AppLog.write(.persistence, "flight ring unavailable: \(error)")
            return nil
        }
    }

    /// The GL vendor is asked only of a GL renderer: under cairo or Vulkan, making a context just to
    /// read its vendor would load a whole GL driver into the process for one string.
    private static func drawsWithGL(_ renderer: String?) -> Bool {
        guard let renderer else { return false }
        return renderer.contains("GL") || renderer.contains("Ngl")
    }

    private static func header(window: UnsafeMutablePointer<GtkWidget>) -> FlightHeader {
        let renderer = tailscode_renderer_name(window).map { String(cString: $0) }
        var vendor: String?
        if Self.drawsWithGL(renderer), let raw = tailscode_gl_vendor(window) {
            vendor = String(cString: raw)
            g_free(raw)
        }
        let toolkit =
            "gtk \(gtk_get_major_version()).\(gtk_get_minor_version()).\(gtk_get_micro_version())"
            + " adw \(adw_get_major_version()).\(adw_get_minor_version())"
        return FlightHeader(
            version: TailscodeVersion.current, toolkit: toolkit, renderer: renderer,
            glVendor: vendor, limits: ResourceGuard.outcome?.code ?? "none")
    }
}

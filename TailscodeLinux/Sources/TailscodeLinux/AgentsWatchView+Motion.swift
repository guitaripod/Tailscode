import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// When the wall last drew a frame, by its frame clock.
struct WatchCadence {
    var frame = 0.0
}

extension AgentsWatchView {
    static let sceneNames = ["calm", "busy", "attention", "alarm", "finishing", "crowded", "squad"]
    static let cycleEvery: TimeInterval = 8
    static let driftPixels = 6.0
    static let driftLoop: TimeInterval = 600

    var isTurning: Bool { lap.isTurning }

    func start() {
        isLive = true
        RepeatingMotion.watch(stage.widget) { [weak self] in
            Gtk.onMain { [weak self] in
                self?.updateClock()
                self?.redrawEverything()
            }
        }
        updateClock()
        tickSecond()
    }

    func stop() {
        isLive = false
        context.plainModel?.halt()
        lap.lift()
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        updateClock()
        if visible { redrawEverything() }
    }

    /// How long the wall means each frame to last right now, in seconds, for a bench to judge a late one by.
    var frameTarget: Double { 1 / Double(max(1, cadenceCap())) }

    /// Whether the wall's window draws with a GPU renderer: its frames then cost nodes and not
    /// pixels, and it may move at its display's pace.
    var drawsWithGPU: Bool { tailscode_widget_draws_with_gpu(stage.widget) != 0 }

    /// How long one refresh of the wall's display lasts, in seconds; 0 when its clock has not said.
    var refreshInterval: Double { tailscode_frame_refresh_ms(stage.widget) / 1000 }

    /// Frames a second the wall may draw at now, from Core's `WallCadence`: the display's smooth
    /// rate under a GPU renderer (72 on a 144 Hz panel, 60 on a 60 Hz one), thirty while the main
    /// thread is critically behind, one when dimmed and calm, none while hidden. The software
    /// renderer draws every node of every frame on the main thread, so it gets low power's twenty.
    func cadenceCap() -> Int {
        let now = context.clock.now
        let asleep = wall.isCalm && dim.amount >= 0.99 && dim.isDimmed(at: now)
        let refresh = refreshInterval
        let gpu = drawsWithGPU
        let smooth = gpu ? WallCadence.smoothRate(refreshHz: refresh > 0 ? 1 / refresh : 60) : nil
        return WallCadence.cap(
            effectsLive: effects.isLive(at: context.seconds), breathing: context.animated,
            dimmedCalm: asleep, hidden: !isVisible, lowPower: !gpu, thermal: .nominal, proMotion: false,
            smooth: smooth, strained: CascadeBudget.level >= .critical)
    }

    func updateClock() {
        context.animated = RepeatingMotion.deskAllows && !context.style.still
        let wanted = isLive && cadenceCap() >= 2
        if wanted {
            if !lap.isTurning { lap.lay(on: stage.widget, meaning: .working) }
            if !lap.isTurning { pumpFades() }
        } else {
            lap.lift()
        }
    }

    /// A desk that asks for no movement still gets a crossfade: with no frame clock to run, the
    /// effects that play are stepped on a short timer for as long as they last.
    func pumpFades() {
        guard !fadePumping, isLive, isVisible, !lap.isTurning, effects.isLive(at: context.seconds) else { return }
        fadePumping = true
        Gtk.after(50) { [weak self] in
            guard let self else { return }
            self.fadePumping = false
            guard self.isLive else { return }
            self.frame()
            self.pumpFades()
        }
    }

    /// When the frame being drawn will be seen, by the stage's frame clock and the wall's own skew,
    /// or the wall clock between frames.
    private var frameTime: Double {
        guard lap.isTurning, let clock = gtk_widget_get_frame_clock(stage.widget) else {
            return context.clock.seconds
        }
        let micros = gdk_frame_clock_get_frame_time(clock)
        guard micros > 0 else { return context.clock.seconds }
        return Double(micros) / 1_000_000 + context.clock.skew
    }

    /// One tick of the frame clock: drawn when a frame is due at the wall's cadence, every frame of
    /// a display up to 100 Hz and every second one above, so each lasts the same number of refreshes.
    /// Everything that moves is asked to draw again, which builds nodes and rasterises nothing.
    func frame() {
        let t = frameTime
        let cap = cadenceCap()
        guard cap > 0 else { return }
        guard t - cadence.frame >= Self.due(after: 1.0 / Double(cap), refresh: refreshInterval) else { return }
        let dt = min(0.1, max(0, t - cadence.frame))
        cadence.frame = t
        context.frameSeconds = t
        frames += 1
        guard isVisible, isLive else { return }
        if dim.step(dt: dt, at: context.clock.now, animated: context.animated) {
            gtk_widget_set_opacity(scrim, dim.scrim)
        }
        if fieldRuns {
            moteField.advance(
                by: dt, mood: wall.mood, target: attentionPoint, slow: 1 - 0.6 * dim.amount,
                aspect: lastSize.width / max(1, lastSize.height))
        }
        let effectsLive = effects.isLive(at: t) || effects.painted || effects.hasRipples
        if effectsLive { tickEffects(at: t) }
        let groundMoves =
            context.animated
            && (context.style.field != .none || context.style.light || !wall.tiles.isEmpty)
        if groundMoves || effectsLive { backdrop.redraw() }
        for view in tiles.values { view.frame() }
        for view in workers.values { view.frame() }
        if wall.hasOverdue { vignette.redraw() }
        if wall.tiles.isEmpty { calm.orb.redraw() }
    }

    /// How long after the last frame the next one is due: half a refresh short of the whole number
    /// of refreshes nearest the interval, so a frame lands on the same refresh every time whatever
    /// the clock's jitter — thirty a second on a 165 Hz panel is every fifth or sixth refresh, never a
    /// coin toss between the two — and a hair short of the interval when the display has not said.
    static func due(after interval: Double, refresh: Double) -> Double {
        guard refresh > 0 else { return interval - 0.0005 }
        let refreshes = max(1, (interval / refresh).rounded())
        return (refreshes - 0.5) * refresh
    }

    /// Whether the field moves: not under Still, a desk that asks for less, or with no field at all.
    var fieldRuns: Bool {
        WallCadence.fieldRuns(lowPower: false, thermal: .nominal, style: queueStyle) && context.animated
    }

    var attentionPoint: (x: Double, y: Double)? {
        guard let index = wall.needsYouIndex, geometry.tiles.indices.contains(index), lastSize.width > 1
        else { return nil }
        let rect = geometry.tiles[index]
        return ((rect.x + rect.width / 2) / lastSize.width, (rect.y + rect.height / 2) / lastSize.height)
    }

    func redrawEverything() {
        backdrop.redraw()
        vignette.redraw()
        calm.orb.redraw()
        ribbon.canvas.redraw()
        for view in tiles.values { view.redrawAll() }
        for view in workers.values { view.redrawAll() }
        for view in crowds.values { view.redrawAll() }
    }

    func tickSecond() {
        guard isLive else { return }
        let now = context.clock.now
        advanceScene(now: now)
        if scene == nil { reread(now: now) }
        top.tick(now: now)
        for view in tiles.values {
            view.tick(now: now)
            view.evaluateHold()
        }
        for view in workers.values { view.tick(now: now) }

        rails.apply(wall, now: now)
        ribbon.canvas.redraw()
        updateDrift()
        refreshNight(now: now)
        if !lap.isTurning, dim.step(dt: 1, at: now, animated: false) {
            gtk_widget_set_opacity(scrim, dim.scrim)
        }
        if peekLayer.isExpired(at: now) { onPeekExpired() }
        if now.timeIntervalSince(hourFetchedAt) >= 20 {
            hourFetchedAt = now
            onHourWanted()
        }
        updateClock()
        if !lap.isTurning { redrawEverything() }
    }

    private func updateDrift() {
        let phase = 2 * Double.pi * context.seconds.truncatingRemainder(dividingBy: Self.driftLoop) / Self.driftLoop
        let next = (
            x: (Self.driftPixels * sin(phase)).rounded(), y: (Self.driftPixels * cos(phase * 2)).rounded()
        )
        guard next.x != drift.x || next.y != drift.y else { return }
        drift = next
        stage.invalidate()
    }

    /// How much light a state spills, the figures Core's scene uses on the other walls.
    static func lightOf(_ state: WallState) -> Double {
        switch state {
        case .working: return 0.05
        case .thinking: return 0.04
        case .needsYou(let urgency): return urgency == .overdue ? 0.13 : 0.09
        case .retrying: return 0.06
        case .background(let stuck): return stuck ? 0.05 : 0.035
        case .quiet: return 0.025
        case .finished(let outcome):
            switch outcome {
            case .done: return 0.035
            case .failed: return 0.08
            case .stopped, .unknown: return 0.02
            }
        case .away: return 0.02
        }
    }

    func showScene(_ name: String) {
        let now = context.clock.now
        guard let found = AgentDemo.wallScenes(now: now).first(where: { $0.name == name }) else { return }
        if scene?.name != name { cycleVisited.append(name) }
        scene = found
        sceneStarted = now
        applyWall(
            found.wall.reflowed(aspect: lastSize.width / max(1, lastSize.height), gridAspect: gridAspect),
            now: now, event: true)
    }

    func startScene(_ name: String) {
        cycleStarted = nil
        cycleVisited = []
        showScene(name)
    }

    func startCycle() {
        cycleVisited = []
        cycleStarted = context.clock.now
        scene = nil
        showScene(Self.sceneNames[0])
    }

    func leaveScene() {
        scene = nil
        cycleStarted = nil
        reread(now: context.clock.now)
    }

    private func advanceScene(now: Date) {
        guard let current = scene else { return }
        if cycleStarted != nil {
            guard now.timeIntervalSince(sceneStarted) >= Self.cycleEvery else { return }
            let index = Self.sceneNames.firstIndex(of: current.name) ?? 0
            showScene(Self.sceneNames[(index + 1) % Self.sceneNames.count])
        } else if now.timeIntervalSince(sceneStarted) >= 6 {
            let keep = current.name
            scene = nil
            showScene(keep)
        }
    }
}

extension AgentsWatchView {
    /// Any touch of the wall by a person: a dimmed wall comes back, over a second.
    func userTouched() {
        let before = dim.isDimmed(at: context.clock.now)
        dim.wake(at: context.clock.now)
        if before { updateClock() }
    }

    func toggleDim() {
        dim.toggle(at: context.clock.now)
        updateClock()
        if !lap.isTurning || !context.animated {
            dim.step(dt: 1, at: context.clock.now, animated: false)
            gtk_widget_set_opacity(scrim, dim.scrim)
        }
    }

    /// Takes the pointer away while the wall is left alone in fullscreen, and gives it back.
    func setPointerHidden(_ hidden: Bool) {
        let name: String? = hidden ? "none" : nil
        gtk_widget_set_cursor_from_name(stage.widget, name)
        for view in tiles.values { gtk_widget_set_cursor_from_name(view.widget, hidden ? "none" : "pointer") }
        for view in Array(workers.values) + Array(crowds.values) {
            gtk_widget_set_cursor_from_name(view.widget, hidden ? "none" : "pointer")
        }
    }

    func settleDim() {
        dim.step(dt: 60, at: context.clock.now, animated: true)
        gtk_widget_set_opacity(scrim, dim.scrim)
        updateClock()
    }
}

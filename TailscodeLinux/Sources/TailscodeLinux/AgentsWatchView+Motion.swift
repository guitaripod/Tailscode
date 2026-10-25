import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// When each layer last drew. One frame clock drives them all, capped at thirty a second, and a
/// layer that moves slowly asks for fewer: the motes and the glow need fifteen, the marks that
/// turn need thirty.
struct WatchCadence {
    var frame = 0.0
    var motes = 0.0
    var card = 0.0
    var glyph = 0.0
    var calm = 0.0
    var vignette = 0.0
    var worker = 0.0
    var workerCard = 0.0

    static func due(_ last: inout Double, _ now: Double, _ interval: Double) -> Bool {
        guard now - last >= interval - 0.0005 else { return false }
        last = now
        return true
    }
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

    func updateClock() {
        context.animated = RepeatingMotion.allowed
        let now = context.clock.now
        let asleep = wall.isCalm && dim.amount >= 0.99 && dim.isDimmed(at: now)
        let wanted = isVisible && isLive && context.animated && !asleep
        if wanted {
            if !lap.isTurning { lap.lay(on: stage.widget, meaning: .working) }
        } else {
            lap.lift()
        }
    }

    func frame() {
        let t = context.seconds
        guard t - cadence.frame >= 1.0 / 30 - 0.0005 else { return }
        let dt = min(0.1, t - cadence.frame)
        cadence.frame = t
        frames += 1
        guard isVisible, isLive else { return }
        if dim.step(dt: dt, at: context.clock.now, animated: context.animated) {
            gtk_widget_set_opacity(scrim, dim.scrim)
        }
        if WatchCadence.due(&cadence.motes, t, 1.0 / 15) {
            moteField.step(
                dt: 1.0 / 15, mood: wall.mood, target: attentionPoint, slow: 1 - 0.6 * dim.amount)
            motes.redraw()
        }
        let glyphDue = WatchCadence.due(&cadence.glyph, t, 1.0 / 30)
        let cardDue = WatchCadence.due(&cadence.card, t, 1.0 / 12)
        for view in tiles.values {
            view.frame(
                card: cardDue && view.isAnimating, glyph: glyphDue && view.glyphAnimates, beat: false)
        }
        let workerGlyphDue = WatchCadence.due(&cadence.worker, t, 1.0 / 15)
        let workerCardDue = WatchCadence.due(&cadence.workerCard, t, 1.0 / 6)
        for view in workers.values {
            view.frame(
                card: workerCardDue && view.isAnimating, glyph: workerGlyphDue && view.glyphAnimates)
        }
        if wall.hasOverdue, WatchCadence.due(&cadence.vignette, t, 1.0 / 15) { vignette.redraw() }
        if wall.tiles.isEmpty, WatchCadence.due(&cadence.calm, t, 1.0 / 15) { calm.orb.redraw() }
    }

    var attentionPoint: (x: Double, y: Double)? {
        guard let index = wall.needsYouIndex, geometry.tiles.indices.contains(index), lastSize.width > 1
        else { return nil }
        let rect = geometry.tiles[index]
        return ((rect.x + rect.width / 2) / lastSize.width, (rect.y + rect.height / 2) / lastSize.height)
    }

    func redrawEverything() {
        ground.redraw()
        motes.redraw()
        vignette.redraw()
        calm.orb.redraw()
        ribbon.canvas.redraw()
        plates.redraw()
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
        let moved = dim.step(dt: 1, at: now, animated: context.animated && lap.isTurning)
        if moved { gtk_widget_set_opacity(scrim, dim.scrim) }
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

    func paintGround(_ cr: OpaquePointer, _ width: Double, _ height: Double) {
        let palette = context.palette
        WatchAmbient.ground(
            cr, width: width, height: height, unit: context.unit, palette: palette,
            tint: palette.mood(wall.mood, hasFailure: wall.hasFailure))
    }

    func paintMotes(_ cr: OpaquePointer, _ width: Double, _ height: Double) {
        let palette = context.palette
        let ink = palette.mood(wall.mood, hasFailure: wall.hasFailure).mixed(with: palette.text, 0.45)
        moteField.paint(
            cr, width: width, height: height, unit: context.unit, ink: ink, t: context.seconds,
            animated: context.animated, brightness: 1)
    }

    func paintPlates(_ cr: OpaquePointer, _ width: Double, _ height: Double) {
        let palette = context.palette
        let u = context.unit
        let pad = 0.55 * u
        for (index, tile) in wall.tiles.enumerated() where tile.squad != nil {
            guard geometry.tiles.indices.contains(index) else { continue }
            let cell = geometry.tiles[index]
            let ink = palette.ink(tile.state)
            agentsRoundedRect(
                cr, x: cell.x - pad, y: cell.y - pad, width: cell.width + 2 * pad,
                height: cell.height + 2 * pad, radius: 2.3 * u)
            ink.set(cr, alpha: 0.05)
            cairo_fill_preserve(cr)
            ink.set(cr, alpha: 0.26)
            cairo_set_line_width(cr, max(1, 0.14 * u))
            cairo_stroke(cr)
        }
    }

    func paintVignette(_ cr: OpaquePointer, _ width: Double, _ height: Double) {
        guard wall.hasOverdue else { return }
        let swell = WatchGlyph.breath(context.seconds, period: 6, animated: context.animated)
        WatchAmbient.vignette(
            cr, width: width, height: height, unit: context.unit, ink: context.palette.overdue,
            intensity: 0.07 + 0.1 * swell)
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

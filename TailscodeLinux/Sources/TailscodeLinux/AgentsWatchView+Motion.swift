import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// When each layer last drew. One frame clock drives them all, capped at thirty a second, and a
/// layer that moves slowly asks for fewer: the motes and the glow need fifteen, the ground two,
/// the marks that turn need thirty. How many frames a second the clock itself may run is Core's
/// `WallCadence`: 30 while an effect plays or something breathes, 1 when dimmed and calm, none
/// while hidden.
struct WatchCadence {
    var frame = 0.0
    var motes = 0.0
    var card = 0.0
    var glyph = 0.0
    var calm = 0.0
    var vignette = 0.0
    var worker = 0.0
    var workerCard = 0.0
    var ground = 0.0

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

    /// Frames a second the wall may draw at now, from Core's `WallCadence`.
    func cadenceCap() -> Int {
        let now = context.clock.now
        let asleep = wall.isCalm && dim.amount >= 0.99 && dim.isDimmed(at: now)
        return WallCadence.cap(
            effectsLive: effects.isLive(at: context.seconds), breathing: context.animated,
            dimmedCalm: asleep, hidden: !isVisible, lowPower: false, thermal: .nominal, proMotion: false)
    }

    func updateClock() {
        context.animated = RepeatingMotion.allowed && !context.style.still
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

    func frame() {
        let t = context.seconds
        let cap = cadenceCap()
        guard cap > 0, t - cadence.frame >= 1.0 / Double(cap) - 0.0005 else { return }
        let dt = min(0.1, t - cadence.frame)
        cadence.frame = t
        frames += 1
        guard isVisible, isLive else { return }
        if dim.step(dt: dt, at: context.clock.now, animated: context.animated) {
            gtk_widget_set_opacity(scrim, dim.scrim)
        }
        if WatchCadence.due(&cadence.motes, t, 1.0 / 15) {
            if fieldRuns {
                moteField.step(
                    dt: 1.0 / 15, mood: wall.mood, target: attentionPoint, slow: 1 - 0.6 * dim.amount,
                    aspect: lastSize.width / max(1, lastSize.height))
            }
            if context.style.field != .none { motes.redraw() }
        }
        if context.animated, context.style.light || context.style.field == .aurora,
            WatchCadence.due(&cadence.ground, t, 1.0 / 2)
        {
            ground.redraw()
        }
        if effects.isLive(at: t) || effects.painted || effects.hasRipples { tickEffects(at: t) }
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
        ground.redraw()
        motes.redraw()
        effects.canvas.redraw()
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
        refreshNight(now: now)
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
        let tint = palette.mood(wall.mood, hasFailure: wall.hasFailure)
        let unit = context.unit
        groundCache.paint(
            cr,
            key: WatchGroundCache.Key(
                width: Int(width), height: Int(height), unit: unit, tint: tint, palette: palette)
        ) { inner in
            WatchAmbient.ground(inner, width: width, height: height, unit: unit, palette: palette, tint: tint)
        }
        let t = context.seconds
        if context.style.field == .aurora {
            auroraCache.paint(
                cr, width: width, height: height, ink: tint, text: palette.text, t: context.animated ? t : 0)
        }
        if context.style.light { paintLights(cr, palette: palette, t: t) }
        for piece in effects.ripples {
            guard case .ripple(let rect, let corner, let grow, let span, let alpha) = piece.shape else { continue }
            WatchGround.ripple(
                cr, rect: WatchRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
                corner: corner, grow: grow, width: span, ink: piece.ink, alpha: alpha,
                bounds: (width, height))
        }
    }

    /// The light each tile spills on the ground around it, as strong as Core's scene makes it: the
    /// state's own figure, swelling and ebbing with the tile's breath, and fading with the tile.
    func paintLights(_ cr: OpaquePointer, palette: WatchPalette, t: Double) {
        var drawn = 0
        for (index, tile) in wall.tiles.enumerated() where drawn < WallScene.maxLights {
            guard geometry.tiles.indices.contains(index) else { continue }
            let main = geometry.squads.indices.contains(index) ? geometry.squads[index]?.parent : nil
            let swell = WatchTilePaint.glow(tile.state, t: t, animated: context.animated)
            let strength = Self.lightOf(tile.state) * (0.75 + 0.5 * swell) * WatchTileView.opacity(tile)
            WatchGround.spill(
                cr, rect: main ?? geometry.tiles[index], unit: context.unit, ink: palette.ink(tile.state),
                strength: strength)
            drawn += 1
        }
        lightsDrawn = drawn
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

    func paintMotes(_ cr: OpaquePointer, _ width: Double, _ height: Double) {
        guard context.style.field != .none else { return }
        let palette = context.palette
        let ink = palette.mood(wall.mood, hasFailure: wall.hasFailure).mixed(with: palette.text, 0.45)
        moteField.paint(
            cr, width: width, height: height, unit: context.unit, ink: ink, t: context.seconds,
            animated: context.animated, brightness: context.isNight ? 0.5 : 1,
            trails: context.style.field == .currents && context.animated)
    }

    func paintPlates(_ cr: OpaquePointer, _ width: Double, _ height: Double) {
        guard context.style.showsSquads else { return }
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

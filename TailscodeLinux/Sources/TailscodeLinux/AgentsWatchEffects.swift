import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// One piece of an effect ready to paint: its shape and the colour it is drawn in.
struct WatchFxPiece {
    var shape: WallShape
    var ink: PartyInk
}

/// Where a tile stood when it left the wall, kept for a moment so its leaving still has a place to play.
struct WatchDeparted {
    var anchor: WallAnchor
    var until: Double
}

/// The effects on the wall: Core's queue of timed gestures, the shapes they have at this moment, and
/// the canvas that paints them in Cairo between the glass plates and the words. Rings, blooms and
/// motes add their light; the bands that spread from a tile's edge are handed to the ground, which
/// paints them under the glass. The arrays are kept at the size they grew to, so a frame allocates
/// only the shapes of each live effect.
final class WatchEffectsLayer: @unchecked Sendable {
    static let departedLasts = 1.5

    let canvas = AgentsCanvas(width: 1, height: 1)
    private(set) var queue = WallEffectQueue()
    private(set) var pieces: [WatchFxPiece] = []
    private(set) var ripples: [WatchFxPiece] = []
    private(set) var drains: [String: Double] = [:]
    private(set) var pulses: [String: Double] = [:]
    private(set) var arrivals: [String: Double] = [:]
    private(set) var hadRipples = false
    private(set) var painted = false
    private(set) var added = 0
    var departed: [String: WatchDeparted] = [:]

    init() {
        pieces.reserveCapacity(256)
        ripples.reserveCapacity(WallScene.maxRipples)
        gtk_widget_set_can_target(canvas.widget, 0)
        gtk_widget_set_can_focus(canvas.widget, 0)
        tailscode_set_accessible_hidden(canvas.widget, 1)
        canvas.paint = { [weak self] cr, width, height in self?.paint(cr, width, height) }
    }

    var live: [WallEffect] { queue.live }

    func isLive(at t: Double) -> Bool { queue.isActive(at: t) }

    var hasRipples: Bool { !ripples.isEmpty }

    func add(
        _ events: [WallEvent], at t: Double, style: WallStyle,
        contexts: [String: (from: Double, to: Double)]
    ) {
        let before = queue.live.count
        queue.add(events, at: t, style: style, contexts: contexts)
        added += max(0, queue.live.count - before)
    }

    func clear() {
        queue = WallEffectQueue()
        pieces.removeAll(keepingCapacity: true)
        ripples.removeAll(keepingCapacity: true)
        drains.removeAll(keepingCapacity: true)
        pulses.removeAll(keepingCapacity: true)
        arrivals.removeAll(keepingCapacity: true)
        departed.removeAll()
    }

    /// The shapes of every live effect at `t`, with the colour each is drawn in. `resolve` says where
    /// an effect hangs and which state its tile is in; an effect with no place to hang draws nothing.
    /// Returns whether the canvas must be painted: while anything plays and once more after it ends,
    /// so the last frame is cleared.
    func prepare(
        at t: Double, unit: Double, palette: WatchPalette,
        resolve: (WallEffect) -> (anchor: WallAnchor, state: WallState?)?
    ) -> Bool {
        queue.prune(at: t)
        if !departed.isEmpty { departed = departed.filter { $0.value.until > t } }
        hadRipples = !ripples.isEmpty
        pieces.removeAll(keepingCapacity: true)
        ripples.removeAll(keepingCapacity: true)
        drains.removeAll(keepingCapacity: true)
        pulses.removeAll(keepingCapacity: true)
        arrivals.removeAll(keepingCapacity: true)
        for effect in queue.live where effect.isStarted(at: t) && !effect.isEnded(at: t) {
            note(effect, at: t)
            guard let place = resolve(effect) else { continue }
            let ink = palette.ink(effect.ink, state: place.state)
            for shape in WallEffectShapes.shapes(for: effect, at: t, anchor: place.anchor, unit: unit) {
                if case .ripple = shape {
                    if ripples.count < WallScene.maxRipples { ripples.append(WatchFxPiece(shape: shape, ink: ink)) }
                } else {
                    pieces.append(WatchFxPiece(shape: shape, ink: ink))
                }
            }
        }
        let drawing = !pieces.isEmpty
        let needs = drawing || painted
        painted = drawing
        return needs
    }

    /// What an effect asks of its tile besides shapes: the ring's share while a drain plays, the
    /// flash of a step on the glass, and how far a newcomer has come in.
    private func note(_ effect: WallEffect, at t: Double) {
        switch effect.kind {
        case .drain:
            if let share = WallEffectShapes.drainShare(effect, at: t) { drains[effect.tile] = share }
        case .spark:
            let flash = max(0, 1 - 2.5 * max(0, t - effect.start))
            pulses[effect.tile] = max(pulses[effect.tile] ?? 0, flash)
        case .gather:
            let born = effect.progress(at: t)
            let ramp = max(0, min(1, (born - 0.35) / 0.65))
            arrivals[effect.tile] = ramp * ramp * (3 - 2 * ramp)
        default:
            break
        }
    }

    func paint(_ cr: OpaquePointer, _ width: Double, _ height: Double) {
        guard !pieces.isEmpty else { return }
        cairo_set_operator(cr, CAIRO_OPERATOR_ADD)
        for piece in pieces {
            switch piece.shape {
            case .ring(let x, let y, let radius, let ringWidth, let alpha):
                Self.ring(cr, x: x, y: y, radius: radius, width: ringWidth, alpha: alpha, ink: piece.ink)
            case .bloom(let x, let y, let radius, let alpha):
                Self.bloom(cr, x: x, y: y, radius: radius, alpha: alpha, ink: piece.ink)
            case .dot(let x, let y, let size, let alpha):
                Self.dot(cr, x: x, y: y, size: size, alpha: alpha, ink: piece.ink.lifted(0.35))
            case .ripple:
                break
            }
        }
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
    }

    /// A soft ring: a band whose brightness falls off on both sides like a gaussian, painted as one
    /// gradient over the annulus alone.
    static func ring(
        _ cr: OpaquePointer, x: Double, y: Double, radius: Double, width: Double, alpha: Double, ink: PartyInk
    ) {
        guard alpha > 0.002, radius > 0.5 else { return }
        let scale = max(1.2, width)
        let inner = max(0, radius - 3.2 * scale)
        let outer = radius + 3.2 * scale
        guard let pattern = cairo_pattern_create_radial(x, y, inner, x, y, outer) else { return }
        for step in 0...8 {
            let at = Double(step) / 8
            let band = at * 6.4 - 3.2
            cairo_pattern_add_color_stop_rgba(pattern, at, ink.red, ink.green, ink.blue, alpha * exp(-band * band))
        }
        cairo_new_path(cr)
        cairo_arc(cr, x, y, outer, 0, 2 * .pi)
        if inner > 0.5 {
            cairo_new_sub_path(cr)
            cairo_arc_negative(cr, x, y, inner, 0, 2 * .pi)
        }
        cairo_set_source(cr, pattern)
        cairo_fill(cr)
        cairo_pattern_destroy(pattern)
    }

    /// A glow that falls off from its centre like a gaussian, reaching two and a half radii.
    static func bloom(
        _ cr: OpaquePointer, x: Double, y: Double, radius: Double, alpha: Double, ink: PartyInk
    ) {
        guard alpha > 0.002, radius > 0.5 else { return }
        let reach = radius * 2.4
        guard let pattern = cairo_pattern_create_radial(x, y, 0, x, y, reach) else { return }
        for step in 0...8 {
            let at = Double(step) / 8
            let out = at * 2.4
            cairo_pattern_add_color_stop_rgba(pattern, at, ink.red, ink.green, ink.blue, alpha * exp(-out * out))
        }
        cairo_new_path(cr)
        cairo_arc(cr, x, y, reach, 0, 2 * .pi)
        cairo_set_source(cr, pattern)
        cairo_fill(cr)
        cairo_pattern_destroy(pattern)
    }

    /// A mote of light: a filled circle inside a halo of two and a fifth of its size at a fifth of
    /// its strength. It is passed lifted toward white by the caller, so a mote of the tile's own
    /// colour still shows against the tile's glass.
    static func dot(
        _ cr: OpaquePointer, x: Double, y: Double, size: Double, alpha: Double, ink: PartyInk
    ) {
        guard alpha > 0.002, size > 0.5 else { return }
        let radius = size / 2
        ink.set(cr, alpha: alpha * 0.22)
        cairo_new_path(cr)
        cairo_arc(cr, x, y, radius * 2.2, 0, 2 * .pi)
        cairo_fill(cr)
        ink.set(cr, alpha: alpha)
        cairo_new_path(cr)
        cairo_arc(cr, x, y, radius, 0, 2 * .pi)
        cairo_fill(cr)
    }
}

extension AgentsWatchView {
    /// What the queue is told: the person's style, and still whenever the desk asks for less
    /// movement, so a desk that reduces motion gets the crossfade and not the gesture.
    var queueStyle: WallStyle {
        var style = context.style
        style.still = style.still || !RepeatingMotion.allowed
        return style
    }

    /// Where an effect hangs: its tile's plate, the glyph as the tile draws it, the worker's slot
    /// when it names one, and the heartbeat strip. A tile that has left the wall plays from where it
    /// last stood.
    func place(_ effect: WallEffect) -> (anchor: WallAnchor, state: WallState?)? {
        if let index = wall.tiles.firstIndex(where: { $0.id == effect.tile }),
            let anchor = tileAnchor(index, worker: effect.worker)
        {
            return (anchor, wall.tiles[index].state)
        }
        guard let gone = effects.departed[effect.tile] else { return nil }
        return (gone.anchor, nil)
    }

    func tileAnchor(_ index: Int, worker: String?) -> WallAnchor? {
        guard geometry.tiles.indices.contains(index), wall.tiles.indices.contains(index) else { return nil }
        let tile = wall.tiles[index]
        let squad = geometry.squads.indices.contains(index) ? geometry.squads[index] : nil
        let main = squad?.parent ?? geometry.tiles[index]
        let u = geometry.unit
        let view = tiles[tile.id]
        let glyph = view?.glyphBox ?? TileRect(x: 0, y: 0, width: 0, height: 0)
        let size = glyph.width > 0 ? Double(glyph.width) : 8 * u
        let glyphX = main.x + (glyph.width > 0 ? Double(glyph.x) : 1.7 * u) + size / 2
        let glyphY = main.y + (glyph.width > 0 ? Double(glyph.y) : 1.7 * u) + size / 2
        var beat = WallRect(x: main.x + 1.7 * u, y: main.maxY - 1.7 * u - 3 * u, width: max(0, main.width * 0.4), height: 3 * u)
        if let box = view?.beatBox {
            beat = WallRect(
                x: main.x + Double(box.x), y: main.y + Double(box.y), width: Double(box.width),
                height: Double(box.height))
        }
        var slot: WallRect?
        if let id = worker, let squad, let place = tile.workers.firstIndex(where: { $0.id == id }),
            squad.slots.indices.contains(place)
        {
            slot = Self.wallRect(squad.slots[place])
        }
        return WallAnchor(
            tile: Self.wallRect(main), glyphX: glyphX, glyphY: glyphY, glyphSize: size, worker: slot,
            beat: beat, width: lastSize.width, height: lastSize.height)
    }

    static func wallRect(_ rect: WatchRect) -> WallRect {
        WallRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    /// Keeps where every tile that is about to leave last stood, so its leaving has a place to play.
    func remember(departing next: AgentWall) {
        let staying = Set(next.tiles.map(\.id))
        let until = context.seconds + WatchEffectsLayer.departedLasts
        for (index, tile) in wall.tiles.enumerated() where !staying.contains(tile.id) {
            if let anchor = tileAnchor(index, worker: nil) {
                effects.departed[tile.id] = WatchDeparted(anchor: anchor, until: until)
            }
        }
    }

    /// The share of the context ring a compaction falls from and to, for each tile that has both.
    static func contexts(from old: AgentWall?, to next: AgentWall) -> [String: (from: Double, to: Double)] {
        guard let old else { return [:] }
        var out: [String: (from: Double, to: Double)] = [:]
        for tile in next.tiles {
            guard let was = old.tiles.first(where: { $0.id == tile.id })?.contextShare,
                let now = tile.contextShare
            else { continue }
            out[tile.id] = (was, now)
        }
        return out
    }

    /// Plays what changed between two live reads of the wall.
    func play(_ events: [WallEvent], contexts: [String: (from: Double, to: Double)]) {
        guard !events.isEmpty, isLive, isVisible else { return }
        effects.add(events, at: context.seconds, style: queueStyle, contexts: contexts)
        effectsStarted()
    }

    func effectsStarted() {
        updateClock()
        pumpFades()
        effects.canvas.redraw()
    }

    /// One frame of the effects: where each piece is now, the canvas painted, the ground repainted
    /// while a band spreads across it, and each tile told what its effects ask of it.
    func tickEffects(at t: Double) {
        let wasRippling = effects.hasRipples
        let needsPaint = effects.prepare(at: t, unit: geometry.unit, palette: context.palette) { place($0) }
        if needsPaint { effects.canvas.redraw() }
        if effects.hasRipples || wasRippling { ground.redraw() }
        let still = queueStyle.still
        for (key, view) in tiles {
            view.setEffects(
                drain: still ? nil : effects.drains[key], pulse: effects.pulses[key] ?? 0,
                arrival: effects.arrivals[key] ?? 1)
        }
    }

    /// The kinds of event `agents-fx` knows, by the words a person would use as well as Core's own.
    static func eventKind(_ word: String) -> WallEvent.Kind? {
        let key = word.lowercased().filter { $0.isLetter }
        let names: [String: WallEvent.Kind] = [
            "step": .step, "joined": .joined, "join": .joined, "arrive": .joined, "left": .left,
            "leave": .left, "asked": .asked, "ask": .asked, "answered": .answered, "approved": .answered,
            "finished": .finished, "finish": .finished, "done": .finished, "failed": .failed,
            "fail": .failed, "failure": .failed, "stopped": .stopped, "stop": .stopped,
            "retried": .retried, "retry": .retried, "quiet": .quiet, "resumed": .resumed,
            "compacted": .compacted, "compact": .compacted, "away": .away, "back": .back,
            "workerstarted": .workerStarted, "workerstart": .workerStarted, "worker": .workerStarted,
            "workerended": .workerEnded, "workerend": .workerEnded, "workerquiet": .workerQuiet,
            "workerstuck": .workerStuck,
        ]
        return names[key]
    }

    /// The event `agents-fx` fires: on the first tile the kind suits, so the harness can show every
    /// effect on the wall or the scene that is up. An ask lands on a tile that waits, a worker's on
    /// a tile that has one.
    func syntheticEvent(_ kind: WallEvent.Kind) -> (event: WallEvent, contexts: [String: (from: Double, to: Double)])? {
        let tiles = wall.tiles
        func first(_ suits: (WallTile) -> Bool) -> WallTile? { tiles.first(where: suits) ?? tiles.first }
        switch kind {
        case .asked, .answered:
            guard let tile = first({ $0.state.isNeedsYou }) else { return nil }
            return (WallEvent(kind: kind, tile: tile.id), [:])
        case .workerStarted, .workerEnded, .workerQuiet, .workerStuck:
            guard let tile = first({ !$0.workers.isEmpty }) else { return nil }
            return (WallEvent(kind: kind, tile: tile.id, worker: tile.workers.first?.id), [:])
        case .compacted:
            guard let tile = first({ $0.contextShare != nil }) else { return nil }
            let from = tile.contextShare ?? 0.9
            return (WallEvent(kind: kind, tile: tile.id), [tile.id: (from, max(0.12, from - 0.6))])
        case .step:
            guard let tile = first({ if case .working = $0.state { return true } else { return false } })
            else { return nil }
            return (WallEvent(kind: kind, tile: tile.id), [:])
        default:
            guard let tile = tiles.first else { return nil }
            return (WallEvent(kind: kind, tile: tile.id), [:])
        }
    }

    /// Fires one synthetic event through the same queue the live wall uses.
    @discardableResult
    func fire(_ kind: WallEvent.Kind) -> WallEvent? {
        guard let made = syntheticEvent(kind) else { return nil }
        dim.wake(at: context.clock.now)
        effects.add([made.event], at: context.seconds, style: queueStyle, contexts: made.contexts)
        effectsStarted()
        return made.event
    }
}

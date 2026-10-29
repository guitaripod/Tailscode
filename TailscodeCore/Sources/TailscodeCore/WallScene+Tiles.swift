import Foundation

extension WallScene {
    /// Builds one frame: the ground values first, then each tile, the calm orb, the effects, the hold,
    /// the field and the ribbon. Arrays are sized once and appended to.
    struct Builder {
        let input: WallSceneInput
        let animated: Bool
        let t: Double
        let unit: Double
        var scene: WallScene
        var live: [WallEffect] = []

        init(_ input: WallSceneInput) {
            self.input = input
            let animated = input.animated && !input.style.still
            self.animated = animated
            t = input.t
            unit = input.layout.unit
            let wall = input.wall
            let palette = input.palette
            let hasFailure = wall.tiles.contains { tile in
                if case .finished(.failed) = tile.state { return true }
                return false
            }
            let overdue = wall.tiles.contains { tile in
                if case .needsYou(.overdue) = tile.state { return true }
                return false
            }
            let breathing = 0.16 + 0.1 * sin(2 * .pi * input.t / 9)
            let dim = WallMath.clamp(input.dim, 0, 1)
            scene = WallScene(
                width: input.layout.width, height: input.layout.height, unit: input.layout.unit,
                palette: palette, tint: palette.mood(wall.mood, hasFailure: hasFailure), tintAlpha: 0.085,
                vignette: overdue ? (animated ? breathing : 0.18) : 0, vignetteInk: palette.overdue,
                dim: (1 - 0.6 * dim) * (input.peeking ? 0.45 : 1),
                driftX: animated ? sin(2 * .pi * input.t / 600) * 6 : 0,
                driftY: animated ? cos(2 * .pi * input.t / 600) * 6 : 0,
                aurora: input.style.field == .aurora ? 1 : 0, gridAlpha: 0.032)
            live = input.effects.filter { $0.isStarted(at: input.t) && !$0.isEnded(at: input.t) }
            scene.plates.reserveCapacity(input.wall.tiles.count * 8 + 8)
            scene.glyphs.reserveCapacity(input.wall.tiles.count * 8 + 8)
        }

        mutating func run() {
            addTiles()
            if input.wall.tiles.isEmpty { addCalmOrb() }
            addEffects()
            addHold()
            addField()
            addRibbon()
            scene.isAnimating = !live.isEmpty || input.hold != nil
        }

        var palette: WallPalette { input.palette }
        var cornerRadius: Double { max(1.6 * unit, 10) }
        var smallCorner: Double { max(1.2 * unit, 8) }

        mutating func addTiles() {
            let layout = input.layout
            for (index, tile) in input.wall.tiles.enumerated() where index < layout.tiles.count {
                let cell = layout.tiles[index]
                let squad = index < layout.squads.count ? layout.squads[index] : nil
                addTile(tile, cell: cell, squad: squad)
            }
        }

        mutating func addTile(_ tile: WallTile, cell: WallRect, squad: WallSquadRects?) {
            let main = squad?.parent ?? cell
            let face = tile.state.face
            let opacity = opacityOf(tile)
            let swell = face.swell(at: t, animated: animated)
            let look = face.look(swell: swell, unit: unit)
            let ink = palette.ink(for: tile.state)
            let pulse = pulseOf(tile)
            let metrics = WallTileMetrics.tile(main, unit: unit)
            if let squad, !squad.slots.isEmpty || squad.more != nil {
                scene.plates.append(
                    WallPlate(
                        rect: cell.inset(-4), corner: cornerRadius + 4, ink: ink, opacity: opacity * 0.5,
                        wash: 0.012, borderAlpha: 0.1, sheen: 0))
            }
            scene.plates.append(
                WallPlate(
                    rect: main, corner: cornerRadius, ink: ink, opacity: opacity,
                    wash: look.wash + pulse * 0.03, flat: look.flat, borderAlpha: look.borderAlpha,
                    borderWidth: look.borderWidth, hatch: face == .away))
            if input.style.light, scene.lights.count < WallScene.maxLights {
                let strength = face.light * (0.75 + 0.5 * swell) * opacity
                scene.lights.append(WallLight(rect: main, ink: ink, strength: strength))
            }
            addGlyph(of: tile, face: face, at: metrics, ink: ink, opacity: opacity, pulse: pulse)
            addBeat(of: tile, in: metrics.beat, ink: ink, opacity: opacity)
            guard let squad else { return }
            for (slot, rect) in squad.slots.enumerated() where slot < tile.workers.count {
                addWorker(tile.workers[slot], in: rect, parentOpacity: opacity)
            }
            if let more = squad.more {
                let needsEyes = tile.squad?.moreNeedsEyes ?? false
                scene.plates.append(
                    WallPlate(
                        rect: more, corner: smallCorner, ink: needsEyes ? palette.needs : palette.dim,
                        opacity: opacity, wash: 0.02, borderAlpha: needsEyes ? 0.5 : 0.25, sheen: 0.4))
            }
        }

        func opacityOf(_ tile: WallTile) -> Double {
            var opacity = 1.0
            if let gather = live.first(where: { $0.kind == .gather && $0.tile == tile.id }) {
                let born = gather.progress(at: t)
                opacity = min(opacity, WallMath.smooth((born - 0.35) / 0.65))
            }
            if case .finished = tile.state { opacity *= 1 - 0.55 * WallMath.clamp(tile.fade, 0, 1) }
            if case .away = tile.state { opacity *= 0.7 }
            return opacity
        }

        /// A step's flash on the glass, `1` as it lands and gone in four tenths of a second.
        func pulseOf(_ tile: WallTile) -> Double {
            var strongest = 0.0
            for effect in live where effect.kind == .spark && effect.tile == tile.id {
                strongest = max(strongest, 1 - 2.5 * max(0, t - effect.start))
            }
            return max(0, strongest)
        }

        mutating func addBeat(of tile: WallTile, in strip: WallRect, ink: WallInk, opacity: Double) {
            guard let beat = tile.beat, !beat.isEmpty, strip.width > 4, strip.height > 2 else { return }
            if beat.allSatisfy({ $0 == 0 }) {
                let rect = WallRect(x: strip.x, y: strip.maxY - 2, width: strip.width, height: 2)
                scene.bars.append(WallBar(rect: rect, corner: 0, ink: palette.dim, alpha: 0.55 * opacity))
                return
            }
            let pitch = strip.width / Double(beat.count)
            let width = max(1.5, pitch * 0.62)
            let ceiling = Double(AgentBeat.ceiling)
            let slide = WallMath.clamp(input.beatSlide, -1, 1)
            for (index, value) in beat.enumerated() {
                let left = strip.x + (Double(index) + slide) * pitch
                let right = left + width
                guard right > strip.x, left < strip.maxX else { continue }
                let x = max(left, strip.x)
                let span = min(right, strip.maxX) - x
                guard span > 0 else { continue }
                if value == 0 {
                    let rect = WallRect(x: x, y: strip.maxY - 2, width: span, height: 2)
                    scene.bars.append(WallBar(rect: rect, corner: 0, ink: palette.dim, alpha: 0.4 * opacity))
                } else {
                    let level = min(1, Double(value) / max(1, ceiling * 2 / 3))
                    let lift = max(strip.height * 0.34, strip.height * level)
                    let rect = WallRect(x: x, y: strip.maxY - lift, width: span, height: lift)
                    scene.bars.append(
                        WallBar(
                            rect: rect, corner: min(width / 2, 1.5), ink: ink,
                            alpha: (0.6 + 0.4 * level) * opacity))
                }
            }
        }

        mutating func addWorker(_ worker: WallWorker, in rect: WallRect, parentOpacity: Double) {
            var opacity = parentOpacity
            if let thread = live.first(where: { $0.kind == .thread && $0.worker == worker.id }) {
                opacity *= WallMath.smooth((thread.progress(at: t) - 0.3) / 0.7)
            }
            if worker.state.isFinished { opacity *= 1 - 0.45 * WallMath.clamp(worker.fade, 0, 1) }
            let ink = palette.ink(for: worker.state)
            let working = worker.state.ordinal == 0
            let quiet = worker.state.ordinal == 1
            scene.plates.append(
                WallPlate(
                    rect: rect, corner: smallCorner, ink: ink, opacity: opacity,
                    wash: working ? 0.05 : 0.025, borderAlpha: quiet ? 0.45 : 0.26, sheen: 0.6))
            let metrics = WallTileMetrics.worker(rect, unit: unit)
            addWorkerGlyph(worker, at: metrics, ink: ink, opacity: opacity)
        }
    }
}

extension WallState {
    enum Face {
        case working, thinking, needs, overdue, retrying, quiet, background, stuck
        case done, failed, stopped, away

        func swell(at t: Double, animated: Bool) -> Double {
            switch self {
            case .needs: return WallMath.knock(t, period: 4.2, second: 0.34, animated: animated)
            case .overdue: return WallMath.knock(t, period: 2.6, second: 0.26, animated: animated)
            case .working: return WallMath.breath(t, period: 5.2, animated: animated)
            case .thinking: return WallMath.breath(t, period: 8, animated: animated)
            case .background: return WallMath.breath(t, period: 6.5, animated: animated)
            case .retrying: return WallMath.breath(t, period: 4, animated: animated)
            default: return 0.5
            }
        }

        var light: Double {
            switch self {
            case .working: return 0.05
            case .thinking: return 0.04
            case .needs: return 0.09
            case .overdue: return 0.13
            case .failed: return 0.08
            case .retrying: return 0.06
            case .background: return 0.035
            case .stuck: return 0.05
            case .quiet: return 0.025
            case .done: return 0.035
            case .stopped, .away: return 0.02
            }
        }

        struct Look {
            var wash: Double
            var borderAlpha: Double
            var borderWidth: Double
            var flat: Double
        }

        func look(swell: Double, unit: Double) -> Look {
            var wash = 0.06 + 0.06 * swell
            var border = 0.34
            var width = 1.0
            var flat = 0.0
            switch self {
            case .overdue:
                wash = 0.15 + 0.1 * swell
                border = 0.8 + 0.2 * swell
                width = 0.34 * unit
                flat = wash * 0.5
            case .needs:
                wash = 0.1 + 0.08 * swell
                border = 0.55 + 0.4 * swell
                width = 0.26 * unit
                flat = wash * 0.5
            case .retrying:
                border = 0.5
                width = 0.2 * unit
            case .quiet:
                wash = 0.04
                border = 0.5
            case .failed:
                wash = 0.14
                border = 0.85
                width = 0.26 * unit
            case .done:
                wash = 0.03
                border = 0.4
            case .stopped, .away:
                wash = 0.03
                border = 0.3
            case .stuck:
                wash = 0.07
                border = 0.5
            case .working, .thinking, .background: break
            }
            return Look(wash: wash, borderAlpha: border, borderWidth: max(1, width), flat: flat)
        }
    }

    var face: Face {
        switch self {
        case .working: return .working
        case .thinking: return .thinking
        case .needsYou(let urgency): return urgency == .overdue ? .overdue : .needs
        case .retrying: return .retrying
        case .quiet: return .quiet
        case .background(let stuck): return stuck ? .stuck : .background
        case .finished(let outcome):
            switch outcome {
            case .done: return .done
            case .failed: return .failed
            case .stopped, .unknown: return .stopped
            }
        case .away: return .away
        }
    }
}

import Foundation

extension WallScene.Builder {
    mutating func addEffects() {
        let layout = input.layout
        let tiles = input.wall.tiles
        for effect in live {
            guard let index = tiles.firstIndex(where: { $0.id == effect.tile }), index < layout.tiles.count
            else {
                addDeparted(effect)
                continue
            }
            let tile = tiles[index]
            let squad = index < layout.squads.count ? layout.squads[index] : nil
            let main = squad?.parent ?? layout.tiles[index]
            let metrics = WallTileMetrics.tile(main, unit: unit)
            var slot: WallRect?
            if let id = effect.worker, let squad, let place = tile.workers.firstIndex(where: { $0.id == id }),
                place < squad.slots.count
            {
                slot = squad.slots[place]
            }
            let anchor = WallAnchor(
                tile: main, glyphX: metrics.glyphX, glyphY: metrics.glyphY, glyphSize: metrics.glyphSize,
                worker: slot, beat: metrics.beat, width: layout.width, height: layout.height)
            let ink = palette.ink(effect.ink, state: tile.state)
            let shapes = WallEffectShapes.shapes(for: effect, at: t, anchor: anchor, unit: unit)
            for shape in shapes { add(shape, kind: effect.kind, ink: ink, size: metrics.glyphSize) }
        }
    }

    private mutating func addDeparted(_ effect: WallEffect) {
        guard let rect = input.departed[effect.tile] else { return }
        let metrics = WallTileMetrics.tile(rect, unit: unit)
        let anchor = WallAnchor(
            tile: rect, glyphX: metrics.glyphX, glyphY: metrics.glyphY, glyphSize: metrics.glyphSize,
            worker: nil, beat: metrics.beat, width: input.layout.width, height: input.layout.height)
        let ink = palette.ink(effect.ink, state: nil)
        for shape in WallEffectShapes.shapes(for: effect, at: t, anchor: anchor, unit: unit) {
            add(shape, kind: effect.kind, ink: ink, size: metrics.glyphSize)
        }
    }

    private mutating func add(_ shape: WallShape, kind: WallEffect.Kind, ink: WallInk, size: Double) {
        switch shape {
        case .ring(let x, let y, let radius, let width, let alpha):
            let p1 = radius / size
            let p2 = max(0.005, width / size)
            scene.glows.append(
                WallGlyph(
                    x: x, y: y, size: size, extent: p1 + 3.2 * p2 + 0.02, kind: .ring, ink: ink, alpha: alpha,
                    p1: p1, p2: p2))
        case .bloom(let x, let y, let radius, let alpha):
            let p1 = max(0.01, radius / size)
            scene.glows.append(
                WallGlyph(x: x, y: y, size: size, extent: p1 * 2.4, kind: .bloom, ink: ink, alpha: alpha, p1: p1))
        case .dot(let x, let y, let diameter, let alpha):
            scene.dots.append(
                WallDot(
                    x: x, y: y, size: diameter, core: WallEffectShapes.core(for: kind), ink: ink, alpha: alpha))
        case .ripple(let rect, let corner, let grow, let width, let alpha):
            guard scene.ripples.count < WallScene.maxRipples else { return }
            scene.ripples.append(
                WallRipple(rect: rect, corner: corner, grow: grow, width: width, ink: ink, alpha: alpha))
        }
    }

    mutating func addHold() {
        guard let hold = input.hold else { return }
        let size = max(unit * 7, 56)
        let progress = WallMath.clamp(hold.progress, 0, 1)
        scene.glows.append(
            WallGlyph(
                x: hold.x, y: hold.y, size: size, extent: 0.6, kind: .bloom, ink: palette.needs, alpha: 0.25,
                p1: 0.45))
        scene.glyphs.append(
            WallGlyph(
                x: hold.x, y: hold.y, size: size, extent: 0.6, kind: .arc, ink: palette.needs, alpha: 0.95,
                p1: 0.42, p2: 0.07, p3: progress, p4: 0.25))
    }

    mutating func addField() {
        guard input.style.field != .none else { return }
        let motes = input.motes
        let width = input.layout.width
        let height = input.layout.height
        let night = input.style.isNight(at: input.now) ? 0.5 : 1.0
        let ink = palette.text.mixed(with: scene.tint, 0.55)
        let currents = input.style.field == .currents && animated
        scene.dots.reserveCapacity(scene.dots.count + motes.count * (currents ? 12 : 1))
        for i in 0..<motes.count {
            let twinkle = animated ? 0.5 + 0.5 * sin(motes.phase[i] + t * 0.45) : 0.55
            let alpha = (0.05 + 0.13 * twinkle) * night
            let radius = max(0.8, motes.size[i] * unit * 0.8)
            let x = motes.x[i] * width
            let y = motes.y[i] * height
            scene.dots.append(WallDot(x: x, y: y, size: radius * 4.4, core: 0.45, ink: ink, alpha: alpha * 1.6))
            guard currents else { continue }
            addTrail(of: i, from: (x, y), radius: radius, alpha: alpha, ink: ink)
        }
    }

    private mutating func addTrail(
        of index: Int, from head: (Double, Double), radius: Double, alpha: Double, ink: WallInk
    ) {
        let motes = input.motes
        let base = index * WallMotes.trailLength
        for k in 1..<WallMotes.trailLength {
            let tx = motes.trailX[base + k] * input.layout.width
            let ty = motes.trailY[base + k] * input.layout.height
            let length = hypot(head.0 - tx, head.1 - ty)
            let steps = min(6, Int((length / max(1, radius)).rounded(.up)))
            guard steps >= 1 else { continue }
            for s in 1...steps {
                let f = Double(s) / Double(steps + 1)
                let fade = 1 - (Double(k - 1) + f) / 3.4
                scene.dots.append(
                    WallDot(
                        x: WallMath.lerp(head.0, tx, f), y: WallMath.lerp(head.1, ty, f), size: radius * 2.6,
                        core: 0.5, ink: ink, alpha: alpha * fade * 0.9))
            }
        }
    }

    mutating func addRibbon() {
        guard let rect = input.layout.ribbon, rect.width > 0 else { return }
        let calm = input.wall.isCalm && input.wall.tiles.isEmpty
        let track = WallRibbon.track(in: rect, unit: unit, calm: calm)
        guard track.width > 0, track.height > 0 else { return }
        scene.bars.append(WallBar(rect: track, corner: track.height / 2, ink: palette.text, alpha: 0.07))
        if let ribbon = input.ribbon { addRibbonContent(ribbon, on: track) }
        let line = WallRect(
            x: track.maxX - 4, y: track.y - unit * 0.4, width: 4, height: track.height + unit * 0.8)
        scene.bars.append(WallBar(rect: line, corner: 0, ink: palette.working, alpha: 0.3))
        let core = WallRect(x: track.maxX - 2, y: line.y, width: 2, height: line.height)
        scene.bars.append(WallBar(rect: core, corner: 0, ink: palette.working, alpha: 1))
    }

    private mutating func addRibbonContent(_ ribbon: WallRibbon, on track: WallRect) {
        for gap in ribbon.unseen {
            let left = track.x + gap.lowerBound * track.width
            let right = track.x + gap.upperBound * track.width
            guard right - left > 1 else { continue }
            scene.plates.append(
                WallPlate(
                    rect: WallRect(x: left, y: track.y, width: right - left, height: track.height),
                    corner: 0, ink: palette.dim, opacity: 0.5, wash: 0, borderAlpha: 0, borderWidth: 0,
                    hatch: true, sheen: 0))
        }
        let thickness = track.height * 0.56
        for span in ribbon.spans {
            let left = track.x + span.from * track.width
            let right = track.x + span.to * track.width
            let width = min(max(2, right - left), track.maxX - left)
            guard width > 0 else { continue }
            let ink: WallInk
            let alpha: Double
            switch span.phase {
            case .working: (ink, alpha) = (palette.working, 0.7)
            case .needsYou: (ink, alpha) = (palette.needs, 0.95)
            case .background: (ink, alpha) = (palette.working, 0.32)
            }
            scene.bars.append(
                WallBar(
                    rect: WallRect(x: left, y: track.y + (track.height - thickness) / 2, width: width, height: thickness),
                    corner: 0, ink: ink, alpha: alpha))
        }
        let radius = min(track.height * 0.42, unit * 0.9)
        for mark in ribbon.marks {
            let at = min(max(track.x + mark.at * track.width, track.x + radius), track.maxX - radius)
            let ink: WallInk
            switch mark.outcome {
            case .done: ink = palette.finished
            case .failed: ink = palette.failed
            case .stopped, .unknown: ink = palette.dim
            }
            scene.bars.append(
                WallBar(
                    rect: WallRect(x: at - radius, y: track.midY - radius, width: 2 * radius, height: 2 * radius),
                    corner: radius, ink: ink, alpha: 0.95))
        }
    }
}

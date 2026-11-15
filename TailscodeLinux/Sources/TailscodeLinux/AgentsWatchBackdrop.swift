import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The pictures the wall's ground is drawn from: the ground itself, painted once for its size,
/// mood and palette, and the light each tile spills, painted once for where the tile stands and
/// drawn as bright as its breath says. Everything else on the ground is drawn by the GPU.
final class WallBackdropPictures {
    let ground = WallPicture()
    private(set) var lights: [String: WallPicture] = [:]

    /// A light painted at this strength is drawn at the strength a tile asks for by its opacity.
    static let lightReference = 0.2

    func light(_ key: String) -> WallPicture {
        if let made = lights[key] { return made }
        let made = WallPicture()
        lights[key] = made
        return made
    }

    func keepLights(_ keys: Set<String>) {
        guard lights.keys.contains(where: { !keys.contains($0) }) else { return }
        lights = lights.filter { keys.contains($0.key) }
    }
}

extension AgentsWatchView {
    /// One frame of everything under the tiles, in the order the layers used to stack: the ground,
    /// the aurora, the tiles' light, the bands spreading from an edge, the motes, the squads' plates
    /// and the effects. Nothing here is rasterised unless the ground's size or mood changed or a
    /// tile moved.
    func drawBackdrop(_ s: WallSnapshot, _ width: Double, _ height: Double) {
        drawGround(s, width, height)
        drawMotes(s, width, height)
        drawPlates(s)
        effects.draw(s)
    }

    func drawGround(_ s: WallSnapshot, _ width: Double, _ height: Double) {
        let palette = context.palette
        let tint = palette.mood(wall.mood, hasFailure: wall.hasFailure)
        let unit = context.unit
        let full = WatchRect(x: 0, y: 0, width: width, height: height)
        pictures.ground.ensure("\(tint.hex)|\(unit)|\(context.paletteKey)", width: width, height: height, in: s) {
            cr, w, h in
            WatchAmbient.ground(cr, width: w, height: h, unit: unit, palette: palette, tint: tint)
        }
        s.picture(pictures.ground, full)
        let t = context.seconds
        if context.style.field == .aurora {
            WatchGround.aurora(s, width: width, height: height, ink: tint, text: palette.text, t: context.animated ? t : 0)
        }
        if context.style.light { drawLights(s, palette: palette, t: t) } else { pictures.keepLights([]) }
        for piece in effects.ripples {
            guard case .ripple(let rect, let corner, let grow, let span, let alpha) = piece.shape else { continue }
            WatchGround.ripple(
                s, rect: WatchRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height), corner: corner,
                grow: grow, width: span, ink: piece.ink, alpha: alpha)
        }
    }

    /// The light each tile spills on the ground around it, as strong as Core's scene makes it: the
    /// state's own figure, swelling and ebbing with the tile's breath, and fading with the tile.
    func drawLights(_ s: WallSnapshot, palette: WatchPalette, t: Double) {
        var drawn = 0
        var kept = Set<String>()
        let unit = context.unit
        let radius = 1.6 * unit
        let reach = WatchGround.spillReach * unit
        let margin = reach + radius
        for (index, tile) in wall.tiles.enumerated() where drawn < WallScene.maxLights {
            guard geometry.tiles.indices.contains(index) else { continue }
            let main = geometry.squads.indices.contains(index) ? geometry.squads[index]?.parent : nil
            let rect = main ?? geometry.tiles[index]
            let swell = WatchTilePaint.glow(tile.state, t: t, animated: context.animated)
            let strength = Self.lightOf(tile.state) * (0.75 + 0.5 * swell) * WatchTileView.opacity(tile)
            drawn += 1
            guard strength > 0.002, rect.width > 2 * radius + 1, rect.height > 2 * radius + 1 else { continue }
            let ink = palette.ink(tile.state)
            let key = tile.id
            kept.insert(key)
            let picture = pictures.light(key)
            let bounds = WatchRect(
                x: rect.x - margin, y: rect.y - margin, width: rect.width + 2 * margin, height: rect.height + 2 * margin)
            let shape = "\(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))|\(ink.hex)|\(unit)|\(context.paletteKey)"
            picture.ensure(shape, width: bounds.width, height: bounds.height, in: s, detail: 0.5) { cr, _, _ in
                WatchGround.spill(
                    cr, rect: WatchRect(x: margin, y: margin, width: rect.width, height: rect.height), unit: unit,
                    ink: ink, strength: WallBackdropPictures.lightReference)
            }
            s.picture(picture, bounds, opacity: min(1, strength / WallBackdropPictures.lightReference))
        }
        pictures.keepLights(kept)
        lightsDrawn = drawn
    }

    func drawMotes(_ s: WallSnapshot, _ width: Double, _ height: Double) {
        guard context.style.field != .none else { return }
        let palette = context.palette
        let ink = palette.mood(wall.mood, hasFailure: wall.hasFailure).mixed(with: palette.text, 0.45)
        moteField.draw(
            s, width: width, height: height, unit: context.unit, ink: ink, t: context.seconds,
            animated: context.animated, brightness: context.isNight ? 0.5 : 1,
            trails: context.style.field == .currents && context.animated)
    }

    func drawPlates(_ s: WallSnapshot) {
        guard context.style.showsSquads else { return }
        let palette = context.palette
        let u = context.unit
        let pad = 0.55 * u
        for (index, tile) in wall.tiles.enumerated() where tile.squad != nil {
            guard geometry.tiles.indices.contains(index) else { continue }
            let cell = geometry.tiles[index]
            let ink = palette.ink(tile.state)
            let plate = WatchRect(x: cell.x - pad, y: cell.y - pad, width: cell.width + 2 * pad, height: cell.height + 2 * pad)
            s.fill(plate, radius: 2.3 * u, ink: ink, alpha: 0.05)
            s.stroke(plate, radius: 2.3 * u, line: max(1, 0.14 * u), ink: ink, alpha: 0.26)
        }
    }

    func drawVignette(_ s: WallSnapshot, _ width: Double, _ height: Double) {
        guard wall.hasOverdue else { return }
        let swell = WatchGlyph.breath(context.seconds, period: 6, animated: context.animated)
        WatchAmbient.vignette(
            s, width: width, height: height, ink: context.palette.overdue, intensity: 0.07 + 0.1 * swell)
    }

    /// The ground as the frame draws it, into a cairo context, for a check that compares pixels.
    func paintGround(_ cr: OpaquePointer, _ width: Double, _ height: Double) {
        WallSnapshot.render(cr) { drawGround($0, width, height) }
    }

    /// The motes as the frame draws them, into a cairo context, for a check that compares pixels.
    func paintMotes(_ cr: OpaquePointer, _ width: Double, _ height: Double) {
        WallSnapshot.render(cr) { drawMotes($0, width, height) }
    }
}

extension WatchMotes {
    /// The field as nodes: a halo and a point for each mote, twinkling on its own phase, and with
    /// Currents each one's last four positions as a trail that thins and fades behind it.
    func draw(
        _ s: WallSnapshot, width: Double, height: Double, unit: Double, ink: PartyInk, t: Double,
        animated: Bool, brightness: Double, trails: Bool
    ) {
        fit(width: width, height: height)
        let field = self.field
        let share = animated ? stepShare : 1
        let length = WallMotes.trailLength
        func sample(_ index: Int, _ age: Int) -> (x: Double, y: Double) {
            guard age > 0 else { return (field.x[index], field.y[index]) }
            let at = index * length + min(age, length) - 1
            return (field.trailX[at], field.trailY[at])
        }
        func point(_ index: Int, _ age: Int) -> (x: Double, y: Double) {
            let newer = sample(index, age)
            let older = sample(index, age + 1)
            return ((older.x + (newer.x - older.x) * share) * width, (older.y + (newer.y - older.y) * share) * height)
        }
        buffer.removeAll(keepingCapacity: true)
        for index in 0..<field.count {
            let twinkle = animated ? 0.5 + 0.5 * sin(field.phase[index] + t * 0.45) : 0.55
            let head = point(index, 0)
            buffer.append(head.x)
            buffer.append(head.y)
            buffer.append(max(0.8, field.size[index] * unit * 0.8))
            buffer.append((0.05 + 0.13 * twinkle) * brightness)
        }
        s.motes(buffer, halo: 2.2, haloShare: 0.22, ink: ink)
        if trails {
            for step in 0..<length {
                segments.removeAll(keepingCapacity: true)
                for index in 0..<field.count {
                    let from = point(index, step)
                    let to = point(index, step + 1)
                    segments.append(from.x)
                    segments.append(from.y)
                    segments.append(to.x)
                    segments.append(to.y)
                }
                let fade = 1 - Double(step) / Double(length)
                s.segments(segments, line: max(1, unit * 0.34 * fade), ink: ink, alpha: 0.16 * fade * brightness)
            }
        }
    }
}

extension WatchGround {
    /// The aurora's three blooms as gradients the GPU draws.
    static func aurora(_ s: WallSnapshot, width: Double, height: Double, ink: PartyInk, text: PartyInk, t: Double) {
        let reach = 0.55 * max(width, height)
        for bloom in blooms(t: t) {
            let colour = ink.mixed(with: text, bloom.mix)
            let stops = [0.0, 0.25, 0.5, 0.75, 1.0].map { stop in
                WallStop(offset: stop, ink: colour, alpha: bloom.alpha * exp(-stop * stop * 3.6) * (1 - stop * stop * stop * stop))
            }
            s.radial(x: bloom.x * width, y: bloom.y * height, from: 0, to: reach, stops: stops)
        }
    }

    /// A band of light spreading from a tile's edge, as three bands of falling width and rising
    /// strength the GPU draws outside the tile.
    static func ripple(
        _ s: WallSnapshot, rect: WatchRect, corner: Double, grow: Double, width: Double, ink: PartyInk, alpha: Double
    ) {
        guard alpha > 0.002, rect.width > 1, rect.height > 1 else { return }
        for (span, share) in [(4.0, 0.12), (2.0, 0.30), (0.8, 0.55)] {
            let line = max(1.5, width * span)
            s.band(rect, radius: corner, from: grow - line / 2, to: grow + line / 2, ink: ink, alpha: alpha * share)
        }
    }
}

extension WatchAmbient {
    /// The edge that breathes when something has waited too long, as four gradients the GPU draws.
    static func vignette(_ s: WallSnapshot, width: Double, height: Double, ink: PartyInk, intensity: Double) {
        let band = min(width, height) * 0.13
        let stops = [WallStop(offset: 0, ink: ink, alpha: intensity), WallStop(offset: 1, ink: ink, alpha: 0)]
        s.linear(WatchRect(x: 0, y: 0, width: width, height: band), from: (0, 0), to: (0, band), stops: stops)
        s.linear(
            WatchRect(x: 0, y: height - band, width: width, height: band), from: (0, height), to: (0, height - band),
            stops: stops)
        s.linear(WatchRect(x: 0, y: 0, width: band, height: height), from: (0, 0), to: (band, 0), stops: stops)
        s.linear(
            WatchRect(x: width - band, y: 0, width: band, height: height), from: (width, 0), to: (width - band, 0),
            stops: stops)
    }
}

import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension WallState {
    /// What a picture of the state depends on, without the dates some states carry, so a quiet
    /// tile is not painted again every second it stays quiet.
    var paintKey: String {
        switch self {
        case .working: return "w"
        case .thinking: return "t"
        case .needsYou(let urgency): return "n\(urgency)"
        case .retrying: return "r"
        case .quiet: return "q"
        case .background(let stuck): return stuck ? "bs" : "b"
        case .finished(let outcome): return "f\(outcome)"
        case .away: return "a"
        }
    }
}

/// A card's glass as the renderer draws it: `WatchTilePaint.card`'s glass, wash, edge, rim,
/// ultracode ring and focus, each a node the GPU draws, so a card that breathes costs a dozen nodes
/// a frame and no pixels, and one wearing the ultracode ring a hundred or so more for its runs.
/// Only the hatching of a machine that went away is painted, once.
final class WallCard {
    private let hatch = WallPicture()

    static let rainbow: [Double] = Ultracode.rainbowStops.flatMap { [$0.red, $0.green, $0.blue] }

    func draw(
        _ s: WallSnapshot, width: Double, height: Double, unit: Double, corner: Double = 1,
        face: WatchTilePaint.Face, palette: WatchPalette, paletteKey: Int, t: Double, animated: Bool
    ) {
        guard width > 2, height > 2 else { return }
        let ink = palette.ink(face.state)
        let radius = 1.6 * unit * corner
        let swell = WatchTilePaint.glow(face.state, t: t, animated: animated)
        let shape = WatchRect(x: 0.5, y: 0.5, width: width - 1, height: height - 1)
        let full = WatchRect(x: 0, y: 0, width: width, height: height)
        let strength = WatchTilePaint.washStrength(face, swell: swell)
        let text = palette.text
        s.roundedClip(shape, radius: radius) {
            s.linear(
                full, from: (0, 0), to: (0, height),
                stops: [WallStop(offset: 0, ink: text, alpha: 0.085), WallStop(offset: 1, ink: text, alpha: 0.03)])
            s.linear(
                full, from: (0, 0), to: (0, height * 0.9),
                stops: [WallStop(offset: 0, ink: ink, alpha: strength * 1.6), WallStop(offset: 1, ink: ink, alpha: 0)])
            if face.state.isNeedsYou { s.fill(full, radius: 0, ink: ink, alpha: strength * 0.5) }
            if case .away = face.state {
                hatch.ensure("\(paletteKey)|\(unit)", width: width, height: height, in: s) { cr, w, h in
                    WatchTilePaint.hatch(cr, width: w, height: h, unit: unit, face: face, palette: palette)
                }
                s.picture(hatch, full)
            }
        }
        let (alpha, line) = WatchTilePaint.border(face.state, unit: unit, swell: swell)
        s.stroke(shape, radius: radius, line: line, ink: ink, alpha: alpha)
        s.clipped(WatchRect(x: radius, y: 0, width: max(0, width - 2 * radius), height: 2)) {
            s.stroke(
                WatchRect(x: 1.5, y: 1.5, width: width - 3, height: radius * 4), radius: radius, line: 1,
                ink: .white, alpha: 0.1)
        }
        if face.ultracode {
            let phase = animated && face.state.auraTurns ? Ultracode.aura(at: t).phase : 0
            aura(s, width: width, height: height, unit: unit, radius: radius, phase: phase)
        }
        if face.focused {
            s.stroke(
                WatchRect(x: unit * 0.35, y: unit * 0.35, width: width - unit * 0.7, height: height - unit * 0.7),
                radius: radius, line: max(1.5, unit * 0.2), ink: palette.text, alpha: 0.85)
        }
    }

    /// The ultracode ring: the rainbow swept around the card's centre in a band just inside the
    /// edge, once wide and faint and once thin and bright, as `WatchTilePaint.aura` paints it. The
    /// sweep starts on the left and turns clockwise with the phase.
    private func aura(_ s: WallSnapshot, width: Double, height: Double, unit: Double, radius: Double, phase: Double) {
        let inset = WallPlate.auraInset * unit
        let corner = max(0, radius - inset)
        let line = max(1.5, 0.14 * unit)
        guard width > 2 * inset + line, height > 2 * inset + line else { return }
        let rect = WatchRect(x: inset, y: inset, width: width - 2 * inset, height: height - 2 * inset)
        let degrees = -90 - 360 * phase
        s.sweepBand(
            rect, radius: corner, band: unit * 0.9, degrees: degrees, alpha: WallPlate.auraAlpha * 0.16,
            stops: Self.rainbow)
        s.sweepBand(rect, radius: corner, band: line, degrees: degrees, alpha: WallPlate.auraAlpha, stops: Self.rainbow)
    }
}

/// A state's mark as the renderer draws it, the same marks as `WatchGlyph.paint`: the context ring,
/// the lit core and the dashes are pictures painted when they change, and what moves is a scale,
/// a turn, an opacity or a ring the GPU draws itself, so a mark that breathes costs a few nodes.
final class WallGlyph {
    private let ring = WallPicture()
    private let body = WallPicture()
    private let dashes = WallPicture()
    private let still = WallPicture()

    func draw(
        _ s: WallSnapshot, size: Double, state: WallState, share: Double?, fade: Double,
        palette: WatchPalette, paletteKey: Int, t: Double, animated: Bool
    ) {
        guard size > 2 else { return }
        let c = size / 2
        let ink = palette.ink(state)
        let ringRadius = size * 0.455
        let ringWidth = size * 0.058
        let coreRadius = size * 0.29
        switch state {
        case .working:
            contextRing(s, size: size, share: share, ink: ink, palette: palette, paletteKey: paletteKey)
            let swell = WatchGlyph.breath(t, period: 3.4, animated: animated)
            core(s, c: c, r: coreRadius, scale: 0.93 + 0.07 * swell, ink: ink, glow: 0.35 + 0.35 * swell, paletteKey: paletteKey)
        case .thinking:
            contextRing(s, size: size, share: share, ink: ink, palette: palette, paletteKey: paletteKey)
            let swell = WatchGlyph.breath(t, period: 7.5, animated: animated)
            core(s, c: c, r: coreRadius, scale: 0.9 + 0.06 * swell, ink: ink, glow: 0.2 + 0.3 * swell, paletteKey: paletteKey)
        case .needsYou(let urgency):
            let overdue = urgency == .overdue
            let period = overdue ? 2.6 : 4.2
            let second = overdue ? 0.26 : 0.34
            let hit = WatchGlyph.knock(t, period: period, second: second, animated: animated)
            contextRing(s, size: size, share: share, ink: ink, palette: palette, paletteKey: paletteKey)
            if animated { waves(s, c: c, core: coreRadius, outer: ringRadius, ink: ink, t: t, period: period, second: second) }
            core(s, c: c, r: coreRadius, scale: 0.9 + 0.2 * hit, ink: ink, glow: 0.45 + 0.5 * hit, paletteKey: paletteKey)
        case .retrying:
            contextRing(s, size: size, share: share, ink: ink, palette: palette, paletteKey: paletteKey, factor: 0.82, track: false)
            dashes.ensure("\(ink.hex)|\(paletteKey)", width: size, height: size, in: s) { cr, w, _ in
                WatchGlyph.crawl(cr, w / 2, w * 0.455, w * 0.058, ink, 0, false)
            }
            let turn = animated ? (0.55 * t).truncatingRemainder(dividingBy: 2 * .pi) * 180 / .pi : 0
            s.turned(about: c, c, degrees: turn) { s.picture(dashes, WatchRect(x: 0, y: 0, width: size, height: size)) }
            core(s, c: c, r: coreRadius * 0.45, scale: 1, ink: ink, glow: 0.2, paletteKey: paletteKey)
        case .quiet:
            contextRing(s, size: size, share: share, ink: ink, palette: palette, paletteKey: paletteKey)
            if animated {
                let phase = t.truncatingRemainder(dividingBy: 60) / 6
                if phase < 1 {
                    s.ring(
                        x: c, y: c, radius: coreRadius + (ringRadius * 1.1 - coreRadius) * phase,
                        line: max(1, coreRadius * 0.1), ink: ink.lifted(0.2), alpha: 0.4 * (1 - phase))
                }
            }
            let flat = coreRadius * 0.92
            s.disc(x: c, y: c, radius: flat, ink: ink, alpha: 0.9)
            s.ring(x: c, y: c, radius: flat, line: max(1, flat * 0.08), ink: ink.lifted(0.25), alpha: 0.5)
        case .background(let stuck):
            let radius = ringRadius * 0.86
            let width = ringWidth * 1.25
            s.ring(x: c, y: c, radius: radius, line: width, ink: ink, alpha: stuck ? 0.95 : 0.7)
            s.ring(x: c, y: c, radius: radius * 0.5, line: width * 0.6, ink: ink, alpha: 0.16)
            let angle = stuck ? -.pi / 2 : (animated ? t * 2 * .pi / 6.5 - .pi / 2 : 0.8 * .pi)
            let x = c + cos(angle) * radius
            let y = c + sin(angle) * radius
            s.disc(x: x, y: y, radius: width * 1.35, ink: ink.lifted(0.35), alpha: 1)
            s.disc(x: x, y: y, radius: width * 2.4, ink: ink, alpha: 0.22)
        case .finished(let outcome):
            let cooled = (fade * 100).rounded() / 100
            still.ensure("f\(outcome)|\(cooled)|\(ink.hex)|\(paletteKey)", width: size, height: size, in: s) { cr, w, _ in
                WatchGlyph.finish(cr, w / 2, w, outcome, ink, palette, cooled)
            }
            s.picture(still, WatchRect(x: 0, y: 0, width: size, height: size))
        case .away:
            still.ensure("a|\(ink.hex)|\(paletteKey)", width: size, height: size, in: s) { cr, w, _ in
                WatchGlyph.hatched(cr, w / 2, w * 0.4, ink)
            }
            s.picture(still, WatchRect(x: 0, y: 0, width: size, height: size))
        }
    }

    private func contextRing(
        _ s: WallSnapshot, size: Double, share: Double?, ink: PartyInk, palette: WatchPalette, paletteKey: Int,
        factor: Double = 1, track: Bool = true
    ) {
        guard let share else { return }
        let held = (max(0, min(1, share)) * 1000).rounded() / 1000
        ring.ensure("\(held)|\(ink.hex)|\(factor)|\(track)|\(paletteKey)", width: size, height: size, in: s) { cr, w, _ in
            WatchGlyph.contextRing(cr, w / 2, w * 0.455 * factor, w * 0.058, held, ink, palette, track: track)
        }
        s.picture(ring, WatchRect(x: 0, y: 0, width: size, height: size))
    }

    private func core(
        _ s: WallSnapshot, c: Double, r: Double, scale: Double, ink: PartyInk, glow: Double, paletteKey: Int
    ) {
        s.radial(
            x: c, y: c, from: r * scale * 0.5, to: r * scale * 1.68,
            stops: [WallStop(offset: 0, ink: ink, alpha: 0.5 * glow), WallStop(offset: 1, ink: ink, alpha: 0)])
        body.ensure("\(ink.hex)|\(paletteKey)", width: 2 * r, height: 2 * r, in: s) { cr, w, _ in
            WatchGlyph.body(cr, w / 2, w / 2, ink)
        }
        s.turned(about: c, c, scale: scale) {
            s.picture(body, WatchRect(x: c - r, y: c - r, width: 2 * r, height: 2 * r))
        }
    }

    private func waves(
        _ s: WallSnapshot, c: Double, core: Double, outer: Double, ink: PartyInk, t: Double, period: Double,
        second: Double
    ) {
        let p = t.truncatingRemainder(dividingBy: period)
        for start in [0, second] {
            let q = (p - start) / 1.1
            guard q >= 0, q < 1 else { continue }
            s.ring(
                x: c, y: c, radius: core + (outer * 1.12 - core) * q, line: max(1.2, core * 0.12), ink: ink,
                alpha: 0.6 * (1 - q) * (1 - q))
        }
    }
}

/// The calm wall's orb as the renderer draws it, `WatchCalmView.paint`'s halo, rings and body: the
/// halo and the rings are nodes and only the body is a picture, scaled as it breathes.
final class WallCalmOrb {
    private let body = WallPicture()

    func draw(_ s: WallSnapshot, size: Double, palette: WatchPalette, paletteKey: Int, t: Double, animated: Bool) {
        guard size > 2 else { return }
        let centre = size / 2
        let ink = palette.working.mixed(with: palette.text, 0.25)
        let swell = WatchGlyph.breath(t, period: 9, animated: animated)
        let core = size * (0.17 + 0.012 * swell)
        s.radial(
            x: centre, y: centre, from: core * 0.4, to: size * 0.5,
            stops: [
                WallStop(offset: 0, ink: ink, alpha: 0.2 + 0.1 * swell), WallStop(offset: 1, ink: ink, alpha: 0),
            ])
        for ring in 0..<3 {
            let radius = size * (0.27 + 0.085 * Double(ring))
            let drift = animated ? 0.5 + 0.5 * sin(2 * .pi * (t / 14 - Double(ring) * 0.14)) : 0.6
            s.ring(
                x: centre, y: centre, radius: radius, line: max(1, size * 0.004), ink: ink,
                alpha: (0.18 - 0.04 * Double(ring)) * (0.55 + 0.45 * drift))
        }
        let full = size * 0.182
        body.ensure("\(ink.hex)|\(paletteKey)", width: 2 * full, height: 2 * full, in: s) { cr, w, _ in
            WatchCalmView.body(cr, centre: w / 2, core: w / 2, ink: ink)
        }
        s.turned(about: centre, centre, scale: core / full) {
            s.picture(body, WatchRect(x: centre - full, y: centre - full, width: 2 * full, height: 2 * full))
        }
    }
}

/// A heartbeat strip as a picture of its bars, painted when the beat changes and slid by the GPU
/// when a new beat pushes the old ones along.
final class WallBeat {
    private let bars = WallPicture()

    func draw(
        _ s: WallSnapshot, width: Double, height: Double, beat: [Int], slide: Double, ink: PartyInk,
        palette: WatchPalette, paletteKey: Int
    ) {
        guard !beat.isEmpty, width > 0, height > 0 else { return }
        let key = beat.map(String.init).joined(separator: ",") + "|\(ink.hex)|\(paletteKey)"
        bars.ensure(key, width: width, height: height, in: s) { cr, w, h in
            WatchTilePaint.beat(cr, width: w, height: h, beat: beat, slide: 0, ink: ink, palette: palette)
        }
        let full = WatchRect(x: 0, y: 0, width: width, height: height)
        guard slide > 0, !beat.allSatisfy({ $0 == 0 }) else {
            s.picture(bars, full)
            return
        }
        let pitch = width / Double(beat.count)
        s.clipped(full) {
            s.turned(about: 0, 0, by: slide * pitch, 0) { s.picture(bars, full) }
        }
    }
}

import Foundation

extension WallScene.Builder {
    static let amberShare = 0.85
    static let ringRadius = 0.455
    static let ringWidth = 0.058
    static let coreRadius = 0.29

    /// The context share a tile's ring shows: the draining value while a compaction plays, otherwise
    /// what the reading says; nil draws no ring at all.
    func shownShare(of tile: WallTile) -> Double? {
        for effect in live where effect.kind == .drain && effect.tile == tile.id {
            if let share = WallEffectShapes.drainShare(effect, at: t) { return share }
        }
        return tile.contextShare
    }

    func ringInk(_ share: Double, _ ink: WallInk) -> WallInk {
        guard share > Self.amberShare else { return ink }
        return ink == palette.needs ? palette.overdue : palette.needs
    }

    mutating func addGlyph(
        of tile: WallTile, face: WallState.Face, at metrics: WallTileMetrics, ink: WallInk,
        opacity: Double, pulse: Double
    ) {
        let share = shownShare(of: tile).map { WallMath.clamp($0, 0, 1) }
        let mark = Mark(
            x: metrics.glyphX, y: metrics.glyphY, size: metrics.glyphSize, alpha: opacity)
        switch face {
        case .working:
            addRing(mark, share, ink)
            let swell = WallMath.breath(t, period: 3.4, animated: animated) + pulse * 0.6
            scene.glyphs.append(
                mark.glyph(
                    .orb, 0.75, ink, p1: Self.coreRadius * (0.93 + 0.07 * swell), p2: 0.35 + 0.35 * swell))
        case .thinking:
            addRing(mark, share, ink)
            let swell = WallMath.breath(t, period: 7.5, animated: animated)
            scene.glyphs.append(
                mark.glyph(
                    .orb, 0.75, ink, p1: Self.coreRadius * (0.9 + 0.06 * swell), p2: 0.2 + 0.3 * swell))
        case .needs, .overdue:
            addAsk(mark, share, ink, overdue: face == .overdue)
        case .retrying:
            if let share {
                scene.glyphs.append(
                    mark.glyph(
                        .arc, 0.62, ringInk(share, ink), p1: Self.ringRadius * 0.8, p2: Self.ringWidth,
                        p3: share, p4: 0))
            }
            scene.glyphs.append(
                mark.glyph(
                    .dashes, 0.62, ink, alpha: opacity * 0.95, p1: Self.ringRadius, p2: 0.067,
                    p3: animated ? -t * 0.09 : 0))
            scene.glyphs.append(mark.glyph(.orb, 0.6, ink, p1: 0.13, p2: 0.2))
        case .quiet:
            addRing(mark, share, ink)
            addQuietRipple(of: tile, mark, ink)
            scene.glyphs.append(mark.glyph(.flat, 0.5, ink, p1: 0.267))
        case .background, .stuck:
            let still = face == .stuck || !animated
            scene.glyphs.append(
                mark.glyph(
                    .hollow, 0.6, ink, p1: 0.39, p2: 0.072, p3: still ? 0.9 : t * 2 * .pi / 6.5, p4: 0.075))
        case .done:
            scene.glyphs.append(mark.glyph(.check, 0.6, ink))
        case .failed:
            scene.glyphs.append(mark.glyph(.cross, 0.6, ink))
        case .stopped:
            if case .finished(.unknown) = tile.state {
                scene.glyphs.append(mark.glyph(.ring, 0.6, ink, p1: 0.36, p2: 0.035))
            } else {
                scene.glyphs.append(mark.glyph(.square, 0.6, palette.dim))
            }
        case .away:
            scene.glyphs.append(mark.glyph(.hatched, 0.6, palette.dim, p1: 0.4))
        }
    }

    private mutating func addRing(_ mark: Mark, _ share: Double?, _ ink: WallInk, track: Bool = true) {
        guard let share else { return }
        scene.glyphs.append(
            mark.glyph(
                .arc, 0.62, ringInk(share, ink), p1: Self.ringRadius, p2: Self.ringWidth, p3: share,
                p4: track ? 0.14 : 0))
    }

    private mutating func addAsk(_ mark: Mark, _ share: Double?, _ ink: WallInk, overdue: Bool) {
        let period = overdue ? 2.6 : 4.2
        let second = overdue ? 0.26 : 0.34
        let hit = WallMath.knock(t, period: period, second: second, animated: animated)
        addRing(mark, share, ink)
        if animated {
            let phase = t.truncatingRemainder(dividingBy: period)
            var start = 0.0
            for _ in 0..<2 {
                let q = (phase - start) / 1.1
                if q >= 0, q < 1 {
                    scene.glows.append(
                        mark.glyph(
                            .ring, 0.75, ink, alpha: mark.alpha * 0.6 * (1 - q) * (1 - q),
                            p1: Self.coreRadius + (0.51 - Self.coreRadius) * q, p2: 0.03))
                }
                start = second
            }
        }
        scene.glyphs.append(
            mark.glyph(.orb, 0.8, ink, p1: Self.coreRadius * (0.9 + 0.2 * hit), p2: 0.45 + 0.5 * hit))
    }

    private mutating func addQuietRipple(of tile: WallTile, _ mark: Mark, _ ink: WallInk) {
        guard animated, case .quiet(let since) = tile.state else { return }
        let age = max(0, input.now.timeIntervalSince(since))
        let phase = age.truncatingRemainder(dividingBy: 60) / 2.6
        guard phase < 1 else { return }
        scene.glows.append(
            mark.glyph(
                .ring, 0.9, ink, alpha: mark.alpha * 0.5 * (1 - phase), p1: Self.coreRadius + 0.4 * phase,
                p2: 0.04))
    }

    mutating func addWorkerGlyph(
        _ worker: WallWorker, at metrics: WallTileMetrics, ink: WallInk, opacity: Double
    ) {
        let mark = Mark(x: metrics.glyphX, y: metrics.glyphY, size: metrics.glyphSize, alpha: opacity)
        let salt = Double(worker.id.count)
        switch worker.state {
        case .working:
            let swell = WallMath.breath(t + salt, period: 3.4, animated: animated)
            scene.glyphs.append(
                mark.glyph(
                    .orb, 0.75, ink, p1: Self.coreRadius * (0.92 + 0.08 * swell), p2: 0.3 + 0.3 * swell))
        case .quiet:
            scene.glyphs.append(mark.glyph(.flat, 0.5, ink, p1: 0.26))
        case .background(let stuck):
            let angle = stuck || !animated ? 0.9 : t * 2 * .pi / 6.5 + salt
            scene.glyphs.append(mark.glyph(.hollow, 0.6, ink, p1: 0.36, p2: 0.08, p3: angle, p4: 0.085))
        case .finished:
            let cooled = opacity * (1 - 0.5 * WallMath.clamp(worker.fade, 0, 1))
            scene.glyphs.append(mark.glyph(.ring, 0.6, ink, alpha: cooled, p1: 0.36, p2: 0.035))
        }
    }

    mutating func addCalmOrb() {
        let centre = input.layout.centre
        guard centre.width > 0 else { return }
        let mark = Mark(x: centre.midX, y: centre.midY - 2 * unit, size: centre.width, alpha: 0.9)
        let swell = WallMath.breath(t, period: 11, animated: animated)
        scene.glyphs.append(
            mark.glyph(
                .orb, 0.95, palette.quiet, p1: Self.coreRadius * (0.94 + 0.06 * swell),
                p2: 0.35 + 0.25 * swell))
        scene.glyphs.append(
            mark.glyph(.arc, 0.62, palette.quiet, alpha: 0.5, p1: Self.ringRadius, p2: 0.012, p3: 1, p4: 0))
    }

    /// A glyph's place and the opacity it is drawn at, so each mark names only what is its own.
    struct Mark {
        let x: Double
        let y: Double
        let size: Double
        let alpha: Double

        func glyph(
            _ kind: WallGlyphKind, _ extent: Double, _ ink: WallInk, alpha: Double? = nil,
            p1: Double = 0, p2: Double = 0, p3: Double = 0, p4: Double = 0
        ) -> WallGlyph {
            WallGlyph(
                x: x, y: y, size: size, extent: extent, kind: kind, ink: ink, alpha: alpha ?? self.alpha,
                p1: p1, p2: p2, p3: p3, p4: p4)
        }
    }
}

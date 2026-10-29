import Foundation
import Testing

@testable import TailscodeCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let rose = WallPalette.current(theme: .rosePine)

private struct Setup {
    var width = 1920.0
    var height = 1080.0
    var safe = WallInsets.zero
    var fold: WallFold?
    var style = WallStyle.studio
    var t = 12.0
    var effects: [WallEffect] = []
    var ribbon: WallRibbon?
    var hold: WallHold?
    var dim = 0.0
    var peeking = false
    var animated = true
    var beatSlide = 0.0
}

private func build(_ wall: AgentWall, _ setup: Setup = Setup()) -> (scene: WallScene, layout: WallLayout, wall: AgentWall) {
    let reading = WallLayout.reading(
        width: setup.width, height: setup.height, safe: setup.safe, fold: setup.fold, style: setup.style)
    let read = wall.reflowed(aspect: reading.aspect, gridAspect: reading.gridAspect, pages: reading.pages)
    let layout = WallLayout.make(
        width: setup.width, height: setup.height, safe: setup.safe, fold: setup.fold, wall: read,
        style: setup.style)
    let input = WallSceneInput(
        wall: read, layout: layout, palette: rose, style: setup.style, t: setup.t, now: now,
        effects: setup.effects, motes: WallMotes(width: setup.width, height: setup.height, seed: 99_173),
        ribbon: setup.ribbon, hold: setup.hold, dim: setup.dim, peeking: setup.peeking,
        animated: setup.animated, beatSlide: setup.beatSlide)
    return (WallScene.build(input), layout, read)
}

private func demo(_ name: String) -> AgentWall {
    AgentDemo.wallScenes(now: now).first { $0.name == name }!.wall
}

private func finite(_ value: Any) -> Bool {
    if let number = value as? Double { return number.isFinite }
    return Mirror(reflecting: value).children.allSatisfy { finite($0.value) }
}

private let names = ["calm", "busy", "attention", "alarm", "finishing", "crowded", "squad"]

private let screens: [(String, Setup)] = [
    ("display", Setup()),
    ("iPad portrait", Setup(width: 1032, height: 1376, safe: WallInsets(bottom: 20))),
    ("book", Setup(width: 951, height: 669, fold: WallFold(axis: .vertical, from: 455.5, to: 495.5))),
    ("laptop", Setup(width: 669, height: 951, fold: WallFold(axis: .horizontal, from: 455.5, to: 495.5))),
    ("tent", Setup(width: 678, height: 466, safe: WallInsets(bottom: 21, trailing: 84))),
    ("closed", Setup(width: 466, height: 678, safe: WallInsets(top: 82, bottom: 34, trailing: 84))),
    ("window", Setup(width: 760, height: 560)),
]

@Suite struct WallSceneBuildTests {
    @Test(arguments: names) func everyDemoSceneBuildsOnEveryScreenWithoutBadNumbers(_ name: String) {
        for (screen, setup) in screens {
            let built = build(demo(name), setup)
            #expect(finite(built.scene), "\(name) on \(screen)")
            #expect(built.scene.lights.count <= 8 && built.scene.ripples.count <= 12)
            #expect(built.scene.width == setup.width && built.scene.height == setup.height)
            #expect(built.scene.unit == built.layout.unit)
        }
    }

    @Test(arguments: names) func everyDemoSceneBuildsWhileEveryEffectPlays(_ name: String) {
        let wall = demo(name)
        let kinds: [WallEffect.Kind] = [
            .spark, .thread, .dissolve, .exhale, .groundRipple, .knock, .fracture, .pulse, .approved, .drain,
            .gather, .scatter, .fade,
        ]
        var setup = Setup()
        setup.effects = wall.tiles.flatMap { tile in
            kinds.map { kind in
                WallEffect(
                    kind: kind, tile: tile.id, worker: tile.workers.first?.id, start: 11, duration: 2,
                    ink: .tile, amplitude: 1.6, seed: 5, from: 0.9, to: 0.2)
            }
        }
        for (screen, base) in screens {
            var made = setup
            (made.width, made.height, made.safe, made.fold) = (base.width, base.height, base.safe, base.fold)
            let built = build(wall, made)
            #expect(finite(built.scene), "\(name) on \(screen)")
            #expect(built.scene.ripples.count <= 12 && built.scene.lights.count <= 8)
            #expect(built.scene.isAnimating == !wall.tiles.isEmpty)
        }
    }

    @Test func buildingTwiceGivesTheSameFrame() {
        #expect(build(demo("squad")).scene == build(demo("squad")).scene)
    }

    @Test func theGroundCarriesTheMoodTheDimAndTheDrift() {
        let calm = build(demo("calm")).scene
        #expect(calm.tint == rose.mood(.calm, hasFailure: false) && calm.tintAlpha == 0.085)
        #expect(calm.gridAlpha == 0.032 && calm.dim == 1 && calm.aurora == 0)
        #expect(build(demo("busy")).scene.tint == rose.working)
        #expect(build(demo("attention")).scene.tint == rose.needs)
        var dimmed = Setup()
        dimmed.dim = 1
        #expect(abs(build(demo("busy"), dimmed).scene.dim - 0.4) < 1e-9)
        dimmed.peeking = true
        #expect(abs(build(demo("busy"), dimmed).scene.dim - 0.18) < 1e-9)
        var turn = Setup()
        turn.t = 150
        let drifted = build(demo("busy"), turn).scene
        #expect(abs(drifted.driftX - 6) < 1e-9 && abs(drifted.driftY) < 1e-9)
        turn.animated = false
        let held = build(demo("busy"), turn).scene
        #expect(held.driftX == 0 && held.driftY == 0)
    }

    @Test func anOverdueAskBreathesTheEdgeAndNothingElseDoes() {
        let alarm = build(demo("alarm"), Setup()).scene
        #expect(demo("alarm").tiles.contains { $0.state == .needsYou(.overdue) })
        #expect(alarm.vignette >= 0.06 && alarm.vignette <= 0.26 && alarm.vignetteInk == rose.overdue)
        var still = Setup()
        still.animated = false
        #expect(build(demo("alarm"), still).scene.vignette == 0.18)
        #expect(build(demo("busy")).scene.vignette == 0)
        #expect(build(demo("calm")).scene.vignette == 0)
    }

    @Test func auroraIsTheStylesField() {
        var setup = Setup()
        setup.style = .showcase
        #expect(build(demo("busy"), setup).scene.aurora == 1)
        #expect(build(demo("busy")).scene.aurora == 0)
    }
}

@Suite struct WallSceneStyleTests {
    @Test func lightOffMeansNoLights() {
        var setup = Setup()
        setup.style.light = false
        #expect(build(demo("crowded"), setup).scene.lights.isEmpty)
        let lit = build(demo("crowded")).scene
        #expect(lit.lights.count == min(8, demo("crowded").tiles.count) && lit.lights.allSatisfy { $0.strength > 0 })
    }

    @Test func fieldNoneMeansNoMoteDots() {
        var setup = Setup()
        setup.style.field = .none
        for name in names { #expect(build(demo(name), setup).scene.dots.isEmpty, "\(name)") }
        #expect(!build(demo("busy")).scene.dots.isEmpty)
    }

    @Test func currentsAddTrailsAndMotesDoNot() {
        var setup = Setup()
        setup.style.field = .currents
        let motes = WallMotes(width: 1920, height: 1080, seed: 99_173)
        var moving = motes
        for _ in 0..<60 { moving.step(dt: 1 / 30, mood: .busy, target: nil, slow: 1, aspect: 16.0 / 9) }
        let wall = demo("busy")
        func dots(_ style: WallStyle) -> Int {
            var made = setup
            made.style = style
            let reading = WallLayout.reading(width: 1920, height: 1080, safe: .zero, fold: nil, style: style)
            let read = wall.reflowed(aspect: reading.aspect, gridAspect: reading.gridAspect)
            let layout = WallLayout.make(width: 1920, height: 1080, safe: .zero, fold: nil, wall: read, style: style)
            let input = WallSceneInput(
                wall: read, layout: layout, palette: rose, style: style, t: 3, now: now, motes: moving)
            return WallScene.build(input).dots.count
        }
        var plain = setup.style
        plain.field = .motes
        #expect(dots(plain) == moving.count)
        #expect(dots(setup.style) > moving.count)
    }

    @Test func stillMovesNothingAndTheFieldStopsTwinkling() {
        var one = Setup()
        one.style.still = true
        one.t = 3
        var two = one
        two.t = 41.5
        for name in ["busy", "attention", "squad", "calm"] {
            let a = build(demo(name), one).scene
            let b = build(demo(name), two).scene
            #expect(a.dots == b.dots && !a.dots.isEmpty, "\(name)")
            #expect(a.glows == b.glows, "\(name)")
            #expect(a.glyphs == b.glyphs && a.plates == b.plates, "\(name)")
            #expect(a.driftX == 0 && a.vignette == b.vignette && !a.isAnimating)
        }
        var live = Setup()
        live.t = 3
        var later = live
        later.t = 41.5
        #expect(build(demo("busy"), live).scene.dots != build(demo("busy"), later).scene.dots)
    }

    @Test func nightMakesTheFieldFainter() {
        var night = Setup()
        night.style.night = .always
        let day = build(demo("busy")).scene.dots
        let dark = build(demo("busy"), night).scene.dots
        #expect(zip(day, dark).allSatisfy { abs($1.alpha - $0.alpha / 2) < 1e-9 })
    }
}

@Suite struct WallSceneTileTests {
    @Test func everyTileGetsAPlateAGlyphAndItsHeartbeat() {
        var setup = Setup()
        setup.style.showsHour = false
        let built = build(demo("busy"), setup)
        let tiles = built.wall.tiles
        #expect(built.scene.plates.count >= tiles.count)
        for (index, tile) in tiles.enumerated() {
            let rect = built.layout.squads[index]?.parent ?? built.layout.tiles[index]
            #expect(built.scene.plates.contains { $0.rect == rect })
            let metrics = WallTileMetrics.tile(rect, unit: built.layout.unit)
            #expect(built.scene.glyphs.contains { $0.x == metrics.glyphX && $0.y == metrics.glyphY && $0.size == metrics.glyphSize })
            if tile.beat != nil {
                let strip = metrics.beat
                let own = built.scene.bars.filter { strip.inset(-0.01).intersects($0.rect) }
                #expect(!own.isEmpty)
                for bar in own {
                    #expect(bar.rect.x >= strip.x - 0.01 && bar.rect.maxX <= strip.maxX + 0.01)
                    #expect(bar.rect.y >= strip.y - 0.01 && bar.rect.maxY <= strip.maxY + 0.01)
                }
            }
        }
    }

    @Test func heartbeatBarsSlideWithoutLeavingTheStrip() {
        var setup = Setup()
        setup.style.showsHour = false
        setup.beatSlide = 0.7
        let built = build(demo("busy"), setup)
        let strips = built.wall.tiles.enumerated().map {
            WallTileMetrics.tile(built.layout.squads[$0.offset]?.parent ?? built.layout.tiles[$0.offset], unit: built.layout.unit).beat
        }
        for bar in built.scene.bars {
            #expect(strips.contains { bar.rect.x >= $0.x - 0.01 && bar.rect.maxX <= $0.maxX + 0.01 && bar.rect.maxY <= $0.maxY + 0.01 })
        }
    }

    @Test func aSquadGetsABackingPlateWorkerPlatesAndGlyphs() throws {
        let built = build(demo("squad"))
        let index = try #require(built.wall.tiles.firstIndex { $0.squad != nil })
        let squad = try #require(built.layout.squads[index])
        let cell = built.layout.tiles[index]
        #expect(built.scene.plates.contains { $0.rect == cell.inset(-4) && $0.sheen == 0 })
        for slot in squad.slots { #expect(built.scene.plates.contains { $0.rect == slot }) }
        if let more = squad.more { #expect(built.scene.plates.contains { $0.rect == more }) }
        let workers = built.wall.tiles[index].workers.prefix(squad.slots.count)
        for (worker, slot) in zip(workers, squad.slots) {
            let metrics = WallTileMetrics.worker(slot, unit: built.layout.unit)
            #expect(built.scene.glyphs.contains { $0.x == metrics.glyphX && $0.y == metrics.glyphY }, "\(worker.title)")
        }
    }

    @Test func aFinishedTileCoolsInOpacityAndAnAwayTileIsHatchedAndDimmer() {
        let built = build(demo("finishing"))
        for (index, tile) in built.wall.tiles.enumerated() {
            let rect = built.layout.squads[index]?.parent ?? built.layout.tiles[index]
            guard let plate = built.scene.plates.first(where: { $0.rect == rect }) else {
                Issue.record("no plate for \(tile.title)")
                continue
            }
            if case .finished = tile.state {
                #expect(abs(plate.opacity - (1 - 0.55 * tile.fade)) < 1e-9)
            }
            if case .away = tile.state { #expect(plate.hatch && abs(plate.opacity - 0.7) < 1e-9) }
            #expect(plate.opacity > 0.4 && plate.opacity <= 1)
        }
        let all = AgentDemo.wallScenes(now: now).flatMap { $0.wall.tiles }
        #expect(all.contains { if case .away = $0.state { return true } else { return false } })
    }

    @Test func eachStateWearsItsOwnGlyph() {
        var seen: Set<Int> = []
        for scene in AgentDemo.wallScenes(now: now) {
            let built = build(scene.wall)
            for (index, tile) in built.wall.tiles.enumerated() {
                let rect = built.layout.squads[index]?.parent ?? built.layout.tiles[index]
                let metrics = WallTileMetrics.tile(rect, unit: built.layout.unit)
                let kinds = built.scene.glyphs.filter { $0.x == metrics.glyphX && $0.y == metrics.glyphY }.map(\.kind)
                switch tile.state {
                case .working, .thinking: #expect(kinds.contains(.orb))
                case .needsYou: #expect(kinds.contains(.orb))
                case .retrying: #expect(kinds.contains(.dashes))
                case .quiet: #expect(kinds.contains(.flat))
                case .background: #expect(kinds.contains(.hollow))
                case .finished(.done): #expect(kinds.contains(.check))
                case .finished(.failed): #expect(kinds.contains(.cross))
                case .finished: #expect(kinds.contains(.square) || kinds.contains(.ring))
                case .away: #expect(kinds.contains(.hatched))
                }
                seen.formUnion(kinds.map(\.rawValue))
            }
        }
        #expect(seen.count >= 6)
    }

    @Test func theContextRingIsAnArcOfTheShare() throws {
        let built = build(demo("busy"))
        let tile = try #require(built.wall.tiles.first { $0.contextShare != nil })
        let index = try #require(built.wall.tiles.firstIndex(of: tile))
        let rect = built.layout.squads[index]?.parent ?? built.layout.tiles[index]
        let metrics = WallTileMetrics.tile(rect, unit: built.layout.unit)
        let arc = try #require(built.scene.glyphs.first { $0.kind == .arc && $0.x == metrics.glyphX && $0.y == metrics.glyphY })
        #expect(abs(arc.p3 - (tile.contextShare ?? 0)) < 1e-9 && arc.p1 == 0.455 && arc.p2 == 0.058)
    }

    @Test func aCalmWallDrawsTheBreathingOrbAboveCentre() throws {
        let built = build(demo("calm"))
        #expect(built.wall.tiles.isEmpty)
        let orb = try #require(built.scene.glyphs.first { $0.kind == .orb })
        #expect(orb.x == built.layout.centre.midX && orb.size == built.layout.centre.width)
        #expect(abs(orb.y - (built.layout.centre.midY - 2 * built.layout.unit)) < 1e-9)
        #expect(built.scene.plates.isEmpty && orb.ink == rose.quiet)
    }

    @Test func theHourIsATrackWithSpansHatchMarksAndANowLine() throws {
        var setup = Setup()
        setup.ribbon = WallRibbon(
            spans: [
                .init(from: 0.1, to: 0.3, phase: .working), .init(from: 0.3, to: 0.4, phase: .needsYou),
                .init(from: 0.8, to: 1, phase: .background),
            ], unseen: [0.5...0.6], marks: [.init(at: 0.7, outcome: .failed), .init(at: 1, outcome: .done)])
        let built = build(demo("busy"), setup)
        let rect = try #require(built.layout.ribbon)
        let track = WallRibbon.track(in: rect, unit: built.layout.unit, calm: false)
        let inRibbon = built.scene.bars.filter { track.inset(-built.layout.unit * 2).intersects($0.rect) }
        #expect(inRibbon.count == 1 + 3 + 2 + 2)
        #expect(inRibbon.contains { $0.ink == rose.failed } && inRibbon.contains { $0.ink == rose.finished })
        let hatch = try #require(built.scene.plates.first { $0.hatch && $0.rect.y == track.y })
        #expect(abs(hatch.rect.x - (track.x + 0.5 * track.width)) < 1e-9 && abs(hatch.rect.width - 0.1 * track.width) < 1e-9)
        var bare = Setup()
        bare.ribbon = nil
        #expect(build(demo("busy"), bare).scene.bars.count < built.scene.bars.count)
        var noHour = Setup()
        noHour.style.showsHour = false
        noHour.ribbon = setup.ribbon
        #expect(build(demo("busy"), noHour).scene.plates.allSatisfy { !$0.hatch })
    }
}

@Suite struct WallSceneEffectTests {
    private func firstTile(_ name: String = "busy") -> (tile: WallTile, wall: AgentWall) {
        let wall = demo(name)
        return (wall.tiles[0], wall)
    }

    @Test func noEffectMeansNothingAnimatesButTheFieldAndBreath() {
        #expect(!build(demo("busy")).scene.isAnimating)
        #expect(build(demo("busy")).scene.ripples.isEmpty)
    }

    @Test func aSparkIsADotAndPulsesTheGlass() throws {
        let (tile, wall) = firstTile()
        var setup = Setup()
        setup.style.field = .none
        setup.effects = [WallEffect(kind: .spark, tile: tile.id, start: 11.9, duration: 0.45, ink: .tile)]
        let sparked = build(wall, setup)
        let plain = build(wall, Setup(style: setup.style))
        #expect(sparked.scene.isAnimating && sparked.scene.dots.count == 1)
        let rect = sparked.layout.squads[0]?.parent ?? sparked.layout.tiles[0]
        let strip = WallTileMetrics.tile(rect, unit: sparked.layout.unit).beat
        let dot = try #require(sparked.scene.dots.first)
        #expect(dot.x >= strip.x && dot.x <= strip.maxX && dot.core == 0.25)
        #expect(dot.ink == rose.ink(for: tile.state))
        let glass = try #require(sparked.scene.plates.first { $0.rect == rect })
        let calm = try #require(plain.scene.plates.first { $0.rect == rect })
        #expect(glass.wash > calm.wash)
    }

    @Test func anExhaleRingsTheGlowsAndRipplesTheGround() throws {
        let (tile, wall) = firstTile()
        var setup = Setup()
        setup.style.field = .none
        setup.effects = [
            WallEffect(kind: .exhale, tile: tile.id, start: 11, duration: 1.8, ink: .finished),
            WallEffect(kind: .groundRipple, tile: tile.id, start: 11, duration: 2.2, ink: .finished),
        ]
        let built = build(wall, setup)
        let ring = try #require(built.scene.glows.first { $0.kind == .ring })
        #expect(ring.ink == rose.finished && ring.p1 > 0 && ring.extent > ring.p1)
        #expect(built.scene.glows.contains { $0.kind == .bloom })
        let ripple = try #require(built.scene.ripples.first)
        #expect(ripple.ink == rose.finished && ripple.alpha > 0)
    }

    @Test func rippleCountStopsAtTwelve() {
        let wall = demo("crowded")
        var setup = Setup()
        setup.effects = (0..<30).map {
            WallEffect(kind: .knock, tile: wall.tiles[$0 % wall.tiles.count].id, start: 11, duration: 2, ink: .needs, seed: UInt32($0))
        }
        #expect(build(wall, setup).scene.ripples.count == 12)
    }

    @Test func aDrainOverridesTheRingAndFallsToItsEnd() throws {
        let (tile, wall) = firstTile()
        var setup = Setup()
        func share(at t: Double) throws -> Double {
            var made = setup
            made.t = t
            made.effects = [WallEffect(kind: .drain, tile: tile.id, start: 10, duration: 2.6, ink: .tile, from: 0.9, to: 0.1)]
            let built = build(wall, made)
            let rect = built.layout.squads[0]?.parent ?? built.layout.tiles[0]
            let metrics = WallTileMetrics.tile(rect, unit: built.layout.unit)
            return try #require(built.scene.glyphs.first { $0.kind == .arc && $0.x == metrics.glyphX }).p3
        }
        setup.style.field = .none
        let start = try share(at: 10.01)
        let middle = try share(at: 11.3)
        let end = try share(at: 12.5)
        #expect(start > 0.85 && abs(middle - 0.5) < 0.01 && end < 0.2 && start > middle && middle > end)
    }

    @Test func aGatherFadesTheTileInAndAnUnknownTileIsIgnored() throws {
        let (tile, wall) = firstTile()
        var setup = Setup()
        setup.style.field = .none
        func opacity(at t: Double) throws -> Double {
            var made = setup
            made.t = t
            made.effects = [WallEffect(kind: .gather, tile: tile.id, start: 10, duration: 1.3, ink: .tile)]
            let built = build(wall, made)
            let rect = built.layout.squads[0]?.parent ?? built.layout.tiles[0]
            return try #require(built.scene.plates.first { $0.rect == rect }).opacity
        }
        let early = try opacity(at: 10.1)
        let late = try opacity(at: 11.2)
        #expect(early < 0.05 && late > 0.9 && early < late)
        setup.effects = [WallEffect(kind: .exhale, tile: "nobody", start: 11, duration: 2, ink: .finished)]
        let ghost = build(wall, setup).scene
        #expect(ghost.glows.isEmpty && ghost.ripples.isEmpty && ghost.isAnimating)
    }

    @Test func aWorkerThreadFadesItsPlateInAndRunsToItsSlot() throws {
        let wall = demo("squad")
        let index = try #require(wall.tiles.firstIndex { !$0.workers.isEmpty && $0.squad != nil })
        let worker = wall.tiles[index].workers[0]
        var setup = Setup()
        setup.style.field = .none
        setup.t = 10.1
        setup.effects = [
            WallEffect(kind: .thread, tile: wall.tiles[index].id, worker: worker.id, start: 10, duration: 1.1, ink: .working)
        ]
        let built = build(wall, setup)
        let slot = try #require(built.layout.squads[index]?.slots.first)
        let plate = try #require(built.scene.plates.first { $0.rect == slot })
        #expect(plate.opacity < 0.05)
        #expect(!built.scene.dots.isEmpty && built.scene.dots.allSatisfy { $0.ink == rose.working })
    }

    @Test func aHoldDrawsABloomAndAnArcWhoseProgressFills() throws {
        var setup = Setup()
        setup.hold = WallHold(tile: "x", x: 500, y: 300, progress: 0.5)
        let built = build(demo("attention"), setup)
        let arc = try #require(built.scene.glyphs.first { $0.kind == .arc && $0.x == 500 && $0.y == 300 })
        #expect(arc.p3 == 0.5 && arc.p4 == 0.25 && arc.ink == rose.needs && arc.size >= 56)
        #expect(built.scene.glows.contains { $0.kind == .bloom && $0.x == 500 })
        #expect(built.scene.isAnimating)
    }

    @Test func stillTurnsTheGestureIntoAGlow() throws {
        let (tile, wall) = firstTile()
        var setup = Setup()
        setup.style.still = true
        setup.style.field = .none
        setup.effects = [WallEffect(kind: .fade, tile: tile.id, start: 11.5, duration: 0.8, ink: .tile)]
        let built = build(wall, setup)
        #expect(built.scene.glows.count == 1 && built.scene.glows[0].kind == .bloom)
        #expect(built.scene.dots.isEmpty)
    }
}

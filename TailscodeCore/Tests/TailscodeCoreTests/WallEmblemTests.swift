import Foundation
import Testing

@testable import TailscodeCore

private let tile = WallRect(x: 100, y: 80, width: 520, height: 340)
private let text = WallInk(red: 0.9, green: 0.9, blue: 0.92)
private let dim = WallInk(red: 0.5, green: 0.5, blue: 0.55)

private func emblem(_ model: String, _ effort: String? = nil, providerID: String? = nil) -> WallEmblem? {
    WallEmblem(chip: ModelBadge.chip(model: model, effort: effort, providerID: providerID, catalog: []))
}

private func scene(
    _ state: WallState = .working, style: WallStyle = .studio, t: Double = 3, animated: Bool = true,
    night: Bool = false, in rect: WallRect = tile
) -> WallEmblemScene {
    WallEmblemScene(
        tile: rect, unit: 10, state: state, t: t, animated: animated, style: style, night: night, text: text,
        dim: dim)
}

private func dots(_ pieces: [WallEmblemPiece]) -> [(x: Double, y: Double, size: Double, alpha: Double)] {
    pieces.compactMap { piece in
        if case .dot(let x, let y, let size, let alpha) = piece.shape { return (x, y, size, alpha) }
        return nil
    }
}

@Suite struct WallEmblemTests {
    @Test func aMakerIsToldByItsShape() {
        #expect(emblem("claude-fable-5")?.form == .spark)
        #expect(emblem("claude-haiku-5")?.form == .spark)
        #expect(emblem("gpt-5.1-codex")?.form == .knot)
        #expect(emblem("gemini-3-pro")?.form == .star)
        #expect(emblem("grok-4-fast")?.form == .slash)
        #expect(emblem("llama-4-70b")?.form == .loop)
        #expect(emblem("mistral-large")?.form == .wind)
        #expect(emblem("deepseek-reasoner")?.form == .wave)
        #expect(emblem("qwen3-coder:30b")?.form == .swirl)
        #expect(emblem("hunyuan-turbo")?.form == .orbit)
        #expect(emblem("hunyuan-turbo")?.maker == nil)
        #expect(emblem("kimi-k2")?.satellites == 1)
    }

    @Test func aTileWithNoModelWearsNothing() {
        #expect(WallEmblem(chip: nil) == nil)
    }

    @Test func aModelRanksAmongItsMakers() {
        #expect(emblem("claude-haiku-5")?.rank == 0)
        #expect(emblem("claude-sonnet-5")?.rank == 1)
        #expect(emblem("claude-opus-5")?.rank == 2)
        #expect(emblem("claude-fable-5")?.rank == 3)
        #expect(emblem("gpt-5.1-codex-mini")?.rank == 0)
        #expect(emblem("gpt-5.1-codex")?.rank == 2)
        #expect(emblem("gemini-3-flash")?.rank == 0)
        #expect(emblem("qwen3:8b")?.rank == 0)
        #expect(emblem("qwen3-coder:30b")?.rank == 1)
        #expect(emblem("gpt-oss:120b")?.rank == 2)
        #expect(emblem("grok-4")?.rank == 1)
    }

    @Test func aHeavierModelDrawsMoreOfItsShape() {
        let light = WallEmblemShapes.pieces(for: emblem("claude-haiku-5")!, in: scene())
        let heavy = WallEmblemShapes.pieces(for: emblem("claude-fable-5")!, in: scene())
        #expect(heavy.count > light.count * 2)
        #expect(heavy.contains { if case .ring = $0.shape { return true } else { return false } })
    }

    @Test func theEffortLightsItsPips() {
        #expect(emblem("claude-opus-5", "low")?.litPips == 1)
        #expect(emblem("claude-opus-5", "medium")?.litPips == 2)
        #expect(emblem("claude-opus-5", "max")?.litPips == 5)
        #expect(emblem("claude-opus-5", "none")?.litPips == 0)
        #expect(emblem("claude-opus-5", Ultracode.effortLevel)?.litPips == 5)
        #expect(emblem("claude-opus-5", Ultracode.effortLevel)?.power == true)
        #expect(emblem("claude-opus-5")?.litPips == nil)
        #expect(emblem("claude-opus-5", "auto")?.litPips == nil)
    }

    @Test func aHotterEffortMovesFasterAndShedsEmbers() {
        let low = emblem("claude-opus-5", "low")!
        let max = emblem("claude-opus-5", "max")!
        #expect(max.pace > low.pace)
        var still = WallStyle.studio
        still.effects = .off
        let quiet = WallEmblemShapes.pieces(for: max, in: scene(style: still))
        let subtle = WallEmblemShapes.pieces(for: max, in: scene())
        let lively = WallEmblemShapes.pieces(for: max, in: scene(style: .showcase))
        #expect(subtle.count > quiet.count)
        #expect(lively.count > subtle.count)
        let cold = WallEmblemShapes.pieces(for: low, in: scene())
        let coldOff = WallEmblemShapes.pieces(for: low, in: scene(style: still))
        #expect(cold.count == coldOff.count)
    }

    @Test func theFigureHoldsStillWhenTheWallDoes() {
        let figure = emblem("gpt-5.1-codex", "high")!
        var off = WallStyle.studio
        off.effects = .off
        for held in [scene(style: off, t: 1), scene(t: 1, animated: false), scene(.quiet(since: .distantPast), t: 1)] {
            var later = held
            later.t = 40
            #expect(WallEmblemShapes.pieces(for: figure, in: held) == WallEmblemShapes.pieces(for: figure, in: later))
            #expect(!WallEmblemShapes.isLive(held))
        }
        var later = scene(t: 40)
        later.t = 40
        #expect(WallEmblemShapes.pieces(for: figure, in: scene(t: 1)) != WallEmblemShapes.pieces(for: figure, in: later))
    }

    @Test func theSwitchTakesTheFigureOff() {
        var style = WallStyle.studio
        style.showsEmblems = false
        #expect(WallEmblemShapes.pieces(for: emblem("claude-opus-5", "high")!, in: scene(style: style)).isEmpty)
        #expect(!WallStyle.nightDesk.showsEmblems)
        #expect(WallStyle.showcase.showsEmblems)
        #expect(WallStyle.decoded("{}").showsEmblems)
        #expect(!WallStyle.decoded(style.encoded()).showsEmblems)
    }

    @Test func nightAndASettledTileDimTheFigure() {
        let figure = emblem("claude-sonnet-5", "medium")!
        func brightest(_ scene: WallEmblemScene) -> Double {
            dots(WallEmblemShapes.pieces(for: figure, in: scene)).map(\.alpha).max() ?? 0
        }
        #expect(brightest(scene(night: true)) < brightest(scene()))
        #expect(brightest(scene(.finished(.done))) < brightest(scene()))
        #expect(brightest(scene(.needsYou(.fresh))) < brightest(scene()))
    }

    @Test func everyPieceStaysOnItsTile() {
        for form in ["claude-fable-5", "gpt-5.1-codex", "gemini-3-pro", "grok-4", "llama-4-70b",
            "mistral-large", "deepseek-reasoner", "qwen3-max", "kimi-k2", "hunyuan-turbo"]
        {
            for t in stride(from: 0.0, to: 30, by: 1.7) {
                let figure = emblem(form, Ultracode.effortLevel)!
                let pieces = WallEmblemShapes.pieces(for: figure, in: scene(style: .showcase, t: t))
                #expect(!pieces.isEmpty)
                for dot in dots(pieces) {
                    #expect(dot.x > tile.x && dot.x < tile.maxX && dot.y > tile.y && dot.y < tile.maxY)
                    #expect(dot.alpha > 0 && dot.alpha <= 1 && dot.size >= 1.8)
                }
                #expect(pieces.count < 260)
            }
        }
    }

    @Test func aTileTooSmallWearsNoFigure() {
        let small = WallRect(x: 0, y: 0, width: 70, height: 40)
        #expect(WallEmblemShapes.place(in: small, unit: 6) == nil)
        #expect(WallEmblemShapes.pieces(for: emblem("claude-opus-5")!, in: scene(in: small)).isEmpty)
    }

    @Test func theSameModelLooksTheSameEverywhere() {
        let one = WallEmblemShapes.pieces(for: emblem("qwen3-coder:30b", "think")!, in: scene(t: 7))
        let two = WallEmblemShapes.pieces(for: emblem("qwen3-coder:30b", "think")!, in: scene(t: 7))
        #expect(one == two)
        #expect(emblem("hunyuan-turbo")?.seed != emblem("ernie-5")?.seed)
    }

    @Test func theSceneCarriesTheFigureAndTheSwitchDropsIt() {
        let wall = AgentDemo.wallScenes(now: Date(timeIntervalSince1970: 1_800_000_000)).first { $0.name == "busy" }!.wall
        #expect(Set(wall.tiles.compactMap { $0.emblem?.form }).count >= 2)
        func dotCount(_ style: WallStyle) -> Int {
            var style = style
            style.field = .none
            let reading = WallLayout.reading(width: 1920, height: 1080, safe: .zero, fold: nil, style: style)
            let read = wall.reflowed(aspect: reading.aspect, gridAspect: reading.gridAspect, pages: reading.pages)
            let layout = WallLayout.make(width: 1920, height: 1080, safe: .zero, fold: nil, wall: read, style: style)
            return WallScene.build(
                WallSceneInput(
                    wall: read, layout: layout, palette: .current(theme: .rosePine), style: style, t: 5,
                    now: Date(timeIntervalSince1970: 1_800_000_000),
                    motes: WallMotes(width: 1920, height: 1080, seed: 7))
            ).dots.count
        }
        var off = WallStyle.studio
        off.showsEmblems = false
        #expect(dotCount(.studio) > 60)
        #expect(dotCount(off) == 0)
    }
}

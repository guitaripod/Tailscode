#if os(macOS)
import Foundation
import TailscodeCore

/// Everything a still of one demo wall on one screen needs, staged the way a client stages a frame.
struct Staged {
    let wall: AgentWall
    let layout: WallLayout
    let scene: WallScene
}

enum Staging {
    static let time: TimeInterval = 12.3
    static let scale = 2.0

    static func stage(_ source: AgentWall, screen: Screen, theme: AppTheme, now: Date) -> Staged {
        let style = WallStyle.studio
        let reading = WallLayout.reading(
            width: screen.width, height: screen.height, safe: screen.safe, fold: screen.fold, style: style)
        let wall = source.reflowed(
            aspect: reading.aspect, gridAspect: reading.gridAspect, pages: reading.pages)
        let layout = WallLayout.make(
            width: screen.width, height: screen.height, safe: screen.safe, fold: screen.fold, wall: wall,
            style: style)
        var motes = WallMotes(width: screen.width, height: screen.height, seed: 1_234_567)
        for _ in 0..<200 {
            motes.step(
                dt: 0.05, mood: wall.mood, target: nil, slow: 1, aspect: screen.width / screen.height)
        }
        let input = WallSceneInput(
            wall: wall, layout: layout, palette: WallPalette.current(theme: theme), style: style, t: time,
            now: now, effects: effects(for: wall, style: style), motes: motes, ribbon: ribbon,
            hold: nil, dim: 0, peeking: false, animated: true, beatSlide: 0.4)
        return Staged(wall: wall, layout: layout, scene: WallScene.build(input))
    }

    private static func effects(for wall: AgentWall, style: WallStyle) -> [WallEffect] {
        guard !wall.tiles.isEmpty else { return [] }
        var queue = WallEffectQueue()
        let ids = wall.tiles.map(\.id)
        func tile(_ index: Int) -> String { ids[index % ids.count] }
        let host = wall.tiles.first { !$0.workers.isEmpty } ?? wall.tiles[0]
        let worker = host.workers.first?.id
        let plan: [(Double, WallEvent)] = [
            (0.35, WallEvent(kind: .asked, tile: tile(0))),
            (0.6, WallEvent(kind: .finished, tile: tile(1))),
            (0.5, WallEvent(kind: .failed, tile: tile(ids.count - 1))),
            (0.5, WallEvent(kind: .workerStarted, tile: host.id, worker: worker)),
            (0.7, WallEvent(kind: .workerEnded, tile: host.id, worker: worker)),
            (0.2, WallEvent(kind: .step, tile: tile(2))),
            (0.4, WallEvent(kind: .retried, tile: tile(3))),
            (1.05, WallEvent(kind: .joined, tile: tile(4))),
            (0.4, WallEvent(kind: .left, tile: tile(5))),
            (1.2, WallEvent(kind: .compacted, tile: tile(2))),
        ]
        let contexts = Dictionary(ids.map { ($0, (from: 0.8, to: 0.3)) }, uniquingKeysWith: { first, _ in first })
        for (ago, event) in plan {
            queue.add([event], at: time - ago, style: style, contexts: contexts)
        }
        return queue.live
    }

    static let ribbon = WallRibbon(
        spans: [
            .init(from: 0.05, to: 0.22, phase: .working), .init(from: 0.3, to: 0.34, phase: .needsYou),
            .init(from: 0.34, to: 0.6, phase: .working), .init(from: 0.62, to: 0.7, phase: .background),
            .init(from: 0.78, to: 0.96, phase: .working),
        ],
        unseen: [0.36...0.44],
        marks: [.init(at: 0.22, outcome: .done), .init(at: 0.6, outcome: .failed), .init(at: 0.96, outcome: .done)])
}
#endif

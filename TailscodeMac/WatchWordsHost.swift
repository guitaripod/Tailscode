import AppKit
import TailscodeCore

/// Every word on the wall, in one view the size of the wall: the tiles' and workers' views placed by
/// frame from Core's layout, the bands, the rails and their chips. It is told what to say and where
/// (`prepare`), puts each word there (`begin`), and glides what is already shown to its new place
/// while the renderer morphs the glass beneath it (`glide`); a size is the new one at once, so a
/// tile's words are measured once for the size they will have and never while they move.
@MainActor
final class WatchWordsHost: WatchPassView {
    let bands = WatchBandWords()
    let rails = WatchRailWords()
    private(set) var tiles: [String: WatchTileWordsView] = [:]
    private(set) var workers: [String: WatchWorkerWordsView] = [:]
    private(set) var crowds: [String: WatchWorkerWordsView] = [:]
    private var registry: [String: NSView] = [:]
    private var starts: [String: CGPoint] = [:]
    private(set) var targets: [String: CGRect] = [:]
    var actions: AgentsActions?
    var onHoldBegan: ((WatchTileWordsView, NSEvent) -> Void)?
    var onHoldEnded: ((WatchTileWordsView, Bool) -> Void)?
    var onDeny: ((String) -> Void)?
    var onChat: ((String) -> Void)?
    var onOpenChat: ((String) -> Void)?
    var onWatch: ((String) -> Void)?

    init() {
        super.init(frame: .zero)
        for (key, label) in bands.labels { register(key, label) }
        register("title.recent", rails.recentTitle)
        register("title.listed", rails.listedTitle)
        for (index, chip) in rails.recentChips.enumerated() {
            register("chip.recent.\(index)", chip)
            chip.onPress = { [weak self] chip in self?.onOpenChat?(chip.id) }
        }
        for (index, chip) in rails.listedChips.enumerated() {
            register("chip.listed.\(index)", chip)
            chip.onPress = { [weak self] chip in self?.onWatch?(chip.id) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func register(_ key: String, _ view: NSView) {
        registry[key] = view
        view.isHidden = true
        addSubview(view)
    }

    func tileView(_ id: String) -> WatchTileWordsView? { tiles[id] }

    func prepare(
        wall: AgentWall, layout: WallLayout, face: WatchFace, now: Date,
        presses: [String: WatchTileWordsView.Press]
    ) -> [String: CGRect] {
        var frames = bands.apply(wall, layout: layout, face: face, now: now)
        frames.merge(rails.apply(wall, layout: layout, face: face, now: now)) { _, new in new }
        var seen = Set<String>()
        var seenWorkers = Set<String>()
        var seenCrowds = Set<String>()
        for (index, tile) in wall.tiles.enumerated() where index < layout.tiles.count {
            let squad = index < layout.squads.count ? layout.squads[index] : nil
            let rect = (squad?.parent ?? layout.tiles[index]).watchFrame
            let view = tiles[tile.id] ?? makeTile(tile.id)
            frames["tile:" + tile.id] = rect
            view.resize(to: rect.size)
            let phase = tile.ask.map { actions?.phase(for: tile.id, askID: $0.id) ?? .idle } ?? .idle
            view.apply(tile, face: face, now: now, phase: phase)
            view.press = presses[tile.id] ?? .rest
            seen.insert(tile.id)
            guard let squad else { continue }
            for (slot, slotRect) in squad.slots.enumerated() where slot < tile.workers.count {
                let worker = tile.workers[slot]
                let workerView = workers[worker.id] ?? makeWorker(worker.id)
                frames["worker:" + worker.id] = slotRect.watchFrame
                workerView.resize(to: slotRect.watchFrame.size)
                workerView.apply(worker, parent: tile.id, face: face, now: now)
                seenWorkers.insert(worker.id)
            }
            if let more = squad.more, let hidden = tile.squad?.hidden, hidden > 0 {
                let crowd = crowds[tile.id] ?? makeCrowd(tile.id)
                frames["crowd:" + tile.id] = more.watchFrame
                crowd.resize(to: more.watchFrame.size)
                crowd.apply(
                    more: hidden, needsEyes: tile.squad?.moreNeedsEyes ?? false, parent: tile.id, face: face)
                seenCrowds.insert(tile.id)
            }
        }
        drop(&tiles, keeping: seen, prefix: "tile:")
        drop(&workers, keeping: seenWorkers, prefix: "worker:")
        drop(&crowds, keeping: seenCrowds, prefix: "crowd:")
        return frames
    }

    private func drop<View: NSView>(_ pool: inout [String: View], keeping seen: Set<String>, prefix: String) {
        for (key, view) in pool where !seen.contains(key) {
            view.removeFromSuperview()
            registry[prefix + key] = nil
            pool[key] = nil
        }
    }

    private func makeTile(_ id: String) -> WatchTileWordsView {
        let view = WatchTileWordsView(face: lastFace)
        view.onHoldBegan = { [weak self] view, event in self?.onHoldBegan?(view, event) }
        view.onHoldEnded = { [weak self] view, inside in self?.onHoldEnded?(view, inside) }
        view.onDeny = { [weak self] view in self?.onDeny?(view.key) }
        view.onChat = { [weak self] view in self?.onChat?(view.key) }
        tiles[id] = view
        registry["tile:" + id] = view
        view.isHidden = true
        addSubview(view)
        return view
    }

    private func makeWorker(_ id: String) -> WatchWorkerWordsView {
        let view = WatchWorkerWordsView(face: lastFace)
        workers[id] = view
        registry["worker:" + id] = view
        view.isHidden = true
        addSubview(view)
        return view
    }

    private func makeCrowd(_ id: String) -> WatchWorkerWordsView {
        let view = WatchWorkerWordsView(face: lastFace)
        crowds[id] = view
        registry["crowd:" + id] = view
        view.isHidden = true
        addSubview(view)
        return view
    }

    var lastFace = WatchFace(palette: WallPalette.current(theme: ThemeSelection.theme), type: WatchType(unit: 10), style: .studio)

    /// Puts every word at its target, at once, or at the place it stood when it is to glide there.
    func begin(_ frames: [String: CGRect], gliding: Bool) {
        starts = [:]
        targets = frames
        for (key, view) in registry {
            guard let target = frames[key] else {
                view.isHidden = true
                continue
            }
            let shown = !view.isHidden
            var origin = target.origin
            if gliding, shown {
                starts[key] = view.frame.origin
                origin = view.frame.origin
            }
            view.isHidden = false
            view.frame = CGRect(origin: origin, size: target.size)
        }
    }

    /// Moves the words that are gliding `progress` of the way, `0...1`, from where they stood.
    func glide(_ progress: Double) {
        let p = CGFloat(min(1, max(0, progress)))
        for (key, start) in starts {
            guard let target = targets[key], let view = registry[key] else { continue }
            view.setFrameOrigin(
                CGPoint(x: start.x + (target.minX - start.x) * p, y: start.y + (target.minY - start.y) * p))
        }
    }

    func settle() {
        starts = [:]
        for (key, target) in targets { registry[key]?.frame = target }
    }

    var isGliding: Bool { !starts.isEmpty }
}

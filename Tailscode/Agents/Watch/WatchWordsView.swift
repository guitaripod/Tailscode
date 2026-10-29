import TailscodeCore
import UIKit

/// What a finger or a pointer can be on, in the wall's own coordinates.
enum WatchTarget: Equatable {
    case tile(String)
    case worker(String)
    case pill(String, WatchTileView.Pill)
    case chip(WatchChipView.Kind)
}

/// The layer of words above the ground: the chrome, a view for every tile, and a small one for every
/// sub-agent. Frames are set from Core's layout in one pass whenever the wall or the screen changes,
/// never by constraints; when a turn of the screen moves the tiles, each tile's words travel from
/// where they were to where they are on a spring while the ground morphs under them.
@MainActor
final class WatchWordsView: UIView, UIPointerInteractionDelegate {
    struct Handlers {
        var peek: (String) -> Void = { _ in }
        var approve: (String) -> Void = { _ in }
        var deny: (String) -> Void = { _ in }
        var chat: (String) -> Void = { _ in }
    }

    static let springLasts: TimeInterval = 0.6

    let chrome = WatchChromeView()
    var handlers = Handlers()

    private var tiles: [String: WatchTileView] = [:]
    private var workers: [String: WatchWorkerView] = [:]
    private var order: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        addSubview(chrome)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ context: WatchWordsContext, animated: Bool) {
        let wall = context.wall
        let layout = context.layout
        var live = Set<String>()
        var liveWorkers = Set<String>()
        var created = Set<String>()
        var ordered: [String] = []
        let pass = { [self] in
            chrome.frame = bounds
            chrome.apply(context)
            for (index, tile) in wall.tiles.enumerated() where index < layout.tiles.count {
                live.insert(tile.id)
                ordered.append(tile.id)
                let squad = index < layout.squads.count ? layout.squads[index] : nil
                let main = squad?.parent ?? layout.tiles[index]
                let view = tileView(for: tile.id, created: &created)
                view.frame = main.cgRect.rounded()
                view.apply(tile, main: main, context: context, action: context.actions[tile.id])
                guard let squad else { continue }
                layoutWorkers(of: tile, squad: squad, parent: view, context: context, live: &liveWorkers, created: &created)
            }
        }
        if animated {
            UIView.animate(
                withDuration: Self.springLasts, delay: 0, usingSpringWithDamping: 0.9,
                initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]
            ) { pass() }
        } else {
            pass()
        }
        retire(tiles: live, workers: liveWorkers)
        order = ordered
        for key in created {
            let target: CGFloat
            let view: UIView?
            if let tile = tiles[key] {
                view = tile
                target = tile.tile.map(WatchTileView.opacity(of:)) ?? 1
            } else {
                view = workers[key]
                target = 1
            }
            view?.alpha = 0
            UIView.animate(withDuration: 0.4, delay: 0.1) { view?.alpha = target }
        }
        refreshAccessibility(wall)
    }

    func tick(_ context: WatchWordsContext) {
        chrome.tick(context)
        for tile in context.wall.tiles {
            tiles[tile.id]?.tick(now: context.now, context: context, action: context.actions[tile.id])
        }
        for (index, tile) in context.wall.tiles.enumerated() where index < context.layout.squads.count {
            guard let squad = context.layout.squads[index] else { continue }
            for (slot, worker) in tile.workers.enumerated() where slot < squad.slots.count {
                workers[workerKey(tile.id, worker.id)]?.apply(
                    worker, rect: squad.slots[slot], parentOpacity: tiles[tile.id]?.alpha ?? 1,
                    context: context)
            }
        }
    }

    private static let divider = "\u{1F}"

    private func workerKey(_ tile: String, _ worker: String) -> String { tile + Self.divider + worker }

    private func tileView(for id: String, created: inout Set<String>) -> WatchTileView {
        if let view = tiles[id] { return view }
        let view = WatchTileView()
        view.onPeek = { [weak self] in self?.handlers.peek(id) }
        view.onApprove = { [weak self] in self?.handlers.approve(id) }
        view.onDeny = { [weak self] in self?.handlers.deny(id) }
        view.onChat = { [weak self] in self?.handlers.chat(id) }
        view.addInteraction(UIPointerInteraction(delegate: self))
        tiles[id] = view
        addSubview(view)
        created.insert(id)
        return view
    }

    private func layoutWorkers(
        of tile: WallTile, squad: WallSquadRects, parent: WatchTileView, context: WatchWordsContext,
        live: inout Set<String>, created: inout Set<String>
    ) {
        let opacity = parent.alpha
        for (slot, worker) in tile.workers.enumerated() where slot < squad.slots.count {
            let key = workerKey(tile.id, worker.id)
            live.insert(key)
            let view = workerView(for: key, created: &created)
            view.frame = squad.slots[slot].cgRect.rounded()
            view.apply(worker, rect: squad.slots[slot], parentOpacity: opacity, context: context)
        }
        if let more = squad.more {
            let key = workerKey(tile.id, "+")
            live.insert(key)
            let view = workerView(for: key, created: &created)
            view.frame = more.cgRect.rounded()
            view.apply(
                more: tile.squad?.hidden ?? 0, needsEyes: tile.squad?.moreNeedsEyes ?? false, rect: more,
                parentOpacity: opacity, context: context)
        }
    }

    private func workerView(for key: String, created: inout Set<String>) -> WatchWorkerView {
        if let view = workers[key] { return view }
        let view = WatchWorkerView()
        workers[key] = view
        addSubview(view)
        created.insert(key)
        return view
    }

    private func retire(tiles live: Set<String>, workers liveWorkers: Set<String>) {
        for (id, view) in tiles where !live.contains(id) {
            tiles[id] = nil
            UIView.animate(withDuration: 0.25, animations: { view.alpha = 0 }) { _ in view.removeFromSuperview() }
        }
        for (key, view) in workers where !liveWorkers.contains(key) {
            workers[key] = nil
            UIView.animate(withDuration: 0.25, animations: { view.alpha = 0 }) { _ in view.removeFromSuperview() }
        }
    }

    private func refreshAccessibility(_ wall: AgentWall) {
        var elements: [Any] = [chrome.headline, chrome.watch]
        for id in order {
            if let view = tiles[id] { elements.append(view) }
            for key in workers.keys.sorted() where key.hasPrefix(id + Self.divider) {
                if let view = workers[key] { elements.append(view) }
            }
        }
        if !chrome.calm.isHidden { elements.append(chrome.calm) }
        for label in [chrome.headline, chrome.watch, chrome.calm] { label.isAccessibilityElement = true }
        accessibilityElements = elements
    }

    func tileView(_ id: String) -> WatchTileView? { tiles[id] }

    func frame(ofTile id: String) -> CGRect? { tiles[id]?.frame }

    /// What a point is on: a tile's button, a tile, a sub-agent, a chip in a rail, or nothing.
    func target(at point: CGPoint) -> WatchTarget? {
        for id in order {
            guard let view = tiles[id], view.frame.insetBy(dx: -6, dy: -6).contains(point) else { continue }
            if let pill = view.pill(at: point) { return .pill(id, pill) }
        }
        for (key, view) in workers where view.frame.contains(point) {
            return .worker(key.components(separatedBy: Self.divider).first ?? "")
        }
        for id in order {
            if let view = tiles[id], view.frame.contains(point) { return .tile(id) }
        }
        for target in chrome.rails.targets where target.frame.insetBy(dx: -4, dy: -4).contains(point) {
            return .chip(target.kind)
        }
        return nil
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction, styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        guard let view = interaction.view as? WatchTileView else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: 14)
        return UIPointerStyle(effect: .lift(UITargetedPreview(view: view, parameters: parameters)))
    }
}

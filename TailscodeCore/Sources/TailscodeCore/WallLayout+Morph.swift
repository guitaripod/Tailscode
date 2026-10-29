import Foundation

extension WallRect {
    /// The rectangle `progress` of the way from `self` to `other`.
    public func lerp(to other: WallRect, _ progress: Double) -> WallRect {
        let p = min(1, max(0, progress))
        return WallRect(
            x: x + (other.x - x) * p, y: y + (other.y - y) * p,
            width: width + (other.width - width) * p, height: height + (other.height - height) * p)
    }
}

extension WallLayout {
    /// This layout as it stands `progress` of the way from `old`, for a turn, a fold or a resize: each
    /// tile glides from where the same tile stood (matched by id, so a tile keeps its identity) and a
    /// tile that was not there grows from its own centre; the chrome glides with it.
    public func morphed(
        from old: WallLayout, oldIDs: [String], newIDs: [String], progress: Double
    ) -> WallLayout {
        let p = min(1, max(0, progress))
        guard p < 1 else { return self }
        var next = self
        var before: [String: Int] = [:]
        for (index, id) in oldIDs.enumerated() where index < old.tiles.count { before[id] = index }
        for (index, id) in newIDs.enumerated() where index < tiles.count {
            let target = tiles[index]
            let start: WallRect
            if let was = before[id] {
                start = old.tiles[was]
            } else {
                start = WallRect(x: target.midX, y: target.midY, width: 0, height: 0)
            }
            next.tiles[index] = start.lerp(to: target, p)
            guard index < squads.count, let squad = squads[index] else { continue }
            let from = start
            let scaleX = target.width > 0 ? from.width / target.width : 0
            let scaleY = target.height > 0 ? from.height / target.height : 0
            func place(_ rect: WallRect) -> WallRect {
                let origin = WallRect(
                    x: from.x + (rect.x - target.x) * scaleX, y: from.y + (rect.y - target.y) * scaleY,
                    width: rect.width * scaleX, height: rect.height * scaleY)
                return origin.lerp(to: rect, p)
            }
            next.squads[index] = WallSquadRects(
                parent: place(squad.parent), slots: squad.slots.map(place), more: squad.more.map(place))
        }
        next.headline = old.headline.lerp(to: headline, p)
        next.watchLine = old.watchLine.lerp(to: watchLine, p)
        next.clock = old.clock.lerp(to: clock, p)
        next.date = old.date.lerp(to: date, p)
        next.grid = old.grid.lerp(to: grid, p)
        next.centre = old.centre.lerp(to: centre, p)
        if let ribbon, let was = old.ribbon { next.ribbon = was.lerp(to: ribbon, p) }
        if let rail = recentRail, let was = old.recentRail { next.recentRail = was.lerp(to: rail, p) }
        if let rail = listedRail, let was = old.listedRail { next.listedRail = was.lerp(to: rail, p) }
        return next
    }
}

import Foundation

extension SplitLayout {
    /// The main slot: the first pane of the root's first side. A lone pane has no main slot,
    /// because there is nothing to promote over.
    public var masterPane: PaneID? {
        guard case .split(_, _, _, let first, _) = root else { return nil }
        return Self.leaves(of: first).first
    }

    /// Exchanges two panes wherever they sit in the tree. Ids travel with their panes, so focus
    /// and history follow the pane rather than the slot; like `exchange`, it unzooms.
    @discardableResult
    public mutating func swap(_ a: PaneID, _ b: PaneID) -> Bool {
        guard a != b, contains(a), contains(b) else { return false }
        root = Self.relabeling(root) { $0 == a ? b : $0 == b ? a : $0 }
        zoomedPane = nil
        return true
    }

    /// Puts `pane` in the main slot by swapping it with the pane there. Promoting the pane that
    /// is already main swaps it with the first pane of the other side and follows the new main,
    /// so the same key toggles the two panes a person is working between.
    @discardableResult
    public mutating func promote(_ pane: PaneID) -> Bool {
        guard contains(pane), case .split(_, _, _, let first, let second) = root,
            let master = Self.leaves(of: first).first
        else { return false }
        guard pane == master else { return swap(pane, master) }
        guard let next = Self.leaves(of: second).first, swap(pane, next) else { return false }
        focus(next)
        return true
    }

    /// Moves every pane one slot along the reading order — forward sends the last pane to the
    /// first slot — while the tree keeps its shape and its ratios.
    @discardableResult
    public mutating func rotate(forward: Bool) -> Bool {
        let ids = paneIDs
        guard ids.count > 1 else { return false }
        let rotated = forward ? [ids[ids.count - 1]] + ids.dropLast() : Array(ids.dropFirst()) + [ids[0]]
        var index = 0
        root = Self.relabeling(root) { _ in
            defer { index += 1 }
            return rotated[index]
        }
        zoomedPane = nil
        return true
    }

    /// Takes `pane` out of where it is and splits `target` on `edge`, giving `pane` that side —
    /// what dragging one pane's strip onto another pane does.
    @discardableResult
    public mutating func move(_ pane: PaneID, onto target: PaneID, edge: PaneDropEdge) -> Bool {
        guard pane != target, contains(pane), contains(target),
            let pruned = Self.removing(pane, from: root)
        else { return false }
        root = Self.replacingLeaf(target, in: pruned) {
            .split(
                id: SplitID(), axis: edge.axis, ratio: 0.5,
                first: .pane(edge.placesArrivalFirst ? pane : target),
                second: .pane(edge.placesArrivalFirst ? target : pane))
        }
        zoomedPane = nil
        focus(pane)
        return true
    }

    /// Takes `pane` out and gives it the whole far edge of the window, vim's `ctrl+w H/J/K/L`.
    /// It takes one pane's fair share of that axis, the rest keeping theirs.
    @discardableResult
    public mutating func moveToEdge(_ pane: PaneID, edge: SplitDirection) -> Bool {
        guard contains(pane), paneCount > 1, let rest = Self.removing(pane, from: root) else {
            return false
        }
        let axis: SplitAxis = edge == .left || edge == .right ? .horizontal : .vertical
        let leading = edge == .left || edge == .up
        let share = 1 / (1 + Self.span(of: rest, along: axis))
        root = .split(
            id: SplitID(), axis: axis, ratio: leading ? share : 1 - share,
            first: leading ? .pane(pane) : rest, second: leading ? rest : .pane(pane))
        zoomedPane = nil
        focus(pane)
        return true
    }

    /// Rebuilds the tree as `arrangement` with the panes in `order` — the ones named there first,
    /// then the rest in reading order — keeping every id, the focus, the zoom and the history.
    /// An arrangement is a shape, not a mode: the tree stays freely editable afterwards.
    @discardableResult
    public mutating func arrange(_ arrangement: SplitArrangement, order: [PaneID] = []) -> Bool {
        var ids: [PaneID] = []
        for id in order + paneIDs where contains(id) && !ids.contains(id) { ids.append(id) }
        guard let built = SplitEven.arrange(ids: ids, as: arrangement) else { return false }
        root = built.root
        return true
    }

    /// Focus the next pane in reading order (the previous one backwards), wrapping. A placement
    /// that hid panes for want of room keeps them out of the cycle; a zoom does not, and moving
    /// on from a zoomed pane shows the arrangement again, as a directional move does.
    @discardableResult
    public mutating func cycleFocus(forward: Bool, skipping placement: PanePlacement? = nil)
        -> PaneID?
    {
        var candidates = paneIDs
        if let placement, placement.hiddenReason == .noRoom {
            candidates.removeAll { placement.hidden.contains($0) && $0 != focusedPane }
        }
        guard candidates.count > 1 else { return nil }
        let index = candidates.firstIndex(of: focusedPane) ?? 0
        let next = candidates[(index + (forward ? 1 : candidates.count - 1)) % candidates.count]
        zoomedPane = nil
        focus(next)
        return next
    }

    /// Applies a pane dropped on a pane: the middle swaps the two, an edge moves the dragged pane
    /// to that side of the target.
    @discardableResult
    public mutating func apply(_ intent: PaneMoveIntent) -> Bool {
        switch intent {
        case .swap(let a, let b): return swap(a, b)
        case .move(let pane, let target, let edge): return move(pane, onto: target, edge: edge)
        }
    }

    static func relabeling(_ node: SplitNode, _ transform: (PaneID) -> PaneID) -> SplitNode {
        switch node {
        case .pane(let id):
            return .pane(transform(id))
        case .split(let id, let axis, let ratio, let first, let second):
            let head = relabeling(first, transform)
            let tail = relabeling(second, transform)
            return .split(id: id, axis: axis, ratio: ratio, first: head, second: tail)
        }
    }
}

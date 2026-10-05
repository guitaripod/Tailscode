import Foundation

/// A container's size in logical points.
public struct SplitSize: Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Why a pane is in the layout but not on screen.
public enum HiddenReason: String, Sendable, Equatable {
    /// The window is too small for every pane at its minimum, so the least recently focused
    /// panes step aside until the rest fit.
    case noRoom
    /// One pane borrowed the whole window.
    case zoomed
}

/// One divider as drawn: the seam it paints, the band a pointer can grab, the rectangle it
/// divides, and where along that rectangle it sits and may travel. `position`, `lowest` and
/// `highest` are the first side's extent, measured from the parent's leading edge along `axis`.
public struct DividerPlacement: Sendable, Equatable {
    public var id: SplitID
    public var axis: SplitAxis
    public var line: SplitRect
    public var hit: SplitRect
    public var parent: SplitRect
    public var position: Double
    public var lowest: Double
    public var highest: Double

    public init(
        id: SplitID, axis: SplitAxis, line: SplitRect, hit: SplitRect, parent: SplitRect,
        position: Double, lowest: Double, highest: Double
    ) {
        self.id = id
        self.axis = axis
        self.line = line
        self.hit = hit
        self.parent = parent
        self.position = position
        self.lowest = lowest
        self.highest = highest
    }
}

/// Where every pane and divider goes in a container of one size: the only geometry a host
/// draws from. Rects are in the container's logical points with the origin top-left.
public struct PanePlacement: Sendable, Equatable {
    public var frames: [PaneID: SplitRect]
    public var dividers: [DividerPlacement]
    /// Panes in the tree that are not placed, in reading order.
    public var hidden: [PaneID]
    public var hiddenReason: HiddenReason?
    /// Whether the overflow strip is shown, which is exactly when something is hidden.
    public var stripNeeded: Bool
    /// The area the placed panes and their seams tile: the container less the strip.
    public var bounds: SplitRect
    /// Where the strip goes when it is needed, along the container's bottom edge.
    public var strip: SplitRect?

    public init(
        frames: [PaneID: SplitRect], dividers: [DividerPlacement], hidden: [PaneID],
        hiddenReason: HiddenReason?, stripNeeded: Bool, bounds: SplitRect, strip: SplitRect?
    ) {
        self.frames = frames
        self.dividers = dividers
        self.hidden = hidden
        self.hiddenReason = hiddenReason
        self.stripNeeded = stripNeeded
        self.bounds = bounds
        self.strip = strip
    }

    public func divider(_ id: SplitID) -> DividerPlacement? {
        dividers.first { $0.id == id }
    }

    public func isPlaced(_ pane: PaneID) -> Bool {
        frames[pane] != nil
    }
}

extension SplitLayout {
    /// The tree laid out in a container of `size`. Pure: the same tree and size always give the
    /// same rects, and no ratio in the tree is ever written by a solve — a clamped or hidden
    /// presentation is a presentation, and growing the window brings back exactly what was there.
    ///
    /// Every split cuts at its ratio, clamped so both sides keep their minimum, snapped to the
    /// device pixel (`scale` 1 for GTK's integer allocations, the backing scale on the Mac), and
    /// the second side takes the exact remainder, so the rects and the one-point seams between
    /// them tile the container with no gap. A tree that cannot fit hides its least recently
    /// focused panes until it does, never the focused one; a zoom hides every other pane. Either
    /// way the strip that names the hidden panes takes `stripHeight` off the bottom, and the
    /// solve runs once more at the reduced height.
    ///
    /// - Parameter minimum: what each pane needs, already combined with anything the host knows
    ///   about the slot; the default treats every pane as a chat, which can always become a glance.
    public func placement(
        in size: SplitSize, scale: Double = 1, stripHeight: Double = PaneSizing.stripHeight,
        minimum: (PaneID) -> PaneMinimum = { _ in PaneSizing.chatGlance }
    ) -> PanePlacement {
        let width = size.width.isFinite ? max(0, size.width) : 0
        let height = size.height.isFinite ? max(0, size.height) : 0
        var minimums: [PaneID: PaneMinimum] = [:]
        for id in paneIDs { minimums[id] = minimum(id) }
        let whole = solvePlacement(
            in: SplitRect(x: 0, y: 0, width: width, height: height), scale: scale,
            minimums: minimums)
        guard !whole.hidden.isEmpty else { return whole }
        let strip = min(height, max(0, stripHeight.isFinite ? stripHeight : 0))
        var reduced = solvePlacement(
            in: SplitRect(x: 0, y: 0, width: width, height: height - strip), scale: scale,
            minimums: minimums)
        reduced.stripNeeded = true
        reduced.strip = SplitRect(x: 0, y: height - strip, width: width, height: strip)
        return reduced
    }

    /// Moves a divider to put its first side at `coordinate` points from the parent's leading
    /// edge, clamped so neither side drops below its minimum. The clamp lives here so both
    /// toolkits drag identically and no gesture can squeeze a pane smaller than it may be.
    /// Dragging twice to the same point is the same as dragging once.
    @discardableResult
    public mutating func drag(
        _ split: SplitID, to coordinate: Double, in placement: PanePlacement
    ) -> Bool {
        guard coordinate.isFinite, let divider = placement.divider(split) else { return false }
        let available = divider.parent.extent(along: divider.axis) - PaneSizing.gutter
        guard available > 0 else { return false }
        let clamped = min(max(coordinate, divider.lowest), divider.highest)
        setRatio(clamped / available, of: split)
        return true
    }

    /// Moves the divider on `pane`'s edge that faces `direction` by `points` that way. A pane
    /// already against the window on that side moves its opposite divider instead, the same way,
    /// which narrows it — the edge that can move is the one that moves.
    @discardableResult
    public mutating func nudge(
        _ pane: PaneID, toward direction: SplitDirection, by points: Double,
        in placement: PanePlacement
    ) -> Bool {
        let axis: SplitAxis = direction == .left || direction == .right ? .horizontal : .vertical
        let trailing = direction == .right || direction == .down
        let candidates = Self.ancestors(of: pane, in: root).filter {
            $0.axis == axis && placement.divider($0.id) != nil
        }
        guard let chosen = candidates.first(where: { $0.paneInFirst == trailing }) ?? candidates.first,
            let divider = placement.divider(chosen.id)
        else { return false }
        return drag(chosen.id, to: divider.position + (trailing ? points : -points), in: placement)
    }

    /// Grows `pane` by `points` along `axis` (shrinks it for a negative amount), moving the
    /// nearest divider that bounds it on that axis — vim's `ctrl+w >` and `ctrl+w +`.
    @discardableResult
    public mutating func grow(
        _ pane: PaneID, along axis: SplitAxis, by points: Double, in placement: PanePlacement
    ) -> Bool {
        guard
            let nearest = Self.ancestors(of: pane, in: root).first(where: {
                $0.axis == axis && placement.divider($0.id) != nil
            }),
            let divider = placement.divider(nearest.id)
        else { return false }
        let delta = nearest.paneInFirst ? points : -points
        return drag(nearest.id, to: divider.position + delta, in: placement)
    }

    /// The resize chords: `.right` makes `pane` wider, `.left` narrower, `.down` taller and `.up`
    /// shorter, by `step` points.
    @discardableResult
    public mutating func resize(
        _ pane: PaneID, _ direction: SplitDirection, step: Double = PaneSizing.keyboardStep,
        in placement: PanePlacement
    ) -> Bool {
        switch direction {
        case .right: return grow(pane, along: .horizontal, by: step, in: placement)
        case .left: return grow(pane, along: .horizontal, by: -step, in: placement)
        case .down: return grow(pane, along: .vertical, by: step, in: placement)
        case .up: return grow(pane, along: .vertical, by: -step, in: placement)
        }
    }

    /// Whether `pane` has room to halve along `axis`: both halves of its current rect, less the
    /// seam, must hold a glance. A pane that is not placed has no room at all.
    public func canSplit(_ pane: PaneID, axis: SplitAxis, in placement: PanePlacement) -> Bool {
        guard let rect = placement.frames[pane] else { return false }
        let half = (rect.extent(along: axis) - PaneSizing.gutter) / 2
        return half >= PaneSizing.chatGlance.extent(along: axis)
    }

    struct Ancestor {
        let id: SplitID
        let axis: SplitAxis
        let paneInFirst: Bool
    }

    /// The splits above `pane`, nearest first, with which side the pane is on.
    static func ancestors(of pane: PaneID, in node: SplitNode) -> [Ancestor] {
        guard case .split(let id, let axis, _, let first, let second) = node else { return [] }
        if leaves(of: first).contains(pane) {
            return ancestors(of: pane, in: first) + [Ancestor(id: id, axis: axis, paneInFirst: true)]
        }
        if leaves(of: second).contains(pane) {
            return ancestors(of: pane, in: second)
                + [Ancestor(id: id, axis: axis, paneInFirst: false)]
        }
        return []
    }

    private func solvePlacement(
        in bounds: SplitRect, scale: Double, minimums: [PaneID: PaneMinimum]
    ) -> PanePlacement {
        if let zoomedPane, contains(zoomedPane) {
            let others = paneIDs.filter { $0 != zoomedPane }
            return PanePlacement(
                frames: [zoomedPane: bounds], dividers: [], hidden: others,
                hiddenReason: others.isEmpty ? nil : .zoomed, stripNeeded: false, bounds: bounds,
                strip: nil)
        }
        var tree = root
        var dropped: Set<PaneID> = []
        var queue = recency.filter { $0 != focusedPane }
        while !Self.fits(tree, in: bounds, minimums: minimums), !queue.isEmpty {
            let next = queue.removeFirst()
            guard let pruned = Self.removing(next, from: tree) else { break }
            tree = pruned
            dropped.insert(next)
        }
        var frames: [PaneID: SplitRect] = [:]
        var dividers: [DividerPlacement] = []
        Self.place(
            tree, in: bounds, scale: scale, minimums: minimums, frames: &frames,
            dividers: &dividers)
        let hidden = paneIDs.filter { dropped.contains($0) }
        return PanePlacement(
            frames: frames, dividers: dividers, hidden: hidden,
            hiddenReason: hidden.isEmpty ? nil : .noRoom, stripNeeded: false, bounds: bounds,
            strip: nil)
    }

    private static func fits(
        _ node: SplitNode, in bounds: SplitRect, minimums: [PaneID: PaneMinimum]
    ) -> Bool {
        minExtent(node, along: .horizontal, minimums: minimums) <= bounds.width
            && minExtent(node, along: .vertical, minimums: minimums) <= bounds.height
    }

    /// The least room a subtree needs along `axis`: a split along it needs both sides and the
    /// seam between them, a split across it needs only its larger side.
    static func minExtent(
        _ node: SplitNode, along axis: SplitAxis, minimums: [PaneID: PaneMinimum]
    ) -> Double {
        switch node {
        case .pane(let id):
            return (minimums[id] ?? .zero).extent(along: axis)
        case .split(_, let own, _, let first, let second):
            let head = minExtent(first, along: axis, minimums: minimums)
            let tail = minExtent(second, along: axis, minimums: minimums)
            return own == axis ? head + PaneSizing.gutter + tail : max(head, tail)
        }
    }

    private static func place(
        _ node: SplitNode, in rect: SplitRect, scale: Double, minimums: [PaneID: PaneMinimum],
        frames: inout [PaneID: SplitRect], dividers: inout [DividerPlacement]
    ) {
        switch node {
        case .pane(let id):
            frames[id] = rect
        case .split(let id, let axis, let ratio, let first, let second):
            let gutter = PaneSizing.gutter
            let extent = rect.extent(along: axis)
            let available = max(0, extent - gutter)
            let lowest = minExtent(first, along: axis, minimums: minimums)
            let highest = max(lowest, available - minExtent(second, along: axis, minimums: minimums))
            let cut = snapped(
                min(max(available * ratio, lowest), highest), lowest: lowest, highest: highest,
                scale: scale)
            let tail = max(0, extent - cut - gutter)
            let half = PaneSizing.dividerHit / 2
            let head: SplitRect
            let line: SplitRect
            let hit: SplitRect
            let rest: SplitRect
            switch axis {
            case .horizontal:
                head = SplitRect(x: rect.x, y: rect.y, width: cut, height: rect.height)
                line = SplitRect(x: rect.x + cut, y: rect.y, width: gutter, height: rect.height)
                hit = SplitRect(
                    x: line.midX - half, y: rect.y, width: PaneSizing.dividerHit,
                    height: rect.height)
                rest = SplitRect(
                    x: rect.x + cut + gutter, y: rect.y, width: tail, height: rect.height)
            case .vertical:
                head = SplitRect(x: rect.x, y: rect.y, width: rect.width, height: cut)
                line = SplitRect(x: rect.x, y: rect.y + cut, width: rect.width, height: gutter)
                hit = SplitRect(
                    x: rect.x, y: line.midY - half, width: rect.width,
                    height: PaneSizing.dividerHit)
                rest = SplitRect(
                    x: rect.x, y: rect.y + cut + gutter, width: rect.width, height: tail)
            }
            dividers.append(
                DividerPlacement(
                    id: id, axis: axis, line: line, hit: hit, parent: rect, position: cut,
                    lowest: lowest, highest: highest))
            place(first, in: head, scale: scale, minimums: minimums, frames: &frames,
                dividers: &dividers)
            place(second, in: rest, scale: scale, minimums: minimums, frames: &frames,
                dividers: &dividers)
        }
    }

    /// The cut on the device-pixel grid, kept inside the clamp. A range narrower than one device
    /// pixel cannot hold a snapped value, and there the exact clamp wins over the grid.
    private static func snapped(
        _ value: Double, lowest: Double, highest: Double, scale: Double
    ) -> Double {
        guard scale.isFinite, scale > 0 else { return value }
        var result = (value * scale).rounded() / scale
        if result < lowest { result = (lowest * scale).rounded(.up) / scale }
        if result > highest { result = (highest * scale).rounded(.down) / scale }
        guard result >= lowest, result <= highest else { return value }
        return result
    }
}

extension SplitRect {
    public func extent(along axis: SplitAxis) -> Double {
        axis == .horizontal ? width : height
    }
}

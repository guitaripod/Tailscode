import Foundation

/// What a pane verb did to the tree, so a host redoes only as much as the verb undid.
public enum SplitVerbEffect: Sendable, Equatable {
    /// Panes changed slots or the tree changed shape: the host rebuilds around the same panes.
    case restructured
    /// Only ratios moved: the host reapplies positions to the dividers it already has.
    case resized
    /// Only the focus moved, and perhaps the zoom came off.
    case refocused
}

/// What a divider key asks for. The same four words on both desktops: arrows step by the
/// keyboard step (large with shift), Home and End go to the extremes.
public enum DividerKey: Sendable, Equatable {
    case back(large: Bool)
    case forward(large: Bool)
    case lowest
    case highest
}

extension SplitLayout {
    /// Does what a registered split chord asks, the single path both desktops dispatch through, so
    /// a verb cannot mean one thing under GTK and another under AppKit. Nil when the chord is not
    /// a tree verb or there was nothing for it to do: one pane has nothing to arrange, promote
    /// or rotate, and a window with no divider on that axis has nothing to resize.
    ///
    /// - Parameter placement: the tree laid out in the host's canvas, which the resize verbs
    ///   read their clamps from.
    @discardableResult
    public mutating func perform(_ action: KeyAction, placement: PanePlacement) -> SplitVerbEffect?
    {
        switch action {
        case .arrangeSplits:
            guard paneCount > 1 else { return nil }
            return arrange(SplitEven.shape(of: self).nextInCycle) ? .restructured : nil
        case .promoteSplit:
            return promote(focusedPane) ? .restructured : nil
        case .rotateSplits(let forward):
            return rotate(forward: forward) ? .restructured : nil
        case .moveSplitToEdge(let edge):
            return moveToEdge(focusedPane, edge: edge) ? .restructured : nil
        case .resizeSplit(let direction):
            return resize(focusedPane, direction, in: placement) ? .resized : nil
        case .cycleSplit(let forward):
            return cycleFocus(forward: forward, skipping: placement) == nil ? nil : .refocused
        default:
            return nil
        }
    }

    /// Rebuilds the tree as a named arrangement, the choice a menu makes directly rather than by
    /// walking the cycle. Choosing the shape the tree already reads as still evens it out.
    @discardableResult
    public mutating func choose(_ arrangement: SplitArrangement) -> SplitVerbEffect? {
        guard paneCount > 1 else { return nil }
        return arrange(arrangement) ? .restructured : nil
    }

    /// Moves a divider by a key: a step either way, or all the way to an extreme. Every road
    /// ends in `drag`, so a key can no more squeeze a pane below its minimum than a pointer can.
    @discardableResult
    public mutating func move(
        _ split: SplitID, by key: DividerKey, in placement: PanePlacement
    ) -> Bool {
        guard let divider = placement.divider(split) else { return false }
        let target: Double
        switch key {
        case .back(let large): target = divider.position - Self.keyStep(large: large)
        case .forward(let large): target = divider.position + Self.keyStep(large: large)
        case .lowest: target = divider.lowest
        case .highest: target = divider.highest
        }
        return drag(split, to: target, in: placement)
    }

    /// Every divider in the tree, outermost first, in reading order.
    public var splitIDs: [SplitID] {
        Self.splitIDs(in: root)
    }

    /// The panes on either side of a divider, in reading order, or nil for a divider the tree
    /// does not hold.
    public func sides(of split: SplitID) -> (first: [PaneID], second: [PaneID])? {
        Self.sides(of: split, in: root)
    }

    private static func splitIDs(in node: SplitNode) -> [SplitID] {
        guard case .split(let id, _, _, let first, let second) = node else { return [] }
        return [id] + splitIDs(in: first) + splitIDs(in: second)
    }

    private static func keyStep(large: Bool) -> Double {
        large ? PaneSizing.keyboardStepLarge : PaneSizing.keyboardStep
    }

    private static func sides(
        of split: SplitID, in node: SplitNode
    ) -> (first: [PaneID], second: [PaneID])? {
        guard case .split(let id, _, _, let first, let second) = node else { return nil }
        if id == split { return (leaves(of: first), leaves(of: second)) }
        return sides(of: split, in: first) ?? sides(of: split, in: second)
    }
}

/// How a divider introduces itself to a screen reader: which two panes it divides and where it
/// stands between its extremes. One wording for both desktops.
public enum DividerReading {
    /// "Divider between A and B", where a side holding several panes is named by its first pane
    /// and how many more sit with it.
    public static func label(first: [String], second: [String]) -> String {
        Localized.text("Divider between %@ and %@", side(first), side(second))
    }

    /// The position as a share of the way between the two extremes, 0 to 100, which is the
    /// value a splitter announces; a divider with no travel left reads as 50.
    public static func percent(_ divider: DividerPlacement) -> Int {
        let travel = divider.highest - divider.lowest
        guard travel > 0 else { return 50 }
        let share = (divider.position - divider.lowest) / travel
        return Int((min(max(share, 0), 1) * 100).rounded())
    }

    public static func value(_ divider: DividerPlacement) -> String {
        Localized.text("%@ percent", "\(percent(divider))")
    }

    private static func side(_ names: [String]) -> String {
        guard let head = names.first else { return "" }
        guard names.count > 1 else { return head }
        return Localized.text("%@ and %@ more", head, "\(names.count - 1)")
    }
}

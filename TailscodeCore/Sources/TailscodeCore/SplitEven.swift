import Foundation

/// How several chats share one window when they are opened together. The names describe what the
/// eye sees rather than an axis: a row of columns, a stack of rows, or a grid that balances both.
public enum SplitArrangement: String, CaseIterable, Sendable {
    case sideBySide
    case stacked
    case grid

    public var title: String {
        switch self {
        case .sideBySide: return Localized.text("Side by side")
        case .stacked: return Localized.text("Stacked")
        case .grid: return Localized.text("Grid")
        }
    }

    /// One column of meaning for the text desks; the boxes are the arrangement drawn small.
    public var glyph: String {
        switch self {
        case .sideBySide: return "▥"
        case .stacked: return "▤"
        case .grid: return "▦"
        }
    }

    /// The Apple clients' symbol for the same meaning.
    public var symbolName: String {
        switch self {
        case .sideBySide: return "rectangle.split.3x1"
        case .stacked: return "rectangle.split.1x2"
        case .grid: return "rectangle.split.2x2"
        }
    }

    public func caption(count: Int) -> String {
        switch self {
        case .sideBySide:
            return Localized.text("%@ columns, each the same width", "\(count)")
        case .stacked:
            return Localized.text("%@ rows, each the same height", "\(count)")
        case .grid:
            return Localized.text("%@ panes in rows and columns, shared evenly", "\(count)")
        }
    }

    /// What a screen reader is told the button does — the words carry the count the glyph implies.
    public func accessibleLabel(count: Int) -> String {
        Localized.text("Open the %@ marked chats %@", "\(count)", title.lowercased())
    }
}

/// A selection spent on the window itself: the marked chats opened all at once as one tiling,
/// every pane an equal share. The tree arithmetic lives here so all three surfaces that offer the
/// gesture build exactly the same arrangement, and the clients only mint panes for the ids.
public enum SplitEven {
    /// Past this many panes nothing is readable, whatever the arrangement — the verbs simply do
    /// not appear rather than opening a window of slivers.
    public static let limit = 9

    /// The arrangements worth offering for what is held: none for a single chat (opening it is
    /// the plain open), both lines for two, and a grid once a third pane gives it a second row.
    public static func offers(count: Int) -> [SplitArrangement] {
        guard count >= 2, count <= limit else { return [] }
        guard count >= 3 else { return [.sideBySide, .stacked] }
        return [.sideBySide, .stacked, .grid]
    }

    public static func header(count: Int) -> String {
        Localized.text("Open all %@ as one split", "\(count)")
    }

    /// The tree for `count` panes in `arrangement`, equalized so every pane holds its fair share,
    /// with the first pane focused and `paneIDs` in reading order — the order the marked rows were
    /// drawn is the order the panes land.
    public static func layout(count: Int, as arrangement: SplitArrangement) -> SplitLayout? {
        guard offers(count: count).contains(arrangement) else { return nil }
        let shape: [Int]
        switch arrangement {
        case .sideBySide: shape = [count]
        case .stacked: shape = Array(repeating: 1, count: count)
        case .grid: shape = gridRows(count)
        }
        var layout = SplitLayout()
        var rowSeeds = [layout.focusedPane]
        for _ in 1..<shape.count {
            guard let fresh = layout.split(rowSeeds[rowSeeds.count - 1], axis: .vertical) else {
                return nil
            }
            rowSeeds.append(fresh)
        }
        for (seed, width) in zip(rowSeeds, shape) {
            var last = seed
            for _ in 1..<width {
                guard let fresh = layout.split(last, axis: .horizontal) else { return nil }
                last = fresh
            }
        }
        layout.equalize()
        layout.focus(layout.paneIDs[0])
        return layout
    }

    /// Which of the three arrangements a tree reads as, so a remembered split can be drawn small
    /// without storing a name beside it: every divider along one axis is that line, and a tree
    /// mixing both is a grid however it nests. A window of one pane is no arrangement at all and
    /// reads as the plainest of the three.
    public static func shape(of layout: SplitLayout) -> SplitArrangement {
        var axes: Set<SplitAxis> = []
        collectAxes(layout.root, into: &axes)
        if axes.count > 1 { return .grid }
        return axes.first == .vertical ? .stacked : .sideBySide
    }

    private static func collectAxes(_ node: SplitNode, into axes: inout Set<SplitAxis>) {
        guard case .split(_, let axis, _, let first, let second) = node else { return }
        axes.insert(axis)
        collectAxes(first, into: &axes)
        collectAxes(second, into: &axes)
    }

    /// How a grid distributes `count` across rows: as square as the count allows, with the
    /// remainder spread rather than dumped — seven panes read as 3·2·2, never 3·3·1.
    static func gridRows(_ count: Int) -> [Int] {
        let columns = Int(Double(count).squareRoot().rounded(.up))
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        let base = count / rows
        let extra = count % rows
        return (0..<rows).map { $0 < extra ? base + 1 : base }
    }
}

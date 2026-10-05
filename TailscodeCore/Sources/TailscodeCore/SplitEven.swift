/// How several chats share one window. The names describe what the eye sees rather than an axis:
/// a row of columns, a stack of rows, a grid that balances both, or one main pane with the rest
/// stacked beside it or under it.
public enum SplitArrangement: String, CaseIterable, Sendable {
    case sideBySide
    case stacked
    case grid
    case mainStack
    case mainTop

    public var title: String {
        switch self {
        case .sideBySide: return Localized.text("Side by side")
        case .stacked: return Localized.text("Stacked")
        case .grid: return Localized.text("Grid")
        case .mainStack: return Localized.text("Main and stack")
        case .mainTop: return Localized.text("Main on top")
        }
    }

    /// One column of meaning for the text desks; the boxes are the arrangement drawn small.
    public var glyph: String {
        switch self {
        case .sideBySide: return "▥"
        case .stacked: return "▤"
        case .grid: return "▦"
        case .mainStack: return "◧"
        case .mainTop: return "⬒"
        }
    }

    /// The Apple clients' symbol for the same meaning.
    public var symbolName: String {
        switch self {
        case .sideBySide: return "rectangle.split.3x1"
        case .stacked: return "rectangle.split.1x2"
        case .grid: return "rectangle.split.2x2"
        case .mainStack: return "rectangle.lefthalf.inset.filled"
        case .mainTop: return "rectangle.tophalf.inset.filled"
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
        case .mainStack:
            return Localized.text("%@ panes: one main on the left, the rest stacked beside it", "\(count)")
        case .mainTop:
            return Localized.text("%@ panes: one main on top, the rest side by side under it", "\(count)")
        }
    }

    /// What a screen reader is told the button does — the words carry the count the glyph implies.
    public func accessibleLabel(count: Int) -> String {
        Localized.text("Open the %@ marked chats %@", "\(count)", title.lowercased())
    }

    /// The order `ctrl+w a` walks: columns, rows, grid, main and stack, then round again. Main on
    /// top is reached from a menu rather than the cycle, and steps back to columns.
    public static let cycle: [SplitArrangement] = [.sideBySide, .stacked, .grid, .mainStack]

    public var nextInCycle: SplitArrangement {
        guard let index = Self.cycle.firstIndex(of: self) else { return Self.cycle[0] }
        return Self.cycle[(index + 1) % Self.cycle.count]
    }
}

/// A selection spent on the window itself: the marked chats opened all at once as one tiling,
/// every pane an equal share. The tree arithmetic lives here so all three surfaces that offer the
/// gesture build exactly the same arrangement, and the clients only mint panes for the ids.
public enum SplitEven {
    /// Past this many panes nothing is readable, whatever the arrangement — the verbs simply do
    /// not appear rather than opening a window of slivers.
    public static let limit = 9

    /// The share the main pane takes in the two main arrangements.
    public static let mainRatio = 0.58

    /// The arrangements worth offering for what is held: none for a single chat (opening it is
    /// the plain open), both lines for two, and once a third pane gives a second row the grid and
    /// main-and-stack too — main and stack leading from four, where one pane among many is the
    /// arrangement people keep.
    public static func offers(count: Int) -> [SplitArrangement] {
        guard count >= 2, count <= limit else { return [] }
        guard count >= 3 else { return [.sideBySide, .stacked] }
        guard count >= 4 else { return [.sideBySide, .stacked, .grid, .mainStack] }
        return [.mainStack, .sideBySide, .stacked, .grid]
    }

    public static func header(count: Int) -> String {
        Localized.text("Open all %@ as one split", "\(count)")
    }

    /// The tree for `count` fresh panes in `arrangement`, built by `arrange(ids:as:)` — only for
    /// an arrangement the count is offered.
    public static func layout(count: Int, as arrangement: SplitArrangement) -> SplitLayout? {
        guard offers(count: count).contains(arrangement) else { return nil }
        return arrange(ids: (0..<count).map { _ in PaneID() }, as: arrangement)
    }

    /// The tree for these panes in `arrangement`, the same builder for a bulk open (fresh ids)
    /// and a re-arrangement of panes already open (their own ids). Every pane holds its fair
    /// share, except that a main pane takes `mainRatio`; the panes land in reading order, and the
    /// first is focused. Any count from one works — the bulk limit is the offer's, not the
    /// builder's — and duplicate or no ids build nothing.
    public static func arrange(ids: [PaneID], as arrangement: SplitArrangement) -> SplitLayout? {
        guard !ids.isEmpty, Set(ids).count == ids.count else { return nil }
        let root: SplitNode
        switch arrangement {
        case .sideBySide:
            root = line(ids[...], axis: .horizontal)
        case .stacked:
            root = line(ids[...], axis: .vertical)
        case .grid:
            var rows: [SplitNode] = []
            var start = 0
            for width in gridRows(ids.count) {
                rows.append(line(ids[start..<(start + width)], axis: .horizontal))
                start += width
            }
            root = chain(rows[...], axis: .vertical)
        case .mainStack:
            root = main(ids, axis: .horizontal, rest: .vertical)
        case .mainTop:
            root = main(ids, axis: .vertical, rest: .horizontal)
        }
        return SplitLayout(root: root, focused: ids[0])
    }

    /// Which arrangement a tree reads as, so a remembered split can be drawn small without
    /// storing a name beside it: every divider along one axis is that line; one pane beside a
    /// line of the other axis is a main arrangement; anything else mixing both is a grid however
    /// it nests. A window of one pane is no arrangement at all and reads as the plainest.
    public static func shape(of layout: SplitLayout) -> SplitArrangement {
        var axes: Set<SplitAxis> = []
        collectAxes(layout.root, into: &axes)
        if axes.count > 1 {
            if case .split(_, let axis, _, .pane, let rest) = layout.root, case .split = rest {
                var restAxes: Set<SplitAxis> = []
                collectAxes(rest, into: &restAxes)
                if restAxes == [axis == .horizontal ? .vertical : .horizontal] {
                    return axis == .horizontal ? .mainStack : .mainTop
                }
            }
            return .grid
        }
        return axes.first == .vertical ? .stacked : .sideBySide
    }

    private static func line(_ ids: ArraySlice<PaneID>, axis: SplitAxis) -> SplitNode {
        chain(ArraySlice(ids.map(SplitNode.pane)), axis: axis)
    }

    /// Nodes in a row along `axis`, each holding an equal share: right-nested, the way repeated
    /// splits of the last pane build them, so the reading order is the order given.
    private static func chain(_ nodes: ArraySlice<SplitNode>, axis: SplitAxis) -> SplitNode {
        guard let head = nodes.first else { return .pane(PaneID()) }
        guard nodes.count > 1 else { return head }
        return .split(
            id: SplitID(), axis: axis, ratio: 1 / Double(nodes.count), first: head,
            second: chain(nodes.dropFirst(), axis: axis))
    }

    private static func main(_ ids: [PaneID], axis: SplitAxis, rest: SplitAxis) -> SplitNode {
        guard ids.count > 1 else { return .pane(ids[0]) }
        return .split(
            id: SplitID(), axis: axis, ratio: mainRatio, first: .pane(ids[0]),
            second: line(ids.dropFirst(), axis: rest))
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

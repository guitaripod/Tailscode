import Foundation

/// Which way a split lays its two children: `horizontal` puts them side by side (vim's
/// `:vsplit`), `vertical` stacks them. The names describe the axis the panes are arranged
/// along, matching GTK's orientation vocabulary; the Mac adapter flips its own `isVertical`.
public enum SplitAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

/// A direction the eye can move between panes. Geometry, not tree order: the neighbor is
/// whichever pane actually sits that way on screen.
public enum SplitDirection: String, Codable, Sendable, CaseIterable {
    case left
    case right
    case up
    case down
}

/// One pane's stable identity, minted at split time and carried through persistence so a
/// restored layout rebinds each pane to the session it was showing.
public struct PaneID: Hashable, Sendable, Codable {
    public let raw: String

    public init() { raw = UUID().uuidString }
    public init(raw: String) { self.raw = raw }

    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// One split node's stable identity, so a host can map a divider widget back to the ratio it
/// owns across rebuilds.
public struct SplitID: Hashable, Sendable, Codable {
    public let raw: String

    public init() { raw = UUID().uuidString }
    public init(raw: String) { self.raw = raw }

    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// The layout tree itself: a leaf is a pane, an interior node is a divider. Binary with a ratio
/// rather than n-ary with weights because every toolkit here has a natural two-child split
/// widget, and any arrangement is reachable by nesting.
public indirect enum SplitNode: Sendable, Equatable, Codable {
    case pane(PaneID)
    case split(id: SplitID, axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode)
}

/// A rectangle in whatever space the caller works in; the solver hands out frames in the unit
/// square so hosts multiply by their pixel size and tests need no toolkit.
public struct SplitRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let unit = SplitRect(x: 0, y: 0, width: 1, height: 1)

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// The whole tiling arrangement as one value: the tree, which pane holds focus, which pane is
/// zoomed, and the focus history that decides where focus lands when a pane closes. Every verb
/// is a pure mutation here so all three clients share one behavior and the tests never touch a
/// widget.
public struct SplitLayout: Sendable, Equatable, Codable {
    public private(set) var root: SplitNode
    public private(set) var focusedPane: PaneID
    public private(set) var zoomedPane: PaneID?
    private var focusHistory: [PaneID]

    public init() {
        let pane = PaneID()
        root = .pane(pane)
        focusedPane = pane
        zoomedPane = nil
        focusHistory = [pane]
    }

    /// Every pane in the tree, in reading order (first child before second, depth first).
    public var paneIDs: [PaneID] {
        Self.leaves(of: root)
    }

    public var paneCount: Int { paneIDs.count }

    public func contains(_ pane: PaneID) -> Bool {
        paneIDs.contains(pane)
    }

    /// Whether the layout is well formed: a focused pane that exists, unique pane ids, and
    /// ratios a divider can actually sit at. A snapshot that fails this is discarded whole —
    /// a broken tree restored is a window nobody can use.
    public var isValid: Bool {
        let ids = paneIDs
        guard !ids.isEmpty, Set(ids).count == ids.count, ids.contains(focusedPane) else {
            return false
        }
        if let zoomedPane, !ids.contains(zoomedPane) { return false }
        return Self.ratiosValid(root)
    }

    public mutating func focus(_ pane: PaneID) {
        guard contains(pane) else { return }
        focusedPane = pane
        focusHistory.removeAll { $0 == pane }
        focusHistory.append(pane)
    }

    /// Splits `pane` in two along `axis`; the new pane takes the second half and the focus.
    ///
    /// - Parameter placingNewFirst: gives the new pane the *first* half instead. The keyboard verbs
    ///   never need this — vim's `:vsplit` always opens to one side — but a chat dropped against a
    ///   pane's left edge has to land on the left, and a highlight that promised the left half and
    ///   delivered the right would be a lie.
    @discardableResult
    public mutating func split(
        _ pane: PaneID, axis: SplitAxis, placingNewFirst: Bool = false
    ) -> PaneID? {
        guard contains(pane) else { return nil }
        let fresh = PaneID()
        root = Self.replacingLeaf(pane, in: root) {
            .split(
                id: SplitID(), axis: axis, ratio: 0.5,
                first: .pane(placingNewFirst ? fresh : pane),
                second: .pane(placingNewFirst ? pane : fresh))
        }
        zoomedPane = nil
        focus(fresh)
        return fresh
    }

    /// Removes `pane`; its sibling subtree inherits the whole space. Focus returns to the most
    /// recently used surviving pane — the one the eye was on before — never to tree order.
    /// The last pane refuses to close: an empty window is not a layout.
    @discardableResult
    public mutating func close(_ pane: PaneID) -> PaneID? {
        guard contains(pane), paneCount > 1 else { return nil }
        guard let collapsed = Self.removing(pane, from: root) else { return nil }
        root = collapsed
        focusHistory.removeAll { $0 == pane }
        if zoomedPane == pane { zoomedPane = nil }
        let survivor = focusHistory.last(where: { contains($0) }) ?? paneIDs[0]
        focus(survivor)
        return survivor
    }

    public func ratio(of split: SplitID) -> Double? {
        Self.findRatio(split, in: root)
    }

    public mutating func setRatio(_ ratio: Double, of split: SplitID) {
        let clamped = min(0.95, max(0.05, ratio))
        root = Self.settingRatio(clamped, of: split, in: root)
    }

    /// Gives every pane its fair share, the way vim's `ctrl+w =` does: each divider splits by how
    /// many pane-widths each side needs along its own axis, so three panes in a row end up a third
    /// each however the tree nests, while a lone pane beside a stack keeps half the window rather
    /// than being squeezed to the stack's leaf count.
    public mutating func equalize() {
        root = Self.equalizing(root)
    }

    /// Exchanges `pane` with its sibling subtree in place — the two swap positions, the
    /// divider stays where it is.
    public mutating func exchange(_ pane: PaneID) {
        guard contains(pane) else { return }
        zoomedPane = nil
        root = Self.exchangingSibling(of: pane, in: root)
    }

    /// One pane borrows the whole window without the tree forgetting anything — zoom again and
    /// the layout is exactly as it was. Any structural change or directional move unzooms.
    public mutating func toggleZoom(_ pane: PaneID) {
        guard contains(pane) else { return }
        zoomedPane = zoomedPane == pane ? nil : pane
        focus(pane)
    }

    /// Every pane's frame with the given rect carved up by the tree's ratios. The zoom is
    /// deliberately ignored: the frames describe the layout's truth, and hiding is the host's
    /// presentation of the zoom, not a different geometry.
    public func frames(in rect: SplitRect = .unit) -> [PaneID: SplitRect] {
        var result: [PaneID: SplitRect] = [:]
        Self.solve(root, in: rect, into: &result)
        return result
    }

    /// The pane the eye would reach moving `direction` from `pane`: prefers panes sharing the
    /// departed edge (most overlap wins, then nearest center), falls back to the nearest pane
    /// strictly that way. `nil` at the window's edge.
    public func neighbor(of pane: PaneID, direction: SplitDirection) -> PaneID? {
        let all = frames()
        guard let from = all[pane] else { return nil }
        let epsilon = 1e-9

        struct Candidate {
            let id: PaneID
            let overlap: Double
            let centerGap: Double
            let distance: Double
        }

        var touching: [Candidate] = []
        var beyond: [Candidate] = []
        for (id, frame) in all where id != pane {
            let horizontalOverlap =
                min(from.maxX, frame.maxX) - max(from.x, frame.x)
            let verticalOverlap =
                min(from.maxY, frame.maxY) - max(from.y, frame.y)
            let edgeGap: Double
            let overlap: Double
            let centerGap: Double
            let ahead: Bool
            switch direction {
            case .left:
                edgeGap = abs(frame.maxX - from.x)
                overlap = verticalOverlap
                centerGap = abs(frame.midY - from.midY)
                ahead = frame.midX < from.midX - epsilon
            case .right:
                edgeGap = abs(frame.x - from.maxX)
                overlap = verticalOverlap
                centerGap = abs(frame.midY - from.midY)
                ahead = frame.midX > from.midX + epsilon
            case .up:
                edgeGap = abs(frame.maxY - from.y)
                overlap = horizontalOverlap
                centerGap = abs(frame.midX - from.midX)
                ahead = frame.midY < from.midY - epsilon
            case .down:
                edgeGap = abs(frame.y - from.maxY)
                overlap = horizontalOverlap
                centerGap = abs(frame.midX - from.midX)
                ahead = frame.midY > from.midY + epsilon
            }
            let dx = frame.midX - from.midX
            let dy = frame.midY - from.midY
            let candidate = Candidate(
                id: id, overlap: overlap, centerGap: centerGap,
                distance: dx * dx + dy * dy)
            if edgeGap < epsilon, overlap > epsilon {
                touching.append(candidate)
            } else if ahead {
                beyond.append(candidate)
            }
        }
        if !touching.isEmpty {
            return touching.min { a, b in
                if a.overlap != b.overlap { return a.overlap > b.overlap }
                return a.centerGap < b.centerGap
            }?.id
        }
        return beyond.min { $0.distance < $1.distance }?.id
    }

    /// Moves focus one pane in `direction`, unzooming first — a directional move while zoomed
    /// means "show me the arrangement again". Returns false at the edge so hosts can decide to
    /// hand focus to the chrome beside the tree instead.
    @discardableResult
    public mutating func focusNeighbor(_ direction: SplitDirection) -> Bool {
        zoomedPane = nil
        guard let target = neighbor(of: focusedPane, direction: direction) else { return false }
        focus(target)
        return true
    }

    private static func leaves(of node: SplitNode) -> [PaneID] {
        switch node {
        case .pane(let id): return [id]
        case .split(_, _, _, let first, let second):
            return leaves(of: first) + leaves(of: second)
        }
    }

    private static func ratiosValid(_ node: SplitNode) -> Bool {
        switch node {
        case .pane: return true
        case .split(_, _, let ratio, let first, let second):
            return ratio.isFinite && ratio > 0 && ratio < 1 && ratiosValid(first)
                && ratiosValid(second)
        }
    }

    private static func replacingLeaf(
        _ pane: PaneID, in node: SplitNode, with replacement: () -> SplitNode
    ) -> SplitNode {
        switch node {
        case .pane(let id):
            return id == pane ? replacement() : node
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(
                id: id, axis: axis, ratio: ratio,
                first: replacingLeaf(pane, in: first, with: replacement),
                second: replacingLeaf(pane, in: second, with: replacement))
        }
    }

    private static func removing(_ pane: PaneID, from node: SplitNode) -> SplitNode? {
        switch node {
        case .pane(let id):
            return id == pane ? nil : node
        case .split(let id, let axis, let ratio, let first, let second):
            let prunedFirst = removing(pane, from: first)
            let prunedSecond = removing(pane, from: second)
            guard let prunedFirst else { return prunedSecond }
            guard let prunedSecond else { return prunedFirst }
            return .split(
                id: id, axis: axis, ratio: ratio, first: prunedFirst, second: prunedSecond)
        }
    }

    private static func findRatio(_ split: SplitID, in node: SplitNode) -> Double? {
        switch node {
        case .pane: return nil
        case .split(let id, _, let ratio, let first, let second):
            if id == split { return ratio }
            return findRatio(split, in: first) ?? findRatio(split, in: second)
        }
    }

    private static func settingRatio(
        _ ratio: Double, of split: SplitID, in node: SplitNode
    ) -> SplitNode {
        switch node {
        case .pane: return node
        case .split(let id, let axis, let current, let first, let second):
            return .split(
                id: id, axis: axis, ratio: id == split ? ratio : current,
                first: settingRatio(ratio, of: split, in: first),
                second: settingRatio(ratio, of: split, in: second))
        }
    }

    private static func equalizing(_ node: SplitNode) -> SplitNode {
        switch node {
        case .pane: return node
        case .split(let id, let axis, _, let first, let second):
            let head = span(of: first, along: axis)
            let tail = span(of: second, along: axis)
            return .split(
                id: id, axis: axis, ratio: head / (head + tail), first: equalizing(first),
                second: equalizing(second))
        }
    }

    /// How many pane-widths a subtree needs along `axis`: a split along it adds its sides, a
    /// split across it stacks them into the wider one's footprint.
    private static func span(of node: SplitNode, along axis: SplitAxis) -> Double {
        switch node {
        case .pane: return 1
        case .split(_, let own, _, let first, let second):
            let head = span(of: first, along: axis)
            let tail = span(of: second, along: axis)
            return own == axis ? head + tail : max(head, tail)
        }
    }

    private static func exchangingSibling(of pane: PaneID, in node: SplitNode) -> SplitNode {
        switch node {
        case .pane: return node
        case .split(let id, let axis, let ratio, let first, let second):
            if first == .pane(pane) || second == .pane(pane) {
                return .split(id: id, axis: axis, ratio: ratio, first: second, second: first)
            }
            return .split(
                id: id, axis: axis, ratio: ratio,
                first: exchangingSibling(of: pane, in: first),
                second: exchangingSibling(of: pane, in: second))
        }
    }

    private static func solve(
        _ node: SplitNode, in rect: SplitRect, into result: inout [PaneID: SplitRect]
    ) {
        switch node {
        case .pane(let id):
            result[id] = rect
        case .split(_, let axis, let ratio, let first, let second):
            switch axis {
            case .horizontal:
                let cut = rect.width * ratio
                solve(
                    first, in: SplitRect(x: rect.x, y: rect.y, width: cut, height: rect.height),
                    into: &result)
                solve(
                    second,
                    in: SplitRect(
                        x: rect.x + cut, y: rect.y, width: rect.width - cut, height: rect.height),
                    into: &result)
            case .vertical:
                let cut = rect.height * ratio
                solve(
                    first, in: SplitRect(x: rect.x, y: rect.y, width: rect.width, height: cut),
                    into: &result)
                solve(
                    second,
                    in: SplitRect(
                        x: rect.x, y: rect.y + cut, width: rect.width, height: rect.height - cut),
                    into: &result)
            }
        }
    }
}

/// What one pane was showing, by reference: enough to find the session again on launch, and
/// enough to say what is missing when it cannot be found.
public struct SplitPaneSession: Codable, Sendable, Equatable {
    public let profileID: String
    public let sessionID: String

    public init(profileID: String, sessionID: String) {
        self.profileID = profileID
        self.sessionID = sessionID
    }
}

/// The layout and its sessions as one persisted value, under one shared key, so both desktops
/// restore the same arrangement the same way. Sessions are keyed by the pane id's raw string
/// because JSON dictionaries want string keys.
public struct SplitSnapshot: Codable, Sendable, Equatable {
    public static let defaultsKey = "tailscode.layout.tree"

    public let layout: SplitLayout
    public let sessions: [String: SplitPaneSession]
    /// What each video slot was watching, by pane. Kept beside the sessions rather than inside
    /// them because a slot holds no conversation at all, and decoded leniently so a layout written
    /// before slots existed still restores.
    public let videos: [String: String]
    /// The page each browser slot ended on, by pane — a slot restores what it was reading.
    public let pages: [String: String]

    public init(
        layout: SplitLayout, sessions: [String: SplitPaneSession], videos: [String: String] = [:],
        pages: [String: String] = [:]
    ) {
        self.layout = layout
        self.sessions = sessions
        self.videos = videos
        self.pages = pages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = try container.decode(SplitLayout.self, forKey: .layout)
        sessions = try container.decode([String: SplitPaneSession].self, forKey: .sessions)
        videos = try container.decodeIfPresent([String: String].self, forKey: .videos) ?? [:]
        pages = try container.decodeIfPresent([String: String].self, forKey: .pages) ?? [:]
    }

    public var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ string: String) -> SplitSnapshot? {
        guard let data = string.data(using: .utf8),
            let snapshot = try? JSONDecoder().decode(SplitSnapshot.self, from: data),
            snapshot.layout.isValid
        else { return nil }
        return snapshot
    }

    public func session(for pane: PaneID) -> SplitPaneSession? {
        sessions[pane.raw]
    }

    public func video(for pane: PaneID) -> VideoTarget? {
        videos[pane.raw].flatMap(VideoTarget.classify)
    }

    public func page(for pane: PaneID) -> WebTarget? {
        pages[pane.raw].flatMap(WebTarget.classify)
    }
}

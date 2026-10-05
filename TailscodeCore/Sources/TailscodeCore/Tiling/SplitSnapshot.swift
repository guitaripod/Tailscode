import Foundation

/// The layout and what every pane holds as one persisted value, under one shared key, so both
/// desktops restore the same arrangement the same way. Keyed by the pane id's raw string because
/// JSON dictionaries want string keys.
///
/// Schema 2 keeps what a pane holds as one `PaneContent` per pane. It also writes the four
/// dictionaries schema 1 kept — sessions, videos, pages, draws — so a build from before the
/// change, handed this snapshot by a downgrade, still restores it; the reader prefers `contents`
/// and migrates a snapshot that has only the dictionaries. The legacy fields go in the release
/// after next.
public struct SplitSnapshot: Codable, Sendable, Equatable {
    public static let defaultsKey = "tailscode.layout.tree"
    public static let currentSchema = 2
    /// More panes than this is not a layout anyone made by hand; a snapshot holding more is cut
    /// back to the first ones in reading order rather than restored as a window of slivers.
    public static let paneCeiling = 12

    public let schema: Int
    public let layout: SplitLayout
    public let contents: [String: PaneContent]
    /// Panes the person asked to keep live, by raw id.
    public let pinned: [String]
    public let sessions: [String: SplitPaneSession]
    public let videos: [String: String]
    public let pages: [String: String]
    public let draws: [String: String]

    public init(
        layout: SplitLayout, contents: [String: PaneContent], pinned: [String] = []
    ) {
        schema = Self.currentSchema
        self.layout = layout
        self.contents = contents.filter { $0.value != .empty }
        self.pinned = pinned
        var sessions: [String: SplitPaneSession] = [:]
        var videos: [String: String] = [:]
        var pages: [String: String] = [:]
        var draws: [String: String] = [:]
        for (key, content) in self.contents {
            switch content {
            case .empty: break
            case .chat(let session): sessions[key] = session
            case .video(let address): videos[key] = address
            case .web(let address): pages[key] = address
            case .draw(let address): draws[key] = address
            }
        }
        self.sessions = sessions
        self.videos = videos
        self.pages = pages
        self.draws = draws
    }

    /// The schema 1 shape, kept so the hosts that still think in four dictionaries build the same
    /// value. A pane named in more than one takes the one a host restored first: draw, then page,
    /// then video, then the chat.
    public init(
        layout: SplitLayout, sessions: [String: SplitPaneSession], videos: [String: String] = [:],
        pages: [String: String] = [:], draws: [String: String] = [:]
    ) {
        self.init(
            layout: layout,
            contents: Self.migrate(sessions: sessions, videos: videos, pages: pages, draws: draws))
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case layout
        case contents
        case pinned
        case sessions
        case videos
        case pages
        case draws
    }

    /// Lenient past the layout itself: a schema 1 snapshot, one missing any dictionary, and one
    /// written by a newer build with kinds this one does not know all decode — the unknown kind
    /// as an empty pane, never as a refusal of the whole window.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let layout = try container.decode(SplitLayout.self, forKey: .layout)
        let pinned = (try? container.decodeIfPresent([String].self, forKey: .pinned)) ?? []
        let contents: [String: PaneContent]
        if let stored = try? container.decodeIfPresent(
            [String: PaneContent].self, forKey: .contents)
        {
            contents = stored
        } else {
            contents = Self.migrate(
                sessions: (try? container.decodeIfPresent(
                    [String: SplitPaneSession].self, forKey: .sessions)) ?? [:],
                videos: (try? container.decodeIfPresent([String: String].self, forKey: .videos))
                    ?? [:],
                pages: (try? container.decodeIfPresent([String: String].self, forKey: .pages))
                    ?? [:],
                draws: (try? container.decodeIfPresent([String: String].self, forKey: .draws))
                    ?? [:])
        }
        self.init(layout: layout, contents: contents, pinned: pinned)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(layout, forKey: .layout)
        try container.encode(contents, forKey: .contents)
        try container.encode(pinned, forKey: .pinned)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(videos, forKey: .videos)
        try container.encode(pages, forKey: .pages)
        try container.encode(draws, forKey: .draws)
    }

    public var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// What reading a stored snapshot produced, and how many panes past the ceiling it dropped —
    /// a host records the cut rather than letting panes vanish without a word.
    public struct Decoded: Sendable, Equatable {
        public let snapshot: SplitSnapshot
        public let droppedPanes: Int
    }

    public static func decode(_ string: String) -> SplitSnapshot? {
        decodeReporting(string)?.snapshot
    }

    /// Reads a stored snapshot. A tree that is not valid — duplicate ids, a ratio a divider
    /// cannot sit at, a focus on no pane — discards the whole snapshot; one holding more than
    /// `paneCeiling` panes keeps the first ones in reading order.
    public static func decodeReporting(_ string: String) -> Decoded? {
        guard let data = string.data(using: .utf8),
            let snapshot = try? JSONDecoder().decode(SplitSnapshot.self, from: data),
            snapshot.layout.isValid
        else { return nil }
        let ids = snapshot.layout.paneIDs
        guard ids.count > paneCeiling else { return Decoded(snapshot: snapshot, droppedPanes: 0) }
        let dropped = Set(ids.dropFirst(paneCeiling).map(\.raw))
        let trimmed = SplitSnapshot(
            layout: snapshot.layout.keepingFirst(paneCeiling),
            contents: snapshot.contents.filter { !dropped.contains($0.key) },
            pinned: snapshot.pinned.filter { !dropped.contains($0) })
        return Decoded(snapshot: trimmed, droppedPanes: dropped.count)
    }

    /// What `pane` holds; a pane nothing was recorded for is empty.
    public func content(for pane: PaneID) -> PaneContent {
        contents[pane.raw] ?? .empty
    }

    public func isPinned(_ pane: PaneID) -> Bool {
        pinned.contains(pane.raw)
    }

    public func session(for pane: PaneID) -> SplitPaneSession? {
        guard case .chat(let session) = content(for: pane) else { return nil }
        return session
    }

    public func video(for pane: PaneID) -> VideoTarget? {
        guard case .video(let address) = content(for: pane) else { return nil }
        return VideoTarget.classify(address)
    }

    public func page(for pane: PaneID) -> WebTarget? {
        guard case .web(let address) = content(for: pane) else { return nil }
        return WebTarget.classify(address)
    }

    /// The draw slot a pane held: the ComfyUI endpoint and the last prompt, as one encoded line.
    public func draw(for pane: PaneID) -> String? {
        guard case .draw(let address) = content(for: pane) else { return nil }
        return address
    }

    private static func migrate(
        sessions: [String: SplitPaneSession], videos: [String: String],
        pages: [String: String], draws: [String: String]
    ) -> [String: PaneContent] {
        var contents: [String: PaneContent] = [:]
        for (key, session) in sessions { contents[key] = .chat(session) }
        for (key, address) in videos { contents[key] = .video(address) }
        for (key, address) in pages { contents[key] = .web(address) }
        for (key, address) in draws { contents[key] = .draw(address) }
        return contents
    }
}

extension SplitLayout {
    /// The layout with only its first `count` panes in reading order. Focus stays where it was
    /// when that pane survives, and otherwise goes to the most recently used survivor.
    func keepingFirst(_ count: Int) -> SplitLayout {
        let ids = paneIDs
        guard count > 0, ids.count > count else { return self }
        var tree = root
        for id in ids.dropFirst(count) {
            if let pruned = Self.removing(id, from: tree) { tree = pruned }
        }
        let kept = Set(ids.prefix(count))
        let survivor =
            kept.contains(focusedPane)
            ? focusedPane : focusHistory.last(where: { kept.contains($0) }) ?? ids[0]
        return SplitLayout(
            root: tree, focused: survivor, zoomed: zoomedPane, history: focusHistory)
    }
}

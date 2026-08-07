import Foundation

/// Where a section is in its life. A board is filled by several sources answering at different
/// speeds, so each section says for itself whether it is still waiting, has nothing, or could not
/// be reached — one spinner over the whole pane would lie about three of the four.
public enum WatchPhase: Sendable, Equatable {
    case idle
    case loading
    case ready
    case failed(String)
}

/// What a row says about itself in one word, in the vocabulary the chat list already uses.
public enum WatchBadge: Sendable, Equatable {
    case live(String)
    case offline(String)
    case plain(String)

    public var text: String {
        switch self {
        case .live(let text), .offline(let text), .plain(let text): return text
        }
    }
}

/// What a row is, underneath what it says. The client renders every kind the same way — a title,
/// a line under it, a badge, maybe a picture — and only needs the kind to know what activating it
/// means.
public enum WatchRowKind: Sendable, Equatable {
    case channel(MediaEntry)
    case category(MediaCategory)
    case typed(VideoTarget)
    case expander(String)
    case note
}

/// What activating a row means to the pane. A step the board takes itself — opening a category,
/// expanding a section — never reaches here.
public enum WatchAction: Sendable, Equatable {
    case play(VideoTarget)
    case follow(MediaChannel)
    case reload
}

public struct WatchRow: Sendable, Equatable, Identifiable {
    public let sectionID: String
    public let kind: WatchRowKind
    public let title: String
    public let detail: String
    public let badge: WatchBadge?
    /// A second line under the detail, dimmer than it — the stream's own tags, or why a section is
    /// empty. A row carrying one is still an ordinary row.
    public let note: String?
    public let thumbnail: String?
    public let avatar: String?
    public let source: MediaSource?
    public let isPrimary: Bool
    public let isFollowed: Bool

    init(
        sectionID: String, kind: WatchRowKind, title: String, detail: String,
        badge: WatchBadge? = nil, note: String? = nil, thumbnail: String? = nil,
        avatar: String? = nil, source: MediaSource? = nil, isPrimary: Bool = false,
        isFollowed: Bool = false
    ) {
        self.sectionID = sectionID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.badge = badge
        self.note = note
        self.thumbnail = thumbnail
        self.avatar = avatar
        self.source = source
        self.isPrimary = isPrimary
        self.isFollowed = isFollowed
    }

    public var id: String { "\(sectionID)/\(anchor)" }

    /// A note is text the board owed the reader, not something to press. Everything else does
    /// something, and the cursor skips what does not.
    public var isActivatable: Bool {
        if case .note = kind { return false }
        return true
    }

    /// The channel this row is about, when it is about one — what following it would follow.
    public var channel: MediaChannel? {
        switch kind {
        case .channel(let entry): return entry.channel
        case .category, .typed, .expander, .note: return nil
        }
    }

    private var anchor: String {
        switch kind {
        case .channel(let entry): return entry.id
        case .category(let category): return "cat/\(category.id)"
        case .typed(let target): return "typed/\(target.address)"
        case .expander(let id): return "more/\(id)"
        case .note: return "note/\(title)"
        }
    }
}

public struct WatchSection: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let phase: WatchPhase
    public let rows: [WatchRow]
    /// How many rows the section is holding back behind its expander — zero when it shows all it
    /// has. Drawn by the client only if it wants to; the expander row already says the number.
    public let hidden: Int

    public var isEmpty: Bool { rows.isEmpty }
}

/// What a keystroke means to the board. Every chord here is one a text field cannot want, because
/// the board is driven from the same box somebody types a channel name into: the letters belong to
/// the field, and the board takes only the arrows, Enter, Tab, Escape and deliberate control
/// chords.
public enum WatchCommand: Sendable, Equatable {
    case up
    case down
    case activate
    case expand
    case back
    case follow
    case reload
}

/// What is on, in a pane. The board is what the empty video slot shows instead of a bare text box:
/// the channels this device follows with their live state, what is popular now, what a category
/// holds, and — the moment anything is typed — what those words would open, alongside what the
/// sources found for them.
///
/// Toolkit-free, like every chooser here: the sections, the compact-then-expand rule, the cursor
/// and the key bindings all live in one place so GTK and AppKit render the same board and answer
/// the same keys. Nothing in it fetches; the client hands feeds in as they land and the board
/// restates itself around whatever has arrived so far.
public struct WatchChooser: Sendable, Equatable {
    /// How many rows a section shows before it starts holding the rest behind one row. Four is
    /// what fits beside a conversation without the board becoming the pane.
    public static let compactLimit = 4
    public static let searchLimit = 6

    public private(set) var query = ""
    public private(set) var cursor = 0
    public private(set) var expanded: Set<String> = []
    public private(set) var sections: [WatchSection] = []
    public private(set) var rows: [WatchRow] = []

    private var watchlist: [MediaChannel] = []
    private var followed: Set<String> = []
    private var live = MediaFeed()
    private var livePhase = WatchPhase.idle
    private var results = MediaFeed()
    private var resultsPhase = WatchPhase.idle
    private var browse = MediaFeed()
    private var browsePhase = WatchPhase.idle
    private var top = MediaFeed()
    private var topPhase = WatchPhase.idle
    private var openCategory: MediaCategory?
    private var inside = MediaFeed()
    private var insidePhase = WatchPhase.idle
    private var now = Date()
    private var accountsLine: String?
    /// Whether anybody has moved the cursor yet. Answers arrive from several sources at once, and
    /// until somebody has actually chosen where to look, the cursor belongs at the top of the board
    /// rather than pinned to whichever section happened to answer first.
    private var moved = false

    public init(watchlist: [MediaChannel] = [], followed: [MediaChannel] = []) {
        self.watchlist = watchlist
        self.followed = Set(followed.map(\.id))
        rebuild()
    }

    public var isEmpty: Bool { rows.isEmpty }

    /// The row under the cursor, when the cursor is on one. A board holding nothing but the lines
    /// it owed the reader — "checking…", "Twitch did not answer" — focuses nothing, because there
    /// is nothing there to press.
    public var focused: WatchRow? {
        guard rows.indices.contains(cursor), rows[cursor].isActivatable else { return nil }
        return rows[cursor]
    }

    public var heading: String {
        if let openCategory { return openCategory.name }
        return query.isEmpty ? Localized.text("What's on") : Localized.text("Watch")
    }

    public var hint: String {
        Localized.text("↑↓ moves · enter watches · tab expands · ctrl+f follows · esc clears")
    }

    public var prompt: String { Localized.text("Channel, link, or words") }

    /// The line the board carries at the bottom while nothing is playing: what a stream will cost
    /// the grid, said before a pane is spent on one.
    public var notice: String { VideoNotice.splitCost }

    /// True while any section is still waiting on a source — what a client shows a quiet marker
    /// for, never a spinner over rows that already arrived.
    public var isLoading: Bool {
        [livePhase, resultsPhase, browsePhase, topPhase, insidePhase].contains(.loading)
    }

    public mutating func type(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != query else { return }
        query = trimmed
        if trimmed.isEmpty {
            results = MediaFeed()
            resultsPhase = .idle
        } else {
            resultsPhase = .loading
        }
        cursor = 0
        moved = false
        rebuild()
    }

    /// The channels this device follows or recently watched, with whatever live state has arrived.
    /// The list stands on its own: a source that never answers leaves every row offline rather
    /// than leaving the section empty.
    public mutating func stock(watchlist: [MediaChannel], followed: [MediaChannel]) {
        self.watchlist = watchlist
        self.followed = Set(followed.map(\.id))
        rebuild()
    }

    /// Where the followed list came from, when an account supplied it. A list of three hundred
    /// channels somebody never typed in is worth attributing: the section says whose it is rather
    /// than letting it look like something this device invented.
    public mutating func attribute(_ line: String?) {
        let trimmed = line?.trimmingCharacters(in: .whitespacesAndNewlines)
        accountsLine = (trimmed?.isEmpty ?? true) ? nil : trimmed
        rebuild()
    }

    public mutating func filled(live feed: MediaFeed) {
        self.live = feed
        livePhase = feed.failures.isEmpty ? .ready : .failed(feed.failures.joined(separator: " · "))
        rebuild()
    }

    public mutating func filled(results feed: MediaFeed, for words: String) {
        guard words.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
        results = feed
        resultsPhase = feed.failures.isEmpty ? .ready : .failed(feed.failures.joined(separator: " · "))
        rebuild()
    }

    public mutating func filled(top feed: MediaFeed) {
        self.top = feed
        topPhase = feed.failures.isEmpty ? .ready : .failed(feed.failures.joined(separator: " · "))
        rebuild()
    }

    public mutating func filled(categories feed: MediaFeed) {
        browse = feed
        browsePhase = feed.failures.isEmpty ? .ready : .failed(feed.failures.joined(separator: " · "))
        rebuild()
    }

    public mutating func filled(inside feed: MediaFeed, of category: MediaCategory) {
        guard openCategory?.id == category.id else { return }
        inside = feed
        insidePhase = feed.failures.isEmpty ? .ready : .failed(feed.failures.joined(separator: " · "))
        rebuild()
    }

    public mutating func loading(_ section: String) {
        switch section {
        case Self.liveID: livePhase = .loading
        case Self.resultsID: resultsPhase = .loading
        case Self.browseID: browsePhase = .loading
        case Self.topID: topPhase = .loading
        case Self.insideID: insidePhase = .loading
        default: return
        }
        rebuild()
    }

    /// Re-reads the uptimes without touching anything else — a board left open should not claim a
    /// stream has been running for four hours when it has been running for five.
    public mutating func tick(_ moment: Date = Date()) {
        now = moment
        rebuild()
    }

    /// The category the board has open, when it has one; the client fetches what is inside it.
    public var opened: MediaCategory? { openCategory }

    /// The words a search is owed, when one is owed — nil when nothing is typed or the answer for
    /// what is typed already arrived.
    public var pendingSearch: String? {
        guard !query.isEmpty, resultsPhase == .loading else { return nil }
        return query
    }

    public mutating func move(by delta: Int) {
        let stops = rows.indices.filter { rows[$0].isActivatable }
        guard !stops.isEmpty else { return }
        guard let place = stops.firstIndex(where: { $0 >= cursor }) ?? stops.indices.last else {
            return
        }
        let landing = max(0, min(stops.count - 1, place + delta))
        cursor = stops[landing]
        moved = true
    }

    public mutating func focus(_ index: Int) {
        guard rows.indices.contains(index), rows[index].isActivatable else { return }
        cursor = index
        moved = true
    }

    /// Activates the row under the cursor. A category opening, a section expanding and the board
    /// stepping back are taken here and answer nil; only what the pane must act on comes out.
    public mutating func activate() -> WatchAction? {
        guard let row = focused else { return nil }
        return activate(row)
    }

    public mutating func activate(_ row: WatchRow) -> WatchAction? {
        switch row.kind {
        case .channel(let entry):
            return .play(entry.target)
        case .typed(let target):
            return .play(target)
        case .category(let category):
            openCategory = category
            inside = MediaFeed()
            insidePhase = .loading
            cursor = 0
            moved = false
            rebuild()
            return nil
        case .expander(let id):
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            rebuild()
            return nil
        case .note:
            return nil
        }
    }

    /// Steps back out of whatever the board went into: an open category first, then the search.
    /// Answers false when there was nothing to step back from, so Escape goes on to mean whatever
    /// else the app makes it mean.
    @discardableResult
    public mutating func back() -> Bool {
        if openCategory != nil {
            openCategory = nil
            inside = MediaFeed()
            insidePhase = .idle
            cursor = 0
            moved = false
            rebuild()
            return true
        }
        guard !query.isEmpty else { return false }
        type("")
        return true
    }

    public mutating func handle(_ command: WatchCommand) -> (handled: Bool, action: WatchAction?) {
        switch command {
        case .up:
            move(by: -1)
            return (true, nil)
        case .down:
            move(by: 1)
            return (true, nil)
        case .activate:
            return (true, activate())
        case .expand:
            guard let row = focused else { return (false, nil) }
            let id = row.sectionID
            guard sections.first(where: { $0.id == id })?.hidden ?? 0 > 0 || expanded.contains(id)
            else { return (true, nil) }
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            rebuild()
            return (true, nil)
        case .back:
            return (back(), nil)
        case .follow:
            guard let channel = focused?.channel else { return (true, nil) }
            return (true, .follow(channel))
        case .reload:
            return (true, .reload)
        }
    }

    /// Keys the board claims. Every one of them is a chord a text field has no use for, because the
    /// same keystroke stream is typing a channel name: bare letters and digits stay in the box.
    public static func command(for chord: KeyChord) -> WatchCommand? {
        if chord.control {
            guard let character = Keymap.scalar(chord.keyval) else { return nil }
            switch character {
            case "n": return .down
            case "p": return .up
            case "f": return .follow
            case "r": return .reload
            default: return nil
            }
        }
        guard !chord.alt else { return nil }
        switch chord.keyval {
        case Keymap.up: return .up
        case Keymap.down: return .down
        case Keymap.enter: return .activate
        case Keymap.tab: return .expand
        case Keymap.escape: return .back
        default: return nil
        }
    }

    /// Carries the person's place across a re-render. Feeds land while somebody is reading, so the
    /// cursor follows the row it was on by identity, not by index — a board that reshuffles under
    /// a finger is a board that opens the wrong stream.
    private mutating func keepPlace(on identity: String?) {
        guard moved, let identity, let index = rows.firstIndex(where: { $0.id == identity }),
            rows[index].isActivatable
        else {
            cursor = rows.firstIndex { $0.isActivatable } ?? -1
            return
        }
        cursor = index
    }

    public static let liveID = "live"
    public static let followingID = "following"
    public static let resultsID = "results"
    public static let browseID = "browse"
    public static let topID = "top"
    public static let insideID = "inside"

    private mutating func rebuild() {
        let held = focused?.id
        sections = query.isEmpty ? restingSections() : searchingSections()
        rows = sections.flatMap(\.rows)
        keepPlace(on: held)
    }

    private func restingSections() -> [WatchSection] {
        if let openCategory {
            return [
                section(
                    id: Self.insideID, title: openCategory.name,
                    detail: openCategory.detail, phase: insidePhase,
                    rows: inside.entries.map { row(for: $0, in: Self.insideID) },
                    empty: Localized.text("Nothing is streaming here right now"))
            ]
        }
        var built: [WatchSection] = []
        let known = Dictionary(uniqueKeysWithValues: live.entries.map { ($0.id, $0) })
        let stocked = watchlist.map { channel in
            known[channel.id] ?? MediaEntry(channel: channel)
        }
        let onAir = MediaRank.byAudience(stocked.filter(\.isLive))
        let offAir = stocked.filter { !$0.isLive }

        if !watchlist.isEmpty || livePhase == .loading {
            built.append(
                section(
                    id: Self.liveID, title: Localized.text("Live now"),
                    detail: Localized.text("%@ of yours", "\(onAir.count)"), phase: livePhase,
                    rows: onAir.map { row(for: $0, in: Self.liveID) },
                    empty: Localized.text("Nothing you follow is on")))
        }
        if !offAir.isEmpty {
            built.append(
                section(
                    id: Self.followingID, title: Localized.text("Following"),
                    detail: accountsLine ?? Localized.text("%@ offline", "\(offAir.count)"),
                    phase: .ready,
                    rows: offAir.map { row(for: $0, in: Self.followingID) }, empty: "", limit: 3))
        }
        built.append(
            section(
                id: Self.topID, title: Localized.text("Popular now"),
                detail: Localized.text("Across Twitch and YouTube"), phase: topPhase,
                rows: top.entries.map { row(for: $0, in: Self.topID) },
                empty: Localized.text("Nothing came back")))
        if !browse.categories.isEmpty || browsePhase == .loading || browsePhase.isFailure {
            built.append(
                section(
                    id: Self.browseID, title: Localized.text("Browse"),
                    detail: Localized.text("By category"), phase: browsePhase,
                    rows: browse.categories.map { row(for: $0, in: Self.browseID) },
                    empty: Localized.text("No categories came back"), limit: 5))
        }
        return built.filter { !$0.rows.isEmpty }
    }

    private func searchingSections() -> [WatchSection] {
        var built: [WatchSection] = []
        if let target = VideoTarget.classify(query) {
            built.append(
                WatchSection(
                    id: "typed", title: Localized.text("Open"), detail: "", phase: .ready,
                    rows: [
                        WatchRow(
                            sectionID: "typed", kind: .typed(target),
                            title: Self.wording(for: target), detail: target.playbackURL,
                            badge: .plain(target.source), source: MediaSource(rawValue: target.source),
                            isPrimary: true)
                    ], hidden: 0))
        }
        built.append(
            section(
                id: Self.resultsID, title: Localized.text("Live for “%@”", query), detail: "",
                phase: resultsPhase,
                rows: results.entries.map { row(for: $0, in: Self.resultsID) },
                empty: Localized.text("Nothing live matches those words"),
                limit: Self.searchLimit))
        return built.filter { !$0.rows.isEmpty }
    }

    /// One section, compacted: the first few rows, then one row standing for the rest. A section
    /// that is loading or that failed says so as its own row rather than as a missing section.
    private func section(
        id: String, title: String, detail: String, phase: WatchPhase, rows: [WatchRow],
        empty: String, limit: Int = WatchChooser.compactLimit
    ) -> WatchSection {
        if rows.isEmpty {
            let line: String?
            switch phase {
            case .loading: line = Localized.text("Checking…")
            case .failed(let reason): line = reason
            case .ready: line = empty.isEmpty ? nil : empty
            case .idle: line = nil
            }
            guard let line else {
                return WatchSection(id: id, title: title, detail: detail, phase: phase, rows: [], hidden: 0)
            }
            return WatchSection(
                id: id, title: title, detail: detail, phase: phase,
                rows: [WatchRow(sectionID: id, kind: .note, title: line, detail: "")], hidden: 0)
        }
        let showsAll = expanded.contains(id) || rows.count <= limit
        let shown = showsAll ? rows : Array(rows.prefix(limit))
        let hidden = rows.count - shown.count
        var built = shown
        if hidden > 0 {
            built.append(
                WatchRow(
                    sectionID: id, kind: .expander(id),
                    title: Localized.text("%@ more", "\(hidden)"),
                    detail: Localized.text("tab shows them")))
        } else if showsAll, rows.count > limit {
            built.append(
                WatchRow(
                    sectionID: id, kind: .expander(id), title: Localized.text("Fewer"),
                    detail: Localized.text("tab hides them again")))
        }
        if case .failed(let reason) = phase {
            built.append(WatchRow(sectionID: id, kind: .note, title: reason, detail: ""))
        }
        return WatchSection(
            id: id, title: title, detail: detail, phase: phase, rows: built, hidden: hidden)
    }

    /// A channel as three lines: who it is, what they are streaming, and the facts about it. The
    /// audience lives in the badge and nowhere else, so the line under the title is never the same
    /// number twice. The section it belongs to is passed in rather than inferred: the same channel
    /// can appear in what is on and in what is popular, and a row that named the wrong section
    /// would expand the wrong list and answer to the wrong identity.
    private func row(for entry: MediaEntry, in sectionID: String) -> WatchRow {
        WatchRow(
            sectionID: sectionID, kind: .channel(entry),
            title: entry.channel.name,
            detail: entry.stream?.title ?? Localized.text("Offline"),
            badge: entry.isLive
                ? .live(entry.badge ?? Localized.text("live")) : .offline(Localized.text("offline")),
            note: entry.isLive ? entry.context(now: now) : nil,
            thumbnail: entry.stream?.thumbnail, avatar: entry.channel.avatar,
            source: entry.channel.source, isFollowed: followed.contains(entry.channel.id))
    }

    private func row(for category: MediaCategory, in sectionID: String) -> WatchRow {
        WatchRow(
            sectionID: sectionID, kind: .category(category), title: category.name,
            detail: category.detail, thumbnail: category.art, source: category.source)
    }

    private static func wording(for target: VideoTarget) -> String {
        switch target {
        case .twitch(let login): return Localized.text("Watch %@ on Twitch", login)
        case .youtube(let handle): return Localized.text("Watch %@ on YouTube", handle)
        case .link: return Localized.text("Open this link")
        case .search(let words): return Localized.text("Search for “%@”", words)
        }
    }
}

extension WatchChooser {
    /// A row addressed by section and index, which is how a client that draws sections rather than
    /// one flat list reports a click.
    public mutating func focus(section id: String, offset: Int) {
        guard let section = sections.first(where: { $0.id == id }),
            section.rows.indices.contains(offset),
            let index = rows.firstIndex(where: { $0.id == section.rows[offset].id })
        else { return }
        focus(index)
    }
}

extension WatchPhase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// The board's rules, checked headlessly in the Kit rather than in one client — both desktops run
/// this from their own `--selftest`, so the shared model is proved once and identically.
public enum WatchChooserCheck {
    public static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(3600 * 4 + 720)
        let caedrel = MediaChannel(source: .twitch, handle: "caedrel", name: "Caedrel")
        let lofi = MediaChannel(source: .youtube, handle: "@LofiGirl", name: "Lofi Girl")
        let quiet = MediaChannel(source: .twitch, handle: "quietone", name: "Quiet One")
        let live = MediaEntry(
            channel: caedrel,
            stream: MediaStream(
                title: "LCK", category: "League of Legends", viewers: 36579, startedAt: start,
                thumbnail: "https://example/preview.jpg", tags: ["English", "Esports"]),
            checkedAt: now)

        expect(MediaFormat.viewers(947) == "947", "a small audience is said exactly")
        expect(MediaFormat.viewers(36579) == "37K", "a big one is rounded")
        expect(MediaFormat.viewers(1624) == "1.6K", "a small thousand keeps a decimal")
        expect(MediaFormat.viewers(1_624_404) == "1.6M", "millions read as millions")
        expect(MediaFormat.uptime(since: start, now: now) == Localized.text("%@h %@m", "4", "12"),
            "uptime reads in hours and minutes")
        expect(MediaFormat.uptime(since: now, now: now) == nil, "a stream just started claims nothing")

        expect(caedrel.target == .twitch("caedrel"), "a Twitch channel opens as a Twitch target")
        expect(lofi.target == .youtube("@LofiGirl"), "a YouTube handle keeps its @")
        expect(live.badge == "37K", "a live row wears its audience")
        expect(
            live.detail(now: now)
                == "League of Legends · 37K · \(Localized.text("%@h %@m", "4", "12"))",
            "the detail line is category, audience, uptime")

        let ranked = MediaRank.byAudience([
            MediaEntry(channel: quiet),
            live,
            MediaEntry(channel: lofi, stream: MediaStream(title: "lofi", viewers: 1678)),
        ])
        expect(ranked.map(\.channel.handle) == ["caedrel", "@LofiGirl", "quietone"],
            "live before offline, biggest audience first")
        expect(MediaRank.byAudience([live, live]).count == 1, "the same channel is one row")

        var board = WatchChooser(watchlist: [caedrel, lofi, quiet], followed: [caedrel])
        expect(
            WatchChooser(watchlist: [caedrel], followed: []).rows.first?.sectionID
                == WatchChooser.followingID,
            "a row names the section it is drawn in")
        expect(board.sections.count == 1, "before any answer the board is only the list it owns")
        expect(board.rows.count == 3, "and every channel on it is a row")
        board.filled(live: MediaFeed(entries: [live]))
        expect(board.sections.first?.id == WatchChooser.liveID, "what is on leads")
        expect(board.sections.first?.rows.first?.badge == .live("37K"), "the live row says how many")
        expect(
            board.sections.contains { $0.id == WatchChooser.followingID },
            "the ones that are not on are still listed")
        expect(board.rows.first?.isFollowed == true, "a followed channel says so")

        board.filled(top: MediaFeed(entries: (0..<7).map { index in
            MediaEntry(
                channel: MediaChannel(source: .twitch, handle: "t\(index)", name: "Top \(index)"),
                stream: MediaStream(title: "on", viewers: 1000 - index))
        }))
        let popular = board.sections.first { $0.id == WatchChooser.topID }
        expect(
            popular?.rows.first?.sectionID == WatchChooser.topID,
            "a channel listed under what is popular says so, not that it is one of yours")
        if let index = board.rows.firstIndex(where: { $0.sectionID == WatchChooser.topID }) {
            board.focus(index)
            expect(board.handle(.expand).handled, "tab expands the section the cursor is in")
            expect(
                board.sections.first { $0.id == WatchChooser.topID }?.hidden == 0,
                "and that section stops holding anything back")
            _ = board.handle(.expand)
        }
        expect(popular?.rows.count == WatchChooser.compactLimit + 1, "a long section is compacted")
        expect(popular?.hidden == 3, "and says how many it is holding")
        expect(popular?.rows.last?.kind == .expander(WatchChooser.topID), "behind one row")
        if let index = board.rows.firstIndex(where: { $0.kind == .expander(WatchChooser.topID) }) {
            board.focus(index)
            expect(board.activate() == nil, "expanding is a step, not an outcome")
            expect(
                board.sections.first { $0.id == WatchChooser.topID }?.rows.count == 8,
                "and the rest come out")
        } else {
            failures.append("the expander is a row")
        }

        var typed = WatchChooser(watchlist: [caedrel], followed: [])
        typed.type("lofi hip hop")
        expect(typed.sections.first?.id == "typed", "what was typed leads its own answer")
        expect(typed.rows.first?.isPrimary == true, "and is the primary row")
        expect(typed.pendingSearch == "lofi hip hop", "a search is owed while it is unanswered")
        expect(typed.rows.first?.kind == .typed(.search("lofi hip hop")), "words are read as a search")
        typed.filled(results: MediaFeed(entries: [live]), for: "wrong words")
        expect(typed.pendingSearch != nil, "an answer to a stale question is dropped")
        typed.filled(results: MediaFeed(entries: [live]), for: "lofi hip hop")
        expect(typed.pendingSearch == nil, "the answer to the live question lands")
        expect(typed.rows.count == 2, "the typed row, then what was found")
        expect(typed.back(), "escape steps out of a search")
        expect(typed.query.isEmpty, "and clears it")
        expect(!typed.back(), "with nothing typed there is nothing to step back from")

        var browsing = WatchChooser(watchlist: [], followed: [])
        let games = [
            MediaCategory(source: .twitch, id: "Rust", name: "Rust", viewers: 187_920),
            MediaCategory(source: .twitch, id: "Chess", name: "Chess", viewers: 4_120),
        ]
        browsing.filled(categories: MediaFeed(categories: games))
        expect(
            browsing.sections.contains { $0.id == WatchChooser.browseID }, "categories are browsable")
        if let index = browsing.rows.firstIndex(where: { $0.kind == .category(games[0]) }) {
            browsing.focus(index)
            expect(browsing.activate() == nil, "opening a category is a step")
            expect(browsing.opened == games[0], "and the board says which one it opened")
            expect(browsing.sections.first?.rows.first?.kind == .note, "which is checking, not empty")
            browsing.filled(inside: MediaFeed(entries: [live]), of: games[0])
            expect(browsing.rows.first?.title == "Caedrel", "then holds what is streaming in it")
            expect(browsing.back(), "escape leaves a category")
            expect(browsing.opened == nil, "and closes it")
        } else {
            failures.append("a category is a row")
        }

        var failing = WatchChooser(watchlist: [caedrel], followed: [])
        failing.filled(live: MediaFeed(failures: ["Twitch did not answer"]))
        expect(
            failing.rows.contains { $0.kind == .note && $0.title == "Twitch did not answer" },
            "a source that failed says so in the board")
        expect(
            failing.rows.contains { $0.channel?.handle == "caedrel" },
            "and the list this device owns is still listed")
        let noteIndex = failing.rows.firstIndex { $0.kind == .note }
        if let noteIndex {
            failing.focus(noteIndex)
            expect(failing.cursor != noteIndex, "the cursor does not stop on a note")
        }

        var following = WatchChooser(watchlist: [caedrel], followed: [])
        following.filled(live: MediaFeed(entries: [live]))
        expect(following.handle(.follow).action == .follow(caedrel), "ctrl+f follows what is focused")
        expect(following.handle(.reload).action == .reload, "ctrl+r asks for fresh answers")
        expect(following.handle(.activate).action == .play(.twitch("caedrel")), "enter watches it")

        let commands: [(UInt32, UInt32, WatchCommand?)] = [
            (Keymap.up, 0, .up),
            (Keymap.down, 0, .down),
            (Keymap.enter, 0, .activate),
            (Keymap.tab, 0, .expand),
            (Keymap.escape, 0, .back),
            (UInt32(UnicodeScalar("f").value), Keymap.control, .follow),
            (UInt32(UnicodeScalar("n").value), Keymap.control, .down),
            (UInt32(UnicodeScalar("j").value), 0, nil),
            (UInt32(UnicodeScalar("3").value), 0, nil),
            (UInt32(UnicodeScalar("a").value), 0, nil),
        ]
        for (keyval, state, expected) in commands {
            guard let chord = KeyChord.canonical(keyval: keyval, state: state) else {
                failures.append("chord \(keyval) does not canonicalize")
                continue
            }
            expect(WatchChooser.command(for: chord) == expected, "key \(keyval)/\(state)")
        }

        let summary = WatchSummary(feed: MediaFeed(entries: [live, MediaEntry(channel: quiet)]), followed: 3)
        expect(summary.badge == Localized.text("%@ live", "1"), "the pane row counts what is on")
        expect(summary.detail == Localized.text("%@ is live", "Caedrel"), "and names it")
        let quietSummary = WatchSummary(live: [], followed: 2)
        expect(
            quietSummary.detail == Localized.text("Nothing you follow is live"),
            "a quiet night says so rather than reverting to a label")

        expect(MediaFetch.count("12,304") == 12304, "a comma is not a decimal point")
        expect(MediaFetch.count("1.2M watching") == 1_200_000, "shorthand is read as the number")
        expect(MediaFetch.count("no numbers here") == nil, "and nothing else is guessed at")
        expect(MediaDate.parse("2026-08-07T07:30:10Z") != nil, "a timestamp parses")
        return failures
    }
}

import CodingAgentKit
import Foundation

/// One folder in the listing being read.
public struct FolderRow: Sendable, Equatable {
    public let name: String
    public let path: String
    /// Offsets into `name` the filter landed on.
    public let highlight: [Int]
    /// Chats already working exactly here.
    public let chats: Int
    /// Chats working somewhere inside it, so a folder that holds a project says so before it is opened.
    public let chatsBelow: Int
    public let starred: Bool

    public init(
        name: String, path: String, highlight: [Int] = [], chats: Int = 0, chatsBelow: Int = 0,
        starred: Bool = false
    ) {
        self.name = name
        self.path = path
        self.highlight = highlight
        self.chats = chats
        self.chatsBelow = chatsBelow
        self.starred = starred
    }
}

/// One step of the path being read, clickable to jump back to it.
public struct FolderCrumb: Sendable, Equatable {
    public let title: String
    public let path: String
    public let isCurrent: Bool
}

public enum FolderPlaceKind: Sendable, Equatable {
    case home
    case root
    case favorite
    case recent
    case project
}

/// A jump: somewhere worth going without walking there.
public struct FolderPlace: Sendable, Equatable {
    public let kind: FolderPlaceKind
    public let title: String
    public let path: String
    public let detail: String
}

public struct FolderPlaceSection: Sendable, Equatable {
    public let title: String?
    public let places: [FolderPlace]
}

/// What the browser wants read: one folder on one server. `path` may be `.` or `~`, which only the
/// server can resolve.
public struct FolderRequest: Sendable, Equatable, Hashable {
    public let profileID: String
    public let path: String

    public init(profileID: String, path: String) {
        self.profileID = profileID
        self.path = path
    }
}

public enum FolderPhase: Sendable, Equatable {
    case loading
    case ready
    case failed(Failure)

    public enum Failure: Sendable, Equatable {
        /// The very first read of this server failed: it is down, wants a password, or is too old
        /// to list its folders.
        case cannotList
        /// The server answered, but not for this path.
        case missing(String)
    }
}

public enum FolderCommand: Sendable, Equatable {
    case up
    case down
    case top
    case bottom
    case halfUp
    case halfDown
    case descend
    case ascend
    case back
    case home
    case root
    case refresh
    case complete
    case chooseHere
    case favoriteHere
    case nextServer
    case previousServer
    case clearFilter
    case dismiss
}

public enum FolderOutcome: Sendable, Equatable {
    case choose(profileID: String, path: String)
    case favorite(profileID: String, path: String)
    case dismiss
}

/// Walking a server's disk to pick the folder a chat will work in, decided once.
///
/// The old answer to "browse the other machine" was a push of the file browser — on the phone a
/// bare list with a title, on the desktops nothing at all, because a native picker would have
/// offered this disk's folders on behalf of a machine across the tailnet. This is the same walk
/// for all three clients: a path you can click back along, up and back and home, a filter that
/// narrows the folder you are in as you type, the places you already work as one-press jumps,
/// every server a keystroke away, and one verb that picks the folder you are standing in. The
/// client reads folders over the server's own listing and offers them back; nothing here touches
/// a network or a toolkit.
public struct FolderBrowser: Sendable, Equatable {
    public static let placeLimit = 8

    public let servers: [NewChatServer]
    private var directories: [String: NewChatDirectories]
    private let chatPaths: [String: [String]]

    public private(set) var serverIndex: Int
    /// The absolute folder being shown, or nil until the server has said what `.` means.
    public private(set) var location: String?
    public private(set) var phase: FolderPhase
    public private(set) var filter: String
    public private(set) var cursor: Int
    public private(set) var rows: [FolderRow]

    private var target: String
    private var trail: [String]
    private var cache: [String: [String]]
    private var homes: [String: String]
    private var lastLocation: [String: String]
    private var everAnswered: Set<String>

    private static let halfPage = 6

    /// - Parameter start: where to open on the preferred server — the folder a half-typed path sits
    ///   in — or nil for the server's home.
    public init(
        servers: [NewChatServer], directories: [String: NewChatDirectories],
        entries: [SessionEntry] = [], preferredServer: String? = nil, start: String? = nil
    ) {
        self.servers = servers
        self.directories = directories
        var paths: [String: [String]] = [:]
        for entry in entries {
            if let directory = entry.session.directory {
                paths[entry.profileID, default: []].append(directory)
            }
        }
        self.chatPaths = paths
        self.serverIndex =
            preferredServer.flatMap { id in servers.firstIndex { $0.profileID == id } } ?? 0
        self.filter = ""
        self.cursor = 0
        self.rows = []
        self.trail = []
        self.cache = [:]
        self.homes = [:]
        self.lastLocation = [:]
        self.everAnswered = []
        self.target = "."
        self.location = nil
        self.phase = .loading
        if let start, let absolute = Self.absolute(start) {
            target = absolute
            location = absolute
        }
        rebuild()
    }

    public var isEmpty: Bool { servers.isEmpty }

    public var server: NewChatServer? {
        servers.indices.contains(serverIndex) ? servers[serverIndex] : servers.first
    }

    public var focused: FolderRow? { rows.indices.contains(cursor) ? rows[cursor] : nil }

    public var home: String? { server.flatMap { homes[$0.profileID] } }

    /// The folder Choose would use: the one on screen. Nil until the server has said where we are.
    public var current: String? { location }

    public var currentName: String {
        guard let location else { return Localized.text("Home") }
        return Self.name(of: location)
    }

    /// The last component of a path, as a person reads a folder's name; the root is `/`.
    public static func name(of path: String) -> String {
        path == "/" ? "/" : NewChatChooser.name(of: path)
    }

    public var isStarredHere: Bool {
        guard let server, let location else { return false }
        return directories[server.profileID]?.favorites.contains(location) ?? false
    }

    public var canGoUp: Bool { location.flatMap(Self.parent(of:)) != nil }
    public var canGoBack: Bool { !trail.isEmpty }

    /// What Choose would pick: the folder the filter has narrowed to when something is typed and a
    /// row is under the cursor, otherwise the folder on screen.
    public var choice: String? {
        if !filter.isEmpty, let row = focused { return row.path }
        return location
    }

    public var summary: String {
        switch phase {
        case .loading: return Localized.text("Reading…")
        case .failed: return ""
        case .ready:
            if rows.isEmpty {
                return filter.isEmpty
                    ? Localized.text("No subfolders — this is a place to start")
                    : Localized.text("Nothing here matches “%@”", filter)
            }
            return rows.count == 1
                ? Localized.text("1 folder") : Localized.text("%@ folders", "\(rows.count)")
        }
    }

    public var hint: String {
        servers.count > 1
            ? Localized.text(
                "type to filter · ↑↓ walk · enter opens · ⌫ goes up · ⌃enter picks · ⌃s switches server"
            )
            : Localized.text("type to filter · ↑↓ walk · enter opens · ⌫ goes up · ⌃enter picks")
    }

    public var crumbs: [FolderCrumb] {
        guard let location else { return [] }
        var result: [FolderCrumb] = []
        var base = ""
        var remainder = location
        if let home, location == home || location.hasPrefix(home + "/") {
            result.append(FolderCrumb(title: "~", path: home, isCurrent: location == home))
            base = home
            remainder = String(location.dropFirst(home.count))
        } else {
            result.append(FolderCrumb(title: "/", path: "/", isCurrent: location == "/"))
        }
        var walked = base
        for part in remainder.split(separator: "/") {
            walked += "/\(part)"
            result.append(
                FolderCrumb(title: String(part), path: walked, isCurrent: walked == location))
        }
        return result
    }

    public var placeSections: [FolderPlaceSection] {
        guard let server else { return [] }
        let known = directories[server.profileID] ?? NewChatDirectories()
        var seen = Set<String>()
        var fixed: [FolderPlace] = []
        let homePath = home ?? "~"
        fixed.append(
            FolderPlace(kind: .home, title: Localized.text("Home"), path: homePath, detail: ""))
        seen.insert(homePath)
        fixed.append(FolderPlace(kind: .root, title: "/", path: "/", detail: ""))
        seen.insert("/")
        func make(_ paths: [String], _ kind: FolderPlaceKind) -> [FolderPlace] {
            paths.filter { seen.insert($0).inserted }.prefix(Self.placeLimit).map {
                FolderPlace(
                    kind: kind, title: NewChatChooser.name(of: $0), path: $0,
                    detail: NewChatChooser.parent(of: $0))
            }
        }
        let starred = make(known.favorites, .favorite)
        let recent = make(known.recents, .recent)
        let projects = make(known.projects, .project)
        var sections = [FolderPlaceSection(title: nil, places: fixed)]
        if !starred.isEmpty {
            sections.append(FolderPlaceSection(title: Localized.text("Starred"), places: starred))
        }
        if !recent.isEmpty {
            sections.append(FolderPlaceSection(title: Localized.text("Recent"), places: recent))
        }
        if !projects.isEmpty {
            sections.append(
                FolderPlaceSection(title: Localized.text("Chats work here"), places: projects))
        }
        return sections
    }

    /// The flat list of places, in the order a client draws and a number key picks them.
    public var places: [FolderPlace] { placeSections.flatMap(\.places) }

    /// The folder the client should read next, nil once it is held. Clients drop duplicate
    /// flights themselves; this only says what the view is waiting for.
    public var wanted: FolderRequest? {
        guard let server, phase == .loading else { return nil }
        return FolderRequest(profileID: server.profileID, path: target)
    }

    // MARK: Navigation

    public mutating func open(_ path: String) {
        guard let destination = Self.absolute(path, home: home) ?? Self.relative(path) else {
            return
        }
        if let location, destination == location, phase == .ready { return }
        if let location { trail.append(location) }
        go(to: destination)
    }

    public mutating func openPlace(_ index: Int) {
        let all = places
        guard all.indices.contains(index) else { return }
        open(all[index].path)
    }

    public mutating func chooseServer(_ profileID: String) {
        guard let index = servers.firstIndex(where: { $0.profileID == profileID }),
            index != serverIndex
        else { return }
        switchServer(to: index)
    }

    public mutating func type(_ text: String) {
        guard text != filter else { return }
        filter = text
        rebuild()
        cursor = 0
    }

    public mutating func focus(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        cursor = index
    }

    public mutating func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        cursor = max(0, min(rows.count - 1, cursor + delta))
    }

    /// A read back from the server. `nodes` nil means it could not list that folder. An answer for
    /// a folder or a server the person has already left is kept for later and not shown.
    public mutating func offer(_ request: FolderRequest, nodes: [FileNode]?) {
        let key = Self.key(request.profileID, request.path)
        if let nodes {
            let resolved = Self.resolve(request.path, nodes: nodes)
            cache[key] = nodes.filter(\.isDirectory).map(\.path).sorted(by: Self.byName)
            if let resolved {
                cache[Self.key(request.profileID, resolved)] = cache[key]
                if request.path == "." || request.path == "~" {
                    homes[request.profileID] = resolved
                }
            }
            everAnswered.insert(request.profileID)
        }
        guard request.profileID == server?.profileID, request.path == target, phase == .loading
        else { return }
        guard nodes != nil else {
            if !everAnswered.contains(request.profileID), request.path.hasPrefix("/"), trail.isEmpty {
                target = "."
                location = nil
                rebuild()
                return
            }
            phase = .failed(
                everAnswered.contains(request.profileID) ? .missing(request.path) : .cannotList)
            rebuild()
            return
        }
        if let resolved = Self.resolve(request.path, nodes: nodes ?? []) {
            location = resolved
            target = resolved
        } else if location == nil {
            location = request.path == "." ? "~" : request.path
        }
        phase = .ready
        rebuild()
    }

    public mutating func handle(_ command: FolderCommand) -> (
        handled: Bool, outcome: FolderOutcome?
    ) {
        switch command {
        case .up: move(by: -1)
        case .down: move(by: 1)
        case .top: cursor = 0
        case .bottom: cursor = max(0, rows.count - 1)
        case .halfUp: move(by: -Self.halfPage)
        case .halfDown: move(by: Self.halfPage)
        case .descend: descend()
        case .ascend: ascend()
        case .back: back()
        case .home:
            open(home ?? "~")
        case .root: open("/")
        case .refresh: refresh()
        case .complete: complete()
        case .chooseHere:
            guard let server, let choice else { return (true, nil) }
            return (true, .choose(profileID: server.profileID, path: choice))
        case .favoriteHere:
            guard let server, let location else { return (true, nil) }
            return (true, .favorite(profileID: server.profileID, path: location))
        case .nextServer:
            guard servers.count > 1 else { return (true, nil) }
            switchServer(to: (serverIndex + 1) % servers.count)
        case .previousServer:
            guard servers.count > 1 else { return (true, nil) }
            switchServer(to: (serverIndex + servers.count - 1) % servers.count)
        case .clearFilter:
            guard !filter.isEmpty else { return (true, nil) }
            type("")
        case .dismiss:
            return (true, .dismiss)
        }
        return (true, nil)
    }

    /// Carries the person's place across a re-gather — a folder just starred — so the star lands
    /// without the list moving under the cursor.
    public func restated(directories: [String: NewChatDirectories]) -> FolderBrowser {
        var next = self
        next.directories = directories
        next.rebuild()
        if let path = focused?.path, let index = next.rows.firstIndex(where: { $0.path == path }) {
            next.cursor = index
        }
        return next
    }

    // MARK: Private

    private mutating func go(to destination: String) {
        filter = ""
        cursor = 0
        target = destination
        if destination.hasPrefix("/") { location = destination }
        guard let server else { return }
        if cache[Self.key(server.profileID, destination)] != nil {
            phase = .ready
        } else {
            phase = .loading
        }
        rebuild()
    }

    private mutating func descend() {
        let typed = filter.trimmingCharacters(in: .whitespaces)
        if NewChatChooser.isPathLike(typed) {
            open(typed)
            return
        }
        guard let row = focused else { return }
        open(row.path)
    }

    private mutating func ascend() {
        guard let location, let parent = Self.parent(of: location) else { return }
        open(parent)
    }

    private mutating func back() {
        guard let previous = trail.popLast() else { return }
        go(to: previous)
    }

    private mutating func refresh() {
        guard let server else { return }
        cache[Self.key(server.profileID, target)] = nil
        phase = .loading
        rebuild()
    }

    /// Tab: a lone match opens, several complete to what every name shares, the way a shell does.
    private mutating func complete() {
        if rows.count == 1 {
            descend()
            return
        }
        guard !filter.isEmpty else { return }
        let shared = PathCompletion.commonPrefix(of: rows.map(\.name))
        if shared.count > filter.count { type(shared) }
    }

    private mutating func switchServer(to index: Int) {
        if let server, let location { lastLocation[server.profileID] = location }
        serverIndex = index
        trail = []
        filter = ""
        cursor = 0
        location = nil
        target = "."
        phase = .loading
        if let server, let remembered = lastLocation[server.profileID] {
            target = remembered
            location = remembered
        }
        if let server, cache[Self.key(server.profileID, target)] != nil { phase = .ready }
        rebuild()
    }

    private mutating func rebuild() {
        guard let server, phase == .ready, let listed = cache[Self.key(server.profileID, target)]
        else {
            rows = []
            cursor = 0
            return
        }
        let known = directories[server.profileID]
        let favorites = Set(known?.favorites ?? [])
        let working = chatPaths[server.profileID] ?? []
        var built: [(row: FolderRow, tier: FuzzyTier)] = []
        for path in listed {
            let name = NewChatChooser.name(of: path)
            guard let hit = FuzzyRank.hit(filter, in: name), hit.tier != .scattered else {
                continue
            }
            let exact = working.filter { $0 == path }.count
            let below = working.filter { $0.hasPrefix(path + "/") }.count
            built.append(
                (
                    FolderRow(
                        name: name, path: path, highlight: hit.highlight, chats: exact,
                        chatsBelow: below, starred: favorites.contains(path)),
                    hit.tier
                ))
        }
        if filter.isEmpty {
            rows = built.map(\.row)
        } else {
            rows = built.sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                return Self.byName(lhs.row.path, rhs.row.path)
            }.map(\.row)
        }
        cursor = min(cursor, max(0, rows.count - 1))
    }

    private static func key(_ profileID: String, _ path: String) -> String {
        "\(profileID)\u{1}\(path)"
    }

    private static func byName(_ lhs: String, _ rhs: String) -> Bool {
        NewChatChooser.name(of: lhs).localizedCaseInsensitiveCompare(NewChatChooser.name(of: rhs))
            == .orderedAscending
    }

    /// The absolute folder a listing of `path` describes. A listing names its children by absolute
    /// path, so any child's parent is the folder itself — the only way to learn what `.` was.
    static func resolve(_ path: String, nodes: [FileNode]) -> String? {
        if path.hasPrefix("/") { return normalized(path) }
        guard let first = nodes.first else { return nil }
        return parent(of: first.path)
    }

    /// An absolute spelling of a typed or remembered path, tilde expanded when the home is known;
    /// nil when it cannot be said yet.
    static func absolute(_ path: String, home: String? = nil) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") { return normalized(trimmed) }
        guard let home else { return nil }
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return normalized(home + trimmed.dropFirst()) }
        return nil
    }

    /// A path only the server can resolve: its home, or something under it.
    private static func relative(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" || trimmed.hasPrefix("~/") || trimmed == "." { return trimmed }
        return nil
    }

    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func parent(of path: String) -> String? {
        guard path.hasPrefix("/"), path != "/" else { return nil }
        guard let mark = path.lastIndex(of: "/") else { return nil }
        let head = String(path[..<mark])
        return head.isEmpty ? "/" : head
    }

    private static let left: UInt32 = 0xFF51
    private static let right: UInt32 = 0xFF53
    private static let homeKey: UInt32 = 0xFF50

    /// The filter owns the letters, always: a folder is found by typing its name, so the keys
    /// claimed here are the ones a one-line field never wants. Backspace and the side arrows walk
    /// the tree only while the field is empty, which is when they have nothing else to do.
    public static func command(for chord: KeyChord, filterIsEmpty: Bool) -> FolderCommand? {
        if chord.control {
            switch chord.keyval {
            case right: return .nextServer
            case left: return .previousServer
            case Keymap.enter: return .chooseHere
            default: break
            }
            switch Keymap.scalar(chord.keyval) {
            case "n", "j": return .down
            case "p", "k": return .up
            case "d": return .halfDown
            case "u": return .halfUp
            case "s": return .nextServer
            case "b": return .favoriteHere
            case "r": return .refresh
            default: return nil
            }
        }
        if chord.alt {
            switch chord.keyval {
            case Keymap.up: return .ascend
            case left: return .back
            case homeKey: return .home
            default: return nil
            }
        }
        switch chord.keyval {
        case Keymap.up: return .up
        case Keymap.down: return .down
        case Keymap.enter: return .descend
        case Keymap.tab: return chord.shift ? .up : .complete
        case Keymap.escape: return filterIsEmpty ? .dismiss : .clearFilter
        case Keymap.backspace: return filterIsEmpty ? .ascend : nil
        case left: return filterIsEmpty ? .ascend : nil
        case right: return filterIsEmpty ? .descend : nil
        default: return nil
        }
    }
}

/// The browser's rules, checked headlessly so the phone, GTK and AppKit are proved against one
/// set of answers.
public enum FolderBrowserCheck {
    public static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }
        func dir(_ path: String) -> FileNode {
            FileNode(path: path, name: NewChatChooser.name(of: path), isDirectory: true)
        }
        func file(_ path: String) -> FileNode {
            FileNode(path: path, name: NewChatChooser.name(of: path), isDirectory: false)
        }

        let alpha = NewChatServer(
            profileID: "a", name: "alpha", backend: .claudeCode, address: "100.0.0.1:4098")
        let beta = NewChatServer(
            profileID: "b", name: "beta", backend: .claudeCode, address: "100.0.0.2:4098")
        let known = [
            "a": NewChatDirectories(
                favorites: ["/home/m/Dev/starred"], recents: ["/home/m/notes"],
                projects: ["/home/m/Dev/tailscode"])
        ]

        var browser = FolderBrowser(servers: [alpha, beta], directories: known)
        expect(browser.wanted == FolderRequest(profileID: "a", path: "."), "it opens on home")
        expect(browser.location == nil, "and does not guess where that is")
        browser.offer(
            FolderRequest(profileID: "a", path: "."),
            nodes: [
                dir("/home/m/zeta"), dir("/home/m/Dev"), file("/home/m/readme.md"),
                dir("/home/m/alpha"),
            ])
        expect(browser.location == "/home/m", "a listing says what dot was")
        expect(browser.home == "/home/m", "and which folder is home")
        expect(browser.rows.map(\.name) == ["alpha", "Dev", "zeta"], "folders only, A to Z")
        expect(browser.wanted == nil, "an answered folder is not asked again")
        expect(
            browser.crumbs.map(\.title) == ["~"] && browser.crumbs.last?.isCurrent == true,
            "home reads as a tilde")

        browser.open("/home/m/Dev")
        expect(browser.location == "/home/m/Dev", "opening shows the path at once")
        expect(
            browser.wanted == FolderRequest(profileID: "a", path: "/home/m/Dev"),
            "and asks for the folder")
        expect(browser.crumbs.map(\.title) == ["~", "Dev"], "the path grows a crumb")
        browser.offer(
            FolderRequest(profileID: "a", path: "/home/m/Dev"),
            nodes: [dir("/home/m/Dev/tailscode"), dir("/home/m/Dev/starred")])
        expect(
            browser.rows.first { $0.name == "tailscode" }?.starred == false,
            "unstarred folders are plain")
        expect(
            browser.rows.first { $0.name == "starred" }?.starred == true, "starred ones say so")
        expect(browser.canGoBack && browser.canGoUp, "there is a way back")

        _ = browser.handle(.ascend)
        expect(browser.location == "/home/m", "up is the parent")
        expect(browser.wanted == nil, "and a folder already read is not read again")
        expect(browser.rows.count == 3, "its folders are on screen at once")
        _ = browser.handle(.back)
        expect(browser.location == "/home/m/Dev", "back returns along the trail")

        browser.type("star")
        expect(browser.rows.map(\.name) == ["starred"], "typing narrows the folder")
        expect(browser.choice == "/home/m/Dev/starred", "and picks what it narrowed to")
        _ = browser.handle(.descend)
        expect(browser.location == "/home/m/Dev/starred", "enter opens the narrowed folder")
        expect(browser.filter.isEmpty, "and clears the filter")
        browser.offer(FolderRequest(profileID: "a", path: "/home/m/Dev/starred"), nodes: [])
        expect(browser.rows.isEmpty && browser.phase == .ready, "an empty folder is a place to start")
        expect(
            browser.handle(.chooseHere).outcome
                == .choose(profileID: "a", path: "/home/m/Dev/starred"),
            "choose picks the folder on screen")
        expect(
            browser.handle(.favoriteHere).outcome
                == .favorite(profileID: "a", path: "/home/m/Dev/starred"),
            "star marks the folder on screen")

        browser.type("/srv/data")
        _ = browser.handle(.descend)
        expect(browser.location == "/srv/data", "a typed path is a jump")
        browser.offer(FolderRequest(profileID: "a", path: "/srv/data"), nodes: nil)
        expect(browser.phase == .failed(.missing("/srv/data")), "a refused folder says which")
        expect(browser.canGoUp, "and the way up stays open")
        _ = browser.handle(.ascend)
        expect(browser.location == "/srv", "so the person is never stranded")

        _ = browser.handle(.nextServer)
        expect(browser.server?.profileID == "b", "servers cycle")
        expect(
            browser.wanted == FolderRequest(profileID: "b", path: "."),
            "the other machine opens on its own home")
        browser.offer(FolderRequest(profileID: "a", path: "/srv"), nodes: [dir("/srv/x")])
        expect(browser.phase == .loading, "an answer from the wrong server changes nothing")
        browser.offer(FolderRequest(profileID: "b", path: "."), nodes: nil)
        expect(browser.phase == .failed(.cannotList), "a server that never answers cannot list")
        _ = browser.handle(.previousServer)
        expect(browser.location == "/srv", "coming back to a server lands where it was left")

        var stale = FolderBrowser(servers: [alpha], directories: [:], start: "/gone/away")
        stale.offer(FolderRequest(profileID: "a", path: "/gone/away"), nodes: nil)
        expect(
            stale.wanted == FolderRequest(profileID: "a", path: ".") && stale.location == nil,
            "a start path nobody answered falls back to home before blaming the server")
        stale.offer(FolderRequest(profileID: "a", path: "."), nodes: nil)
        expect(stale.phase == .failed(.cannotList), "and a server that fails there cannot list")

        var lonely = FolderBrowser(servers: [alpha], directories: [:], start: "/opt/")
        expect(lonely.location == "/opt", "a start path opens there, normalised")
        expect(lonely.handle(.nextServer).outcome == nil, "one server has nothing to cycle")
        lonely.offer(
            FolderRequest(profileID: "a", path: "/opt"),
            nodes: [dir("/opt/projects"), dir("/opt/Programs"), dir("/opt/other")])
        lonely.type("pro")
        _ = lonely.handle(.complete)
        expect(lonely.filter == "pro", "an ambiguous tab adds only what every name shares")
        lonely.type("proj")
        _ = lonely.handle(.complete)
        expect(lonely.location == "/opt/projects", "a lone match opens")
        expect(
            FolderBrowser.normalized("/a/./b/../c/") == "/a/c", "dots and trailing slashes fold")
        expect(FolderBrowser.parent(of: "/") == nil, "the root has no parent")
        expect(FolderBrowser.parent(of: "/a") == "/", "and everything else does")

        let keys: [(UInt32, UInt32, Bool, FolderCommand?)] = [
            (Keymap.enter, 0, true, .descend),
            (Keymap.enter, Keymap.control, false, .chooseHere),
            (Keymap.backspace, 0, true, .ascend),
            (Keymap.backspace, 0, false, nil),
            (Keymap.escape, 0, true, .dismiss),
            (Keymap.escape, 0, false, .clearFilter),
            (UInt32(UnicodeScalar("j").value), 0, false, nil),
            (UInt32(UnicodeScalar("s").value), Keymap.control, false, .nextServer),
            (0xFF51, 0, true, .ascend),
            (0xFF51, 0, false, nil),
        ]
        for (keyval, state, empty, expected) in keys {
            guard let chord = KeyChord.canonical(keyval: keyval, state: state) else {
                failures.append("chord \(keyval) does not canonicalize")
                continue
            }
            expect(
                FolderBrowser.command(for: chord, filterIsEmpty: empty) == expected,
                "key \(keyval)/\(state) empty=\(empty)")
        }
        return failures
    }
}

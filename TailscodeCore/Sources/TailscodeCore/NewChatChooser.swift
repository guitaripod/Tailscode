import CodingAgentKit
import Foundation

/// One machine a new conversation could start on.
public struct NewChatServer: Sendable, Equatable {
    public let profileID: String
    public let name: String
    public let backend: AgentType
    public let address: String
    public let reachable: Bool
    /// Whether this server can list its own folders, which is what makes "Browse…" an offer rather
    /// than a dead row.
    public let canBrowse: Bool
    /// Whether the server is this same machine, which is the one case where a native folder picker
    /// tells the truth.
    public let isLocal: Bool
    /// The levels the server's agent takes for a model its catalog does not describe, as its
    /// backend reports them; nil when nobody has asked, which leaves a recorded level unjudged
    /// rather than dropping one the chat would send.
    public let agentEfforts: [String]?

    public init(
        profileID: String, name: String, backend: AgentType, address: String,
        reachable: Bool = true, canBrowse: Bool = true, isLocal: Bool = false,
        agentEfforts: [String]? = nil
    ) {
        self.profileID = profileID
        self.name = name
        self.backend = backend
        self.address = address
        self.reachable = reachable
        self.canBrowse = canBrowse
        self.isLocal = isLocal
        self.agentEfforts = agentEfforts
    }

    public var title: String { ServerLabel.display(name: name, backend: backend) }
}

/// Where a folder in the list came from. A person picks a directory by recognising it, and what
/// they recognise it as — starred, recent, or "the place four other chats are working" — is worth
/// more than the path itself.
public enum NewChatOrigin: Int, Sendable, Equatable, Comparable, CaseIterable {
    case favorite = 0
    case recent = 1
    case project = 2
    /// The path being typed right now, offered as itself so a folder nobody has used yet is one
    /// Enter away rather than a special case.
    case typed = 3
    /// The server's own folder listing, opened as a screen of its own.
    case browse = 4
    /// A folder read live off the server's disk because the query is a path — the shell's answer,
    /// standing beside the remembered ones.
    case listed = 5

    public static func < (lhs: NewChatOrigin, rhs: NewChatOrigin) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String? {
        switch self {
        case .favorite: return Localized.text("Starred")
        case .recent: return Localized.text("Recent")
        case .project: return nil
        case .typed: return Localized.text("New")
        case .browse: return nil
        case .listed: return nil
        }
    }
}

public struct NewChatRow: Sendable, Equatable {
    public let origin: NewChatOrigin
    public let path: String
    /// The folder's own name, which is what the eye reads first.
    public let title: String
    /// Where it sits, and what else is there.
    public let detail: String
    /// Offsets into `path` that matched what was typed, for highlighting.
    public let highlight: [Int]
    /// How many chats already work here, when any do.
    public let chats: Int

    public init(
        origin: NewChatOrigin, path: String, title: String, detail: String,
        highlight: [Int] = [], chats: Int = 0
    ) {
        self.origin = origin
        self.path = path
        self.title = title
        self.detail = detail
        self.highlight = highlight
        self.chats = chats
    }
}

/// Every folder this device could reasonably offer for one server, gathered from what it already
/// knows rather than asked for again.
public struct NewChatDirectories: Sendable, Equatable {
    public let favorites: [String]
    public let recents: [String]
    public let projects: [String]

    public init(favorites: [String] = [], recents: [String] = [], projects: [String] = []) {
        self.favorites = favorites
        self.recents = recents
        self.projects = projects
    }

    /// The stores the file browser already keeps, plus every directory this server's own chats are
    /// working in — the last of which is the list nobody has to have curated to be useful.
    public static func gather(profileID: String, entries: [SessionEntry]) -> NewChatDirectories {
        let projects = entries
            .filter { $0.profileID == profileID }
            .sorted { $0.session.updatedAt > $1.session.updatedAt }
            .compactMap(\.session.directory)
        var seen = Set<String>()
        return NewChatDirectories(
            favorites: FileBrowserFavorites.all(for: profileID),
            recents: FileBrowserRecents.all(for: profileID),
            projects: projects.filter { seen.insert($0).inserted })
    }
}

/// Which half of the modal the keyboard belongs to. The field has to accept letters — a path is
/// letters — so vim's answer is the honest one: a mode where the letters are text, and a mode
/// where they are verbs, with the way between them written on screen.
public enum NewChatMode: Sendable, Equatable {
    case typing
    case normal
}

/// What a keystroke means to the modal, resolved from the shared `KeyChord` so all three clients
/// bind one keyboard. Two tables, one per mode: while typing only chords the field cannot want are
/// claimed, and in normal mode the letters are the verbs they are everywhere else in this app.
public enum NewChatCommand: Sendable, Equatable {
    case up
    case down
    case top
    case bottom
    case halfUp
    case halfDown
    case activate
    case complete
    case nextServer
    case previousServer
    case enterField
    case leaveField
    case clearField
    case browse
    case favorite
    /// Opens the model dial for the chosen server: the same pill and dial the composer wears.
    case model
    case dismiss
    case pick(Int)
}

/// What the modal hands back to the client.
public enum NewChatOutcome: Sendable, Equatable {
    case start(profileID: String, directory: String?)
    case browse(profileID: String)
    /// The row under the cursor was starred or unstarred; the client persists it and re-gathers.
    case favorite(profileID: String, path: String)
    /// The client opens its model dial for this server; a pick is recorded the way the composer
    /// records one (`NewChatDefaults.record`) and the modal re-reads its defaults.
    case chooseModel(profileID: String)
    case dismiss
}

/// The New Conversation modal, decided once.
///
/// A new chat is two questions — which machine, which folder — and the old form asked them as a
/// text field with six unranked buttons under it, which meant the answer you wanted was either the
/// one already filled in or something you had to type out in full. This asks them as one list: the
/// folders this device already knows about for that server, ranked against what is being typed,
/// with where each came from written on it, and the typed path itself always offered as a row so a
/// folder nobody has used yet needs no special gesture.
///
/// Toolkit-free, and keyboard-first in both modes, because the modal is the fastest thing in the
/// app when it is and the slowest when it is not.
public struct NewChatChooser: Sendable, Equatable {
    public static let visibleLimit = 40
    private static let halfPage = 6

    public let servers: [NewChatServer]
    private let directories: [String: NewChatDirectories]
    private let chatCounts: [String: Int]

    public private(set) var serverIndex: Int
    public private(set) var query: String
    public private(set) var cursor: Int
    public private(set) var mode: NewChatMode
    public private(set) var rows: [NewChatRow]
    public private(set) var listing: NewChatListing?
    /// Whether the modal offers the model dial. A modal asked only where a chat goes, for a
    /// surface that keeps its own model pill, neither claims the key nor says it does.
    public let offersModel: Bool

    /// - Parameter preferredServer: the server the person last started a chat on, pre-chosen rather
    ///   than merely pre-focused — one machine is the overwhelmingly common answer and re-asking it
    ///   every time is the tax this modal is meant to stop charging.
    public init(
        servers: [NewChatServer],
        directories: [String: NewChatDirectories],
        entries: [SessionEntry] = [],
        preferredServer: String? = nil,
        query: String = "",
        mode: NewChatMode = .typing,
        offersModel: Bool = true
    ) {
        self.offersModel = offersModel
        self.servers = servers
        self.directories = directories
        self.chatCounts = Dictionary(
            entries.compactMap { entry in
                entry.session.directory.map { ("\(entry.profileID)\u{1}\($0)", 1) }
            }, uniquingKeysWith: +)
        self.serverIndex =
            preferredServer.flatMap { id in servers.firstIndex { $0.profileID == id } } ?? 0
        self.query = query
        self.cursor = 0
        self.mode = mode
        self.rows = []
        rebuild()
    }

    public var isEmpty: Bool { servers.isEmpty }

    public var server: NewChatServer? {
        servers.indices.contains(serverIndex) ? servers[serverIndex] : servers.first
    }

    public var focused: NewChatRow? {
        rows.indices.contains(cursor) ? rows[cursor] : nil
    }

    /// What Start would use: the folder under the cursor, or the typed path when the list is empty
    /// — never silently nothing when something was typed.
    public var directory: String? {
        if let row = focused, row.origin != .browse { return row.path }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Always the machine and agent by name, even when only one is configured — where a chat will
    /// live is the first thing this modal decides, so it is never left to be inferred from a
    /// window title.
    public var heading: String {
        guard let server else { return Localized.text("No server configured") }
        return server.title
    }

    /// What the chat would open with on the chosen server, re-read on every render so a pick made
    /// elsewhere is already true here.
    public var defaults: NewChatDefaults? {
        server.map {
            NewChatDefaults.resolve(profileID: $0.profileID, agentOptions: $0.agentEfforts)
        }
    }

    /// The keys, on screen, in the mode they work in. A modal that hides its own grammar is a modal
    /// nobody learns.
    public var hint: String {
        switch (mode, offersModel) {
        case (.typing, true):
            return servers.count > 1
                ? Localized.text("⌃n/⌃p walk · tab completes · ⌃s server · ⌃m model · esc for keys")
                : Localized.text("⌃n/⌃p walk · tab completes · ⌃m model · enter starts · esc for keys")
        case (.typing, false):
            return servers.count > 1
                ? Localized.text("⌃n/⌃p walk · tab completes · ⌃s switches server · esc for keys")
                : Localized.text("⌃n/⌃p walk · tab completes · enter starts · esc for keys")
        case (.normal, true):
            return Localized.text("j/k · g/G · 1–9 picks · i types · f stars · m model · enter starts · esc closes")
        case (.normal, false):
            return Localized.text("j/k · g/G · 1–9 picks · i types · f stars · enter starts · esc closes")
        }
    }

    public mutating func type(_ text: String) {
        guard text != query else { return }
        query = text
        mode = .typing
        rebuild()
    }

    /// What the shell half of this modal wants fetched: the folder the typed path sits in, on the
    /// server the chat would start on — asked only while the query is a path, and only once per
    /// folder, because the parent changes at `/` boundaries rather than on every letter.
    public var wantedListing: NewChatListingRequest? {
        guard let server else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parent = PathCompletion.parent(of: trimmed) else { return nil }
        let request = NewChatListingRequest(profileID: server.profileID, parent: parent)
        if let listing, listing.profileID == request.profileID, listing.parent == request.parent {
            return nil
        }
        return request
    }

    /// A listing back from the server. One that no longer answers the query being typed — the
    /// person has moved on, or switched servers — is dropped rather than rendered stale.
    public mutating func offer(_ answered: NewChatListing) {
        guard answered.profileID == server?.profileID else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PathCompletion.parent(of: trimmed) == answered.parent else { return }
        listing = answered
        let path = focused?.path
        rebuild()
        if let path, let index = rows.firstIndex(where: { $0.path == path }) { cursor = index }
    }

    public mutating func chooseServer(_ profileID: String) {
        guard let index = servers.firstIndex(where: { $0.profileID == profileID }) else { return }
        serverIndex = index
        rebuild()
    }

    public mutating func focus(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        cursor = index
    }

    public mutating func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        cursor = max(0, min(rows.count - 1, cursor + delta))
    }

    /// Applies a keystroke. Answers whether the modal claimed it — an unclaimed key belongs to the
    /// text field, which is the rule that keeps typing a path from tripping over the verbs.
    public mutating func handle(_ command: NewChatCommand) -> (
        handled: Bool, outcome: NewChatOutcome?
    ) {
        switch command {
        case .up:
            move(by: -1)
        case .down:
            move(by: 1)
        case .top:
            cursor = 0
        case .bottom:
            cursor = max(0, rows.count - 1)
        case .halfUp:
            move(by: -Self.halfPage)
        case .halfDown:
            move(by: Self.halfPage)
        case .activate:
            return (true, activate())
        case .complete:
            return (true, complete())
        case .nextServer:
            guard servers.count > 1 else { return (true, nil) }
            serverIndex = (serverIndex + 1) % servers.count
            rebuild()
        case .previousServer:
            guard servers.count > 1 else { return (true, nil) }
            serverIndex = (serverIndex + servers.count - 1) % servers.count
            rebuild()
        case .enterField:
            mode = .typing
        case .leaveField:
            mode = .normal
        case .clearField:
            guard !query.isEmpty else { return (true, nil) }
            query = ""
            rebuild()
        case .browse:
            guard let server, server.canBrowse else { return (true, nil) }
            return (true, .browse(profileID: server.profileID))
        case .favorite:
            guard let server, let row = focused, row.origin != .browse else { return (true, nil) }
            return (true, .favorite(profileID: server.profileID, path: row.path))
        case .model:
            guard offersModel else { return (false, nil) }
            guard let server else { return (true, nil) }
            return (true, .chooseModel(profileID: server.profileID))
        case .dismiss:
            return (true, .dismiss)
        case .pick(let index):
            guard rows.indices.contains(index) else { return (true, nil) }
            cursor = index
            return (true, activate())
        }
        return (true, nil)
    }

    public mutating func activate() -> NewChatOutcome? {
        guard let server else { return nil }
        if focused?.origin == .browse {
            return .browse(profileID: server.profileID)
        }
        return .start(profileID: server.profileID, directory: directory)
    }

    /// Tab. At the top of the list it is the shell's tab — the unambiguous rest of the folder
    /// name, case corrected to the disk — because the top row is the typed path itself; a cursor
    /// deliberately walked onto a row keeps the old meaning and adopts that row whole.
    private mutating func complete() -> NewChatOutcome? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if cursor == 0, let listing, listing.profileID == server?.profileID,
            let extended = PathCompletion.completed(query: trimmed, listing: listing),
            extended != trimmed
        {
            query = extended
            rebuild()
            return nil
        }
        guard let row = focused, row.origin != .browse else { return nil }
        query = row.path
        rebuild()
        return nil
    }

    /// Carries the person's place across a re-gather — a folder just starred, a listing that
    /// arrived — so the list changing under the cursor does not move it.
    public func restated(directories: [String: NewChatDirectories], entries: [SessionEntry] = [])
        -> NewChatChooser
    {
        var next = NewChatChooser(
            servers: servers, directories: directories, entries: entries,
            preferredServer: server?.profileID, query: query, mode: mode,
            offersModel: offersModel)
        next.listing = listing
        next.rebuild()
        if let path = focused?.path,
            let index = next.rows.firstIndex(where: { $0.path == path })
        {
            next.focus(index)
        } else {
            next.focus(min(cursor, max(0, next.rows.count - 1)))
        }
        return next
    }

    private mutating func rebuild() {
        rows = Self.build(
            directories: server.map { directories[$0.profileID] ?? NewChatDirectories() }
                ?? NewChatDirectories(),
            query: query, server: server, chatCounts: chatCounts, listing: listing)
        cursor = min(cursor, max(0, rows.count - 1))
    }

    private static func build(
        directories: NewChatDirectories, query: String, server: NewChatServer?,
        chatCounts: [String: Int], listing: NewChatListing?
    ) -> [NewChatRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var ordered: [(origin: NewChatOrigin, path: String, rank: Int)] = []
        var seen = Set<String>()
        func collect(_ paths: [String], as origin: NewChatOrigin) {
            for (rank, path) in paths.enumerated() where seen.insert(path).inserted {
                ordered.append((origin, path, rank))
            }
        }
        collect(directories.favorites, as: .favorite)
        collect(directories.recents, as: .recent)
        collect(directories.projects, as: .project)

        var matched: [(row: NewChatRow, origin: NewChatOrigin, tier: FuzzyTier, rank: Int)] = []
        for candidate in ordered {
            guard
                let hit = FuzzyRank.hit(trimmed, in: candidate.path, separators: ["/", "-", "_"])
            else { continue }
            let chats = server.map { chatCounts["\($0.profileID)\u{1}\(candidate.path)"] ?? 0 } ?? 0
            matched.append(
                (
                    NewChatRow(
                        origin: candidate.origin, path: candidate.path,
                        title: name(of: candidate.path), detail: parent(of: candidate.path),
                        highlight: hit.highlight, chats: chats),
                    candidate.origin, hit.tier, candidate.rank
                ))
        }
        matched.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.origin != rhs.origin { return lhs.origin < rhs.origin }
            return lhs.rank < rhs.rank
        }

        var rows = matched.prefix(visibleLimit).map(\.row)
        if let listing, let profileID = server?.profileID, listing.profileID == profileID {
            var shown = Set(rows.map(\.path))
            for candidate in PathCompletion.matches(query: trimmed, listing: listing)
            where shown.insert(candidate.path).inserted && rows.count < visibleLimit {
                rows.append(
                    NewChatRow(
                        origin: .listed, path: candidate.path, title: candidate.name,
                        detail: parent(of: candidate.path), highlight: candidate.highlight,
                        chats: chatCounts["\(profileID)\u{1}\(candidate.path)"] ?? 0))
            }
        }
        if isPathLike(trimmed), !seen.contains(trimmed), !rows.contains(where: { $0.path == trimmed }) {
            rows.insert(
                NewChatRow(
                    origin: .typed, path: trimmed, title: name(of: trimmed),
                    detail: parent(of: trimmed)), at: 0)
        }
        if server?.canBrowse == true {
            rows.append(
                NewChatRow(
                    origin: .browse, path: "",
                    title: Localized.text("Browse the server…"),
                    detail: server?.address ?? ""))
        }
        return rows
    }

    /// A typed folder is offered as itself once it looks like a path rather than a search: bare
    /// letters are still filtering the list, and offering them as a directory would put a row
    /// reading "dev" above the `~/Dev` the person is halfway to finding.
    static func isPathLike(_ text: String) -> Bool {
        !text.isEmpty && (text.hasPrefix("/") || text.hasPrefix("~") || text.hasPrefix("."))
    }

    static func name(of path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        let last = trimmed.split(separator: "/").last.map(String.init)
        return last ?? trimmed
    }

    static func parent(of path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let mark = trimmed.lastIndex(of: "/") else { return trimmed }
        let head = String(trimmed[..<mark])
        return head.isEmpty ? "/" : head
    }

    private static let left: UInt32 = 0xFF51
    private static let right: UInt32 = 0xFF53

    /// While the field is being typed into, only chords a text field never wants are claimed;
    /// letters, space and the bare arrows that move a caret stay with the field. Escape is the door
    /// to the other mode rather than the way out of the modal, which is what makes the vim half
    /// reachable without a mouse.
    public static func command(for chord: KeyChord, mode: NewChatMode) -> NewChatCommand? {
        if chord.control {
            switch chord.keyval {
            case right: return .nextServer
            case left: return .previousServer
            default: break
            }
            switch Keymap.scalar(chord.keyval) {
            case "n", "j": return .down
            case "p", "k": return .up
            case "d": return .halfDown
            case "u": return .halfUp
            case "s": return .nextServer
            case "b": return .browse
            case "m": return .model
            default: return nil
            }
        }
        guard !chord.alt else { return nil }
        switch chord.keyval {
        case Keymap.up: return .up
        case Keymap.down: return .down
        case Keymap.enter: return .activate
        case Keymap.tab: return chord.shift ? .up : .complete
        case Keymap.escape: return mode == .typing ? .leaveField : .dismiss
        default: break
        }
        guard mode == .normal, let character = Keymap.scalar(chord.keyval) else { return nil }
        switch character {
        case "j": return .down
        case "k": return .up
        case "g": return chord.shift ? .bottom : .top
        case "i", "a", "o", "/": return .enterField
        case "s": return chord.shift ? .previousServer : .nextServer
        case "b": return .browse
        case "f": return .favorite
        case "m": return .model
        case "x": return .clearField
        case "l": return .activate
        default: break
        }
        guard let digit = character.wholeNumberValue, (1...9).contains(digit) else { return nil }
        return .pick(digit - 1)
    }
}

/// What a chat started on a server will open with, said where Start is pressed rather than
/// discovered on the first answer, and the one value the minted chat is then stamped with: the pick
/// this device recorded for that server — the composer's own last-used default, the one a model or
/// level picked anywhere else in the app writes — with the level only where that model takes it,
/// else the server's own default. A fresh session's record names the server's default model, and
/// a chat opened on that record ahead of the pick is how the label and the chat it started came to
/// disagree; `stamp` files this under the new session's own key before it opens, so the pill the
/// chat wears is the pill the modal showed. The model wears its chip where a client colours chips;
/// a device with no pick says the server decides instead of guessing a name.
public struct NewChatDefaults: Sendable, Equatable {
    /// The model the first turn asks for; nil leaves it to the server.
    public let model: ModelSelection?
    /// The level the first turn asks for, already one the model takes; nil leaves it to the
    /// server.
    public let effort: String?
    /// The levels the model takes; nil where nobody can say: the agent's own were never asked,
    /// or the server's own default runs on an agent that names no levels of its own (opencode),
    /// whose model only the server knows. A level is then left unjudged and travels as it is, and
    /// the chat judges it against the model that answers.
    public let options: [String]?
    public let chip: ModelChip?
    public let line: String

    /// - Parameter agentOptions: what the server's backend reports it takes
    ///   (`reasoningEffortOptions`), or nil when the client has not asked it.
    public static func resolve(profileID: String, agentOptions: [String]? = nil) -> NewChatDefaults {
        let model = ModelPreferenceStore.globalModel(forContextID: profileID)
        let catalog = ModelCatalogStore.cached(profileID)
        let judged = agentOptions.flatMap { agent -> [String]? in
            guard model != nil || !agent.isEmpty else { return nil }
            return ModelEffort.options(models: catalog, selection: model, agentOptions: agent)
        }
        return made(
            model: model, effort: EffortPreferenceStore.globalEffort(forContextID: profileID),
            catalog: catalog, options: judged)
    }

    /// The ladder the pill and the dial draw: the model's own levels, or, where nobody can say
    /// which levels the chat's model takes, the one level the first turn will ask for, so the
    /// pill never hides a level the chat then wears.
    public var levels: [String] {
        options ?? effort.map { [$0] } ?? []
    }

    static func made(
        model: ModelSelection?, effort: String?, catalog: [ModelInfo], options: [String]? = nil
    ) -> NewChatDefaults {
        let level = options.map { ModelEffort.surviving(effort, options: $0) } ?? effort
        if let chip = ModelBadge.chip(
            model: model?.modelID, effort: level, providerID: model?.providerID,
            catalog: catalog)
        {
            return NewChatDefaults(
                model: model, effort: level, options: options, chip: chip,
                line: Localized.text("Starts with"))
        }
        if let level, !level.isEmpty {
            return NewChatDefaults(
                model: model, effort: level, options: options, chip: nil,
                line: Localized.text("Starts with the server's default model · %@", level))
        }
        return NewChatDefaults(
            model: model, effort: nil, options: options, chip: nil,
            line: Localized.text("Starts with the server's default model"))
    }

    /// The whole fact as one sentence, for a screen reader or a client with nowhere to hang a
    /// coloured chip.
    public var sentence: String {
        guard let chip else { return line }
        let effort = chip.effort.map { " · \($0)" } ?? ""
        return "\(line) \(chip.name)\(effort)"
    }

    /// Files this under the minted chat's own key before the chat opens, so the composer resolves
    /// the model and level the modal showed ahead of the server's record of its default. A model
    /// or level left to the server stamps nothing, and the chat reads the record as before.
    public func stamp(profileID: String, sessionID: String) {
        QuickAskDefaults.stamp(
            profileID: profileID, sessionID: sessionID, model: model, effort: effort)
    }

    /// A model picked in the modal is the server's last-used default from then on, exactly as a
    /// pick in the composer is: the next new chat opens on it and the modal re-reads it at once.
    /// A pick from another server's catalog is filed against that server, and the client moves the
    /// modal there. Nil is the server's own default, which clears the pick.
    public static func record(model: ModelSelection?, profileID: String) {
        ModelPreferenceStore.recordPick(model, sessionKey: nil, contextID: profileID)
    }

    /// A level picked in the modal, filed the way the composer files one.
    public static func record(effort: String?, profileID: String) {
        EffortPreferenceStore.recordPick(effort, sessionKey: nil, contextID: profileID)
    }

    /// Stamps a chat any surface just minted, before it opens: a party seat with the seat's own
    /// model and level, a quick ask with an aim of its own with that aim, and every other new chat
    /// — the modal's, a sidebar's, an unaimed quick ask's — with what the modal shows for that
    /// server, so no new chat opens on the server's record of its default ahead of the pick the
    /// rest of the app shows.
    public static func stampMinted(
        profileID: String, sessionID: String, agentOptions: [String]?, quickAsk: Bool = false,
        seat: (model: ModelSelection?, effort: String?)? = nil
    ) {
        if let seat {
            QuickAskDefaults.stamp(
                profileID: profileID, sessionID: sessionID, model: seat.model, effort: seat.effort)
        } else if quickAsk, QuickAskDefaults.hasOwnAim(forProfileID: profileID) {
            QuickAskDefaults.stamp(profileID: profileID, sessionID: sessionID)
        } else {
            resolve(profileID: profileID, agentOptions: agentOptions)
                .stamp(profileID: profileID, sessionID: sessionID)
        }
    }
}

/// The modal's rules, checked headlessly so the phone, GTK and AppKit are proved against one set of
/// answers rather than each testing its own widgets.
public enum NewChatChooserCheck {
    public static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let alpha = NewChatServer(
            profileID: "a", name: "alpha", backend: .claudeCode, address: "100.0.0.1:4098",
            isLocal: true)
        let beta = NewChatServer(
            profileID: "b", name: "beta", backend: .openCode, address: "100.0.0.2:4096",
            canBrowse: false)
        let directories = [
            "a": NewChatDirectories(
                favorites: ["/home/m/Dev/starred"],
                recents: ["/home/m/Dev/tailscode", "/home/m/notes"],
                projects: ["/home/m/Dev/tailscode", "/home/m/Dev/kontu"]),
            "b": NewChatDirectories(recents: ["/srv/beta"]),
        ]

        var chooser = NewChatChooser(servers: [alpha, beta], directories: directories)
        expect(chooser.server?.profileID == "a", "the first server leads")
        expect(chooser.rows.first?.origin == .favorite, "a starred folder leads the list")
        expect(
            chooser.rows.map(\.path).filter { $0 == "/home/m/Dev/tailscode" }.count == 1,
            "a folder listed twice is one row")
        expect(chooser.rows.last?.origin == .browse, "a server that can browse offers to")
        expect(chooser.focused?.path == "/home/m/Dev/starred", "the cursor starts on the first row")
        expect(chooser.directory == "/home/m/Dev/starred", "start uses the row under the cursor")

        var preferred = NewChatChooser(
            servers: [alpha, beta], directories: directories, preferredServer: "b")
        expect(preferred.server?.profileID == "b", "the remembered server is pre-chosen")
        expect(
            preferred.rows.contains { $0.origin == .browse } == false,
            "a server that cannot browse does not offer to")
        _ = preferred.handle(.nextServer)
        expect(preferred.server?.profileID == "a", "the server cycles")

        chooser.type("kontu")
        expect(chooser.rows.first?.path == "/home/m/Dev/kontu", "typing ranks the list")
        expect(chooser.rows.first?.highlight.isEmpty == false, "and says which letters it read")
        expect(
            chooser.rows.allSatisfy { $0.origin != .typed },
            "bare letters are a search, not a folder")

        chooser.type("/new/place")
        expect(chooser.rows.first?.origin == .typed, "a typed path is offered as itself")
        expect(chooser.rows.first?.title == "place", "named by its own folder")
        expect(chooser.rows.first?.detail == "/new", "and placed by its parent")
        expect(chooser.directory == "/new/place", "enter would start there")

        chooser.type("")
        expect(chooser.mode == .typing, "typing is the mode the modal opens in")
        _ = chooser.handle(.leaveField)
        expect(chooser.mode == .normal, "esc reaches the verbs")
        _ = chooser.handle(.down)
        _ = chooser.handle(.down)
        expect(chooser.cursor == 2, "j walks")
        _ = chooser.handle(.top)
        expect(chooser.cursor == 0, "gg returns")
        _ = chooser.handle(.enterField)
        expect(chooser.mode == .typing, "i goes back to the field")
        expect(chooser.handle(.complete).outcome == nil, "tab completes rather than starting")
        expect(chooser.query == "/home/m/Dev/starred", "and fills the field from the cursor")

        var shell = NewChatChooser(servers: [alpha, beta], directories: directories)
        expect(shell.wantedListing == nil, "an empty field asks the disk for nothing")
        shell.type("kontu")
        expect(shell.wantedListing == nil, "bare letters are a search, not a walk")
        shell.type("/home/m/De")
        expect(
            shell.wantedListing == NewChatListingRequest(profileID: "a", parent: "/home/m"),
            "a typed path asks for the folder it sits in")
        shell.offer(
            NewChatListing(
                profileID: "a", parent: "/home/m", folders: ["Desktop", "Dev", "notes"]))
        expect(shell.wantedListing == nil, "an answered folder is not asked for again")
        expect(
            shell.rows.contains { $0.origin == .listed && $0.path == "/home/m/Dev" },
            "the disk's own folders join the list")
        expect(
            shell.rows.contains { $0.origin == .listed && $0.path == "/home/m/notes" } == false,
            "but only the ones the letters find")
        expect(shell.rows.first?.origin == .typed, "the typed path still leads")
        _ = shell.handle(.complete)
        expect(shell.query == "/home/m/De", "a tab with nothing shared to add holds still")
        shell.type("/home/m/dev")
        _ = shell.handle(.complete)
        expect(shell.query == "/home/m/Dev/", "a lone match completes whole, case corrected")
        expect(
            shell.wantedListing == NewChatListingRequest(profileID: "a", parent: "/home/m/Dev"),
            "and the walk continues into it")
        shell.offer(NewChatListing(profileID: "a", parent: "/home/m/Dev", folders: [], failed: true))
        expect(shell.wantedListing == nil, "a folder the server refused is not asked for again")
        expect(
            shell.rows.contains { $0.origin == .listed } == false,
            "and offers no rows it cannot vouch for")
        _ = shell.handle(.nextServer)
        expect(
            shell.wantedListing == NewChatListingRequest(profileID: "b", parent: "/home/m/Dev"),
            "switching servers asks the new machine")
        shell.offer(NewChatListing(profileID: "a", parent: "/home/m/Dev", folders: ["stale"]))
        expect(
            shell.rows.contains { $0.origin == .listed } == false,
            "an answer from the wrong server is dropped")

        var lcp = NewChatChooser(servers: [alpha], directories: [:], query: "/srv/pro")
        lcp.offer(
            NewChatListing(
                profileID: "a", parent: "/srv", folders: ["projects", "Programs", "other"]))
        _ = lcp.handle(.complete)
        expect(lcp.query == "/srv/pro", "an ambiguous tab adds only what every match shares")
        expect(
            lcp.rows.contains { $0.path == "/srv/projects" }
                && lcp.rows.contains { $0.path == "/srv/Programs" },
            "and the choices stay on screen, found case-blind")

        var normal = NewChatChooser(servers: [alpha], directories: directories, mode: .normal)
        expect(normal.heading == alpha.title, "one server is still named, never inferred")
        expect(normal.handle(.dismiss).outcome == .dismiss, "esc in normal mode closes")
        let picked = normal.handle(.pick(1)).outcome
        expect(
            picked == .start(profileID: "a", directory: "/home/m/Dev/tailscode"),
            "1–9 starts outright")
        normal.focus(0)
        expect(
            normal.handle(.favorite).outcome
                == .favorite(profileID: "a", path: "/home/m/Dev/starred"),
            "f stars the row under the cursor")
        normal.focus(normal.rows.count - 1)
        expect(normal.handle(.activate).outcome == .browse(profileID: "a"), "enter on browse browses")
        expect(
            normal.handle(.model).outcome == .chooseModel(profileID: "a"),
            "m opens the model dial for the chosen server")
        var whereOnly = NewChatChooser(
            servers: [alpha], directories: directories, mode: .normal, offersModel: false)
        expect(
            whereOnly.handle(.model).handled == false && !whereOnly.hint.contains("m model"),
            "a modal asked only where neither claims m nor names it")

        let keys: [(UInt32, UInt32, NewChatMode, NewChatCommand?)] = [
            (UInt32(UnicodeScalar("j").value), 0, .typing, nil),
            (UInt32(UnicodeScalar("j").value), 0, .normal, .down),
            (UInt32(UnicodeScalar("n").value), Keymap.control, .typing, .down),
            (UInt32(UnicodeScalar("p").value), Keymap.control, .typing, .up),
            (Keymap.escape, 0, .typing, .leaveField),
            (Keymap.escape, 0, .normal, .dismiss),
            (Keymap.enter, 0, .typing, .activate),
            (Keymap.tab, 0, .typing, .complete),
            (UInt32(UnicodeScalar("3").value), 0, .normal, .pick(2)),
            (UInt32(UnicodeScalar("3").value), 0, .typing, nil),
            (UInt32(UnicodeScalar("m").value), 0, .normal, .model),
            (UInt32(UnicodeScalar("m").value), 0, .typing, nil),
            (UInt32(UnicodeScalar("m").value), Keymap.control, .typing, .model),
        ]
        for (keyval, state, mode, expected) in keys {
            guard let chord = KeyChord.canonical(keyval: keyval, state: state) else {
                failures.append("chord \(keyval) does not canonicalize")
                continue
            }
            expect(
                NewChatChooser.command(for: chord, mode: mode) == expected,
                "key \(keyval)/\(state) in \(mode)")
        }

        let recorded = NewChatDefaults.made(
            model: ModelSelection(providerID: "anthropic", modelID: "claude-fable-5"),
            effort: "xhigh", catalog: [])
        expect(
            recorded.chip?.name == "Fable" && recorded.chip?.effort == "xhigh",
            "a recorded pick is named as its chip")
        expect(recorded.sentence == "\(recorded.line) Fable · xhigh", "and read out whole")
        let auto = NewChatDefaults.made(model: nil, effort: nil, catalog: [])
        expect(
            auto.chip == nil && auto.sentence == auto.line,
            "no pick says the server decides rather than guessing")
        let effortOnly = NewChatDefaults.made(model: nil, effort: "high", catalog: [])
        expect(
            effortOnly.chip == nil && effortOnly.line.contains("high"),
            "an effort picked without a model still travels")
        return failures
    }
}

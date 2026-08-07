import CodingAgentKit
import Foundation

/// What a new pane offers before it holds a conversation: which server, then which chat on it.
///
/// A split is the moment a person decides to work in two places at once, and the second place is
/// very often the *other* machine — so the empty pane asks the question the chat list cannot ask,
/// and asks it in that order. One configured server has no question in it, so the chooser skips
/// straight to that server's chats; two or more start on the server step with the pane's own
/// server pre-focused, because splitting to compare the same machine is just as ordinary.
///
/// Toolkit-free on purpose: the rows, the step transitions, the cursor and the key bindings all
/// live here, so GTK and AppKit render the same chooser and behave identically under the keyboard.
public struct PaneChooserServer: Sendable, Equatable {
    public let profileID: String
    public let name: String
    public let backend: AgentType
    public let address: String
    public let reachable: Bool

    public init(
        profileID: String, name: String, backend: AgentType, address: String, reachable: Bool = true
    ) {
        self.profileID = profileID
        self.name = name
        self.backend = backend
        self.address = address
        self.reachable = reachable
    }

    public var title: String { ServerLabel.display(name: name, backend: backend) }
}

/// What activating a row means to the client. The chooser answers the two steps itself; only the
/// outcomes a pane has to act on come back out.
public enum PaneChooserAction: Sendable, Equatable {
    case addServer
    case chooseServer(String)
    case openChat(profileID: String, sessionID: String)
    case newChat(profileID: String)
    case allChats(profileID: String)
    case watch
    case browse
    case back
}

/// A row's one-word state, told in the vocabulary the chat list already uses rather than in a
/// colour each client would have to reinvent.
public enum PaneChooserBadge: Sendable, Equatable {
    case live(String)
    case offline(String)

    public var text: String {
        switch self {
        case .live(let text), .offline(let text): return text
        }
    }
}

public struct PaneChooserRow: Sendable, Equatable {
    public let action: PaneChooserAction
    public let title: String
    public let detail: String
    public let badge: PaneChooserBadge?
    /// What choosing this row costs, when it costs something worth knowing beforehand. Drawn under
    /// the detail and dimmer than it: a row carrying one is still an ordinary row, not a warning.
    public let note: String?
    /// The row that starts something rather than resuming it — drawn with weight, never dimmed.
    public let isPrimary: Bool

    public init(
        action: PaneChooserAction, title: String, detail: String,
        badge: PaneChooserBadge? = nil, note: String? = nil, isPrimary: Bool = false
    ) {
        self.action = action
        self.title = title
        self.detail = detail
        self.badge = badge
        self.note = note
        self.isPrimary = isPrimary
    }
}

/// What a keystroke means to the chooser, resolved from the shared `KeyChord` so both desktops
/// bind the same keys: arrows and `j`/`k` walk, Enter opens, Escape steps back, and 1…9 pick a
/// row outright — the fastest path from `ctrl+w v` to a chat on another machine.
public enum PaneChooserCommand: Sendable, Equatable {
    case up
    case down
    case activate
    case back
    case pick(Int)
}

public struct PaneChooser: Sendable, Equatable {
    public static let chatLimit = 8

    public let servers: [PaneChooserServer]
    private let entries: [SessionEntry]
    public private(set) var serverID: String?
    public private(set) var cursor: Int
    public private(set) var showsEveryChat = false
    /// What is on right now among the channels this device follows, when the app has checked.
    /// Set from outside because the check is a network round trip and the chooser is a value type;
    /// nil simply leaves the watch row saying what it always said.
    public var watchSummary: WatchSummary?

    /// - Parameter preferredServer: the server the pane was already looking at, if any; it is
    ///   pre-focused rather than pre-chosen, so the question is still asked and still answerable
    ///   with one Enter.
    public init(
        servers: [PaneChooserServer], entries: [SessionEntry], preferredServer: String? = nil
    ) {
        self.servers = servers
        self.entries = entries
        cursor = 0
        if servers.count == 1 {
            serverID = servers[0].profileID
        } else if let preferred = preferredServer,
            let index = servers.firstIndex(where: { $0.profileID == preferred })
        {
            cursor = index
        }
    }

    public var isEmpty: Bool { servers.isEmpty }

    public var chosenServer: PaneChooserServer? {
        serverID.flatMap { id in servers.first { $0.profileID == id } }
    }

    public var heading: String {
        if let server = chosenServer { return server.title }
        return servers.isEmpty
            ? Localized.text("No server configured") : Localized.text("Which server?")
    }

    public var hint: String {
        chosenServer == nil
            ? Localized.text("↑↓ or 1–9 · enter chooses")
            : Localized.text("↑↓ or 1–9 · enter opens · esc goes back")
    }

    public var rows: [PaneChooserRow] {
        guard let server = chosenServer else { return serverRows }
        var rows = [
            PaneChooserRow(
                action: .newChat(profileID: server.profileID),
                title: Localized.text("New chat here"),
                detail: server.address, isPrimary: true)
        ]
        let chats = self.chats(on: server.profileID)
        let shown = showsEveryChat ? chats.count : Self.chatLimit
        rows += chats.prefix(shown).map { entry in
            let model = SessionRowModel(
                entry: entry, unreachable: !server.reachable, unread: false, saved: false)
            let badge = model.state.pill?.text
            return PaneChooserRow(
                action: .openChat(profileID: entry.profileID, sessionID: entry.session.id),
                title: model.title, detail: model.detail,
                badge: badge.map { server.reachable ? .live($0) : .offline($0) })
        }
        if chats.count > shown {
            rows.append(
                PaneChooserRow(
                    action: .allChats(profileID: server.profileID),
                    title: Localized.text("Every chat on this server"),
                    detail: Localized.text("%@ more", "\(chats.count - shown)")))
        }
        if servers.count > 1 {
            rows.append(
                PaneChooserRow(
                    action: .back, title: Localized.text("Another server…"),
                    detail: Localized.text("%@ configured", "\(servers.count)")))
        }
        rows.append(watchRow)
        rows.append(Self.browseRow)
        return rows
    }

    /// A pane does not have to hold a conversation. The same question that asks which machine also
    /// offers the one answer that is not a machine at all — a stream, in this pane, in the grid.
    ///
    /// The row reports rather than labels: once this device knows what is on among the channels it
    /// follows, the line under it names them instead of naming the two sites. It still says what it
    /// costs here rather than after the fact — a player repaints its pane every frame, and the
    /// split verbs share that machine.
    var watchRow: PaneChooserRow {
        PaneChooserRow(
            action: .watch, title: Localized.text("Watch something…"),
            detail: watchSummary?.detail ?? Localized.text("Twitch or YouTube, in this pane"),
            badge: watchSummary?.badge.map { .live($0) },
            note: VideoNotice.splitCostLine)
    }

    /// The other answer that is not a machine: a page, in the grid, beside the work it belongs to.
    static let browseRow = PaneChooserRow(
        action: .browse, title: Localized.text("Open a page…"),
        detail: Localized.text("A site, a localhost port, or a search"))

    private var serverRows: [PaneChooserRow] {
        guard !servers.isEmpty else {
            return [
                PaneChooserRow(
                    action: .addServer, title: Localized.text("Add a server…"),
                    detail: Localized.text("Nothing is configured yet"), isPrimary: true)
            ]
        }
        return servers.map { server -> PaneChooserRow in
            let count = chats(on: server.profileID).count
            let live = chats(on: server.profileID).filter { $0.session.isActive == true }.count
            let badge: PaneChooserBadge? =
                !server.reachable
                ? .offline(Localized.text("offline"))
                : live > 0 ? .live(Localized.text("%@ live", "\(live)")) : nil
            return PaneChooserRow(
                action: .chooseServer(server.profileID), title: server.title,
                detail: [server.address, Localized.text("%@ chats", "\(count)")].joined(
                    separator: " · "), badge: badge)
        } + [watchRow, Self.browseRow]
    }

    private func chats(on profileID: String) -> [SessionEntry] {
        entries.filter { $0.profileID == profileID }
    }

    public mutating func move(by delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        cursor = max(0, min(count - 1, cursor + delta))
    }

    public mutating func focus(_ index: Int) {
        guard index >= 0, index < rows.count else { return }
        cursor = index
    }

    /// Activates the row under the cursor. A step within the chooser is taken here and answers
    /// nil; only what the pane must act on — a chat, a new chat, the whole list — comes back.
    public mutating func activate() -> PaneChooserAction? {
        let rows = self.rows
        guard cursor >= 0, cursor < rows.count else { return nil }
        return activate(rows[cursor].action)
    }

    public mutating func activate(_ action: PaneChooserAction) -> PaneChooserAction? {
        switch action {
        case .chooseServer(let id):
            guard servers.contains(where: { $0.profileID == id }) else { return nil }
            serverID = id
            showsEveryChat = false
            cursor = 0
            return nil
        case .allChats:
            showsEveryChat = true
            return nil
        case .back:
            back()
            return nil
        case .openChat, .newChat, .addServer, .watch, .browse:
            return action
        }
    }

    /// Steps back to the server question. One configured server has no question to go back to,
    /// so Escape there belongs to whatever else the app does with it.
    @discardableResult
    public mutating func back() -> Bool {
        guard servers.count > 1, serverID != nil else { return false }
        let previous = serverID
        serverID = nil
        showsEveryChat = false
        cursor = servers.firstIndex { $0.profileID == previous } ?? 0
        return true
    }

    /// Carries the person's place across a re-render: the same server, and the same row if the
    /// listing still has one at that index.
    public func restated(servers: [PaneChooserServer], entries: [SessionEntry]) -> PaneChooser {
        var next = PaneChooser(servers: servers, entries: entries, preferredServer: serverID)
        next.watchSummary = watchSummary
        if let serverID, servers.contains(where: { $0.profileID == serverID }) {
            _ = next.activate(.chooseServer(serverID))
            if showsEveryChat { _ = next.activate(.allChats(profileID: serverID)) }
        }
        next.focus(min(cursor, max(0, next.rows.count - 1)))
        return next
    }

    private static let left: UInt32 = 0xFF51
    private static let right: UInt32 = 0xFF53
    private static let space: UInt32 = 0x20

    public static func command(for chord: KeyChord) -> PaneChooserCommand? {
        guard !chord.control, !chord.alt else { return nil }
        switch chord.keyval {
        case Keymap.up: return .up
        case Keymap.down: return .down
        case Keymap.enter, space, right: return .activate
        case Keymap.escape, left: return .back
        default: break
        }
        guard let character = Keymap.scalar(chord.keyval) else { return nil }
        switch character {
        case "k": return .up
        case "j": return .down
        case "l": return .activate
        case "h": return .back
        default: break
        }
        guard let digit = character.wholeNumberValue, (1...9).contains(digit) else { return nil }
        return .pick(digit - 1)
    }

    /// Applies a keystroke. Answers what the pane must do, and whether the key was the chooser's
    /// at all — an unclaimed key goes on to the app's own shortcut table.
    public mutating func handle(_ command: PaneChooserCommand) -> (
        handled: Bool, action: PaneChooserAction?
    ) {
        switch command {
        case .up:
            move(by: -1)
            return (true, nil)
        case .down:
            move(by: 1)
            return (true, nil)
        case .activate:
            return (true, activate())
        case .back:
            return (back(), nil)
        case .pick(let index):
            guard index < rows.count else { return (true, nil) }
            focus(index)
            return (true, activate())
        }
    }
}

/// The chooser's rules, checked headlessly, in the Kit rather than in one client — both desktops
/// run this from their own `--selftest` so the shared model is proved once and identically.
public enum PaneChooserCheck {
    public static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let alpha = PaneChooserServer(
            profileID: "a", name: "alpha", backend: .claudeCode, address: "100.0.0.1:4098")
        let beta = PaneChooserServer(
            profileID: "b", name: "beta", backend: .openCode, address: "100.0.0.2:4096",
            reachable: false)
        let entries =
            (0..<10).map { index in
                entry(profileID: "a", sessionID: "a\(index)", title: "chat \(index)")
            } + [entry(profileID: "b", sessionID: "b0", title: "beta chat")]

        var two = PaneChooser(servers: [alpha, beta], entries: entries)
        expect(two.chosenServer == nil, "two servers ask the question")
        expect(two.rows.count == 4, "one row per server, plus the two a pane can hold instead")
        expect(two.rows[1].badge == .offline(Localized.text("offline")), "an unreachable server says so")

        var preferred = PaneChooser(servers: [alpha, beta], entries: entries, preferredServer: "b")
        expect(preferred.cursor == 1, "the pane's own server is pre-focused")
        expect(preferred.activate() == nil, "choosing a server is a step, not an outcome")
        expect(preferred.serverID == "b", "the chosen server is the one under the cursor")
        expect(preferred.rows.first?.action == .newChat(profileID: "b"), "new chat leads")
        expect(preferred.rows.count == 5, "one chat on beta, plus new-chat, the way back, and the two")
        expect(preferred.back(), "two servers can be asked again")
        expect(preferred.serverID == nil && preferred.cursor == 1, "back lands on the server left")

        expect(two.handle(.down).handled, "j walks")
        expect(two.cursor == 1, "down moves the cursor")
        expect(two.handle(.up).action == nil, "walking answers nothing")
        _ = two.handle(.activate)
        expect(two.serverID == "a", "enter chooses the focused server")
        expect(two.rows.count == PaneChooser.chatLimit + 5, "eight chats, new chat, more, back, and the two")
        expect(
            two.rows[PaneChooser.chatLimit + 1].action == .allChats(profileID: "a"),
            "the tail is offered rather than hidden")
        _ = two.handle(.pick(PaneChooser.chatLimit + 1))
        expect(two.showsEveryChat, "asking for every chat shows every chat")
        expect(two.rows.count == 14, "ten chats, new chat, back, and the two")
        let picked = two.handle(.pick(1)).action
        expect(picked == .openChat(profileID: "a", sessionID: "a0"), "1-9 opens outright")

        var single = PaneChooser(servers: [alpha], entries: entries)
        expect(single.serverID == "a", "one server is not a question")
        expect(!single.back(), "and has nothing to go back to")
        expect(single.rows.first?.isPrimary == true, "new chat is the primary row")

        let none = PaneChooser(servers: [], entries: [])
        expect(none.rows.first?.action == .addServer, "no server offers to add one")
        expect(
            single.rows.first { $0.action == .watch }?.note == VideoNotice.splitCostLine,
            "the row that offers a stream says what a stream costs the grid")
        expect(
            single.rows.first { $0.action == .browse }?.note == nil,
            "an ordinary row carries no note")

        let commands: [(UInt32, UInt32, PaneChooserCommand?)] = [
            (UInt32(UnicodeScalar("j").value), 0, .down),
            (UInt32(UnicodeScalar("k").value), 0, .up),
            (Keymap.enter, 0, .activate),
            (Keymap.escape, 0, .back),
            (UInt32(UnicodeScalar("3").value), 0, .pick(2)),
            (UInt32(UnicodeScalar("j").value), Keymap.control, nil),
            (UInt32(UnicodeScalar("w").value), 0, nil),
        ]
        for (keyval, state, expected) in commands {
            guard let chord = KeyChord.canonical(keyval: keyval, state: state) else {
                failures.append("chord \(keyval) does not canonicalize")
                continue
            }
            expect(PaneChooser.command(for: chord) == expected, "key \(keyval)/\(state)")
        }
        return failures
    }

    private static func entry(profileID: String, sessionID: String, title: String) -> SessionEntry {
        SessionEntry(
            profileID: profileID, profileName: profileID, host: profileID,
            backendType: .claudeCode,
            session: AgentSession(
                id: sessionID, agentType: .claudeCode, title: title, directory: "/tmp/\(profileID)",
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)))
    }
}

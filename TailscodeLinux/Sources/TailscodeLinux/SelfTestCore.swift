import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The stores are exercised against a throwaway directory rather than the real one: a self-test
    /// that rewrites the user's server list is not a test.
    static func checkStores() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tailscode-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let secrets = FileSecretStore(url: scratch.appendingPathComponent("secrets.json"))
        try secrets.setValue("hunter2", for: "probe")
        guard try secrets.value(for: "probe") == "hunter2" else {
            throw SelfTestFailure("secret did not round-trip")
        }
        try secrets.removeValue(for: "probe")
        guard try secrets.value(for: "probe") == nil else {
            throw SelfTestFailure("secret survived removal")
        }

        let store = LinuxProfileStore(
            secrets: secrets, url: scratch.appendingPathComponent("profiles.json"))
        let profile = ConnectionProfile(
            id: "probe", name: "probe", backend: .claudeCode,
            baseURL: URL(string: "http://127.0.0.1:4098")!, username: "claude")
        try store.save(profile, password: "pw")
        guard try store.profiles().count == 1, try store.password(for: "probe") == "pw" else {
            throw SelfTestFailure("profile did not round-trip")
        }
        try store.delete(id: "probe")
        guard try store.profiles().isEmpty else {
            throw SelfTestFailure("profile survived deletion")
        }
    }

    /// The composer's vim mode, driven the way a person drives it: a starting buffer, a string of
    /// keys, and the text that must come out. It runs in the same `--selftest` as everything else
    /// because a headless box can check an editor perfectly well, and an editor that quietly eats
    /// the wrong word is worse than no editor.
    static func checkCompletion() throws -> Int {
        let commands = ["steam-add-game", "usage", "update-zeroclaw", "flyr", "compact"].map {
            AgentCommand(name: $0, details: "", source: .skill)
        }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("completion case failed: \(label)") }
            checks += 1
        }
        try expect(SlashCompletion.query(in: "/st") == "st", "query reads the word")
        try expect(SlashCompletion.query(in: "/") == "", "bare slash asks for everything")
        try expect(SlashCompletion.query(in: "/goal clear") == nil, "arguments end the query")
        try expect(SlashCompletion.query(in: "plain text") == nil, "prose is not a query")
        try expect(
            SlashCompletion.matches(commands, query: "u").map(\.name) == [
                "update-zeroclaw", "usage",
            ], "prefix matches sort alphabetically")
        try expect(
            SlashCompletion.matches(commands, query: "add").map(\.name) == ["steam-add-game"],
            "a match inside the name still surfaces")
        try expect(
            SlashCompletion.matches(commands, query: "").first?.name == "compact",
            "everything, alphabetically, for a bare slash")
        try expect(
            SlashCompletion.matches(commands, query: "zzz").isEmpty, "no match means no list")

        /// A quick ask is the same box, so it answers the same grammar — except that the chat it
        /// mints has no turns for a transcript command to read, and no project for a repository's
        /// own commands to come from.
        let offered = CommandCatalogStore.forQuickAsk(commands)
        try expect(!offered.contains { $0.name == "compact" }, "a quick ask offers no compaction")
        try expect(offered.count == commands.count - 2, "only the transcript words are dropped")
        try expect(
            QuickAskSend.decide(
                text: "/flyr HEL to ICN", commands: commands, resolvesFromPromptText: false
            ).kind == .command(commands[3], arguments: "HEL to ICN"),
            "a typed command runs as a command")
        try expect(
            QuickAskSend.decide(
                text: "/compact", commands: commands, resolvesFromPromptText: false).kind
                == .prompt, "compaction never survives the quick ask's own catalog")
        try expect(
            QuickAskSend.decide(
                text: "/flyr", commands: commands, resolvesFromPromptText: true).kind == .prompt,
            "an agent that reads its own slash grammar gets the prompt untouched")
        try expect(
            SlashPresentation.noMatchWording("commit", hasProject: false)
                != SlashPresentation.noMatchWording("commit", hasProject: true),
            "a word missing for want of a project says so")
        return checks
    }

    /// The whole keyboard system without a window: the shipped table resolves, canonicalisation
    /// folds keypad and shifted keys, sequences pend and land, the terminal keeps the shell's
    /// chords, approvals win only while one waits, and the rebinding file's grammar applies,
    /// unbinds and reports nonsense.
    static func checkShortcuts() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("shortcut case failed: \(label)") }
            checks += 1
        }
        func chord(
            _ character: Character, control: Bool = false, shift: Bool = false
        ) -> KeyChord? {
            var state: UInt32 = 0
            if control { state |= KeyChord.controlMask }
            if shift { state |= KeyChord.shiftMask }
            guard let scalar = character.unicodeScalars.first else { return nil }
            return KeyChord.canonical(keyval: UInt32(scalar.value), state: state)
        }
        func action(
            _ set: ShortcutSet, _ chord: KeyChord?, _ context: KeyContext,
            pending: [KeyChord] = [], awaiting: Bool = false
        ) -> KeyAction? {
            guard let chord else { return nil }
            let outcome = set.resolve(
                chord, context: context, pending: pending, awaitingApproval: awaiting)
            if case .run(let found) = outcome { return found }
            return nil
        }
        func pends(_ set: ShortcutSet, _ chord: KeyChord?, _ context: KeyContext) -> Bool {
            guard let chord else { return false }
            let outcome = set.resolve(
                chord, context: context, pending: [], awaitingApproval: false)
            if case .pending = outcome { return true }
            return false
        }

        let set = ShortcutSet.build(overrides: [:])
        try expect(
            set.issues.isEmpty, "shipped defaults carry no conflicts: \(set.issues)")

        let parsed = KeySpec.parse("ctrl+shift+h")
        try expect(
            parsed?.chords == [chord("h", control: true, shift: true)].compactMap { $0 },
            "ctrl+shift+h parses to one canonical chord")
        try expect(parsed?.chords.first?.display == "^H", "^H displays as itself")
        try expect(
            KeySpec.parse("normal,insert:ctrl+b")?.contexts == [.normal, .insert],
            "a context prefix limits a spec")
        try expect(
            KeySpec.parse("J")?.chords.first == chord("j", shift: true),
            "an uppercase letter folds to shift plus lowercase")
        try expect(KeySpec.parse("g g")?.chords.count == 2, "a sequence is two chords")
        try expect(KeySpec.parse("bogus+key") == nil, "nonsense refuses to parse")

        try expect(action(set, chord("j"), .normal) == .scrollDown, "j scrolls")
        try expect(action(set, chord("J", shift: true), .normal) == .selectNext, "J selects")
        try expect(action(set, chord("e"), .normal) == .archiveSelected, "e archives")
        try expect(
            action(set, chord("p"), .normal) == .toggleProjectScope, "p scopes to the project")
        try expect(
            action(set, chord("a", shift: true), .normal) == nil,
            "A is spent on a shortcut the machine-wide chord already covers, and the composer's "
                + "vim wants it")
        try expect(action(set, chord("x"), .normal) == .deleteSelected, "x deletes")
        try expect(
            action(set, KeyChord.canonical(keyval: Keymap.enter, state: 0), .normal)
                == .openSelected, "enter opens")
        try expect(
            action(
                set, KeyChord.canonical(keyval: Keymap.keypadEnter, state: Keymap.control),
                .insert) == .send, "keypad enter folds into enter for ^⏎")
        try expect(
            action(
                set, KeyChord.canonical(keyval: Keymap.shiftTab, state: Keymap.shift), .normal)
                == .cycleBackward, "shift+tab cycles backwards")

        try expect(pends(set, chord("g"), .normal), "g waits for a second key")
        let g = chord("g")
        try expect(
            action(set, g, .normal, pending: [g].compactMap { $0 }) == .scrollTop,
            "g g reaches the top")
        try expect(pends(set, chord("y"), .normal), "y waits for a second key")
        let y = chord("y")
        try expect(
            action(set, y, .normal, pending: [y].compactMap { $0 }) == .copySessionID,
            "y y copies the session id")
        try expect(
            action(set, chord("p"), .normal, pending: [y].compactMap { $0 })
                == .copyProjectPath, "y p copies the project path")

        try expect(action(set, chord("f"), .normal) == .findInConversation, "f finds")
        try expect(action(set, chord("f"), .insert) == nil, "bare f types in insert")
        try expect(
            action(set, chord("f", control: true), .insert) == .findInConversation,
            "^f finds while typing")
        try expect(
            action(set, chord("b", control: true), .terminal) == nil,
            "the terminal keeps ^b for the shell")
        try expect(
            action(set, chord("f", control: true), .terminal) == nil,
            "the terminal keeps ^f for the shell")
        try expect(
            action(set, chord("b", control: true, shift: true), .terminal) == .toggleSidebar,
            "^⇧B still toggles the chat list over a shell")
        try expect(
            action(set, chord("j", control: true, shift: true), .terminal)
                == .focus(.terminal), "^⇧J focuses panes from the terminal")
        try expect(
            action(set, KeyChord.canonical(keyval: 0xFFAD, state: Keymap.control), .terminal)
                == .zoomOut, "keypad minus folds into ^- zoom")

        try expect(
            action(set, chord("y"), .normal, awaiting: true) == .allowOnce,
            "y answers a waiting approval")
        try expect(
            action(set, chord("n"), .normal, awaiting: true) == .deny,
            "n denies a waiting approval")
        try expect(
            action(set, chord("n"), .normal) == .newChat,
            "n means a new chat once nothing waits")

        let rebound = ShortcutSet.build(overrides: ["chat.new": ["c"]])
        try expect(action(rebound, chord("c"), .normal) == .newChat, "a rebind lands")
        try expect(action(rebound, chord("n"), .normal) == nil, "a rebind frees the old key")
        let unbound = ShortcutSet.build(overrides: ["chat.new": []])
        try expect(
            action(unbound, chord("n"), .normal) == nil && unbound.issues.isEmpty,
            "an empty rebind unbinds cleanly")
        try expect(
            !ShortcutSet.build(overrides: ["chat.new": ["bogus+key"]]).issues.isEmpty,
            "an unreadable rebind is reported")
        try expect(
            !ShortcutSet.build(overrides: ["chat.filter": ["g"]]).issues.isEmpty,
            "shadowing a sequence's first key is reported")
        try expect(
            ShortcutSet.build(overrides: [:]).helpSections().contains {
                $0.rows.contains { $0.keys.contains("^⏎") }
            }, "the cheatsheet lists effective keys")
        return checks
    }

    /// A chat dragged onto a pane, checked as arithmetic: the payload survives the trip, the
    /// middle of a pane fills it, each edge claims its own side, a pane too narrow to halve only
    /// ever fills, and the highlight covers exactly the half the split will hand over.
    static func checkPaneDrop() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("pane drop: \(label)") }
            checks += 1
        }

        let payload = PaneDragPayload(profileID: "srv-1", sessionID: "ses-9")
        try expect(PaneDragPayload.decode(payload.encoded) == payload, "a payload round-trips")
        try expect(PaneDragPayload.decode("ses-9") == nil, "a bare word is not a chat")
        try expect(
            PaneDragPayload.decode("tailscode-chat\tsrv-1") == nil, "a truncated payload refuses")
        try expect(
            !payload.encoded.contains(" "), "the payload carries no spaces to be split on")

        let wide = (width: 1200.0, height: 800.0)
        func zone(_ x: Double, _ y: Double, _ size: (width: Double, height: Double) = wide)
            -> PaneDropZone
        {
            PaneDropTarget.zone(x: x, y: y, width: size.width, height: size.height)
        }
        try expect(zone(600, 400) == .fill, "the middle opens here")
        try expect(zone(20, 400) == .split(.left), "the left edge splits left")
        try expect(zone(1180, 400) == .split(.right), "the right edge splits right")
        try expect(zone(600, 20) == .split(.top), "the top edge splits above")
        try expect(zone(600, 780) == .split(.bottom), "the bottom edge splits below")
        try expect(zone(10, 10) == .split(.left), "a corner resolves to one edge")
        try expect(
            zone(600, 400, (width: 500, height: 800)) == .fill,
            "a pane with no room to halve only fills")
        try expect(
            zone(10, 400, (width: 500, height: 800)) == .fill,
            "its edges do not offer a split either")
        try expect(
            zone(600, 10, (width: 500, height: 800)) == .split(.top),
            "the axis with room still splits")
        try expect(zone(.nan, 400) == .fill, "a pointer nowhere fills")
        try expect(zone(600, 400, (width: 0, height: 0)) == .fill, "an unallocated pane fills")

        try expect(PaneDropEdge.left.axis == .horizontal, "left halves side by side")
        try expect(PaneDropEdge.bottom.axis == .vertical, "bottom stacks")
        try expect(
            PaneDropEdge.left.placesArrivalFirst && PaneDropEdge.top.placesArrivalFirst,
            "left and top hand the arrival the first half")
        try expect(
            !PaneDropEdge.right.placesArrivalFirst && !PaneDropEdge.bottom.placesArrivalFirst,
            "right and bottom hand it the second")

        let highlight = PaneDropTarget.highlight(
            for: .split(.right), width: 1200, height: 800)
        try expect(
            highlight == SplitRect(x: 600, y: 0, width: 600, height: 800),
            "the highlight covers the half it promises")
        try expect(
            PaneDropTarget.highlight(for: .fill, width: 1200, height: 800)
                == SplitRect(x: 0, y: 0, width: 1200, height: 800),
            "filling highlights the whole pane")
        try expect(
            PaneDropZone.split(.left).caption("port the renderer").contains("port the renderer"),
            "the caption names the chat")
        try expect(
            PaneDropZone.fill.caption(nil) == PaneDropZone.fill.verb,
            "an unnamed chat still says what will happen")

        var layout = SplitLayout()
        let original = layout.focusedPane
        guard
            let arrival = layout.split(original, axis: .horizontal, placingNewFirst: true)
        else { throw SelfTestFailure("pane drop: the tree refused to split") }
        let frames = layout.frames()
        guard let arrived = frames[arrival], let stayed = frames[original] else {
            throw SelfTestFailure("pane drop: the split lost a pane")
        }
        try expect(arrived.x < stayed.x, "a drop on the left edge lands on the left")
        try expect(layout.focusedPane == arrival, "the arriving pane takes the focus")
        try expect(layout.isValid, "the tree stays well formed")
        guard let second = layout.split(arrival, axis: .vertical) else {
            throw SelfTestFailure("pane drop: the tree refused a second split")
        }
        let stacked = layout.frames()
        try expect(
            (stacked[second]?.y ?? 0) > (stacked[arrival]?.y ?? 0),
            "the keyboard's own split still opens second")
        return checks
    }

    /// The pane verbs from the key to the tree: every registered chord resolves to the action Core
    /// dispatches, the action does what the shortcut's words promise, a divider key means the same
    /// step as a pointer, and a strip dragged across panes can never be read as a chat.
    static func checkPaneVerbs() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("pane verbs: \(label)") }
            checks += 1
        }

        let set = ShortcutSet.build(overrides: [:])
        func resolve(_ spec: String) -> KeyAction? {
            guard let (_, chords) = KeySpec.parse(spec) else { return nil }
            var pending: [KeyChord] = []
            for chord in chords {
                switch set.resolve(
                    chord, context: .normal, pending: pending, awaitingApproval: false)
                {
                case .run(let action): return action
                case .pending(let held): pending = held
                case .unbound: return nil
                }
            }
            return nil
        }
        try expect(resolve("ctrl+w a") == .arrangeSplits, "ctrl+w a arranges")
        try expect(resolve("ctrl+w return") == .promoteSplit, "ctrl+w return promotes")
        try expect(resolve("ctrl+w r") == .rotateSplits(true), "ctrl+w r rotates")
        try expect(resolve("ctrl+w shift+r") == .rotateSplits(false), "ctrl+w shift+r rotates back")
        try expect(resolve("ctrl+w shift+h") == .moveSplitToEdge(.left), "shift+h moves far left")
        try expect(resolve("ctrl+w shift+l") == .moveSplitToEdge(.right), "shift+l moves far right")
        try expect(resolve("ctrl+w >") == .resizeSplit(.right), "> widens")
        try expect(resolve("ctrl+w <") == .resizeSplit(.left), "< narrows")
        try expect(resolve("ctrl+w +") == .resizeSplit(.down), "+ makes taller")
        try expect(resolve("ctrl+w -") == .resizeSplit(.up), "- makes shorter")
        try expect(resolve("ctrl+w w") == .cycleSplit(true), "ctrl+w w cycles")

        for group in SplitMenu.groups {
            for id in group.shortcutIDs {
                try expect(!(set.effective[id] ?? []).isEmpty, "the menu row \(id) wears a chord")
            }
        }

        var layout = SplitEven.arrange(ids: (0..<4).map { _ in PaneID() }, as: .sideBySide)!
        let ids = layout.paneIDs
        let placement = layout.placement(in: SplitSize(width: 1200, height: 800))
        var shapes: [SplitArrangement] = []
        for _ in 0..<4 {
            try expect(
                layout.perform(.arrangeSplits, placement: placement) == .restructured,
                "arrange restructures")
            shapes.append(SplitEven.shape(of: layout))
        }
        try expect(
            shapes == [.stacked, .grid, .mainStack, .sideBySide], "arrange walks the cycle")
        try expect(Set(layout.paneIDs) == Set(ids), "arranging keeps every pane")
        try expect(layout.isValid, "the tree stays valid")

        try expect(Gtk.dividerKey(0, large: false) == .back(large: false), "left steps back")
        try expect(Gtk.dividerKey(1, large: true) == .forward(large: true), "shift+right steps far")
        try expect(Gtk.dividerKey(2, large: false) == .lowest, "Home goes to the start")
        try expect(Gtk.dividerKey(3, large: false) == .highest, "End goes to the end")
        try expect(Gtk.dividerKey(9, large: false) == nil, "any other key is not a divider's")

        let strip = PaneMovePayload(pane: ids[1])
        try expect(PaneMovePayload.decode(strip.encoded) == strip, "a strip payload round-trips")
        try expect(PaneDragPayload.decode(strip.encoded) == nil, "a pane is never read as a chat")
        try expect(
            PaneMovePayload.decode(PaneDragPayload(profileID: "srv", sessionID: "ses").encoded)
                == nil,
            "a chat is never read as a pane")
        try expect(
            PaneMovePayload.identifier != PaneDragPayload.identifier,
            "the two travel under different types")
        try expect(
            PaneDropTarget.move(ids[1], onto: ids[1], zone: .fill) == nil,
            "a pane dropped on itself does nothing")
        try expect(
            PaneDropTarget.move(ids[1], onto: ids[0], zone: .fill) == .swap(ids[1], ids[0]),
            "the middle swaps")
        try expect(
            PaneDropTarget.move(ids[1], onto: ids[0], zone: .split(.top))
                == .move(ids[1], onto: ids[0], edge: .top),
            "an edge moves")
        try expect(
            PaneDropZone.fill.moveVerb != PaneDropZone.fill.verb,
            "the highlight names the move, not the open")
        var dropped = layout
        let moved = dropped.apply(.move(ids[1], onto: ids[0], edge: .top))
        try expect(moved && dropped.isValid, "a strip dropped on an edge leaves a valid tree")
        try expect(dropped.focusedPane == ids[1], "the pane that moved takes the focus")
        return checks
    }

    /// Whether this build can actually put a stream in a pane, said plainly: a machine without
    /// libmpv still runs the app, and the slot has to explain itself rather than pretend.
    static var engineState: String {
        tailscode_web_available() != 0 ? "WebKitGTK" : "missing WebKitGTK"
    }

    static var playerState: String {
        tailscode_mpv_available() != 0 ? "available" : "missing libmpv"
    }
}

import Foundation
import TailscodeCore

/// Where a keystroke lands, which decides what it is allowed to mean. Normal owns the letters;
/// insert is any focused text and keeps only deliberate chords; the terminal is stricter still —
/// a shell's own Ctrl+B, Ctrl+E or Ctrl+F must reach the shell, so only Ctrl+Shift moves and zoom
/// live there.
enum KeyContext: String, CaseIterable {
    case normal
    case insert
    case terminal
}

/// One keystroke, canonicalised: letters fold to lowercase with shift carried as a flag, keypad
/// Enter and plus/minus fold into their main-row selves, Shift+Tab's ISO_Left_Tab folds back into
/// Tab, and lock or pointer modifier bits are dropped — so a binding matches the key a person
/// meant rather than the exact bits GDK sent.
struct KeyChord: Hashable {
    let keyval: UInt32
    let control: Bool
    let shift: Bool
    let alt: Bool

    static let controlMask: UInt32 = 1 << 2
    static let shiftMask: UInt32 = 1 << 0
    static let altMask: UInt32 = 1 << 3

    static func canonical(keyval: UInt32, state: UInt32) -> KeyChord? {
        guard !(0xFFE1...0xFFEE).contains(keyval) else { return nil }
        var value = keyval
        var shift = state & shiftMask != 0
        switch value {
        case Keymap.keypadEnter: value = Keymap.enter
        case 0xFFAB: value = UInt32(UnicodeScalar("+").value)
        case 0xFFAD: value = UInt32(UnicodeScalar("-").value)
        case Keymap.shiftTab:
            value = Keymap.tab
            shift = true
        default: break
        }
        if value >= 0x20, value < 0xFF00, let character = Keymap.scalar(value) {
            if character.isLetter {
                if character.isUppercase {
                    let lowered = String(character).lowercased().unicodeScalars.first
                    value = lowered.map { UInt32($0.value) } ?? value
                    shift = true
                }
            } else {
                shift = false
            }
        }
        return KeyChord(
            keyval: value, control: state & controlMask != 0, shift: shift,
            alt: state & altMask != 0)
    }

    var token: String {
        "\(control ? "c" : "")\(shift ? "s" : "")\(alt ? "a" : ""):\(keyval)"
    }

    var display: String {
        var out = ""
        if control { out += "^" }
        if alt { out += "M-" }
        if keyval < 0xFF00, let character = Keymap.scalar(keyval), character.isLetter {
            return out + (shift ? String(character).uppercased() : String(character))
        }
        if shift { out += "⇧" }
        switch keyval {
        case Keymap.enter: return out + "⏎"
        case Keymap.escape: return out + "esc"
        case Keymap.tab: return out + "tab"
        case 0x20: return out + "space"
        case Keymap.up: return out + "↑"
        case Keymap.down: return out + "↓"
        case 0xFF51: return out + "←"
        case 0xFF53: return out + "→"
        default:
            if keyval < 0xFF00, let character = Keymap.scalar(keyval) {
                return out + String(character)
            }
            return out + "0x\(String(keyval, radix: 16))"
        }
    }
}

/// The spec grammar for one binding: modifiers joined with `+`, sequences separated by spaces,
/// an optional `context:` prefix limiting where it applies — `ctrl+shift+h`, `g g`, `J`,
/// `normal,insert:ctrl+b`. This is both the defaults table's language and the rebinding file's.
enum KeySpec {
    static let names: [String: UInt32] = [
        "enter": Keymap.enter, "return": Keymap.enter, "esc": Keymap.escape,
        "escape": Keymap.escape, "tab": Keymap.tab, "space": 0x20,
        "up": Keymap.up, "down": Keymap.down, "left": 0xFF51, "right": 0xFF53,
        "minus": UInt32(UnicodeScalar("-").value), "plus": UInt32(UnicodeScalar("+").value),
        "equal": UInt32(UnicodeScalar("=").value), "slash": UInt32(UnicodeScalar("/").value),
        "question": UInt32(UnicodeScalar("?").value), "colon": UInt32(UnicodeScalar(":").value),
        "comma": UInt32(UnicodeScalar(",").value), "period": UInt32(UnicodeScalar(".").value),
    ]

    static func parse(_ spec: String) -> (contexts: Set<KeyContext>?, chords: [KeyChord])? {
        var body = spec
        var contexts: Set<KeyContext>?
        if let mark = spec.firstIndex(of: ":"), spec.index(after: mark) != spec.endIndex,
            spec[spec.index(after: mark)] != " "
        {
            let head = String(spec[..<mark])
            let parsed = head.split(separator: ",").compactMap {
                KeyContext(rawValue: $0.trimmingCharacters(in: .whitespaces))
            }
            if !parsed.isEmpty, parsed.count == head.split(separator: ",").count {
                contexts = Set(parsed)
                body = String(spec[spec.index(after: mark)...])
            }
        }
        let tokens = body.split(separator: " ").map(String.init)
        guard !tokens.isEmpty, tokens.count <= 2 else { return nil }
        var chords: [KeyChord] = []
        for token in tokens {
            guard let chord = parseChord(token) else { return nil }
            chords.append(chord)
        }
        return (contexts, chords)
    }

    private static func parseChord(_ token: String) -> KeyChord? {
        var parts = token.split(separator: "+", omittingEmptySubsequences: false).map {
            $0.lowercased()
        }
        if parts.count > 1, parts.last == "" {
            parts.removeLast(Array(parts.suffix(2)) == ["", ""] ? 2 : 1)
            parts.append("+")
        }
        guard let key = parts.popLast(), !key.isEmpty else { return nil }
        var control = false
        var shift = false
        var alt = false
        for part in parts {
            switch part {
            case "ctrl", "control": control = true
            case "shift": shift = true
            case "alt", "meta": alt = true
            default: return nil
            }
        }
        var keyval: UInt32
        if let named = names[key] {
            keyval = named
        } else if key.count == 1, let scalar = key.unicodeScalars.first {
            keyval = UInt32(scalar.value)
        } else if token.count == 1, let scalar = token.unicodeScalars.first {
            keyval = UInt32(scalar.value)
        } else {
            return nil
        }
        if token.count == 1, let character = token.first, character.isUppercase {
            shift = true
            keyval = UInt32(String(character).lowercased().unicodeScalars.first?.value ?? 0)
        }
        let state =
            (control ? KeyChord.controlMask : 0) | (shift ? KeyChord.shiftMask : 0)
            | (alt ? KeyChord.altMask : 0)
        return KeyChord.canonical(keyval: keyval, state: state)
    }

    static func display(_ chords: [KeyChord]) -> String {
        chords.map(\.display).joined(separator: " ")
    }
}

enum ShortcutCategory: CaseIterable {
    case chats
    case conversation
    case composer
    case navigate
    case view
    case approvals

    var title: String {
        switch self {
        case .chats: return Localized.text("Chats")
        case .conversation: return Localized.text("Conversation")
        case .composer: return Localized.text("Composer")
        case .navigate: return Localized.text("Focus")
        case .view: return Localized.text("Panes and zoom")
        case .approvals: return Localized.text("When an approval is waiting")
        }
    }
}

/// One action the keyboard can reach: a stable id the rebinding file addresses, the contexts it
/// exists in, and the keys it ships with. The registry is the single source of truth — dispatch,
/// the cheatsheet and the rebinding file all read this table, so they cannot drift apart.
struct ShortcutDefinition {
    let id: String
    let title: String
    let category: ShortcutCategory
    let action: KeyAction
    let contexts: Set<KeyContext>
    let defaults: [String]
    var approval = false
}

enum ShortcutRegistry {
    static let all: [ShortcutDefinition] = [
        .init(
            id: "chat.next", title: Localized.text("Next chat"), category: .chats,
            action: .selectNext, contexts: [.normal], defaults: ["J", "ctrl+n"]),
        .init(
            id: "chat.previous", title: Localized.text("Previous chat"), category: .chats,
            action: .selectPrevious, contexts: [.normal], defaults: ["K", "ctrl+p"]),
        .init(
            id: "chat.open", title: Localized.text("Open the selected chat"), category: .chats,
            action: .openSelected, contexts: [.normal], defaults: ["enter"]),
        .init(
            id: "chat.first", title: Localized.text("First chat"), category: .chats,
            action: .selectFirst, contexts: [.normal], defaults: []),
        .init(
            id: "chat.last", title: Localized.text("Last chat"), category: .chats,
            action: .selectLast, contexts: [.normal], defaults: []),
        .init(
            id: "chat.new", title: Localized.text("New conversation"), category: .chats,
            action: .newChat, contexts: [.normal], defaults: ["n"]),
        .init(
            id: "chat.filter", title: Localized.text("Filter the chat list"), category: .chats,
            action: .search, contexts: [.normal], defaults: ["/"]),
        .init(
            id: "chat.save", title: Localized.text("Save / unsave this chat"), category: .chats,
            action: .toggleSaved, contexts: [.normal], defaults: ["b"]),
        .init(
            id: "chat.archive", title: Localized.text("Archive / unarchive this chat"),
            category: .chats, action: .archiveSelected, contexts: [.normal], defaults: ["e"]),
        .init(
            id: "chat.archiveView", title: Localized.text("Show / leave the archive"),
            category: .chats, action: .toggleArchiveView, contexts: [.normal], defaults: ["E"]),
        .init(
            id: "chat.unread", title: Localized.text("Mark read / unread"), category: .chats,
            action: .toggleUnreadSelected, contexts: [.normal], defaults: ["u"]),
        .init(
            id: "chat.rename", title: Localized.text("Rename this chat"), category: .chats,
            action: .renameSelected, contexts: [.normal], defaults: ["R"]),
        .init(
            id: "chat.fork", title: Localized.text("Fork this chat"), category: .chats,
            action: .forkSelected, contexts: [.normal], defaults: ["F"]),
        .init(
            id: "chat.delete", title: Localized.text("Delete this chat…"), category: .chats,
            action: .deleteSelected, contexts: [.normal], defaults: ["x"]),
        .init(
            id: "chat.copyID", title: Localized.text("Copy the session ID"), category: .chats,
            action: .copySessionID, contexts: [.normal], defaults: ["y y"]),
        .init(
            id: "chat.copyPath", title: Localized.text("Copy the project path"), category: .chats,
            action: .copyProjectPath, contexts: [.normal], defaults: ["y p"]),
        .init(
            id: "scroll.down", title: Localized.text("Scroll down"), category: .conversation,
            action: .scrollDown, contexts: [.normal], defaults: ["j"]),
        .init(
            id: "scroll.up", title: Localized.text("Scroll up"), category: .conversation,
            action: .scrollUp, contexts: [.normal], defaults: ["k"]),
        .init(
            id: "scroll.halfDown", title: Localized.text("Half page down"), category: .conversation,
            action: .halfPageDown, contexts: [.normal], defaults: ["ctrl+d"]),
        .init(
            id: "scroll.halfUp", title: Localized.text("Half page up"), category: .conversation,
            action: .halfPageUp, contexts: [.normal], defaults: ["ctrl+u"]),
        .init(
            id: "scroll.top", title: Localized.text("Top of the conversation"),
            category: .conversation, action: .scrollTop, contexts: [.normal], defaults: ["g g"]),
        .init(
            id: "scroll.bottom", title: Localized.text("Bottom of the conversation"),
            category: .conversation, action: .scrollBottom, contexts: [.normal], defaults: ["G"]),
        .init(
            id: "find.open", title: Localized.text("Find in the conversation"),
            category: .conversation, action: .findInConversation, contexts: [.normal, .insert],
            defaults: ["normal:f", "ctrl+f"]),
        .init(
            id: "turn.stop", title: Localized.text("Stop the running turn"),
            category: .conversation, action: .stop, contexts: [.normal], defaults: ["q", "ctrl+c"]),
        .init(
            id: "refresh", title: Localized.text("Refresh now"), category: .conversation,
            action: .reload, contexts: [.normal], defaults: ["ctrl+r"]),
        .init(
            id: "composer.write", title: Localized.text("Write a message"), category: .composer,
            action: .insert, contexts: [.normal], defaults: ["i", "a", "o"]),
        .init(
            id: "composer.send", title: Localized.text("Send"), category: .composer,
            action: .send, contexts: [.insert], defaults: ["ctrl+enter"]),
        .init(
            id: "mode.leave", title: Localized.text("Back to normal mode"), category: .composer,
            action: .leaveInsert, contexts: [.normal, .insert], defaults: ["escape"]),
        .init(
            id: "palette.commands", title: Localized.text("Slash commands"), category: .composer,
            action: .commandPalette, contexts: [.normal], defaults: [":"]),
        .init(
            id: "focus.chats", title: Localized.text("Focus the chat list"), category: .navigate,
            action: .focus(.chats), contexts: [.normal, .insert, .terminal],
            defaults: ["normal:ctrl+h", "ctrl+shift+h"]),
        .init(
            id: "focus.transcript", title: Localized.text("Focus the transcript"),
            category: .navigate, action: .focus(.transcript),
            contexts: [.normal, .insert, .terminal], defaults: ["normal:ctrl+k", "ctrl+shift+k"]),
        .init(
            id: "focus.files", title: Localized.text("Focus the file tree"), category: .navigate,
            action: .focus(.files), contexts: [.normal, .insert, .terminal],
            defaults: ["normal:ctrl+l", "ctrl+shift+l"]),
        .init(
            id: "focus.terminal", title: Localized.text("Focus the terminal"), category: .navigate,
            action: .focus(.terminal), contexts: [.normal, .insert, .terminal],
            defaults: ["normal:ctrl+j", "ctrl+shift+j"]),
        .init(
            id: "focus.cycle", title: Localized.text("Cycle panes"), category: .navigate,
            action: .cycleForward, contexts: [.normal], defaults: ["tab"]),
        .init(
            id: "focus.cycleBack", title: Localized.text("Cycle panes backwards"),
            category: .navigate, action: .cycleBackward, contexts: [.normal],
            defaults: ["shift+tab"]),
        .init(
            id: "pane.sidebar", title: Localized.text("Show / hide the chat list"),
            category: .view, action: .toggleSidebar, contexts: [.normal, .insert, .terminal],
            defaults: ["normal,insert:ctrl+b", "ctrl+shift+b"]),
        .init(
            id: "pane.files", title: Localized.text("Show / hide the file tree"),
            category: .view, action: .toggleFiles, contexts: [.normal, .insert, .terminal],
            defaults: ["normal,insert:ctrl+e", "ctrl+shift+e"]),
        .init(
            id: "pane.terminal", title: Localized.text("Show / hide the terminal"),
            category: .view, action: .toggleTerminal, contexts: [.normal, .insert, .terminal],
            defaults: ["normal,insert:ctrl+t", "ctrl+shift+t"]),
        .init(
            id: "zoom.in", title: Localized.text("Zoom in"), category: .view, action: .zoomIn,
            contexts: [.normal, .insert, .terminal], defaults: ["ctrl+equal", "ctrl+plus"]),
        .init(
            id: "zoom.out", title: Localized.text("Zoom out"), category: .view, action: .zoomOut,
            contexts: [.normal, .insert, .terminal], defaults: ["ctrl+minus"]),
        .init(
            id: "zoom.reset", title: Localized.text("Reset the zoom"), category: .view,
            action: .zoomReset, contexts: [.normal, .insert, .terminal], defaults: ["ctrl+0"]),
        .init(
            id: "help.toggle", title: Localized.text("Show these shortcuts"), category: .view,
            action: .toggleHelp, contexts: [.normal], defaults: ["?"]),
        .init(
            id: "approve.once", title: Localized.text("Allow once"), category: .approvals,
            action: .allowOnce, contexts: [.normal], defaults: ["y"], approval: true),
        .init(
            id: "approve.always", title: Localized.text("Always allow"), category: .approvals,
            action: .allowAlways, contexts: [.normal], defaults: ["a"], approval: true),
        .init(
            id: "approve.deny", title: Localized.text("Deny"), category: .approvals,
            action: .deny, contexts: [.normal], defaults: ["n"], approval: true),
    ]
}

/// The registry resolved into something a key press can be answered from: per-context chord maps,
/// the prefixes that start a two-key sequence, the approval overlay, and — for the cheatsheet —
/// what every action actually ended up bound to after the rebinding file had its say.
struct ShortcutSet {
    enum Resolution {
        case run(KeyAction)
        case pending([KeyChord])
        case unbound
    }

    let actions: [KeyContext: [String: KeyAction]]
    let prefixes: [KeyContext: Set<String>]
    let approval: [String: KeyAction]
    let effective: [String: [String]]
    let issues: [String]

    static var configURL: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("tailscode", isDirectory: true)
            .appendingPathComponent("keybindings.json")
    }

    static func load() -> ShortcutSet {
        var overrides: [String: [String]] = [:]
        var issues: [String] = []
        if let data = try? Data(contentsOf: configURL) {
            if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let known = Set(ShortcutRegistry.all.map(\.id))
                for (key, value) in parsed where !key.hasPrefix("_") {
                    guard known.contains(key) else {
                        issues.append(Localized.text("unknown shortcut id \"%@\"", key))
                        continue
                    }
                    switch value {
                    case let spec as String:
                        overrides[key] = spec.isEmpty ? [] : [spec]
                    case let specs as [String]:
                        overrides[key] = specs
                    case is NSNull:
                        overrides[key] = []
                    default:
                        issues.append(Localized.text("\"%@\" must be a string, a list or null", key))
                    }
                }
            } else {
                issues.append(Localized.text("keybindings.json is not valid JSON"))
            }
        }
        var set = build(overrides: overrides)
        set = ShortcutSet(
            actions: set.actions, prefixes: set.prefixes, approval: set.approval,
            effective: set.effective, issues: issues + set.issues)
        return set
    }

    static func build(overrides: [String: [String]]) -> ShortcutSet {
        var actions: [KeyContext: [String: KeyAction]] = [:]
        var prefixes: [KeyContext: Set<String>] = [:]
        var owners: [KeyContext: [String: String]] = [:]
        var approval: [String: KeyAction] = [:]
        var effective: [String: [String]] = [:]
        var issues: [String] = []

        for definition in ShortcutRegistry.all {
            let specs = overrides[definition.id] ?? definition.defaults
            var bound: [String] = []
            for spec in specs {
                guard let (specContexts, chords) = KeySpec.parse(spec) else {
                    issues.append(
                        Localized.text("cannot read \"%@\" for %@", spec, definition.id))
                    continue
                }
                bound.append(KeySpec.display(chords))
                if definition.approval {
                    guard chords.count == 1 else {
                        issues.append(
                            Localized.text("%@ takes a single key, not a sequence", definition.id))
                        continue
                    }
                    approval[chords[0].token] = definition.action
                    continue
                }
                let targets = (specContexts ?? definition.contexts)
                    .intersection(definition.contexts)
                let key = chords.map(\.token).joined(separator: ",")
                for context in targets {
                    if let owner = owners[context, default: [:]][key], owner != definition.id {
                        issues.append(
                            Localized.text(
                                "%@ and %@ both want %@", owner, definition.id,
                                KeySpec.display(chords)))
                        continue
                    }
                    owners[context, default: [:]][key] = definition.id
                    actions[context, default: [:]][key] = definition.action
                    if chords.count == 2 {
                        prefixes[context, default: []].insert(chords[0].token)
                    }
                }
            }
            effective[definition.id] = bound
        }
        for (context, starts) in prefixes {
            for start in starts where actions[context]?[start] != nil {
                let name = owners[context]?[start] ?? "?"
                issues.append(
                    Localized.text(
                        "%@ owns a key that also starts a two-key sequence — the sequence never fires",
                        name))
            }
        }
        return ShortcutSet(
            actions: actions, prefixes: prefixes, approval: approval, effective: effective,
            issues: issues)
    }

    func resolve(
        _ chord: KeyChord, context: KeyContext, pending: [KeyChord], awaitingApproval: Bool
    ) -> Resolution {
        if awaitingApproval, context == .normal, !chord.control, !chord.alt, pending.isEmpty,
            let action = approval[chord.token]
        {
            return .run(action)
        }
        let map = actions[context] ?? [:]
        if !pending.isEmpty {
            let key = (pending + [chord]).map(\.token).joined(separator: ",")
            if let action = map[key] { return .run(action) }
        }
        if let action = map[chord.token] { return .run(action) }
        if prefixes[context, default: []].contains(chord.token) { return .pending([chord]) }
        return .unbound
    }

    /// The cheatsheet's model: every bound action, grouped the way the registry groups them, with
    /// the keys it is actually on — overrides included.
    func helpSections() -> [(title: String, rows: [(keys: String, what: String)])] {
        var sections: [(title: String, rows: [(keys: String, what: String)])] = []
        for category in ShortcutCategory.allCases {
            var rows: [(keys: String, what: String)] = []
            for definition in ShortcutRegistry.all where definition.category == category {
                let keys = effective[definition.id] ?? []
                guard !keys.isEmpty else { continue }
                rows.append((keys: keys.joined(separator: " / "), what: definition.title))
            }
            if !rows.isEmpty { sections.append((title: category.title, rows: rows)) }
        }
        return sections
    }

    /// Writes a self-describing starter file if none exists, so "edit the shortcuts" always has
    /// a file to open. Only `_`-prefixed keys are written: the file starts as documentation, and
    /// upgrades keep shipping new defaults to people who never rebound anything.
    static func ensureConfigFile() {
        let url = configURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        var defaults: [String: Any] = [:]
        for definition in ShortcutRegistry.all {
            if definition.defaults.count == 1 {
                defaults[definition.id] = definition.defaults[0]
            } else {
                defaults[definition.id] = definition.defaults
            }
        }
        let payload: [String: Any] = [
            "_readme": [
                "Rebind by id: \"chat.archive\": \"e\", a list for several keys, null to unbind.",
                "Modifiers ctrl+ shift+ alt+ · sequences as two keys with a space: \"g g\".",
                "Named keys: enter escape tab space up down left right minus plus equal.",
                "Limit a binding: \"normal:f\" or \"normal,insert:ctrl+b\" (normal, insert, terminal).",
                "Keys starting with _ are ignored. _defaults shows every id as shipped.",
                "Apply with Settings → Keyboard → Reload, or restart.",
            ],
            "_defaults": defaults,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

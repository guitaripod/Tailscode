import Foundation

/// Which keyboard a chord is being spelled for. The keys are the same; the modifier names, the
/// glyphs and the machinery that claims them are not.
public enum SummonPlatform: Sendable {
    case apple
    case linux
}

/// One chord, held outside the app. A summon is not an in-app shortcut: it is taken from the whole
/// machine, so it is spelled once here and every client hands the same spelling to whatever claims
/// keys on that desktop.
public struct SummonChord: Hashable, Sendable {
    public var control: Bool
    public var alt: Bool
    public var shift: Bool
    /// Command on an Apple keyboard, Super on every other one — the same physical key, and the
    /// only modifier a desktop reserves for itself rather than lending to the focused app.
    public var meta: Bool
    public var key: String

    public init(
        control: Bool = false, alt: Bool = false, shift: Bool = false, meta: Bool = false,
        key: String
    ) {
        self.control = control
        self.alt = alt
        self.shift = shift
        self.meta = meta
        self.key = key.lowercased()
    }

    /// Ctrl+Alt+A: the letter the in-app gesture already uses, inside the two-modifier space a
    /// desktop conventionally leaves to whatever wants a key from the whole machine. It steals no
    /// editing chord, no window-manager verb and nothing a text field can want, and it is spelled
    /// identically on both desktops, so there is one thing to remember rather than two.
    public static let standard = SummonChord(control: true, alt: true, key: "a")

    public var isEmpty: Bool { key.isEmpty }

    public var hasModifier: Bool { control || alt || meta }

    public init?(spec: String) {
        var control = false
        var alt = false
        var shift = false
        var meta = false
        var key: String?
        for raw in spec.lowercased().split(separator: "+") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            switch part {
            case "ctrl", "control", "^": control = true
            case "alt", "option", "opt", "meta-alt": alt = true
            case "shift": shift = true
            case "super", "cmd", "command", "win", "logo", "meta": meta = true
            case "": continue
            default:
                guard key == nil, SummonKeys.info(part) != nil else { return nil }
                key = part
            }
        }
        guard let key else { return nil }
        self.init(control: control, alt: alt, shift: shift, meta: meta, key: key)
    }

    /// The canonical spelling, which is also what is written down: modifiers in a fixed order so
    /// the same chord never persists as two different strings.
    public var spec: String {
        var parts: [String] = []
        if control { parts.append("ctrl") }
        if alt { parts.append("alt") }
        if shift { parts.append("shift") }
        if meta { parts.append("super") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    public func display(on platform: SummonPlatform) -> String {
        let label = SummonKeys.info(key)?.label ?? key.uppercased()
        switch platform {
        case .apple:
            var out = ""
            if control { out += "⌃" }
            if alt { out += "⌥" }
            if shift { out += "⇧" }
            if meta { out += "⌘" }
            return out + label
        case .linux:
            var parts: [String] = []
            if control { parts.append("Ctrl") }
            if alt { parts.append("Alt") }
            if shift { parts.append("Shift") }
            if meta { parts.append("Super") }
            parts.append(label)
            return parts.joined(separator: "+")
        }
    }

    /// What the portal is asked to bind. The trigger grammar is the desktop's, not this app's.
    public var portalTrigger: String {
        var parts: [String] = []
        if control { parts.append("CTRL") }
        if alt { parts.append("ALT") }
        if shift { parts.append("SHIFT") }
        if meta { parts.append("LOGO") }
        parts.append(SummonKeys.info(key)?.portal ?? key)
        return parts.joined(separator: "+")
    }

    public var appleKeyCode: UInt32? { SummonKeys.info(key)?.apple }

    /// Carbon's mask, which predates every modern name for these bits and is still the only way to
    /// claim a key while another app is frontmost without asking for the right to watch every
    /// keystroke on the machine.
    public var appleModifierMask: UInt32 {
        var mask: UInt32 = 0
        if control { mask |= 0x1000 }
        if alt { mask |= 0x0800 }
        if shift { mask |= 0x0200 }
        if meta { mask |= 0x0100 }
        return mask
    }

    public var xBinding: String {
        var parts: [String] = []
        if control { parts.append("Ctrl") }
        if alt { parts.append("Alt") }
        if shift { parts.append("Shift") }
        if meta { parts.append("Mod4") }
        parts.append(SummonKeys.info(key)?.x11 ?? key)
        return parts.joined(separator: "+")
    }

    public var hyprBinding: String {
        var mods: [String] = []
        if control { mods.append("CTRL") }
        if alt { mods.append("ALT") }
        if shift { mods.append("SHIFT") }
        if meta { mods.append("SUPER") }
        return "\(mods.joined(separator: " ")), \(SummonKeys.info(key)?.x11 ?? key)"
    }

    public var gtkAccelerator: String {
        var out = ""
        if control { out += "<Control>" }
        if alt { out += "<Alt>" }
        if shift { out += "<Shift>" }
        if meta { out += "<Super>" }
        return out + (SummonKeys.info(key)?.x11 ?? key)
    }
}

struct SummonKeyInfo: Sendable {
    let name: String
    let label: String
    let portal: String
    let x11: String
    let apple: UInt32?
}

/// The keys a summon may be spelled with, and what each one is called by the four things that have
/// to be told about it.
public enum SummonKeys {
    static let all: [SummonKeyInfo] = {
        let letters: [(String, UInt32)] = [
            ("a", 0), ("b", 11), ("c", 8), ("d", 2), ("e", 14), ("f", 3), ("g", 5), ("h", 4),
            ("i", 34), ("j", 38), ("k", 40), ("l", 37), ("m", 46), ("n", 45), ("o", 31),
            ("p", 35), ("q", 12), ("r", 15), ("s", 1), ("t", 17), ("u", 32), ("v", 9),
            ("w", 13), ("x", 7), ("y", 16), ("z", 6),
        ]
        let digits: [(String, UInt32)] = [
            ("0", 29), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22),
            ("7", 26), ("8", 28), ("9", 25),
        ]
        let functions: [(String, UInt32)] = [
            ("f1", 122), ("f2", 120), ("f3", 99), ("f4", 118), ("f5", 96), ("f6", 97),
            ("f7", 98), ("f8", 100), ("f9", 101), ("f10", 109), ("f11", 103), ("f12", 111),
        ]
        var out: [SummonKeyInfo] = []
        for (name, code) in letters {
            out.append(
                SummonKeyInfo(
                    name: name, label: name.uppercased(), portal: name, x11: name, apple: code))
        }
        for (name, code) in digits {
            out.append(
                SummonKeyInfo(name: name, label: name, portal: name, x11: name, apple: code))
        }
        for (name, code) in functions {
            out.append(
                SummonKeyInfo(
                    name: name, label: name.uppercased(), portal: name.uppercased(),
                    x11: name.uppercased(), apple: code))
        }
        out.append(
            SummonKeyInfo(
                name: "space", label: "Space", portal: "space", x11: "space", apple: 49))
        out.append(
            SummonKeyInfo(
                name: "return", label: "Return", portal: "Return", x11: "Return", apple: 36))
        out.append(SummonKeyInfo(name: "tab", label: "Tab", portal: "Tab", x11: "Tab", apple: 48))
        out.append(
            SummonKeyInfo(
                name: "escape", label: "Esc", portal: "Escape", x11: "Escape", apple: 53))
        out.append(
            SummonKeyInfo(name: "left", label: "←", portal: "Left", x11: "Left", apple: 123))
        out.append(
            SummonKeyInfo(name: "right", label: "→", portal: "Right", x11: "Right", apple: 124))
        out.append(
            SummonKeyInfo(name: "down", label: "↓", portal: "Down", x11: "Down", apple: 125))
        out.append(SummonKeyInfo(name: "up", label: "↑", portal: "Up", x11: "Up", apple: 126))
        out.append(
            SummonKeyInfo(name: "period", label: ".", portal: "period", x11: "period", apple: 47))
        out.append(
            SummonKeyInfo(name: "comma", label: ",", portal: "comma", x11: "comma", apple: 43))
        out.append(
            SummonKeyInfo(name: "slash", label: "/", portal: "slash", x11: "slash", apple: 44))
        out.append(
            SummonKeyInfo(
                name: "grave", label: "`", portal: "grave", x11: "grave", apple: 50))
        out.append(
            SummonKeyInfo(name: "minus", label: "-", portal: "minus", x11: "minus", apple: 27))
        out.append(
            SummonKeyInfo(name: "equal", label: "=", portal: "equal", x11: "equal", apple: 24))
        return out
    }()

    static func info(_ name: String) -> SummonKeyInfo? {
        all.first { $0.name == name.lowercased() }
    }

    /// The key an Apple keyboard press was: Carbon reports a position on the board rather than a
    /// character, which is the right thing to store — a chord is where a hand goes.
    public static func name(appleKeyCode: UInt32) -> String? {
        all.first { $0.apple == appleKeyCode }?.name
    }

    public static var names: [String] { all.map(\.name) }

    static let arrows: Set<String> = ["left", "right", "up", "down"]
}

/// What this app thinks of a chord before anything is asked to bind it. A summon is taken from the
/// whole machine, so the cost of a bad one is not that this app misbehaves — it is that some other
/// program quietly stops answering a key its own users have in their hands. Refusing is therefore
/// part of the feature, and the reason is always the thing that would be taken, never a rule.
public enum SummonJudgement: Sendable, Equatable {
    case fine
    case caution(String)
    case refused(String)

    public var isRefused: Bool {
        if case .refused = self { return true }
        return false
    }

    public var note: String? {
        switch self {
        case .fine: return nil
        case .caution(let text), .refused(let text): return text
        }
    }
}

public enum SummonJudge {
    private static let editing: Set<String> = [
        "a", "c", "v", "x", "z", "s", "f", "w", "q", "n", "t", "p", "o", "r", "y",
    ]

    public static func judge(_ chord: SummonChord, on platform: SummonPlatform)
        -> SummonJudgement
    {
        guard !chord.isEmpty, SummonKeys.info(chord.key) != nil else {
            return .refused(Localized.text("Press the keys you want to summon Tailscode with."))
        }
        let isFunctionKey = chord.key.first == "f" && chord.key.count > 1
        if !chord.hasModifier {
            guard isFunctionKey else {
                return .refused(
                    Localized.text(
                        "A key with no modifier belongs to whatever you are typing into. A summon has to be a chord no text field can want."
                    ))
            }
            return .caution(
                Localized.text(
                    "A bare function key still reaches the app in front of you in some programs."))
        }
        if SummonKeys.arrows.contains(chord.key) {
            if chord.shift {
                return .refused(
                    Localized.text(
                        "Shift and an arrow extends the selection by word in every editor, terminal and text field on this machine. Taking it would break the gesture you use right before you want to ask something."
                    ))
            }
            return .refused(
                Localized.text(
                    "An arrow moves the caret or the workspace on every desktop. Taking it machine-wide breaks either one."
                ))
        }
        if chord.key == "tab" {
            return .refused(
                Localized.text("Tab with a modifier belongs to the window and tab switchers."))
        }
        let single = chord.control != chord.meta && !chord.alt
        let owner = platform == .apple ? chord.meta : chord.control
        if single, owner, !chord.shift, editing.contains(chord.key) {
            let name = chord.display(on: platform)
            return .refused(
                Localized.text(
                    "%@ is an editing shortcut in every app on this machine.", name))
        }
        if chord.key == "space", single {
            return .caution(
                Localized.text(
                    "A single modifier and space is what most launchers and input switchers are on."
                ))
        }
        if !chord.control, !chord.alt, chord.meta, !chord.shift {
            return .caution(
                Localized.text("The desktop itself claims most Super chords before an app sees them.")
            )
        }
        return .fine
    }
}

/// Which desktop is being asked for a key, which decides who has to be asked and in what language.
public enum SummonDesktop: String, Sendable, CaseIterable {
    case kde
    case gnome
    case hyprland
    case sway
    case i3
    case other

    public static func detect(_ environment: [String: String] = ProcessInfo.processInfo.environment)
        -> SummonDesktop
    {
        if environment["HYPRLAND_INSTANCE_SIGNATURE"] != nil { return .hyprland }
        if environment["SWAYSOCK"] != nil { return .sway }
        let names =
            (environment["XDG_CURRENT_DESKTOP"] ?? environment["DESKTOP_SESSION"] ?? "")
            .lowercased()
        if names.contains("hyprland") { return .hyprland }
        if names.contains("sway") { return .sway }
        if names.contains("i3") { return .i3 }
        if names.contains("kde") || names.contains("plasma") { return .kde }
        if names.contains("gnome") { return .gnome }
        return .other
    }

    public var name: String {
        switch self {
        case .kde: return "KDE Plasma"
        case .gnome: return "GNOME"
        case .hyprland: return "Hyprland"
        case .sway: return "Sway"
        case .i3: return "i3"
        case .other: return Localized.text("this desktop")
        }
    }
}

/// The one line a person can put in their own config when this app is not allowed to claim the key
/// itself, in that desktop's own language. Offered as a fact, never as an apology.
public struct SummonRecipe: Sendable, Equatable {
    public let desktop: SummonDesktop
    public let command: String
    public let binding: String
    public let instruction: String

    public static func make(chord: SummonChord, desktop: SummonDesktop, command: String)
        -> SummonRecipe
    {
        switch desktop {
        case .hyprland:
            return SummonRecipe(
                desktop: desktop, command: command,
                binding: "bind = \(chord.hyprBinding), exec, \(command)",
                instruction: Localized.text("Add it to hyprland.conf."))
        case .sway, .i3:
            return SummonRecipe(
                desktop: desktop, command: command,
                binding: "bindsym \(chord.xBinding) exec \(command)",
                instruction: Localized.text(
                    "Add it to your %@ config.", desktop == .sway ? "Sway" : "i3"))
        case .gnome:
            return SummonRecipe(
                desktop: desktop, command: command,
                binding: command,
                instruction: Localized.text(
                    "Settings → Keyboard → Custom Shortcuts, with %@ as the key.",
                    chord.display(on: .linux)))
        case .kde:
            return SummonRecipe(
                desktop: desktop, command: command,
                binding: command,
                instruction: Localized.text(
                    "System Settings → Shortcuts → Tailscode, with %@ as the key.",
                    chord.display(on: .linux)))
        case .other:
            return SummonRecipe(
                desktop: desktop, command: command,
                binding: command,
                instruction: Localized.text(
                    "Bind it to %@ wherever this desktop keeps its shortcuts.",
                    chord.display(on: .linux)))
        }
    }
}

/// What is actually true about the key right now, which is never simply on or off. A chord this
/// app asked for and a chord the machine is holding are two different facts, and the gap between
/// them — a desktop that has been asked and has not answered, a key some other program already
/// owns, a session with nothing to ask — is exactly where a summon that silently does nothing
/// comes from. None of these may read as bound.
public enum SummonState: Sendable, Equatable {
    case off
    case bound(SummonChord, reach: SummonReach)
    case reassigned(SummonChord, trigger: String, reach: SummonReach)
    case awaiting(SummonChord, where: String)
    case taken(SummonChord, by: String?)
    case unavailable(String)

    public var isLive: Bool {
        switch self {
        case .bound, .reassigned: return true
        case .off, .awaiting, .taken, .unavailable: return false
        }
    }

    public var chord: SummonChord? {
        switch self {
        case .bound(let chord, _), .reassigned(let chord, _, _), .awaiting(let chord, _),
            .taken(let chord, _):
            return chord
        case .off, .unavailable: return nil
        }
    }

    public func line(on platform: SummonPlatform) -> String {
        switch self {
        case .off:
            return Localized.text("Off")
        case .bound(let chord, _):
            return Localized.text("%@ anywhere", chord.display(on: platform))
        case .reassigned(_, let trigger, _):
            return Localized.text("%@ anywhere", trigger)
        case .awaiting(let chord, _):
            return Localized.text("Waiting for %@", chord.display(on: platform))
        case .taken(let chord, _):
            return Localized.text("%@ is taken", chord.display(on: platform))
        case .unavailable:
            return Localized.text("Unavailable")
        }
    }

    public func detail(on platform: SummonPlatform) -> String? {
        switch self {
        case .off:
            return Localized.text(
                "Tailscode answers its own window only. Turn this on to ask from anywhere.")
        case .bound(let chord, let reach):
            return Localized.text(
                "Press %@ in any app to ask a question. %@", chord.display(on: platform),
                reach.caveat)
        case .reassigned(let chord, let trigger, let reach):
            return Localized.text(
                "This desktop gave the key to %@ rather than %@. %@", trigger,
                chord.display(on: platform), reach.caveat)
        case .awaiting(let chord, let place):
            return Localized.text(
                "Tailscode asked %@ for %@ and it has not been granted yet. Finish it in that desktop's own shortcut settings, or bind the command below.",
                place, chord.display(on: platform))
        case .taken(let chord, let owner):
            guard let owner else {
                return Localized.text(
                    "Something else on this machine already answers %@. Pick another chord.",
                    chord.display(on: platform))
            }
            return Localized.text(
                "%@ already answers %@. Pick another chord.", owner, chord.display(on: platform))
        case .unavailable(let reason):
            return reason
        }
    }
}

/// How far a claimed key actually reaches, which is not the same question as whether it is
/// claimed. A key the desktop holds on this app's behalf stops existing the moment the app does,
/// and a summon that quietly needs the thing it is summoning is worth saying out loud once rather
/// than discovering on the one morning it is pressed first.
public enum SummonReach: Sendable, Equatable {
    case always
    case whileRunning

    public var caveat: String {
        switch self {
        case .always:
            return Localized.text("Tailscode does not need to be running.")
        case .whileRunning:
            return Localized.text("The desktop holds this key only while Tailscode is running.")
        }
    }
}

/// Whether a key is claimed at all, and which one. Kept beside the quick ask's own memory because
/// it is the same preference — where a question comes from — asked one level further out.
public enum SummonSettings {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    private static let enabledKey = "tailscode.quickask.summon.enabled"
    private static let chordKey = "tailscode.quickask.summon.chord"
    public static let didChange = Notification.Name("tailscode.summon.didChange")

    public static var isEnabled: Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    public static var chord: SummonChord {
        guard let spec = defaults.string(forKey: chordKey), let chord = SummonChord(spec: spec)
        else { return .standard }
        return chord
    }

    public static func setEnabled(_ value: Bool) {
        defaults.set(value, forKey: enabledKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func setChord(_ chord: SummonChord) {
        defaults.set(chord.spec, forKey: chordKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func reset() {
        defaults.removeObject(forKey: chordKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

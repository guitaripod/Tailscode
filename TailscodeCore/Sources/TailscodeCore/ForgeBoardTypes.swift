import Foundation

/// Where one part of the board is in its life. The renderer is a machine that may be asleep, the
/// render is minutes long, and the clips are already on disk — three different waits, so each
/// section says for itself what it is doing rather than sharing one spinner that would lie about
/// two of them.
public enum ForgePhase: Sendable, Equatable {
    case idle
    case checking
    case ready
    case failed(String)
}

/// A thing about the next render somebody can change. Splitting them into a named list rather than
/// letting each client lay out its own form is what keeps a phone, a Mac and a Linux desktop
/// offering the same seven decisions in the same order under the same words.
public enum ForgeField: String, Sendable, Equatable, CaseIterable {
    case endpoint
    case prompt
    case negative
    case sound
    case frame
    case size
    case seconds
    case fps
    case seed

    public var label: String {
        switch self {
        case .endpoint: return Localized.text("Renderer")
        case .prompt: return Localized.text("Prompt")
        case .negative: return Localized.text("Avoid")
        case .sound: return Localized.text("Sound")
        case .frame: return Localized.text("Start from")
        case .size: return Localized.text("Size")
        case .seconds: return Localized.text("Length")
        case .fps: return Localized.text("Smoothness")
        case .seed: return Localized.text("Seed")
        }
    }

    /// The renderer is not a value to type into the board — it is a machine to find, to check and
    /// to remember, which is a surface of its own (`ForgeSetup`). Pressing it opens that surface
    /// rather than a text field, which is the difference between setting something up and editing
    /// a string.
    public var opensSetup: Bool { self == .endpoint }

    /// Whether the board can change this by itself. Words are typed and an address is dictated, so
    /// those go back to the client as something to open; the rest are short lists the board holds,
    /// which is why pressing one of them opens the list rather than walking it blind.
    public var isCyclable: Bool {
        switch self {
        case .size, .seconds, .fps, .seed: return true
        case .endpoint, .prompt, .negative, .sound, .frame: return false
        }
    }

    /// Whether the value is words a person types. The sound is a sentence like the prompt and
    /// the avoid list; the start picture is a thing to pick, and a client opens its own picker.
    public var isTyped: Bool {
        switch self {
        case .prompt, .negative, .sound: return true
        case .endpoint, .frame, .size, .seconds, .fps, .seed: return false
        }
    }

    /// The mark a row wears at its end, so what pressing it does is read before it is pressed: a
    /// setting with a list opens it, and one the client edits discloses. One symbol for the Apple
    /// clients and one glyph for the text ones, so a Mac cannot promise a different act than a
    /// phone for the same row.
    public var affordanceSymbol: String {
        isCyclable ? "chevron.down" : "chevron.right"
    }

    public var affordanceGlyph: String { isCyclable ? "▾" : "›" }

    /// One symbol per decision, so a chip or a row is read down its left edge rather than word by
    /// word. The client owes the drawing; the words are all Core's.
    public var symbol: String {
        switch self {
        case .endpoint: return "desktopcomputer"
        case .prompt: return "text.alignleft"
        case .negative: return "nosign"
        case .sound: return "speaker.wave.2"
        case .frame: return "photo"
        case .size: return "aspectratio"
        case .seconds: return "timer"
        case .fps: return "speedometer"
        case .seed: return "dice"
        }
    }
}

/// What a row is, underneath what it says. Every client draws all five the same way — a title, a
/// line under it, sometimes a badge, sometimes a bar — and only needs the kind to know what
/// pressing it means.
public enum ForgeRowKind: Sendable, Equatable {
    case job
    case field(ForgeField)
    case clip(ForgeEntry)
    case expander(String)
    case note
}

/// What activating a row means to the client. Anything the board can do on its own — walking a
/// setting to its next value, expanding a section, restoring an old recipe into the draft — never
/// reaches here.
public enum ForgeAction: Sendable, Equatable {
    case render(ForgeRecipe)
    case cancel
    case play(ForgeAsset)
    /// A value the board cannot walk: the client opens its own field for it.
    case edit(ForgeField)
    /// A short list the board holds. The client opens it as a menu; picking a row comes back as
    /// `pick`, never as another walk.
    case choose(ForgeField)
    /// There is no renderer yet, so there is nothing to render on. The client asks for an address.
    case configure
    /// There is a renderer and it cannot render yet: the client opens the shared checklist for
    /// images and video, led by video, which says what is missing and hands over the command.
    case checklist
}

/// One row in a setting's menu. The id is what `ForgeBoard.pick` takes back; the title is what the
/// menu shows; the detail is why you would pick it, and may be empty.
public struct ForgeChoice: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let selected: Bool

    public init(id: String, title: String, detail: String = "", selected: Bool) {
        self.id = id
        self.title = title
        self.detail = detail
        self.selected = selected
    }

    public var menuTitle: String { selected ? "✓ \(title)" : title }
}

public struct ForgeRow: Sendable, Equatable, Identifiable {
    public let sectionID: String
    public let kind: ForgeRowKind
    public let title: String
    public let detail: String
    public let badge: String?
    /// A dimmer third line — what a setting means, or why a render stopped. A row carrying one is
    /// still an ordinary row.
    public let note: String?
    /// How far a render has got, when one is running. Nil on every other row, so a client draws a
    /// bar exactly where there is progress to show and nowhere else.
    public let fraction: Double?
    public let isPrimary: Bool
    let enabled: Bool

    init(
        sectionID: String, kind: ForgeRowKind, title: String, detail: String, badge: String? = nil,
        note: String? = nil, fraction: Double? = nil, isPrimary: Bool = false, enabled: Bool = true
    ) {
        self.sectionID = sectionID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.badge = badge
        self.note = note
        self.fraction = fraction
        self.isPrimary = isPrimary
        self.enabled = enabled
    }

    public var id: String { "\(sectionID)/\(anchor)" }

    /// A note is a line the board owed the reader, not something to press; a setting the render in
    /// flight has already consumed is not something to press either. The cursor skips both.
    public var isActivatable: Bool {
        if case .note = kind { return false }
        return enabled
    }

    public var entry: ForgeEntry? {
        if case .clip(let entry) = kind { return entry }
        return nil
    }

    private var anchor: String {
        switch kind {
        case .job: return "job"
        case .field(let field): return "field/\(field.rawValue)"
        case .clip(let entry): return "clip/\(entry.id)"
        case .expander(let id): return "more/\(id)"
        case .note: return "note/\(title)"
        }
    }
}

public struct ForgeSection: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let phase: ForgePhase
    public let rows: [ForgeRow]
    /// How many rows are held back behind the expander — zero when the section shows everything it
    /// has. The expander row already says the number; this is for a client that wants to say it
    /// somewhere else too.
    public let hidden: Int
}

/// What a keystroke means to the board. The same keystream is typing a prompt, so the board claims
/// only what a text field cannot want: the arrows, Enter, Tab, Escape, and control chords somebody
/// pressed on purpose.
public enum ForgeCommand: Sendable, Equatable {
    case up
    case down
    case activate
    case expand
    case render
    case cancel
    case reroll
    case back
}

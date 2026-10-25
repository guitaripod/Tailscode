import Foundation
import TailscodeCore

/// What the capture sheet says about the keys in front of it, worked out from Core's editor and
/// nothing else: whether they can be bound, as which spec, and who would lose them. A value with
/// no view in it, so the words and the buttons they switch can be checked without a window.
struct ShortcutCaptureVerdict: Equatable {
    enum Tone: Equatable {
        case idle
        case free
        case warning
    }

    let spec: String?
    let message: String
    let tone: Tone
    let displaced: [ShortcutEditor.Conflict]

    var canAdd: Bool { spec != nil }
    var takesKeys: Bool { !displaced.isEmpty }

    var addTitle: String {
        takesKeys ? Localized.text("Take it") : Localized.text("Add key")
    }

    static var idle: ShortcutCaptureVerdict {
        ShortcutCaptureVerdict(
            spec: nil,
            message: Localized.text(
                "Press the keys you want. ⌘ belongs to the menu bar and is not available here."),
            tone: .idle, displaced: [])
    }

    /// A ⌘ press is never kept: the menu bar owns those chords, and a binding the registry could
    /// not see would only look as if it worked.
    static var menuBar: ShortcutCaptureVerdict {
        ShortcutCaptureVerdict(
            spec: nil,
            message: Localized.text(
                "⌘ belongs to the menu bar and is not available here. Try Ctrl, Option or Shift."),
            tone: .warning, displaced: [])
    }

    static func unreadable(_ text: String) -> ShortcutCaptureVerdict {
        ShortcutCaptureVerdict(
            spec: nil,
            message: Localized.text(
                "\"%@\" is not a key this app can read. Try ctrl+b, g g, esc or f5.", text),
            tone: .warning, displaced: [])
    }

    /// One press leaves one chord, a second makes it a two-key sequence, and a third starts over
    /// with that press alone.
    static func pressed(_ chord: KeyChord, after chords: [KeyChord]) -> [KeyChord] {
        chords.count == 1 ? chords + [chord] : [chord]
    }

    init(spec: String?, message: String, tone: Tone, displaced: [ShortcutEditor.Conflict]) {
        self.spec = spec
        self.message = message
        self.tone = tone
        self.displaced = displaced
    }

    init(
        chords: [KeyChord], contexts: Set<KeyContext>? = nil, for id: String,
        in bindings: ShortcutBindings
    ) {
        guard !chords.isEmpty else {
            self = .idle
            return
        }
        switch ShortcutEditor.fit(chords, contexts: contexts, for: id) {
        case .refused(let reason):
            self.init(spec: nil, message: reason, tone: .warning, displaced: [])
        case .bound(let spec, let note):
            if bindings.keys(for: id).contains(spec) {
                self.init(
                    spec: nil, message: Localized.text("This action already answers to that key."),
                    tone: .warning, displaced: [])
                return
            }
            let conflicts = ShortcutEditor.conflicts(adding: spec, to: id, in: bindings)
            let verdict = conflicts.isEmpty ? Localized.text("Free") : Self.words(for: conflicts)
            self.init(
                spec: spec, message: [note, verdict].compactMap { $0 }.joined(separator: "\n"),
                tone: conflicts.isEmpty ? .free : .warning, displaced: conflicts)
        }
    }

    /// The spec grammar typed by hand: `normal:ctrl+b`, `g g`, `esc`, `f5`. This is the road for
    /// keys that cannot be pressed into the capture area, because the sheet treats a bare Escape
    /// as "close" and a bare Delete as "clear".
    init(typed text: String, for id: String, in bindings: ShortcutBindings) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            self = .idle
            return
        }
        guard let parsed = KeySpec.parse(trimmed) else {
            self = .unreadable(trimmed)
            return
        }
        self.init(chords: parsed.chords, contexts: parsed.contexts, for: id, in: bindings)
    }

    /// Who has the keys, by the title a person reads in the list, and what taking them does.
    private static func words(for conflicts: [ShortcutEditor.Conflict]) -> String {
        func titles(_ kind: ShortcutEditor.Conflict.Kind) -> String? {
            var seen: [String] = []
            for conflict in conflicts where conflict.kind == kind {
                let quoted = "“\(conflict.title)”"
                if !seen.contains(quoted) { seen.append(quoted) }
            }
            return seen.isEmpty ? nil : ListFormatter.localizedString(byJoining: seen)
        }
        var lines: [String] = []
        if let names = titles(.sameKey) {
            let several = Set(conflicts.filter { $0.kind == .sameKey }.map(\.id)).count > 1
            lines.append(
                several
                    ? Localized.text("%@ also use this key.", names)
                    : Localized.text("%@ also uses this key.", names))
        }
        if let names = titles(.startsSequence) {
            lines.append(
                Localized.text(
                    "A two-key shortcut that starts with this key (%@) would stop working.",
                    names))
        }
        if let names = titles(.beginsWithKey) {
            lines.append(
                Localized.text(
                    "The first key of this sequence is already used on its own (%@), so the sequence could never be reached.",
                    names))
        }
        lines.append(Localized.text("Adding it here takes it from there."))
        return lines.joined(separator: " ")
    }
}

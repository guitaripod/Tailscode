import Foundation

/// Every action's keys as they stand: the shipped table with the person's file laid over it.
/// A value, so an edit is planned against it and judged before a byte is written.
public struct ShortcutBindings: Equatable, Sendable {
    public let specs: [String: [String]]

    public init(overrides: [String: [String]] = [:]) {
        var specs: [String: [String]] = [:]
        for definition in ShortcutRegistry.all {
            specs[definition.id] = overrides[definition.id] ?? definition.defaults
        }
        self.specs = specs
    }

    public static func load() -> ShortcutBindings {
        guard let data = try? Data(contentsOf: ShortcutSet.configURL) else {
            return ShortcutBindings()
        }
        return ShortcutBindings(overrides: ShortcutFile.parse(data).overrides)
    }

    public func keys(for id: String) -> [String] { specs[id] ?? [] }

    public func isCustomized(_ id: String) -> Bool {
        guard let definition = ShortcutRegistry.definition(id) else { return false }
        return keys(for: id) != definition.defaults
    }

    public var customizedCount: Int {
        ShortcutRegistry.all.filter { isCustomized($0.id) }.count
    }
}

/// One key an action answers to, read for display: the chords, and where it applies when that is
/// narrower than where its action does.
public struct ShortcutKey: Hashable, Sendable {
    public let spec: String
    public let chords: [KeyChord]
    public let scope: String?

    public var isReadable: Bool { !chords.isEmpty }
    public var display: String { isReadable ? KeySpec.display(chords) : spec }

    init(spec: String, definition: ShortcutDefinition) {
        self.spec = spec
        let parsed = KeySpec.parse(spec)
        chords = parsed?.chords ?? []
        scope = parsed.flatMap {
            ShortcutEditor.scope(of: $0.contexts, in: definition)
        }
    }
}

/// One row of the rebinding screen.
public struct ShortcutEntry: Sendable {
    public let definition: ShortcutDefinition
    public let keys: [ShortcutKey]
    public let defaultKeys: [ShortcutKey]
    public let isCustomized: Bool

    public var id: String { definition.id }
}

public struct ShortcutSection: Sendable {
    public let category: ShortcutCategory
    public let entries: [ShortcutEntry]
}

/// The rebinding screen's brain, toolkit-free so both desktops draw the same screen from the same
/// facts: what every action is bound to, whether a pressed key may be given to an action at all,
/// who else has it, and the edit that gives it over — written as the file's own changes.
public enum ShortcutEditor {
    public static func sections(bindings: ShortcutBindings, query: String = "")
        -> [ShortcutSection]
    {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return ShortcutCategory.allCases.compactMap { category in
            let entries: [ShortcutEntry] = ShortcutRegistry.all.compactMap { definition in
                guard definition.category == category,
                    !ShortcutSet.unavailable.contains(definition.id)
                else { return nil }
                let entry = ShortcutEntry(
                    definition: definition,
                    keys: bindings.keys(for: definition.id).map {
                        ShortcutKey(spec: $0, definition: definition)
                    },
                    defaultKeys: definition.defaults.map {
                        ShortcutKey(spec: $0, definition: definition)
                    },
                    isCustomized: bindings.isCustomized(definition.id))
                return needle.isEmpty || matches(entry, needle) ? entry : nil
            }
            return entries.isEmpty ? nil : ShortcutSection(category: category, entries: entries)
        }
    }

    private static func matches(_ entry: ShortcutEntry, _ needle: String) -> Bool {
        let haystack =
            [entry.definition.title, entry.definition.id, entry.definition.category.title]
            + entry.keys.flatMap { [$0.display, $0.spec] }
        return haystack.contains { $0.lowercased().contains(needle) }
    }

    /// Where a key applies, said in a few words, when that is less than everywhere its action
    /// works — a bare letter that only means something while nothing is being typed.
    static func scope(of contexts: Set<KeyContext>?, in definition: ShortcutDefinition) -> String? {
        let resolved = (contexts ?? definition.contexts).intersection(definition.contexts)
        guard !resolved.isEmpty, resolved != definition.contexts else { return nil }
        switch resolved {
        case [.normal]: return Localized.text("Only when you are not typing")
        case [.insert]: return Localized.text("Only while you type in the prompt box")
        case [.terminal]: return Localized.text("Only in the terminal")
        case [.normal, .insert]: return Localized.text("Everywhere but the terminal")
        case [.normal, .terminal]: return Localized.text("Not while you type in the prompt box")
        default: return Localized.text("Only while typing and in the terminal")
        }
    }

    public enum Fit: Equatable, Sendable {
        /// The key can be given to the action as `spec`; `note` says so when that is narrower
        /// than the action's own reach.
        case bound(spec: String, note: String?)
        case refused(String)
    }

    /// Whether a pressed key may be given to an action, and as what. A key that a text field or a
    /// shell types would be stolen from whoever is typing, so it is kept out of the contexts where
    /// that happens: a bare `n` becomes "only when you are not typing", and where there is no such
    /// context left the key is refused with the reason, rather than bound and quietly breaking
    /// the prompt box.
    public static func fit(
        _ chords: [KeyChord], contexts requested: Set<KeyContext>? = nil, for id: String
    ) -> Fit {
        guard let definition = ShortcutRegistry.definition(id) else {
            return .refused(Localized.text("That shortcut does not exist"))
        }
        guard let first = chords.first, chords.count <= 2 else {
            return .refused(Localized.text("A shortcut is one key or two in a row"))
        }
        if definition.approval {
            guard chords.count == 1, !first.control, !first.alt else {
                return .refused(Localized.text("A decision takes one key, without Ctrl or Alt"))
            }
            return .bound(spec: KeySpec.spec(chords), note: nil)
        }
        let wanted = (requested ?? definition.contexts).intersection(definition.contexts)
        var allowed = wanted
        var reasons: [String] = []
        if allowed.contains(.insert), first.typesText || first.belongsToTextEditing {
            allowed.remove(.insert)
            reasons.append(
                first.belongsToTextEditing
                    ? Localized.text("the prompt box uses this one to edit text")
                    : Localized.text("in the prompt box it would be typed"))
        }
        if allowed.contains(.terminal), !isTerminalSafe(first) {
            allowed.remove(.terminal)
            reasons.append(Localized.text("the terminal keeps it for the shell"))
        }
        guard !allowed.isEmpty else {
            let why = reasons.first ?? Localized.text("nothing can use it there")
            let advice =
                wanted.contains(.terminal) && !wanted.contains(.insert)
                ? Localized.text("Add Ctrl and Shift.") : Localized.text("Add Ctrl or Alt.")
            return .refused("\(why.prefix(1).uppercased() + why.dropFirst()). \(advice)")
        }
        let narrowed = allowed != definition.contexts
        let note = narrowed ? reasons.first.map { Localized.text("Not everywhere: %@", $0) } : nil
        return .bound(
            spec: KeySpec.spec(chords, contexts: narrowed ? allowed : nil), note: note)
    }

    /// Only Ctrl+Shift chords and the zoom keys live in the terminal; every other control key is
    /// the shell's own.
    private static func isTerminalSafe(_ chord: KeyChord) -> Bool {
        guard chord.control, !chord.alt else { return false }
        if chord.shift { return true }
        return [0x3D, 0x2B, 0x2D, 0x30].contains(chord.keyval)
    }

    public struct Conflict: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// The other action is on this very key.
            case sameKey
            /// The other action is a two-key sequence that begins with this key, which would stop
            /// that sequence ever being reached.
            case startsSequence
            /// This is a two-key sequence beginning with a key the other action is on alone, so
            /// the sequence would never be reached.
            case beginsWithKey
        }

        public let id: String
        public let title: String
        public let spec: String
        public let display: String
        public let kind: Kind
    }

    /// Everyone who would lose a key if `spec` were given to `id`.
    public static func conflicts(
        adding spec: String, to id: String, in bindings: ShortcutBindings
    ) -> [Conflict] {
        guard let definition = ShortcutRegistry.definition(id), let mine = KeySpec.parse(spec)
        else { return [] }
        let myContexts = (mine.contexts ?? definition.contexts).intersection(definition.contexts)
        var found: [Conflict] = []
        for other in ShortcutRegistry.all
        where other.id != id && other.approval == definition.approval
            && !ShortcutSet.unavailable.contains(other.id)
        {
            for otherSpec in bindings.keys(for: other.id) {
                guard let theirs = KeySpec.parse(otherSpec) else { continue }
                let theirContexts = (theirs.contexts ?? other.contexts)
                    .intersection(other.contexts)
                guard definition.approval || !myContexts.isDisjoint(with: theirContexts)
                else { continue }
                let kind: Conflict.Kind?
                if mine.chords == theirs.chords {
                    kind = .sameKey
                } else if definition.approval {
                    kind = nil
                } else if mine.chords.count == 1, theirs.chords.count == 2,
                    theirs.chords[0] == mine.chords[0]
                {
                    kind = .startsSequence
                } else if mine.chords.count == 2, theirs.chords.count == 1,
                    mine.chords[0] == theirs.chords[0]
                {
                    kind = .beginsWithKey
                } else {
                    kind = nil
                }
                if let kind {
                    found.append(
                        Conflict(
                            id: other.id, title: other.title, spec: otherSpec,
                            display: KeySpec.display(theirs.chords), kind: kind))
                }
            }
        }
        return found
    }

    /// An edit, worked out and not yet made: the complete list of keys each touched action ends
    /// with, and the bindings that were taken from other actions to make room.
    public struct Plan: Equatable, Sendable {
        public let changes: [String: [String]]
        public let displaced: [Conflict]

        public var isEmpty: Bool { changes.isEmpty }

        /// The same edit as the file writes it: an action that ends on its shipped keys is
        /// removed from the file rather than pinned there.
        public var fileChanges: [String: ShortcutFile.Change] {
            changes.mapValues { $0 }.reduce(into: [:]) { result, entry in
                let shipped = ShortcutRegistry.definition(entry.key)?.defaults
                result[entry.key] = entry.value == shipped ? .restoreDefault : .bind(entry.value)
            }
        }
    }

    public static func adding(_ spec: String, to id: String, in bindings: ShortcutBindings)
        -> Plan
    {
        guard !bindings.keys(for: id).contains(spec) else {
            return Plan(changes: [:], displaced: [])
        }
        let taken = conflicts(adding: spec, to: id, in: bindings)
        var changes = [id: bindings.keys(for: id) + [spec]]
        for conflict in taken {
            let rest = changes[conflict.id] ?? bindings.keys(for: conflict.id)
            changes[conflict.id] = rest.filter { $0 != conflict.spec }
        }
        return Plan(changes: changes, displaced: taken)
    }

    public static func removing(_ spec: String, from id: String, in bindings: ShortcutBindings)
        -> Plan
    {
        guard bindings.keys(for: id).contains(spec) else {
            return Plan(changes: [:], displaced: [])
        }
        return Plan(
            changes: [id: bindings.keys(for: id).filter { $0 != spec }], displaced: [])
    }

    /// Back to the shipped keys, taking them back from anyone who has since been given one.
    public static func restoring(_ id: String, in bindings: ShortcutBindings) -> Plan {
        guard let definition = ShortcutRegistry.definition(id),
            bindings.isCustomized(id)
        else { return Plan(changes: [:], displaced: []) }
        var changes: [String: [String]] = [id: definition.defaults]
        var displaced: [Conflict] = []
        for spec in definition.defaults {
            for conflict in conflicts(adding: spec, to: id, in: bindings) {
                let rest = changes[conflict.id] ?? bindings.keys(for: conflict.id)
                changes[conflict.id] = rest.filter { $0 != conflict.spec }
                displaced.append(conflict)
            }
        }
        return Plan(changes: changes, displaced: displaced)
    }

    @discardableResult
    public static func apply(_ plan: Plan) throws -> ShortcutBindings {
        try ShortcutFile.write(plan.fileChanges)
        return ShortcutBindings.load()
    }
}

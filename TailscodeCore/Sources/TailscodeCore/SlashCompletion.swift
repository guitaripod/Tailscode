import CodingAgentKit
import Foundation

/// One candidate for a partly-typed `/word`, carrying why it matched so a client can show the
/// person which letters it read. The range is over `command.name`, never the leading slash.
public struct SlashMatch: Sendable, Hashable {
    /// The shared tiers: a slash name and a directory path are found the same way, and the one
    /// ranking they agree on lives in `FuzzyRank`.
    public typealias Kind = FuzzyTier

    public let command: AgentCommand
    public let kind: Kind
    /// The matched letters as offsets into `command.name`, for highlighting. A scattered match
    /// reports every letter it landed on; the others report one contiguous run.
    public let highlight: [Int]

    public init(command: AgentCommand, kind: Kind, highlight: [Int]) {
        self.command = command
        self.kind = kind
        self.highlight = highlight
    }
}

/// What a partly-typed `/word` could become. Prefix matches outrank matches buried inside a name,
/// ties break alphabetically — the order a completion list needs for Tab to feel predictable.
public enum SlashCompletion {
    public static func matches(
        _ commands: [AgentCommand], query: String, recents: [String] = []
    ) -> [AgentCommand] {
        ranked(commands, query: query, recents: recents).map(\.command)
    }

    /// The same order as ``matches(_:query:)``, with the reason each command survived. Commands the
    /// person reached for recently float to the front of their own tier, because a phone types the
    /// same three commands all week — but never across tiers, so a better match always wins.
    public static func ranked(
        _ commands: [AgentCommand], query: String, recents: [String] = []
    ) -> [SlashMatch] {
        let needle = query.lowercased()
        let recency = Dictionary(
            uniqueKeysWithValues: recents.enumerated().map { ($0.element, $0.offset) })
        func rank(_ name: String) -> Int { recency[name] ?? Int.max }

        guard !needle.isEmpty else {
            return
                commands
                .sorted {
                    let (a, b) = (rank($0.name), rank($1.name))
                    return a == b ? $0.name < $1.name : a < b
                }
                .map { SlashMatch(command: $0, kind: .prefix, highlight: []) }
        }

        return
            commands
            .compactMap { command -> SlashMatch? in
                classify(command, needle: needle)
            }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
                let (a, b) = (rank(lhs.command.name), rank(rhs.command.name))
                if a != b { return a < b }
                return lhs.command.name < rhs.command.name
            }
    }

    /// Tried best-first, so a run at the front of a `namespace:name` segment always outranks the
    /// same letters found loose in the middle of some other command.
    private static func classify(_ command: AgentCommand, needle: String) -> SlashMatch? {
        guard let hit = FuzzyRank.hit(needle, in: command.name) else { return nil }
        return SlashMatch(command: command, kind: hit.tier, highlight: hit.highlight)
    }

    /// The query the composer is asking to complete: the whole text is `/word` so far. Past the
    /// first whitespace the person is writing arguments, and nothing should pop up over those.
    public static func query(in text: String) -> String? {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return nil }
        return String(text.dropFirst())
    }
}

/// Which half of a slash invocation the caret is in. Naming a command and filling in its arguments
/// are different jobs and want different help: a list of candidates for the first, the command's
/// own hint for the second.
public enum SlashStage: Sendable, Equatable {
    /// Not a slash draft at all — an ordinary message.
    case none
    /// `/wo` — still choosing which command.
    case naming(query: String)
    /// `/goal ship it` — the command is settled, the rest is its arguments.
    case arguments(name: String, arguments: String)

    public static func of(_ text: String) -> SlashStage {
        guard text.hasPrefix("/"), !text.hasPrefix("//") else { return .none }
        let body = text.dropFirst()
        guard let space = body.firstIndex(where: \.isWhitespace) else {
            return .naming(query: String(body))
        }
        let name = String(body[body.startIndex..<space])
        guard !name.isEmpty else { return .none }
        let arguments = String(body[body.index(after: space)...])
        return .arguments(name: name, arguments: arguments)
    }
}

/// What a typed `/…` should actually do when it is sent. The decision is shared because all three
/// clients owe the same answer: a command the server knows runs as a command, `/compact` always
/// passes through its preflight, and anything the server has never heard of goes out as the words
/// the person wrote — the server is the authority on its own grammar.
///
/// `/design` is the one word this app answers before the server does, and it is not a contradiction
/// of that rule but the reason for it: what comes back is a board this client renders, chooses from
/// and sends follow-ups about, so the brief has to state the convention the board surface reads. A
/// server that has its own design skill still has it — under its own name, in the catalog, one row
/// down — and what it publishes elsewhere is surfaced as the link it is.
public enum SlashDispatch: Sendable, Equatable {
    case compactPreflight(instruction: String)
    case designPreflight(request: String)
    case run(command: AgentCommand, arguments: String?)
    case plainText

    public static let designWord = "design"

    public static func decide(
        text: String,
        commands: [AgentCommand],
        supportsCompaction: Bool,
        resolvesFromPromptText: Bool,
        supportsDesign: Bool = false
    ) -> SlashDispatch {
        let (name, arguments): (String, String)
        switch SlashStage.of(text) {
        case .none:
            return .plainText
        case .naming(let query):
            (name, arguments) = (query, "")
        case .arguments(let typed, let rest):
            (name, arguments) = (typed, rest.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !name.isEmpty else { return .plainText }
        if name == "compact", supportsCompaction {
            return .compactPreflight(instruction: arguments)
        }
        if name == designWord, supportsDesign {
            return .designPreflight(request: arguments)
        }
        guard let command = commands.first(where: { $0.name == name }), !resolvesFromPromptText
        else { return .plainText }
        return .run(command: command, arguments: arguments.isEmpty ? nil : arguments)
    }
}

/// Which commands this device reaches for, most recent first. Small, device-local and shared: the
/// ordering is part of the completion contract, so it cannot live in one client's view code.
public enum SlashRecents {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    static let key = "tailscode.slash.recents"
    private static let capacity = 12

    public static func names() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    public static func record(_ name: String) {
        guard !name.isEmpty else { return }
        var list = names().filter { $0 != name }
        list.insert(name, at: 0)
        defaults.set(Array(list.prefix(capacity)), forKey: key)
    }

    /// The recorded names that still exist in this server's catalog, so a command removed from the
    /// server stops being offered rather than lingering as a row that cannot run.
    public static func surviving(in commands: [AgentCommand]) -> [String] {
        let known = Set(commands.map(\.name))
        return names().filter(known.contains)
    }

    public static func clear() {
        defaults.removeObject(forKey: key)
    }
}

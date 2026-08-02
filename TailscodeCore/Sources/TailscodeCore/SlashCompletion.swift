import CodingAgentKit

/// What a partly-typed `/word` could become. Prefix matches outrank matches buried inside a name,
/// ties break alphabetically — the order a completion list needs for Tab to feel predictable.
public enum SlashCompletion {
    public static func matches(_ commands: [AgentCommand], query: String) -> [AgentCommand] {
        let needle = query.lowercased()
        let named = commands.sorted { $0.name < $1.name }
        guard !needle.isEmpty else { return named }
        let prefixed = named.filter { $0.name.lowercased().hasPrefix(needle) }
        let inner = named.filter {
            let name = $0.name.lowercased()
            return !name.hasPrefix(needle) && name.contains(needle)
        }
        return prefixed + inner
    }

    /// The query the composer is asking to complete: the whole text is `/word` so far. Past the
    /// first whitespace the person is writing arguments, and nothing should pop up over those.
    public static func query(in text: String) -> String? {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return nil }
        return String(text.dropFirst())
    }
}

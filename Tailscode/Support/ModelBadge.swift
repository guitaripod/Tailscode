import CodingAgentKit

/// Compact "which model is driving this chat" text for session cards,
/// e.g. "Fable max" or "Sonnet high". Backends report either an alias
/// ("sonnet") or a full model id ("claude-fable-5"); both collapse to the
/// family name. Sessions without a reported model produce nothing.
enum ModelBadge {
    static func text(for session: AgentSession) -> String? {
        guard let raw = session.model, let name = familyName(raw) else { return nil }
        guard let effort = session.reasoningEffort, !effort.isEmpty else { return name }
        return "\(name) \(effort)"
    }

    private static func familyName(_ raw: String) -> String? {
        let id = raw.lowercased()
        let families = [
            ("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet"),
            ("haiku", "Haiku"), ("grok", "Grok"), ("gpt", "GPT"), ("gemini", "Gemini"),
        ]
        for (needle, name) in families where id.contains(needle) {
            return name
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

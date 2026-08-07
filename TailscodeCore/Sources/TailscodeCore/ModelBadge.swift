import CodingAgentKit

/// Compact "which model is driving this chat" text for session cards,
/// e.g. "Fable max" or "Sonnet high". Backends report either an alias
/// ("sonnet") or a full model id ("claude-fable-5"); both collapse to the
/// family name. Sessions without a reported model produce nothing.
public enum ModelBadge {
    public static func text(for session: AgentSession) -> String? {
        guard let raw = session.model, let name = familyName(raw) else { return nil }
        guard let effort = session.reasoningEffort, !effort.isEmpty else { return name }
        return "\(name) \(effort)"
    }

    /// Chip text for a pending choice: "Opus · max", or "Auto" while the server
    /// is the one deciding.
    public static func label(model: ModelSelection?, effort: String?) -> String {
        let name = model.flatMap { familyName($0.modelID) } ?? Localized.text("Auto")
        guard let effort, !effort.isEmpty else { return name }
        return "\(name) · \(effort)"
    }

    /// The family name alone, for a legend or a table where the effort is not the point.
    public static func shortName(_ raw: String) -> String {
        familyName(raw) ?? raw
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
        guard !trimmed.isEmpty else { return nil }
        // Raw catalog ids ("ollama/qwen3:14b", "hf.co/org/Qwen3.6-…:IQ2_M")
        // read better as names: drop the provider prefix, drop a HF quant tag,
        // and let the size survive a tag split ("qwen3 14b").
        var cleaned = trimmed
        if cleaned.contains("hf.co/") {
            if let last = cleaned.split(separator: "/").last {
                cleaned = String(last.split(separator: ":").first ?? last)
            }
        } else if cleaned.contains(":") {
            cleaned = cleaned.split(separator: ":")
                .filter { $0.lowercased() != "latest" }
                .joined(separator: " ")
        }
        return cleaned.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

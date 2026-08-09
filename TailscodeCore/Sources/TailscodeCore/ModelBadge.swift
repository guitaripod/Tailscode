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

    /// The badge as parts rather than a sentence, for a surface that colours the model by its
    /// family and the effort by its heat instead of folding both into one dim line.
    public static func chip(for session: AgentSession) -> ModelChip? {
        chip(model: session.model, effort: session.reasoningEffort)
    }

    /// The chip for a listed conversation, read in the order the composer's own pill reads: the
    /// pick this device recorded for the chat wins over the server's session record, because the
    /// record lags a pick until the next turn lands — and a row must never name a different model
    /// than the composer open above it. Each fact falls back independently, so an effort picked
    /// without a model still colours the record's own model name. This is also the only reader
    /// that can say ultracode: the server maps the tier to xhigh in its store, so the word
    /// survives only in the device's own pick.
    public static func chip(for entry: SessionEntry) -> ModelChip? {
        let key = "\(entry.profileID)/\(entry.session.id)"
        return chip(
            model: ModelPreferenceStore.model(forKey: key)?.modelID ?? entry.session.model,
            effort: EffortPreferenceStore.effort(forKey: key) ?? entry.session.reasoningEffort)
    }

    public static func chip(model raw: String?, effort: String?) -> ModelChip? {
        guard let raw, let name = familyName(raw) else { return nil }
        let trimmed = effort?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ModelChip(
            name: name, family: ModelTint.family(raw),
            effort: (trimmed?.isEmpty ?? true) ? nil : trimmed)
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

/// What a coloured model label is made of: the name, the family whose hue it wears — nil for a
/// model the catalog does not recognise, which keeps the quiet register — and the effort word,
/// which carries its own heat. Both facts stay words; the colour is on top, never instead.
public struct ModelChip: Equatable, Sendable {
    public let name: String
    public let family: ModelTint.Family?
    public let effort: String?

    public var isUltracode: Bool { effort?.lowercased() == Ultracode.effortLevel }

    public init(name: String, family: ModelTint.Family?, effort: String?) {
        self.name = name
        self.family = family
        self.effort = effort
    }
}

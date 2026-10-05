import CodingAgentKit

/// Compact "which model is driving this chat" text for session cards,
/// e.g. "Fable max" or "Sonnet high". Backends report either an alias
/// ("sonnet") or a full model id ("claude-fable-5"); both collapse to the
/// family name. Sessions without a reported model produce nothing.
public enum ModelBadge {
    public static func text(for session: AgentSession) -> String? {
        guard let raw = session.model,
            let name = familyName(raw, providerID: session.modelProviderID)
        else { return nil }
        guard let effort = session.reasoningEffort, !effort.isEmpty else { return name }
        return "\(name) \(effort)"
    }

    /// Chip text for a pending choice: "Opus · max", or "Auto" while the server
    /// is the one deciding.
    public static func label(model: ModelSelection?, effort: String?) -> String {
        let name =
            model.flatMap { familyName($0.modelID, providerID: $0.providerID) }
            ?? Localized.text("Auto")
        guard let effort, !effort.isEmpty else { return name }
        return "\(name) · \(effort)"
    }

    /// The family name alone, for a legend or a table where the effort is not the point.
    public static func shortName(_ raw: String) -> String {
        familyName(raw, providerID: nil) ?? raw
    }

    /// The word a pill wears for a model the catalog lists. A Claude model answers to its family
    /// word; anything else to the catalog's own display name when that is short enough to sit in
    /// a pill (``catalogNameLimit``) and says more than the id does; and failing both, the id
    /// cleaned of the door it came through and the build it was packed as, keeping the tail that
    /// tells it from its siblings (`gpt-5.1-codex-max` against `-mini`). Never empty: an id with
    /// nothing in it is the server choosing, which is what *Auto* says everywhere else.
    public static func shortName(
        _ id: String, catalogName: String?, providerID: String? = nil
    ) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let word = claudeWord(trimmed, providerID: providerID) { return word }
        let identity = trimmed.isEmpty ? "" : identityName(trimmed)
        if let name = catalogName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty, name.count <= catalogNameLimit,
            !isOnlyTheID(name, id: trimmed, identity: identity)
        {
            return name
        }
        let name = catalogName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !identity.isEmpty {
            return !name.isEmpty && name.count < identity.count && !isOnlyTheID(name, id: trimmed, identity: identity)
                ? name : identity
        }
        return name.isEmpty ? Localized.text("Auto") : name
    }

    /// The word for a pick everywhere a client names one: the catalog's own short name when it has
    /// one worth showing, the id with its packaging taken off otherwise, so a local build or a
    /// gateway id reads as what it is rather than as a Claude alias or a tail-truncated path.
    public static func word(for selection: ModelSelection, in models: [ModelInfo]) -> String {
        let name =
            models.first { $0.id == selection.modelID && $0.providerID == selection.providerID }?.name
            ?? models.first { $0.id == selection.modelID }?.name
        return shortName(selection.modelID, catalogName: name, providerID: selection.providerID)
    }

    /// The longest catalog name a pill wears whole; past it the cleaned id, which keeps the
    /// distinguishing tail, reads better than a truncated display name.
    public static let catalogNameLimit = 18

    /// Whether the model runs on the server's own machine rather than through a hosted door, read
    /// from the door when the caller has it and from the id's own `provider/` prefix when it does
    /// not. `ollama/qwen3:14b` is free and local; `ollama-cloud/qwen3:14b` is the same model
    /// metered, and the two must not read alike.
    public static func runsLocally(_ id: String, providerID: String?) -> Bool {
        let door = providerID.flatMap { $0.isEmpty ? nil : $0 } ?? ProviderIdentity.provider(ofModel: id)
        return door.map(ProviderIdentity.isLocal) ?? false
    }

    /// The one-word mark a view adds beside a model that runs locally, or nil for a hosted one.
    public static func localMark(_ id: String, providerID: String?) -> String? {
        runsLocally(id, providerID: providerID) ? Localized.text("local") : nil
    }

    /// The badge as parts rather than a sentence, for a surface that colours the model by its
    /// family and the effort by its heat instead of folding both into one dim line.
    public static func chip(for session: AgentSession) -> ModelChip? {
        chip(
            model: session.model, effort: session.reasoningEffort,
            providerID: session.modelProviderID)
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
        let pick = ModelPreferenceStore.model(forKey: key)
        return chip(
            model: pick?.modelID ?? entry.session.model,
            effort: EffortPreferenceStore.effort(forKey: key) ?? entry.session.reasoningEffort,
            providerID: pick?.providerID ?? entry.session.modelProviderID)
    }

    public static func chip(model raw: String?, effort: String?) -> ModelChip? {
        chip(model: raw, effort: effort, providerID: nil)
    }

    /// The chip with the door the model runs through, which is what decides whether a model
    /// carrying Claude's words is Claude's.
    public static func chip(model raw: String?, effort: String?, providerID: String?) -> ModelChip? {
        guard let raw, let name = familyName(raw, providerID: providerID) else { return nil }
        let trimmed = effort?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ModelChip(
            name: name, family: ModelTint.family(raw, providerID: providerID),
            effort: (trimmed?.isEmpty ?? true) ? nil : trimmed)
    }

    public static func chip(selection: ModelSelection?, effort: String?) -> ModelChip? {
        chip(model: selection?.modelID, effort: effort, providerID: selection?.providerID)
    }

    /// The name a badge wears. Claude's models answer to a family word because every client of
    /// theirs does — *Opus* is how a person says `claude-opus-5` — and nothing else does: "GPT"
    /// for `gpt-oss:120b` or "Gemini" for a dated preview throws away the one word that says which
    /// model it is. The family word is only worn by a model that is Claude's (``ModelNeedles``):
    /// a Qwen distilled from Opus is a Qwen. Every other id is worn as itself (``identityName``).
    private static func familyName(_ raw: String, providerID: String?) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return claudeWord(trimmed, providerID: providerID) ?? identityName(trimmed)
    }

    /// The family word of a model that is Claude's and names its member. Mythos wears Fable's hue
    /// but keeps its own name, since nobody calls it Fable.
    private static func claudeWord(_ trimmed: String, providerID: String?) -> String? {
        guard ModelNeedles.isClaude(trimmed, providerID: providerID) else { return nil }
        let words = ModelNeedles.words(ModelNeedles.lastSegment(trimmed))
        for (word, name) in [("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]
        where words.contains(word) {
            return name
        }
        return nil
    }

    /// An id worn as itself: the path a gateway hung on it taken off (`ollama-cloud/gpt-oss:120b`
    /// names where it is served, never what it is), the build it was packed as dropped — a quant
    /// tag, `latest`, a `-GGUF` or `-AWQ` tail — and a size tag joined by a hyphen so it reads as
    /// one name. Never empty: an id that is nothing but packaging keeps its own last segment.
    static func identityName(_ trimmed: String) -> String {
        let segment = ModelNeedles.lastSegment(trimmed)
        let pieces = segment.split(separator: ":").map(String.init)
        guard let base = pieces.first else { return trimmed }
        let tag = pieces.dropFirst().flatMap { $0.split(separator: "-").map(String.init) }
            .filter { !isPackaging($0) }
        let name = ([withoutPackagingTail(base)] + tag).filter { !$0.isEmpty }
            .joined(separator: "-")
        if !name.isEmpty { return name }
        return segment.isEmpty ? trimmed : segment
    }

    private static func withoutPackagingTail(_ base: String) -> String {
        var parts = base.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        while parts.count > 1, let last = parts.last, isPackaging(last) {
            parts.removeLast()
        }
        return parts.joined(separator: "-")
    }

    private static let packagingWords: Set<String> = [
        "latest", "gguf", "ud", "awq", "gptq", "exl2", "mlx", "dwq", "nvfp4", "mxfp4", "fp4",
        "fp8", "fp16", "bf16", "f16", "f32", "int4", "int8", "3bit", "4bit", "6bit", "8bit",
    ]

    /// A word that says how the weights were packed rather than which model they are: a format,
    /// a precision, a `latest` pointer, or a llama.cpp quant name (`Q8_0`, `q4_K_M`, `IQ2_M`).
    private static func isPackaging(_ word: String) -> Bool {
        let lower = word.lowercased()
        if packagingWords.contains(lower) { return true }
        var rest = Substring(lower)
        if rest.hasPrefix("i") { rest = rest.dropFirst() }
        guard rest.hasPrefix("q"), let digit = rest.dropFirst().first, digit.isNumber else {
            return false
        }
        return rest.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// A catalog name that only repeats the id says nothing the cleaned id does not say better.
    private static func isOnlyTheID(_ name: String, id: String, identity: String) -> Bool {
        let lower = name.lowercased()
        return lower == id.lowercased() || lower == ModelNeedles.lastSegment(id).lowercased()
            || lower == identity.lowercased()
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

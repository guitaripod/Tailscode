import Foundation

/// The one table a model's house is read from. The catalog's sections and the hue a model wears
/// both look here, so a model filed under Mistral in the list can never wear a stranger's colour
/// on the pill.
///
/// Claude is the one house that is not read off a word anywhere in the name, because its words
/// are the ones other people borrow: a Qwen fine-tune distilled from Opus outputs, a translation
/// model called `opus-mt`, a gateway's `haiku-mt`. A model is Claude only when its door is
/// Anthropic's, its own name starts with `claude`, or it *is* one of the aliases the CLI answers
/// to. Everything else is classified by its own name, and the borrowed words are ignored.
enum ModelNeedles {
    struct House: Sendable {
        let needles: [String]
        let title: String
        let tint: ModelTint.Family?
    }

    /// Order is the order of the sections a person reads, and the order a name that carries two
    /// houses' words is settled in — a DeepSeek distill of Llama is DeepSeek's.
    static let houses: [House] = [
        House(needles: ["claude", "fable", "mythos", "opus", "sonnet", "haiku"], title: "Claude", tint: nil),
        House(needles: ["gpt", "chatgpt", "codex", "o1", "o3", "o4"], title: "GPT", tint: .gpt),
        House(needles: ["gemini"], title: "Gemini", tint: .gemini),
        House(needles: ["grok"], title: "Grok", tint: .grok),
        House(needles: ["deepseek"], title: "DeepSeek", tint: .deepseek),
        House(needles: ["qwen", "qwq"], title: "Qwen", tint: .qwen),
        House(needles: ["kimi"], title: "Kimi", tint: .kimi),
        House(needles: ["glm", "chatglm"], title: "GLM", tint: .glm),
        House(needles: ["llama"], title: "Llama", tint: .llama),
        House(
            needles: ["mistral", "codestral", "devstral", "magistral", "mixtral", "ministral"],
            title: "Mistral", tint: .mistral),
        House(needles: ["gemma"], title: "Gemma", tint: .gemma),
        House(needles: ["command", "cohere"], title: "Command", tint: .command),
        House(needles: ["phi"], title: "Phi", tint: .phi),
        House(needles: ["nova"], title: "Nova", tint: nil),
        House(needles: ["minimax"], title: "MiniMax", tint: .minimax),
        House(needles: ["hunyuan"], title: "Hunyuan", tint: nil),
    ]

    static let claudeIndex = 0

    private static let claudeAliases = ["fable", "mythos", "opus", "sonnet", "haiku"]

    /// The house a model belongs to, as an index into ``houses``. The id is read from its last
    /// path segment — `ollama/` and `openrouter/` are doors, not houses — and the catalog's display
    /// name, when there is one, adds its words; neither can make a model Claude on its own words.
    static func house(id: String, name: String? = nil, providerID: String? = nil) -> Int? {
        if isClaude(id, providerID: providerID) { return claudeIndex }
        let words = self.words(lastSegment(id)).union(self.words(name ?? ""))
        for (index, house) in houses.enumerated() where index != claudeIndex {
            if house.needles.contains(where: words.contains) { return index }
        }
        return nil
    }

    /// The hue a model wears: a Claude model wears its member's (Opus, Sonnet…), anything else its
    /// house's, and a model no house claims nothing — the caller then hashes its name.
    static func tint(_ raw: String, providerID: String? = nil) -> ModelTint.Family? {
        if isClaude(raw, providerID: providerID) { return claudeMember(raw) }
        return house(id: raw, providerID: nil).flatMap { houses[$0].tint }
    }

    /// Whether the id names one of Anthropic's models: the door says so, a path segment before the
    /// name is Anthropic's, the name itself starts with `claude`, or the whole name is one of the
    /// CLI's aliases with nothing but a version after it (`opus`, `sonnet-5`, `opus-4-8[1m]`).
    static func isClaude(_ raw: String, providerID: String? = nil) -> Bool {
        if let providerID, isAnthropicDoor(providerID) { return true }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        let segments = trimmed.split(separator: "/").map(String.init)
        if segments.dropLast().contains(where: isAnthropicDoor) { return true }
        let last = segments.last ?? trimmed
        if last.hasPrefix("claude") || last.contains("anthropic.claude") { return true }
        return segments.count == 1 && isBareAlias(last)
    }

    /// Which Claude answers, for the hue: Fable (Mythos wears its colour), Opus, Sonnet or Haiku.
    /// A Claude id naming none of them answers nil.
    static func claudeMember(_ raw: String) -> ModelTint.Family? {
        let words = self.words(lastSegment(raw.lowercased()))
        if words.contains("fable") || words.contains("mythos") { return .fable }
        for (word, family) in [("opus", ModelTint.Family.opus), ("sonnet", .sonnet), ("haiku", .haiku)]
        where words.contains(word) {
            return family
        }
        return nil
    }

    static func lastSegment(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.split(separator: "/").last ?? Substring(trimmed))
    }

    /// The words a name is matched by: the letter and digit runs ``ModelFamily/tokens(_:)``
    /// yields, plus each whole run between separators, so `o3-mini` offers `o3` as well as `o`
    /// and `3`, while `o3xx` never offers `o3`.
    static func words(_ raw: String) -> Set<String> {
        let runs = raw.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
        return Set(ModelFamily.tokens(raw) + runs)
    }

    private static func isAnthropicDoor(_ providerID: String) -> Bool {
        let id = providerID.lowercased()
        return id == "anthropic" || id == "claude"
    }

    /// An alias followed by nothing but a version: digits, dots and hyphens, then optionally a
    /// bracketed context tag such as `[1m]`. `haiku-mt` is not an alias, it is a model called that.
    private static func isBareAlias(_ name: String) -> Bool {
        if name == "opusplan" { return true }
        guard let alias = claudeAliases.first(where: { name.hasPrefix($0) }) else { return false }
        var rest = Substring(name.dropFirst(alias.count))
        if let bracket = rest.firstIndex(of: "["), rest.hasSuffix("]") {
            rest = rest[rest.startIndex..<bracket]
        }
        return rest.allSatisfy { $0.isNumber || $0 == "-" || $0 == "." }
    }
}

/// How a model provider's catalog key reads as a brand, and where its models
/// live. The server names providers by config keys ("opencode-go",
/// "kimi-code", "ollama"); every picker renders the display name so a row
/// explains itself before a tap, and local providers are called out because
/// "runs on the server's machine" is a fact worth knowing next to a model.
public enum ProviderIdentity {
    public static func displayName(_ providerID: String) -> String {
        switch providerID.lowercased() {
        case "ollama": return "Ollama"
        case "arch": return "Arch"
        case "vllm": return "Arch"
        case "opencode-go": return "OpenCode Go"
        case "opencode": return "OpenCode"
        case "anthropic", "claude": return "Anthropic"
        case "xai": return "xAI"
        case "kimi-code": return "Kimi Code"
        case "openrouter": return "OpenRouter"
        case "bonsai": return "Bonsai"
        case "deepseek": return "DeepSeek"
        case "server": return "Server"
        default:
            let words = providerID.split(separator: "-")
            if words.isEmpty { return providerID }
            return words
                .map {
                    guard let first = $0.first else { return String($0) }
                    return String(first).uppercased() + $0.dropFirst()
                }
                .joined(separator: " ")
        }
    }

    /// Which door a model's tokens went through, read from the model key itself. opencode names
    /// a model `provider/id`, which is the answer outright; a bridge that serves one vendor names
    /// the model alone, and the vendor is then read off the family — the point of the row is to
    /// separate a runtime on the server's own machine from a hosted API, and a model nobody can
    /// place is better left out of the split than filed under a guess.
    public static func provider(ofModel raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let slash = trimmed.firstIndex(of: "/"), slash != trimmed.startIndex {
            return String(trimmed[trimmed.startIndex..<slash])
        }
        let id = trimmed.lowercased()
        let families: [(String, String)] = [
            ("claude", "anthropic"), ("opus", "anthropic"), ("sonnet", "anthropic"),
            ("haiku", "anthropic"), ("fable", "anthropic"), ("gpt", "openai"),
            ("codex", "openai"), ("o3", "openai"), ("o4", "openai"), ("grok", "xai"),
            ("gemini", "google"), ("llama", "meta"), ("qwen", "alibaba"),
            ("deepseek", "deepseek"), ("kimi", "moonshot"), ("mistral", "mistral"),
            ("devstral", "mistral"), ("codestral", "mistral"), ("glm", "zhipu"),
        ]
        for (needle, provider) in families where id.contains(needle) { return provider }
        return nil
    }

    /// True when the provider's models run in a process on the server machine
    /// itself (Ollama, or a local vLLM on Arch) rather than a hosted API.
    public static func isLocal(_ providerID: String) -> Bool {
        let id = providerID.lowercased()
        return id == "ollama" || id == "arch" || id == "vllm"
    }

    /// The brand a provider key bills against, for the quota wall's billing rule — a model
    /// running through the "opencode-go" door spends from Go's caps, one through "deepseek"
    /// from the prepaid balance. Keys with no house of their own answer nil.
    public static func slug(_ providerID: String) -> String? {
        switch providerID.lowercased() {
        case "opencode-go": return "opencode"
        case "opencode": return "opencode-free"
        case "anthropic", "claude": return "claude"
        case "xai", "grok": return "grok"
        case "deepseek": return "deepseek"
        case "openrouter": return "openrouter"
        case "kimi", "kimi-code": return "kimi"
        case "bonsai": return "bonsai"
        case "ollama-cloud": return "ollama-cloud"
        default: return nil
        }
    }
}

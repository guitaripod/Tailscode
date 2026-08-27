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

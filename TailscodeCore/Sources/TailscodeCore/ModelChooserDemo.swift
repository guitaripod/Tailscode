import CodingAgentKit
import Foundation

/// A fleet's worth of catalog with no fleet attached, so the surface that has to survive two
/// hundred models can be looked at without owning two hundred models. The shape is the one that
/// broke the old list — several houses, one model sold through two doors, a machine of your own, a
/// wall in front of something, and names long enough to collide with whatever a row wears on its
/// right — and every client drives the same fixture, so a layout that only holds on one desk is
/// visible as a difference rather than discovered later.
public enum ModelChooserDemo {
    public static func sources() -> [ModelSource] {
        [
            ModelSource(
                profileID: "arch", name: "arch", backend: .openCode, models: hosted,
                isCurrent: true, allowsServerDefault: true, acceptsAnyModelID: false),
            ModelSource(
                profileID: "macbook", name: "macbook", backend: .openCode, models: local,
                isCurrent: false, allowsServerDefault: true, acceptsAnyModelID: false),
            ModelSource(
                profileID: "studio", name: "studio", backend: .claudeCode, models: cli,
                isCurrent: false, allowsServerDefault: true, acceptsAnyModelID: true),
        ]
    }

    public static var selected: ModelSelection {
        ModelSelection(providerID: "anthropic", modelID: "claude-opus-5")
    }

    public static var recents: [ModelSelection] {
        [
            selected,
            ModelSelection(providerID: "deepseek", modelID: "deepseek-v4-pro"),
            ModelSelection(providerID: "ollama", modelID: "nemotron-3.5-lightning:30b-mlx"),
        ]
    }

    private static let full = ModelCapabilities(attachment: true, imageInput: true, pdfInput: true)
    private static let text = ModelCapabilities(attachment: true, imageInput: false, pdfInput: false)

    private static var hosted: [ModelInfo] {
        [
            ModelInfo(
                id: "claude-opus-5", name: "Opus", providerID: "anthropic", capabilities: full,
                variants: ["low", "medium", "high"]),
            ModelInfo(
                id: "anthropic/claude-opus-5", name: "Opus", providerID: "openrouter",
                capabilities: full),
            ModelInfo(id: "claude-fable-5", name: "Fable", providerID: "anthropic", capabilities: full),
            ModelInfo(
                id: "claude-sonnet-5", name: "Sonnet", providerID: "anthropic", capabilities: full,
                variants: ["low", "high"]),
            ModelInfo(id: "claude-haiku-4-5", name: "Haiku", providerID: "anthropic", capabilities: full),
            ModelInfo(
                id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", providerID: "deepseek",
                capabilities: text, variants: ["standard", "deep"]),
            ModelInfo(
                id: "deepseek/deepseek-v4-pro", name: "DeepSeek V4 Pro", providerID: "opencode-go",
                capabilities: text),
            ModelInfo(
                id: "deepseek-v4-flash", name: "DeepSeek V4 Flash", providerID: "deepseek",
                capabilities: text, variants: ["standard", "deep", "deeper"]),
            ModelInfo(
                id: "gpt-5.6-luna", name: "GPT-5.6 Luna", providerID: "opencode-go",
                capabilities: full, variants: ["low", "medium", "high"]),
            ModelInfo(id: "gpt-5.6-codex", name: "GPT-5.6 Codex", providerID: "opencode-go", capabilities: full),
            ModelInfo(
                id: "gemini-3.5-pro-preview-0731", name: "Gemini 3.5 Pro", providerID: "google",
                capabilities: full),
            ModelInfo(id: "gemini-3.5-flash", name: "Gemini 3.5 Flash", providerID: "google", capabilities: full),
            ModelInfo(id: "grok-5-fast", name: "Grok 5 Fast", providerID: "xai", capabilities: text),
            ModelInfo(
                id: "qwen3-max-thinking", name: "Qwen3 Max Thinking", providerID: "opencode-go",
                capabilities: text),
            ModelInfo(id: "kimi-k3", name: "Kimi K3", providerID: "moonshot", capabilities: text),
            ModelInfo(id: "glm-5-air", name: "GLM-5 Air", providerID: "zhipu", capabilities: text),
            ModelInfo(
                id: "mistral-large-3", name: "Mistral Large 3", providerID: "mistral",
                capabilities: text),
            ModelInfo(id: "codestral-2", name: "Codestral 2", providerID: "mistral", capabilities: text),
            ModelInfo(
                id: "llama-4.2-maverick-instruct", name: "Llama 4.2 Maverick", providerID: "groq",
                capabilities: text),
            ModelInfo(id: "command-a-2", name: "Command A2", providerID: "cohere", capabilities: text),
        ]
    }

    private static var local: [ModelInfo] {
        [
            ModelInfo(id: "nemotron-3.5-lightning:30b-mlx", name: "Nemotron 3.5 Lightning (MLX)", providerID: "ollama"),
            ModelInfo(id: "qwen3-coder:30b", name: "Qwen3 Coder", providerID: "ollama"),
            ModelInfo(id: "gemma4:27b", name: "Gemma 4", providerID: "ollama"),
            ModelInfo(id: "glm-5-air:mlx", name: "GLM-5 Air", providerID: "ollama"),
            ModelInfo(id: "deepseek-v4-flash:mlx", name: "DeepSeek V4 Flash", providerID: "ollama"),
        ]
    }

    private static var cli: [ModelInfo] {
        [
            ModelInfo(id: "opus", name: "Opus", providerID: "anthropic", capabilities: full),
            ModelInfo(id: "sonnet", name: "Sonnet", providerID: "anthropic", capabilities: full),
            ModelInfo(id: "haiku", name: "Haiku", providerID: "anthropic", capabilities: full),
        ]
    }

    /// One wall, so the spent register is on screen beside the rest rather than only in a test.
    public static func quotas() -> [UsageQuota] {
        [
            UsageQuota(
                providerName: "Claude", subtitle: "", source: "demo", live: true,
                gauges: [
                    UsageQuota.Gauge(
                        key: "weekly-opus", label: "Weekly · Opus", fraction: 1,
                        resetsAt: Date().addingTimeInterval(11 * 3_600), trustedReset: true),
                    UsageQuota.Gauge(
                        key: "session", label: "5-hour session", fraction: 0.4,
                        resetsAt: Date().addingTimeInterval(2 * 3_600), trustedReset: true),
                ], details: [])
        ]
    }
}

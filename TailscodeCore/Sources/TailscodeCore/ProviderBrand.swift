/// Which brand a quota card belongs to, for the accent its name and bars wear. Grok's slug also
/// tints by appearance — xAI is monochrome, silver on dark and ink on light — which the theme's
/// CSS handles; this only names the slug.
public enum ProviderBrand {
    public static func slug(_ providerName: String) -> String? {
        switch providerName.lowercased() {
        case "claude", "anthropic": return "claude"
        case "grok", "xai": return "grok"
        case "opencode", "opencode go": return "opencode"
        case "deepseek": return "deepseek"
        default: return nil
        }
    }

    /// The brand behind a name somebody else chose. `slug` matches the names the app itself writes
    /// and answers nil to everything else, which is the right answer where a wall's billing rule is
    /// being decided — a guess there bills the wrong models. Reading a card is the other case: a
    /// server that called its provider "Claude Code" or "opencode go (estimated)" is plainly naming
    /// a house we know, and refusing to recognise it only costs the reader its colour and its word.
    public static func brand(_ providerName: String) -> String? {
        if let exact = slug(providerName) { return exact }
        let lower = providerName.lowercased()
        for candidate in ["opencode", "claude", "anthropic", "grok", "deepseek"]
        where lower.contains(candidate) {
            return slug(candidate)
        }
        return nil
    }

    /// The provider as a narrow column names it. A quota card has room for "OpenCode Go" and a
    /// widget row has room for one word, so the brand answers with the word people actually use;
    /// anything with no house of its own keeps the name its server gave it.
    public static func short(_ providerName: String) -> String {
        switch brand(providerName) ?? providerName.lowercased() {
        case "claude": return "Claude"
        case "grok": return "Grok"
        case "opencode": return "opencode"
        case "deepseek": return "DeepSeek"
        default: return providerName
        }
    }

    public static func fillClass(severity: String, slug: String?) -> String {
        guard severity == "ok", let slug else { return "gauge-fill-\(severity)" }
        return "gauge-fill-\(slug)"
    }
}

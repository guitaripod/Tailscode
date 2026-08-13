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

    public static func fillClass(severity: String, slug: String?) -> String {
        guard severity == "ok", let slug else { return "gauge-fill-\(severity)" }
        return "gauge-fill-\(slug)"
    }
}

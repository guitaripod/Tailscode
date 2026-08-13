import CodingAgentKit
import Foundation

/// Which models a provider's window governs. A provider meters some windows against the whole
/// account and others against one model, and the difference is the whole difference between a wall
/// you have walked into and a wall around a model you are not using.
public enum QuotaScope: Sendable, Hashable {
    /// Every model on the provider: at this wall, nothing sends.
    case account
    /// The words the window names its model by — all of them must appear in a model's own name for
    /// the window to be that model's. Only letters count: a provider names the release it happened
    /// to meter ("Weekly · Opus 4.1") while the window it is describing belongs to the family, and
    /// pinning the wall to a version number would let a rename hide it.
    case model([String])
}

/// Reads a quota window's own label for the model it belongs to. The provider says which model a
/// scoped window is for and nowhere else does it say so, which is why this is a parse rather than a
/// table: a family that ships tomorrow is named by the same sentence today's is.
public enum QuotaBinding {
    /// Words a window uses to describe itself — a period, a unit, a plan, a house — rather than to
    /// name a model. What survives these is the model the window was scoped to, if it named one.
    private static let plumbing: Set<String> = [
        "all", "and", "anthropic", "as", "balance", "claude", "credit", "credits", "daily", "day",
        "demand", "extra", "go", "hour", "hourly", "limit", "message", "messages", "model",
        "models", "month", "monthly", "of", "on", "pay", "per", "quota", "request", "requests",
        "rolling", "scoped", "session", "spend", "the", "token", "tokens", "usage", "week",
        "weekly", "window", "you",
    ]

    public static func scope(of gauge: UsageQuota.Gauge) -> QuotaScope {
        let words = ModelFamily.tokens(modelPart(of: gauge.label))
            .filter { word in word.allSatisfy(\.isLetter) && !plumbing.contains(word) }
        return words.isEmpty ? .account : .model(words)
    }

    /// Whether this window stands between the named model and its next send. A model nobody can
    /// name is governed by account-wide windows only: guessing that an unnamed model is the one a
    /// scoped wall belongs to is how a wall ends up shouting at every chat on the machine.
    public static func governs(
        _ scope: QuotaScope, model id: String?, named name: String? = nil
    ) -> Bool {
        switch scope {
        case .account:
            return true
        case .model(let words):
            let tokens = Set(ModelFamily.tokens(id ?? "") + ModelFamily.tokens(name ?? ""))
            guard !tokens.isEmpty else { return false }
            return words.allSatisfy(tokens.contains)
        }
    }

    public static func governs(
        _ gauge: UsageQuota.Gauge, model id: String?, named name: String? = nil
    ) -> Bool {
        governs(scope(of: gauge), model: id, named: name)
    }

    /// Whether the provider this quota belongs to actually bills `candidate`, so an account-wide
    /// wall is only worn by the models that spend against it. A wall belongs to the provider that
    /// meters it: Claude's weekly holds only Claude models, Grok's holds Grok's, and a prepaid
    /// DeepSeek balance holds DeepSeek's — a DeepSeek row under a Claude wall is the one notice
    /// nobody can act on, because no amount of waiting or model-switching on Claude's clock opens
    /// a model billed somewhere else. The exception is the reseller whose caps are account-wide
    /// dollars across every provider it fronts: opencode go bills deepseek, kimi and the rest of
    /// its catalog out of one balance, so its wall holds every hosted model it offers. A quota
    /// from a provider nobody recognises keeps the old behaviour and governs everything, which is
    /// the safe reading of a wall whose house we cannot place.
    public static func bills(_ quota: UsageQuota, candidate: ModelCandidate) -> Bool {
        guard let slug = ProviderBrand.slug(quota.providerName) else { return true }
        switch slug {
        case "opencode": return !candidate.isLocal
        case "claude": return billed(by: "claude", candidate: candidate)
        case "grok": return billed(by: "grok", candidate: candidate)
        case "deepseek": return billed(by: "deepseek", candidate: candidate)
        default: return true
        }
    }

    /// The same rule for a chat's own model, where the door it runs through is known: the
    /// selection's provider id settles who bills it, and the family is the fallback when the
    /// door is a key nobody recognises. A model nobody can name still hears every account-wide
    /// wall — that chat may be on anything.
    public static func bills(
        _ quota: UsageQuota, selection: ModelSelection?, model: String? = nil, named name: String? = nil
    ) -> Bool {
        guard let slug = ProviderBrand.slug(quota.providerName) else { return true }
        guard let selection else {
            guard model != nil || name != nil else { return true }
            let family = ModelFamily.of(name: name ?? "", id: model ?? "")
            switch slug {
            case "opencode": return true
            case "claude": return family.key == "claude"
            case "grok": return family.key == "grok"
            case "deepseek": return family.key == "deepseek"
            default: return true
            }
        }
        if let door = ProviderIdentity.slug(selection.providerID) {
            return door == slug
        }
        let family = ModelFamily.of(name: name ?? selection.modelID, id: selection.modelID)
        switch slug {
        case "opencode": return !ProviderIdentity.isLocal(selection.providerID)
        case "claude": return family.key == "claude"
        case "grok": return family.key == "grok"
        case "deepseek": return family.key == "deepseek"
        default: return true
        }
    }

    /// A model is billed by a house when its family is that house's, or when the gateway
    /// actually running it carries that house's own id — the same model name reached through two
    /// providers may spend from either account.
    private static func billed(by house: String, candidate: ModelCandidate) -> Bool {
        if candidate.family.key == house { return true }
        return candidate.offers.contains { offer in
            ProviderIdentity.slug(offer.providerID) == house
        }
    }

    /// A label that carries both reads "window · model", so only the part past the last separator
    /// can name one — "Weekly · Opus" is Opus's, not a model called Weekly. A label with no
    /// separator is read whole, because a per-product window names nothing else ("Grok Build"), and
    /// it is the plumbing list alone that keeps "5-hour session" from becoming a model.
    private static func modelPart(of label: String) -> String {
        guard let separator = label.range(of: "·", options: .backwards) else { return label }
        return String(label[separator.upperBound...])
    }
}

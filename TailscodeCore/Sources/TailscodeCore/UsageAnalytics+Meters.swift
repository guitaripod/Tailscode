import CodingAgentKit
import Foundation

extension UsageAnalytics {
    /// Which model did the most work. Cache reads are left out of the measure: a cached prefix
    /// is counted once as a write and re-read on every turn after it, so counting the reads ranks
    /// a model by how long its conversations were rather than by how much it did. Ties break on
    /// money and then on name, so a listing never reorders itself between two reads.
    static func byWork(
        _ lhs: SessionSpendReport.ModelShare, _ rhs: SessionSpendReport.ModelShare
    ) -> Bool {
        if lhs.tokens.fresh != rhs.tokens.fresh { return lhs.tokens.fresh > rhs.tokens.fresh }
        if lhs.costUSD != rhs.costUSD { return lhs.costUSD > rhs.costUSD }
        return lhs.model < rhs.model
    }

    /// What a row is measured by: the money wherever the account spent any, the work itself in an
    /// account that spent none.
    static func rank(
        _ costUSD: Double, _ tokens: SessionSpendReport.Tokens, _ priced: Bool
    ) -> Double {
        priced ? costUSD : Double(tokens.fresh)
    }

    /// The trailing value on a meter: what it cost, or — where it did real work and the server
    /// priced none of it — the word for the door rather than a verdict on the bill. A row reading
    /// "$0" beside two million tokens says the model went unused, which is the opposite of what
    /// happened, and *free* says the same of a plan somebody pays for every month. So each zero
    /// names what it is: *Local* for hardware the person already owns, *Plan* for a subscription
    /// billed a flat month (Ollama Cloud, a coding plan), *Free tier* for models a provider gives
    /// away, *Unpriced* for a hosted rate this ledger simply does not have.
    static func value(
        costUSD: Double, tokens: SessionSpendReport.Tokens, prefix: String, door: ModelDoorKind?
    ) -> String {
        if costUSD > 0 { return prefix + SessionSpend.money(costUSD) }
        guard tokens.total > 0 else { return SessionSpend.money(0) }
        switch door {
        case .local: return Localized.text("Local")
        case .subscription: return Localized.text("Plan")
        case .free: return Localized.text("Free tier")
        case .gateway, .key, .none: return Localized.text("Unpriced")
        }
    }

    /// Whether a row's work was billed to nobody at all. A plan's tokens are excluded on purpose:
    /// the money was spent, it just cannot be divided per token.
    static func isFree(
        costUSD: Double, tokens: SessionSpendReport.Tokens, door: ModelDoorKind?
    ) -> Bool {
        guard costUSD <= 0, tokens.total > 0 else { return false }
        return door == .local || door == .free
    }

    /// The numbers under a model's name, led by the door its tokens went through where the name
    /// itself does not already carry it — which is how the list answers *what am I actually
    /// running* rather than only *what did it cost*.
    static func workDetail(
        turns: Int, counted: Int, costUSD: Double, prefix: String, through: String? = nil
    ) -> String {
        var detail = Localized.text("%@ tokens", StatusFacts.tokens(counted))
        if turns > 0 {
            detail = Localized.text("%@ turns · ", Self.count(turns)) + detail
            if costUSD > 0 {
                detail += Localized.text(
                    " · %@ a turn", prefix + SessionSpend.money(costUSD / Double(turns)))
            }
        }
        if let through {
            detail = ProviderIdentity.displayName(through) + " · " + detail
        }
        return detail
    }

    /// Every model folded up by the door its tokens went through. A provider is only worth a row
    /// when there is another to compare it against.
    static func providerMeters(
        models: [String: SessionSpendReport.ModelShare], prefix: String, localLed: Bool
    ) -> [Meter] {
        var rows: [String: (share: SessionSpendReport.ModelShare, models: Int)] = [:]
        for model in models.values {
            guard let key = ProviderIdentity.provider(ofModel: model.model) else { continue }
            var row =
                rows[key]
                ?? (
                    SessionSpendReport.ModelShare(
                        model: key, turns: 0, tokens: SessionSpendReport.Tokens(), costUSD: 0), 0
                )
            row.share.turns += model.turns
            row.share.tokens = add(row.share.tokens, model.tokens)
            row.share.costUSD += model.costUSD
            row.models += 1
            rows[key] = row
        }
        guard rows.count > 1 else { return [] }
        guard !(localLed && rows.keys.allSatisfy(ProviderIdentity.isLocal)) else { return [] }
        let ranked = rows.values.sorted { byWork($0.share, $1.share) }
        let peak = ranked.map { Double($0.share.tokens.fresh) }.max() ?? 0
        return ranked.map { row in
            var detail =
                row.models == 1
                ? Localized.text("1 model") : Localized.text("%d models", row.models)
            detail += Localized.text(
                " · %@ tokens",
                StatusFacts.tokens(localLed ? row.share.tokens.fresh : row.share.tokens.total))
            let door = ModelDoorKind.classify(row.share.model)
            switch door {
            case .local: detail += Localized.text(" · on your own machine")
            case .subscription: detail += Localized.text(" · on a plan you already pay for")
            case .free, .gateway, .key: break
            }
            return Meter(
                label: ProviderIdentity.displayName(row.share.model), detail: detail,
                money: value(
                    costUSD: row.share.costUSD, tokens: row.share.tokens, prefix: prefix,
                    door: door),
                share: peak > 0 ? Double(row.share.tokens.fresh) / peak : 0,
                isFree: isFree(
                    costUSD: row.share.costUSD, tokens: row.share.tokens, door: door),
                door: door)
        }
    }

    /// Two models can wear the same name through two different doors — the same weights served
    /// by a gateway and by its vendor — and two identical rows read as a bug rather than as a
    /// choice. Only the names that collide among the rows actually listed are qualified; a twin
    /// the list cut leaves the row it cannot be confused with short.
    static func modelLabels(
        _ ranked: [SessionSpendReport.ModelShare], names: Names
    ) -> [String: String] {
        var counts: [String: Int] = [:]
        for row in ranked { counts[names(row.model), default: 0] += 1 }
        var labels: [String: String] = [:]
        for row in ranked {
            let short = names(row.model)
            guard counts[short, default: 0] > 1, let key = ProviderIdentity.provider(ofModel: row.model)
            else {
                labels[row.model] = short
                continue
            }
            labels[row.model] = "\(short) · \(ProviderIdentity.displayName(key))"
        }
        return labels
    }

    /// Two checkouts of the same repository, or the same folder name under two parents, land as
    /// two rows wearing one name. Only the names that collide take the parent folder with them.
    static func projectLabels(_ projects: [UsageAnalyticsReport.Project]) -> [String: String]
    {
        var counts: [String: Int] = [:]
        for project in projects { counts[project.name, default: 0] += 1 }
        var labels: [String: String] = [:]
        for project in projects {
            guard counts[project.name, default: 0] > 1 else {
                labels[project.directory] = project.name
                continue
            }
            let parent = URL(fileURLWithPath: project.directory, isDirectory: true)
                .deletingLastPathComponent()
                .lastPathComponent
            labels[project.directory] =
                parent.isEmpty ? project.directory : "\(parent)/\(project.name)"
        }
        return labels
    }

    /// The caption under the models: what the list could not fit, and what ran through a plan or
    /// through a door with no rate — the facts a column of "$0" hides. What ran on the person's
    /// own hardware is ``localWork``'s to say.
    static func modelsLine(
        ranked: [SessionSpendReport.ModelShare], prefix: String, shown: Int, names: Names
    ) -> String? {
        var parts: [String] = []
        let hidden = ranked.dropFirst(shown)
        if !hidden.isEmpty {
            let tokens = StatusFacts.tokens(hidden.reduce(0) { $0 + $1.tokens.total })
            let hiddenCost = hidden.reduce(0) { $0 + $1.costUSD }
            let money =
                hiddenCost > 0
                ? prefix + SessionSpend.money(hiddenCost)
                : Localized.text("no price")
            parts.append(
                hidden.count == 1
                    ? Localized.text("1 more model not shown · %@ tokens · %@", tokens, money)
                    : Localized.text(
                        "%d more models not shown · %@ tokens · %@", hidden.count, tokens, money))
        }
        if let plan = planLine(models: ranked, names: names) { parts.append(plan) }
        if let unpriced = unpricedLine(models: ranked, names: names) { parts.append(unpriced) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

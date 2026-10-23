import CodingAgentKit
import Foundation

extension UsageAnalytics {
    /// The same model reported by two servers under two names is one model. A bridge that serves
    /// a single engine names the model alone (`glm-5.3-flash`) while an opencode server names the
    /// door with it (`ollama-cloud/glm-5.3-flash`), and split in two the account reads as two
    /// models — one of them filed under a vendor nobody holds an account with, its tokens
    /// *unpriced* beside the very same tokens on a plan. So where exactly one qualified row wears
    /// a bare row's name, the bare row joins it: a door a server actually reported outranks one
    /// read off the model's family.
    static func adoptDoors(
        _ rows: [String: SessionSpendReport.ModelShare]
    ) -> [String: SessionSpendReport.ModelShare] {
        var hosts: [String: Set<String>] = [:]
        for key in rows.keys where key.contains("/") {
            hosts[ModelBadge.shortName(key), default: []].insert(key)
        }
        var out: [String: SessionSpendReport.ModelShare] = [:]
        for (key, row) in rows {
            let twins = key.contains("/") ? nil : hosts[ModelBadge.shortName(key)]
            let target = twins?.count == 1 ? twins?.first ?? key : key
            var merged =
                out[target]
                ?? SessionSpendReport.ModelShare(
                    model: target, turns: 0, tokens: .init(), costUSD: 0)
            merged.turns += row.turns
            merged.tokens = add(merged.tokens, row.tokens)
            merged.costUSD += row.costUSD
            out[target] = merged
        }
        return out
    }

    /// Which door a model's tokens went through, where the model key names one at all.
    static func door(of model: SessionSpendReport.ModelShare) -> ModelDoorKind? {
        ProviderIdentity.provider(ofModel: model.model).map(ModelDoorKind.classify)
    }

    /// The one door a whole machine's work went through, where its models agree on one — which
    /// is what lets a server running nothing but Ollama read as local inside an account that
    /// spent money elsewhere. A machine with two kinds of door has no single answer.
    static func door(ofModels models: [SessionSpendReport.ModelShare]) -> ModelDoorKind? {
        let doors = Set(models.filter { $0.tokens.total > 0 }.compactMap(door(of:)))
        return doors.count == 1 ? doors.first : nil
    }

    /// The models a clause is about: the ones that did real work and were billed nothing per
    /// token, through the doors this clause speaks for.
    private static func unbilled(
        _ models: [SessionSpendReport.ModelShare], through doors: Set<ModelDoorKind>
    ) -> [SessionSpendReport.ModelShare] {
        models.filter {
            $0.costUSD <= 0 && $0.tokens.total > 0 && door(of: $0).map(doors.contains) == true
        }
    }

    /// The doors a clause ran through, named as brands.
    private static func doorNames(_ models: [SessionSpendReport.ModelShare]) -> String {
        let doors = Set(models.compactMap { ProviderIdentity.provider(ofModel: $0.model) })
            .map(ProviderIdentity.displayName).sorted()
        return doors.isEmpty ? "" : " " + Localized.text("through %@", doors.joined(separator: ", "))
    }

    /// What went through a plan rather than a meter. A subscription buys a flat month, so its
    /// tokens are neither free nor unpriced — the money was spent and this ledger cannot divide
    /// it — and saying so is the difference between a plan and a hole in the numbers.
    static func planLine(
        models: [SessionSpendReport.ModelShare], names: Names
    ) -> String? {
        let plan = unbilled(models, through: [.subscription])
        guard !plan.isEmpty else { return nil }
        let tokens = StatusFacts.tokens(plan.reduce(0) { $0 + $1.tokens.total })
        let through = doorNames(plan)
        return plan.count == 1
            ? Localized.text(
                "%@ tokens on %@%@ ran on a plan — billed by the month, not per token",
                tokens, names(plan[0].model), through)
            : Localized.text(
                "%@ tokens across %d models%@ ran on a plan — billed by the month, not per token",
                tokens, plan.count, through)
    }

    /// What ran through a hosted door the server has no rate for. A gateway's free tier is
    /// somebody's money; a card that called it free would be claiming a bill that exists is zero.
    static func unpricedLine(
        models: [SessionSpendReport.ModelShare], names: Names
    ) -> String? {
        let unpriced = unbilled(models, through: [.key, .gateway, .free])
        guard !unpriced.isEmpty else { return nil }
        let tokens = StatusFacts.tokens(unpriced.reduce(0) { $0 + $1.tokens.total })
        let through = doorNames(unpriced)
        return unpriced.count == 1
            ? Localized.text(
                "%@ tokens on %@%@ are unpriced — the server reports no rate for it",
                tokens, names(unpriced[0].model), through)
            : Localized.text(
                "%@ tokens across %d models%@ are unpriced — the server reports no rate for them",
                tokens, unpriced.count, through)
    }

    /// What nobody counted, named. A server whose ledger is one running total per conversation
    /// knows the money and the model and nothing about the turns inside, and the difference
    /// between a count of zero and a count nobody took has to be on the screen.
    static func coverageNote(
        coarse: [String], servers: Int, coverage: UsageAnalyticsReport.Coverage
    ) -> String? {
        guard !coarse.isEmpty else { return nil }
        let names = coarse.joined(separator: ", ")
        if coarse.count == servers {
            return coarse.count == 1
                ? Localized.text(
                    "Counted per conversation: %@ reports what each chat spent, not the turns inside it, the tools they called or the hour they ran.",
                    names)
                : Localized.text(
                    "Counted per conversation: %@ report what each chat spent, not the turns inside it, the tools they called or the hour they ran.",
                    names)
        }
        return coarse.count == 1
            ? Localized.text(
                "Turn, tool and clock counts cover %d of %d servers — %@ reports per-conversation totals only.",
                servers - coarse.count, servers, names)
            : Localized.text(
                "Turn, tool and clock counts cover %d of %d servers — %@ report per-conversation totals only.",
                servers - coarse.count, servers, names)
    }
}

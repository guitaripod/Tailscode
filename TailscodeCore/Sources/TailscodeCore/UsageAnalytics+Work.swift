import CodingAgentKit
import Foundation

extension UsageAnalytics {
    /// Money is the yardstick wherever any was spent and the work did not mostly run for free. An
    /// account whose models all run on a machine the person owns has no money to scale by, and a
    /// chart of zeroes would say the month never happened; one that did most of its work there
    /// and paid a little for the rest is about the work, with the bill a line beneath. Either way
    /// it is measured in the work itself.
    static func measuresMoney(costUSD: Double, localLed: Bool) -> Bool {
        costUSD > 0 && !localLed
    }

    /// Whether the work mostly ran on the person's own hardware. Compared as tokens rather than
    /// as a rounded percentage, so a window at 49.6% is not called led by the rounding.
    static func isLocalLed(localTokens: Int, allTokens: Int) -> Bool {
        localTokens > 0 && allTokens > 0
            && Double(localTokens) >= Double(allTokens) * localLedShare
    }

    /// The models that did work through a door on the person's own machine, busiest first.
    static func localRows(
        _ models: [String: SessionSpendReport.ModelShare]
    ) -> [SessionSpendReport.ModelShare] {
        models.values.filter { door(of: $0) == .local && $0.tokens.fresh > 0 }.sorted(by: byWork)
    }

    /// What one machine's models went through: all on the person's own hardware, some of them,
    /// or none of them. It is what says whether that machine's daily buckets are a local
    /// model's alone.
    enum Serving {
        case local
        case mixed
        case none
    }

    static func door(ofServing models: [SessionSpendReport.ModelShare]) -> Serving {
        var rows: [String: SessionSpendReport.ModelShare] = [:]
        for model in models {
            var row = rows[model.model] ?? SessionSpendReport.ModelShare(
                model: model.model, turns: 0, tokens: .init(), costUSD: 0)
            row.tokens = add(row.tokens, model.tokens)
            rows[model.model] = row
        }
        let doors = adoptDoors(rows).values.filter { $0.tokens.fresh > 0 }.map(door(of:))
        let local = doors.filter { $0 == .local }.count
        if local == 0 { return .none }
        return local == doors.count ? .local : .mixed
    }

    /// The bill an account that leads with its work still ran up, as a dim line under the number.
    static func hostedLine(costUSD: Double, prefix: String, estimated: Bool) -> String {
        let money = SessionSpend.money(costUSD)
        return estimated
            ? Localized.text("%@ of hosted spend, an estimate", money)
            : Localized.text("%@ of hosted spend", money)
    }

    /// The trailing value of a project, machine or record whose door is not known. In an account
    /// measured by its money it is the money; in one that spent nothing it is the word for what a
    /// zero means on a machine the person owns; in one that leads with its work but paid a little
    /// it is the work, because a zero there could be a plan or a local model and nothing says.
    static func unpricedRow(
        costUSD: Double, tokens: SessionSpendReport.Tokens, prefix: String, priced: Bool,
        byWork: Bool
    ) -> (value: String, isFree: Bool) {
        if byWork { return (StatusFacts.tokens(tokens.fresh), false) }
        let door: ModelDoorKind? = priced ? nil : .local
        return (
            value(costUSD: costUSD, tokens: tokens, prefix: prefix, door: door),
            isFree(costUSD: costUSD, tokens: tokens, door: door)
        )
    }

    /// A window as a person says it: 262k, 1M. Never a decimal on a thousand, because a context
    /// window is a size class and 262.1k reads as a measurement.
    static func contextLabel(_ window: Int) -> String {
        if window >= 1_000_000 {
            let tenths = Int((Double(window) / 100_000).rounded())
            return tenths % 10 == 0 ? "\(tenths / 10)M" : "\(tenths / 10).\(tenths % 10)M"
        }
        if window >= 1000 { return "\(Int((Double(window) / 1000).rounded()))k" }
        return "\(window)"
    }

    /// What the speed ledger remembers of a model. The ledger is keyed by the id a turn carries,
    /// which has no door in front of it, and a ledger row is keyed by the door and the id.
    private static func speed(
        of model: String, in ledger: ModelSpeedLedger
    ) -> ModelSpeedLedger.Reading? {
        let bare = model.firstIndex(of: "/").map { String(model[model.index(after: $0)...]) }
        return bare.flatMap { ledger.reading(model: $0) } ?? ledger.reading(model: model)
    }

    private static func speedWord(_ reading: ModelSpeedLedger.Reading) -> String {
        Localized.text("%@ tok/s", ResponseStats.rate(reading.tokensPerSecond))
    }

    /// The share of the window the local work is, as a person reads a percentage: never zero for
    /// something, never a hundred while anything else ran, and never half for an account that is
    /// not led by it.
    private static func shareWord(
        _ share: Double, led: Bool, everything: Bool
    ) -> String {
        var points = Int((share * 100).rounded())
        if !led { points = min(points, 49) }
        if !everything { points = min(points, 99) }
        return points == 0 ? "<1%" : "\(points)%"
    }

    static func localWork(
        rows: [SessionSpendReport.ModelShare], allTokens: Int, led: Bool, activeDays: Int?,
        prefix: String, names: Names, contextWindows: [String: Int], speeds: ModelSpeedLedger
    ) -> LocalWork? {
        guard !rows.isEmpty else { return nil }
        let tokens = rows.reduce(0) { $0 + $1.tokens.fresh }
        let share = min(1, Double(tokens) / Double(max(allTokens, tokens)))
        let generated = rows.reduce(0) { $0 + $1.tokens.output }
        let read = tokens - generated
        let separates = generated > 0 && read > 0
        let turns = rows.reduce(0) { $0 + $1.turns }
        let shown = rows.prefix(modelLimit)
        let labels = modelLabels(Array(shown), names: names)
        let providers = Set(rows.compactMap { ProviderIdentity.provider(ofModel: $0.model) })
        let peak = Double(rows.first?.tokens.fresh ?? 0)
        let meters = shown.map { row -> Meter in
            let short = names(row.model)
            let label = labels[row.model] ?? short
            let provider = ProviderIdentity.provider(ofModel: row.model)
            var detail = workDetail(
                turns: row.turns, counted: row.tokens.fresh, costUSD: row.costUSD,
                prefix: prefix,
                through: providers.count > 1 && label == short ? provider : nil)
            if let window = contextWindows[row.model], window > 0 {
                detail += " · " + Localized.text("%@ context", contextLabel(window))
            }
            return Meter(
                label: label, detail: detail,
                money: value(
                    costUSD: row.costUSD, tokens: row.tokens, prefix: prefix, door: .local),
                share: peak > 0 ? Double(row.tokens.fresh) / peak : 0,
                isFree: isFree(costUSD: row.costUSD, tokens: row.tokens, door: .local),
                door: .local,
                speed: speed(of: row.model, in: speeds).map(speedWord))
        }

        var stats = [
            LocalWork.Stat(
                label: Localized.text("Work"), value: StatusFacts.tokens(tokens),
                detail: Localized.text("tokens")),
            LocalWork.Stat(
                label: Localized.text("Share of work"),
                value: shareWord(share, led: led, everything: tokens >= allTokens),
                detail: Localized.text("of the window")),
        ]
        if separates {
            stats.append(
                LocalWork.Stat(
                    label: Localized.text("Wrote"), value: StatusFacts.tokens(generated),
                    detail: Localized.text("read %@", StatusFacts.tokens(read))))
        }
        if let fastest = rows.first(where: { speed(of: $0.model, in: speeds) != nil }),
            let reading = speed(of: fastest.model, in: speeds)
        {
            stats.append(
                LocalWork.Stat(
                    label: Localized.text("Speed"), value: speedWord(reading),
                    detail: labels[fastest.model] ?? names(fastest.model)))
        }
        if stats.count < 4, turns > 0 {
            stats.append(
                LocalWork.Stat(
                    label: Localized.text("Turns"), value: count(turns),
                    detail: activeDays.map { Localized.text("%d active days", $0) }))
        }

        let hidden = rows.dropFirst(modelLimit)
        let caption: String? =
            hidden.isEmpty
            ? nil
            : hidden.count == 1
                ? Localized.text(
                    "1 more local model not shown · %@ tokens",
                    StatusFacts.tokens(hidden.reduce(0) { $0 + $1.tokens.fresh }))
                : Localized.text(
                    "%d more local models not shown · %@ tokens", hidden.count,
                    StatusFacts.tokens(hidden.reduce(0) { $0 + $1.tokens.fresh }))
        return LocalWork(
            title: Localized.text("On your own machine"),
            headline: Localized.text("%@ tokens on your own hardware", StatusFacts.tokens(tokens)),
            tokens: tokens, share: share, generated: separates ? generated : nil,
            read: separates ? read : nil, turns: turns > 0 ? turns : nil, activeDays: activeDays,
            stats: stats, models: meters, caption: caption)
    }

    static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

import CodingAgentKit
import Foundation

/// What a model is, said once for a card a person holds a row to read: the facts the list had no
/// room for — how much it can hold, what it reads, what levels it takes — and what taking it now
/// would do to the conversation in hand.
///
/// Nothing here is invented. A figure the catalog did not publish is left out rather than guessed
/// (the catalog carries no price, so there is no price), a wall is the account's own reading, and
/// the cost of switching is the one the transcript can count: a count of tokens, never money.
public struct ModelPeekReading: Sendable, Equatable {
    public struct Fact: Sendable, Equatable {
        public let value: String
        public let label: String
    }

    public let name: String
    public let detail: String
    public let facts: [Fact]
    public let abilities: [String]
    public let levels: [String]
    public let wall: String?
    public let carry: String?
    public let switchCost: String?

    public static func of(
        _ candidate: ModelCandidate, selected: ModelSelection?, effort: String?,
        agentOptions: [String], contextTokens: Int?, quotas: [UsageQuota] = []
    ) -> ModelPeekReading {
        let model = candidate.primary.model
        let options = ModelEffort.options(
            models: [model], selection: candidate.selection, agentOptions: agentOptions)
        let levels = ModelDial.ascending(options: options)
        var facts: [Fact] = []
        if let window = model.contextWindow, window > 0 {
            facts.append(Fact(value: StatusFacts.tokens(window), label: Localized.text("context")))
        }
        facts.append(
            Fact(
                value: levels.isEmpty ? Localized.text("none") : "\(levels.count)",
                label: Localized.text("effort levels")))
        if candidate.isLocal {
            facts.append(
                Fact(value: Localized.text("Local"), label: Localized.text("Runs on the server's own hardware")))
        }
        let current = !candidate.isElsewhere && candidate.carries(selected)
        let carry = !current && !candidate.isElsewhere
            ? ModelEffort.carry(effort, options: options).forecast(modelName: candidate.name) : nil
        let place = candidate.isElsewhere ? candidate.serverName : nil
        let detail = ([place].compactMap { $0 } + candidate.providerNames).joined(separator: " · ")
        return ModelPeekReading(
            name: candidate.name, detail: detail, facts: facts,
            abilities: ModelFact.of(candidate).filter(\.isCapability).map(\.label),
            levels: levels,
            wall: ModelChooser.wall(for: candidate, quotas: quotas).map(QuotaSurface.bannerBody),
            carry: carry,
            switchCost: current || candidate.isElsewhere
                ? nil : SwitchCost.line(contextTokens: contextTokens))
    }
}

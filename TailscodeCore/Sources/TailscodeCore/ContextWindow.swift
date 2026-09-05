import CodingAgentKit
import Foundation

/// How full the model's context window is, read once for every client.
///
/// The number that matters is not how many tokens the conversation has *spent* — that is the bill,
/// and a turn of forty tool calls bills its context forty times over — but how many the model was
/// handed on its last request, which is what has to fit next time. Every backend that can say so
/// says it on the message (`ChatMessage.context`); the window it has to fit in comes from the
/// server's catalog or, failing that, from what the model's name is known to hold; and a transcript
/// nobody has measured is estimated from its own characters and marked as such. A compaction
/// resets the count to what survived it. The words, the tone and the slices are decided here, so a
/// client decides only how round a ring is.
public struct ContextFill: Sendable, Equatable {
    public enum Basis: Sendable, Equatable {
        /// The server said what the last request held.
        case reported
        /// Read off a compaction seam the server measured: only the summary survived.
        case compacted
        /// Counted from the transcript's own text, because no server said.
        case estimated
    }

    /// The register the fill is drawn in. Quiet while there is room to spare, attention once the
    /// next long answer is worth thinking about, danger when a compaction is close.
    public enum Tone: Sendable, Equatable {
        case quiet
        case attention
        case danger
    }

    /// One band of the window: what kind of tokens they are and how much of the window they take.
    public struct Slice: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let tokens: Int
        /// `0...1` of the window when it is known, of what is used otherwise.
        public let share: Double
    }

    public let used: Int
    public let window: Int?
    public let model: String?
    public let basis: Basis
    public let slices: [Slice]

    public static let attentionAt = 0.5
    public static let dangerAt = 0.8

    public init(used: Int, window: Int?, model: String?, basis: Basis, tiers: MessageUsage? = nil) {
        self.used = used
        self.window = window
        self.model = model
        self.basis = basis
        self.slices = Self.slices(tiers, used: used, window: window)
    }

    public var fraction: Double? {
        guard let window, window > 0 else { return nil }
        return min(1, Double(used) / Double(window))
    }

    public var percent: Int? { fraction.map { Int(($0 * 100).rounded()) } }
    public var remaining: Int? { window.map { max(0, $0 - used) } }
    public var isEstimate: Bool { basis != .reported }

    public var tone: Tone {
        guard let fraction else { return used > Self.wordlessWarning ? .attention : .quiet }
        if fraction >= Self.dangerAt { return .danger }
        if fraction >= Self.attentionAt { return .attention }
        return .quiet
    }

    /// What the band wears: the share first because it is the fact you act on, the count after it
    /// because it is the fact you compare. A count with no window is only a count.
    public var badge: String {
        let count = (isEstimate ? "~" : "") + StatusFacts.tokens(used)
        guard let percent else { return count }
        return "\(percent)% · \(count)"
    }

    public var title: String { Localized.text("Context window") }

    /// The hero line of the panel: what is in the window against what it holds.
    public var headline: String {
        guard let window else { return Localized.text("%@ tokens", StatusFacts.tokens(used)) }
        return Localized.text("%@ of %@", StatusFacts.tokens(used), StatusFacts.tokens(window))
    }

    /// One sentence for a reader in a hurry: the share, whose window, and what is left.
    public var summary: String {
        let name = model.map(ModelBadge.shortName)
        guard let percent, let window, let remaining else {
            if let name {
                return Localized.text(
                    "%@ tokens are in the conversation. How much %@ can hold is not reported, so there is no share to state.",
                    StatusFacts.tokens(used), name)
            }
            return Localized.text(
                "%@ tokens are in the conversation. This model's window is not reported, so there is no share to state.",
                StatusFacts.tokens(used))
        }
        let whose = name.map { Localized.text("%@'s %@ window", $0, StatusFacts.tokens(window)) }
            ?? Localized.text("the %@ window", StatusFacts.tokens(window))
        if remaining == 0 {
            return Localized.text("%@ is full. The next request has to compact first.", whose.capitalizedFirst)
        }
        return Localized.text(
            "%d%% of %@ is in use, with room for about %@ more.", percent, whose,
            StatusFacts.tokens(remaining))
    }

    /// What to do about it, when there is something to do. Nil while the room is comfortable.
    public var advice: String? {
        switch tone {
        case .quiet: return nil
        case .attention:
            return Localized.text(
                "Getting fuller. Compacting trades the transcript for a summary and frees most of it.")
        case .danger:
            return Localized.text(
                "Close to full. A long answer or a big file read may not fit; compacting now frees the room on your terms rather than mid-turn.")
        }
    }

    /// Where the number came from, said plainly, because a fill presented as measured when it was
    /// guessed is the one lie this surface can tell.
    public var source: String {
        switch basis {
        case .reported:
            return Localized.text("Reported by the server from the last request the model was sent")
        case .compacted:
            return Localized.text("Read from the compaction: only the summary is still in the window")
        case .estimated:
            return Localized.text("Estimated from the transcript itself; the server did not say")
        }
    }

    /// The facts under the hero, in the order a person asks them.
    public var facts: [(label: String, value: String)] {
        var rows: [(String, String)] = [(Localized.text("in use"), StatusFacts.tokens(used))]
        if let window { rows.append((Localized.text("window"), StatusFacts.tokens(window))) }
        if let remaining { rows.append((Localized.text("free"), StatusFacts.tokens(remaining))) }
        if let model { rows.append((Localized.text("model"), ModelBadge.shortName(model))) }
        return rows
    }

    /// The state in words for a screen reader, which cannot read a ring.
    public var accessibilityLabel: String {
        var words = [title, headline]
        if let percent { words.append(Localized.text("%d percent in use", percent)) }
        if isEstimate { words.append(Localized.text("estimated")) }
        return words.joined(separator: ", ")
    }

    /// A count that is worth a second look even with no window to measure it against.
    private static let wordlessWarning = 300_000

    private static func slices(_ tiers: MessageUsage?, used: Int, window: Int?) -> [Slice] {
        guard let tiers, !tiers.isEmpty else { return [] }
        let whole = Double(max(window ?? used, 1))
        let bands: [(String, String, Int)] = [
            ("cacheRead", Localized.text("Cache read"), tiers.cacheRead),
            ("cacheWrite", Localized.text("Cache written"), tiers.cacheWrite),
            ("input", Localized.text("Fresh input"), tiers.input),
            ("output", Localized.text("Answer"), tiers.written),
        ]
        return bands.filter { $0.2 > 0 }.map {
            Slice(id: $0.0, label: $0.1, tokens: $0.2, share: Double($0.2) / whole)
        }
    }

    /// The fill of a conversation as it stands, from the transcript and what is known of the model.
    ///
    /// - Parameters:
    ///   - messages: the transcript, oldest first.
    ///   - sessionModel: what the session record says it runs, for a chat with no answer in it yet.
    ///   - catalog: the server's model catalog, whose stated limits outrank anything known by name.
    public static func read(
        messages: [ChatMessage], sessionModel: String? = nil, catalog: [ModelInfo] = []
    ) -> ContextFill? {
        let model = messages.last(where: { $0.role == .assistant && $0.modelID != nil })?.modelID
            ?? sessionModel
        var used: Int?
        var basis = Basis.estimated
        var tiers: MessageUsage?
        scan: for message in messages.reversed() {
            for part in message.parts.reversed() {
                if case .compaction(let compaction) = part.kind {
                    if let after = compaction.tokensAfter {
                        used = after
                        basis = .compacted
                    } else {
                        used = StatusFacts.estimateContextTokens([message])
                    }
                    break scan
                }
            }
            if message.role == .assistant, let context = message.context, !context.isEmpty {
                used = context.total
                tiers = context
                basis = .reported
                break
            }
        }
        if used == nil { used = StatusFacts.estimateContextTokens(messages) }
        guard let used else { return nil }
        let window = ContextWindow.resolve(model: model, catalog: catalog, observed: used)
        return ContextFill(used: used, window: window, model: model, basis: basis, tiers: tiers)
    }
}

/// How many tokens a model holds at once, from the best source that can say.
///
/// A server's catalog is the authority where it states a limit — opencode publishes one per model
/// — and Claude's own aliases are stated by the bridge's catalog. A model reached by a name the
/// catalog does not carry is looked up by what its name is known to hold; a name nobody knows is
/// nil, which every surface renders as a count without a share rather than as a made-up ceiling.
public enum ContextWindow {
    public static func resolve(model: String?, catalog: [ModelInfo], observed: Int) -> Int? {
        guard let model, !model.isEmpty else { return nil }
        let window = fromCatalog(model, catalog: catalog) ?? known(model)
        guard let window else { return nil }
        if observed > window { return stretched(model, past: window) }
        return window
    }

    /// The catalog's own limit for the model, by the exact id first and then by the alias inside a
    /// dated id: a transcript names `claude-opus-4-8-20260101` where the catalog offers `opus`.
    static func fromCatalog(_ model: String, catalog: [ModelInfo]) -> Int? {
        let lower = model.lowercased()
        if let exact = catalog.first(where: { $0.id.lowercased() == lower && $0.contextWindow != nil }) {
            return exact.contextWindow
        }
        let candidates = catalog.filter { info in
            guard let limit = info.contextWindow, limit > 0 else { return false }
            let alias = info.id.lowercased()
            guard !alias.contains("[") else { return false }
            return lower.hasSuffix("/" + alias) || lower.contains("-" + alias + "-")
                || lower.hasSuffix("-" + alias) || lower.hasPrefix(alias + "-")
        }
        return candidates.compactMap(\.contextWindow).min()
    }

    /// What a model's name is known to hold, for a server that states no limit of its own.
    public static func known(_ model: String) -> Int? {
        let name = model.lowercased()
        if name.contains("[1m]") || name.contains("-1m") { return 1_000_000 }
        let table: [(String, Int)] = [
            ("claude", 200_000), ("fable", 200_000), ("opus", 200_000), ("sonnet", 200_000),
            ("haiku", 200_000),
            ("gpt-5", 400_000), ("gpt-4.1", 1_047_576), ("gpt-4o", 128_000), ("o3", 200_000),
            ("o4", 200_000), ("codex", 400_000),
            ("gemini", 1_048_576),
            ("grok-4", 256_000), ("grok-3", 131_072), ("grok-code", 256_000),
            ("deepseek", 128_000), ("kimi", 256_000), ("qwen3", 262_144), ("qwen", 131_072),
            ("glm", 200_000), ("llama", 131_072), ("mistral", 128_000), ("devstral", 262_144),
            ("gemma", 131_072), ("gpt-oss", 131_072),
        ]
        for (needle, window) in table where name.contains(needle) { return window }
        return nil
    }

    /// A fill larger than the window it was matched to means the match was wrong, not the fill:
    /// Claude's dated ids never say whether the account runs the million-token window, so a read
    /// past two hundred thousand is that window. Anything else is unknown rather than invented.
    private static func stretched(_ model: String, past window: Int) -> Int? {
        let name = model.lowercased()
        if name.contains("claude") || name.contains("opus") || name.contains("sonnet")
            || name.contains("fable")
        {
            return 1_000_000
        }
        return nil
    }
}

extension String {
    fileprivate var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

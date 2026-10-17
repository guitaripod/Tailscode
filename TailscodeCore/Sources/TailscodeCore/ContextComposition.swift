import CodingAgentKit
import Foundation

/// What the context window is made of: not the billing tiers (those are `ContextFill.slices`) but
/// the content — the system prompt and tool definitions, what the person said, what the model
/// answered, what its tools returned, pictures, a compaction's summary.
///
/// A server measures the window as one number. This divides it by what each part of the transcript
/// weighs by its own characters, and then **scales every share so the whole is exactly the measured
/// total**: a character count is a rough weight and the sum of rough weights is not to be trusted,
/// but the total is, so the shares are a way of dividing a measured thing and are always marked as
/// estimates of it. What the transcript cannot account for — the system prompt, tool definitions
/// and memory files, which are in every request and in no message — is read from the first request
/// of this life of the window: what it was handed minus what the first turn's words weigh.
public struct ContextComposition: Sendable, Equatable {
    public struct Slice: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let tokens: Int
        public let share: Double
    }

    /// One tool result or call that takes a notable part of the window. The message and part ids
    /// are the transcript's own, so a client can scroll to the row.
    public struct Item: Sendable, Equatable, Identifiable {
        public let id: String
        public let messageID: String
        public let tool: String
        public let detail: String?
        public let tokens: Int
        public let share: Double
        /// The prompt this belongs to, counted from the start of the conversation.
        public let turn: Int
    }

    public let total: Int
    public let slices: [Slice]
    public let items: [Item]

    /// Rough tokens per character of text, code and prose together.
    private static let charsPerToken = 4
    private static let tokensPerImage = 1_500
    private static let namedItems = 3
    private static let smallestItemShare = 0.02

    public static func read(messages: [ChatMessage], fill: ContextFill) -> ContextComposition? {
        guard fill.basis == .reported, fill.used > 0 else { return nil }
        let burn = ContextBurn.read(messages: messages, fill: fill, wholeConversation: true)
        let epochStart = Self.epochStart(in: messages)
        var weights = Weights()
        var turn = messages[..<epochStart].filter { $0.role == .user }.count
        var firstTurnWeight: Int?
        var firstFootprint: Int?
        if let burn, let first = burn.turns.last(where: \.startsEpoch) ?? burn.turns.first {
            firstFootprint = first.footprint
        }

        for index in epochStart..<messages.count {
            let message = messages[index]
            if message.role == .user { turn += 1 }
            weights.add(message, turn: turn)
            if firstTurnWeight == nil, let firstID = burn.flatMap({ firstTurnID(in: $0) }),
                message.id == firstID
            {
                firstTurnWeight = weights.estimateTotal
            }
        }
        let system = max(0, (firstFootprint ?? 0) - (firstTurnWeight ?? 0))
        return scaled(weights, system: firstFootprint == nil ? 0 : system, total: fill.used)
    }

    private static func firstTurnID(in burn: ContextBurn) -> String? {
        (burn.turns.last(where: \.startsEpoch) ?? burn.turns.first)?.messageID
    }

    private static func epochStart(in messages: [ChatMessage]) -> Int {
        guard
            let seam = messages.lastIndex(where: { message in
                message.parts.contains { part in
                    if case .compaction = part.kind { return true }
                    return false
                }
            })
        else { return 0 }
        return seam
    }

    private struct Weights {
        var you = 0
        var answers = 0
        var tools = 0
        var images = 0
        var summary = 0
        var calls: [(id: String, messageID: String, tool: String, detail: String?, tokens: Int, turn: Int)] = []

        var estimateTotal: Int { you + answers + tools + images + summary }

        mutating func add(_ message: ChatMessage, turn: Int) {
            for part in message.parts {
                switch part.kind {
                case .text(let text):
                    let tokens = ContextComposition.estimate(text)
                    if message.role == .user { you += tokens } else { answers += tokens }
                case .tool(let call):
                    let tokens =
                        ContextComposition.estimate(call.name) + 10
                        + ContextComposition.estimate(call.output ?? "")
                        + ContextComposition.size(of: call.input) / ContextComposition.charsPerToken
                    tools += tokens
                    let (tool, detail) = ContextComposition.describe(call)
                    calls.append((
                        "\(message.id):\(part.id)", message.id, tool, detail, tokens, turn
                    ))
                case .file(let file):
                    if file.mime?.hasPrefix("image/") == true {
                        images += ContextComposition.tokensPerImage
                    } else {
                        you += ContextComposition.estimate(file.filename ?? file.path ?? "") + 20
                    }
                case .compaction(let compaction):
                    summary += ContextComposition.estimate(compaction.summary ?? "")
                case .reasoning, .note, .unknown:
                    continue
                }
            }
        }
    }

    private static func scaled(_ weights: Weights, system: Int, total: Int) -> ContextComposition? {
        var systemTokens = min(system, total)
        let estimate = weights.estimateTotal
        if estimate == 0 {
            systemTokens = total
        } else if total - systemTokens == 0 {
            systemTokens = total / 2
        }
        let scale = estimate == 0 ? 0 : Double(total - systemTokens) / Double(estimate)

        var rows: [(id: String, label: String, tokens: Int)] = [
            ("system", Localized.text("System & tools"), systemTokens),
            ("you", Localized.text("You"), Int((Double(weights.you) * scale).rounded())),
            ("answers", Localized.text("Answers"), Int((Double(weights.answers) * scale).rounded())),
            ("tools", Localized.text("Tool output"), Int((Double(weights.tools) * scale).rounded())),
            ("images", Localized.text("Images"), Int((Double(weights.images) * scale).rounded())),
            ("summary", Localized.text("Summary"), Int((Double(weights.summary) * scale).rounded())),
        ]
        let drift = total - rows.reduce(0) { $0 + $1.tokens }
        if drift != 0, let largest = rows.indices.max(by: { rows[$0].tokens < rows[$1].tokens }) {
            rows[largest].tokens += drift
        }
        let whole = Double(max(total, 1))
        let slices = rows.filter { $0.tokens > 0 }.map {
            Slice(id: $0.id, label: $0.label, tokens: $0.tokens, share: Double($0.tokens) / whole)
        }
        let items = weights.calls
            .map { call in
                Item(
                    id: call.id, messageID: call.messageID, tool: call.tool, detail: call.detail,
                    tokens: Int((Double(call.tokens) * scale).rounded()),
                    share: Double(call.tokens) * scale / whole, turn: call.turn)
            }
            .filter { $0.share >= smallestItemShare }
            .sorted { $0.tokens > $1.tokens }
            .prefix(namedItems)
        guard !slices.isEmpty else { return nil }
        return ContextComposition(total: total, slices: slices, items: Array(items))
    }

    fileprivate static func estimate(_ text: String) -> Int {
        text.utf8.count / charsPerToken
    }

    fileprivate static func size(of value: JSONValue?) -> Int {
        switch value {
        case .none, .null: return 0
        case .bool: return 5
        case .integer, .number: return 8
        case .string(let text): return text.utf8.count
        case .array(let values): return values.reduce(2) { $0 + size(of: $1) + 1 }
        case .object(let fields): return fields.reduce(2) { $0 + $1.key.utf8.count + size(of: $1.value) + 4 }
        }
    }

    /// The tool's name and the one argument that says what it was pointed at — a path, a command,
    /// a pattern — kept short enough for a row. Read from the raw input, never from the call's
    /// structured summary, which parses the output too.
    fileprivate static func describe(_ call: ToolCall) -> (tool: String, detail: String?) {
        guard case .object(let fields)? = call.input else { return (call.name, nil) }
        for key in ["file_path", "path", "filePath", "command", "pattern", "url", "query", "description"] {
            guard case .string(let value)? = fields[key], !value.isEmpty else { continue }
            let detail = key.lowercased().contains("path")
                ? String(value.split(separator: "/").last ?? Substring(value))
                : String(value.prefix(48))
            return (call.name, detail)
        }
        return (call.name, nil)
    }
}

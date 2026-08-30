import CodingAgentKit
import Foundation

/// What one answer actually cost to produce, read off the turn itself.
///
/// This is deliberately not the spend panel. Spend is the conversation's account and opens; this is
/// a single line under a single answer, for the question a person asks while reading it — was that
/// slow, was that expensive, what wrote it. It is off by default because most reading does not want
/// it, and the whole point of an opt-in is that turning it on gets the same numbers everywhere.
///
/// Every figure is the server's own arithmetic or a division of two of the server's own numbers.
/// Nothing here is sampled, timed by the client, or interpolated: a client that measured the wait
/// with its own clock would report the network and the app's own scheduling as the model's speed,
/// and two devices watching one conversation would disagree about the same answer. What cannot be
/// derived is left out rather than guessed — a turn whose server said nothing about tokens shows
/// its clock and no rate, and a turn that said nothing at all shows no strip.
///
/// The rate is computed from ``MessageUsage/written`` and never from a total. A turn that read a
/// hundred thousand cached tokens and wrote two hundred did not run at five hundred tokens a
/// second; only the tokens the model produced were produced at the model's speed.
///
/// Where the server also stamped when the first output token landed (``MessagePart/startedAt``),
/// the wait is split the way DeepSeek's harness splits it: the time to that first token is its own
/// figure — the queue and the prompt being read — and the rate is measured only over the
/// generation that followed, because dividing an answer by a wait that includes thirty seconds of
/// prefill reports the prompt's size as the model's slowness. A backend that stamps nothing gets
/// the honest fallback: one rate over the whole wait, and no first-token figure invented for it.
public struct ResponseStats: Sendable, Hashable {
    public let facts: [ResponseStat]
    /// Whether the money was priced from a rate table rather than billed. Always true today —
    /// every backend that reports a per-turn figure prices it — and stated rather than assumed so
    /// a backend that ever bills exactly can stop apologising for it.
    public let estimatedCost: Bool

    public var isEmpty: Bool { facts.isEmpty }

    /// The whole strip as one line, for a surface with no room to lay facts out — a tooltip, a
    /// screen reader, a narrow status band.
    public var line: String { facts.map { "\($0.value)" }.joined(separator: "  ·  ") }

    /// The same line spelled out, which is what a screen reader is given: a strip of five numbers
    /// with no words attached is unreadable without sight of the symbols beside them.
    public var spoken: String { facts.map { "\($0.value) \($0.label)" }.joined(separator: ", ") }

    /// The stats for one settled assistant turn, or nil where there is nothing honest to say.
    ///
    /// - Parameter promptedAt: when the person pressed return, where the client knows it. A server
    ///   that measured the turn itself (``ChatMessage/duration``) outranks it, because the server
    ///   holds the transcript and this device may have joined the conversation halfway through.
    ///
    /// Nil for a turn still being written: a rate over a partial answer moves under the reader's
    /// eye, and everything settled in this app holds perfectly still. Nil for a turn that failed,
    /// which already has a surface saying more than a number could.
    public init?(turn: ChatMessage, promptedAt: Date? = nil) {
        guard turn.role == .assistant, !turn.isStreaming, turn.error == nil else { return nil }
        let elapsed = Self.elapsed(of: turn, promptedAt: promptedAt)
        var facts: [ResponseStat] = []

        let usage = turn.usage
        let firstToken = Self.firstToken(of: turn, promptedAt: promptedAt)
        let generation = Self.generation(of: turn)
        if let usage, usage.written > 0 {
            let measured = generation ?? elapsed
            if let measured, measured >= Self.rateFloor {
                let rate = Double(usage.written) / measured
                let detail =
                    generation != nil
                    ? Localized.text(
                        "%@ tokens written in %@ of generation, measured from the first output token so the prompt being read does not count against the model.",
                        StatusFacts.tokens(usage.written), Self.clock(measured))
                    : Localized.text(
                        "%@ tokens written in %@ — the tokens the model produced, over the whole wait.",
                        StatusFacts.tokens(usage.written), Self.clock(measured))
                let ledger = ModelSpeedLedger.shared
                ledger.record(
                    turnID: turn.id, model: turn.modelID ?? "", tokens: usage.written,
                    seconds: measured)
                let average = ledger.sentence(model: turn.modelID)
                facts.append(
                    ResponseStat(
                        kind: .speed, symbol: "gauge.with.dots.needle.67percent", glyph: "⏱",
                        value: Localized.text("%@ tok/s", Self.rate(rate)),
                        label: Localized.text("output speed"),
                        detail: average.map { "\(detail) \($0)" } ?? detail))
            }
        }

        if let firstToken, firstToken >= 0.05 {
            facts.append(
                ResponseStat(
                    kind: .firstToken, symbol: "bolt", glyph: "⚡",
                    value: Self.clock(firstToken),
                    label: Localized.text("to first token"),
                    detail: Localized.text(
                        "From the prompt going out to the first token the model wrote — the queue and the prompt being read, before any generating began.")))
        }

        if let elapsed {
            facts.append(
                ResponseStat(
                    kind: .elapsed, symbol: "clock", glyph: "◷", value: Self.clock(elapsed),
                    label: Localized.text("elapsed"),
                    detail: Localized.text(
                        "From the moment the prompt went out to the last thing this turn wrote.")))
        }

        if let usage, usage.written > 0 {
            facts.append(
                ResponseStat(
                    kind: .written, symbol: "arrow.up", glyph: "↑",
                    value: StatusFacts.tokens(usage.written),
                    label: Localized.text("written"),
                    detail: usage.reasoning > 0
                        ? Localized.text(
                            "%@ of answer and %@ of thinking.", StatusFacts.tokens(usage.output),
                            StatusFacts.tokens(usage.reasoning))
                        : Localized.text("Tokens this turn produced.")))
        }

        if let usage, usage.read > 0 {
            facts.append(
                ResponseStat(
                    kind: .read, symbol: "arrow.down", glyph: "↓",
                    value: StatusFacts.tokens(usage.read),
                    label: Localized.text("read"),
                    detail: Self.readDetail(usage)))
        }

        if let cost = turn.costUSD, cost > 0 {
            facts.append(
                ResponseStat(
                    kind: .cost, symbol: "creditcard", glyph: "¤",
                    value: "~" + SessionSpend.money(cost),
                    label: Localized.text("estimated"),
                    detail: Localized.text(
                        "What these tokens would have cost on the metered API. A subscription bills a flat fee, so this is never a bill.")))
        }

        if let chip = ModelBadge.chip(model: turn.modelID, effort: turn.reasoningEffort) {
            facts.append(
                ResponseStat(
                    kind: .model, symbol: "cpu", glyph: "◆",
                    value: chip.effort.map { "\(chip.name) \($0)" } ?? chip.name,
                    label: Localized.text("answered by"),
                    detail: Localized.text("The model the server recorded on this turn's own calls.")))
        }

        guard !facts.isEmpty else { return nil }
        self.facts = facts
        self.estimatedCost = true
    }

    /// The turn at `index`, with the prompt above it found for the elapsed. Clients hold a
    /// transcript rather than a turn, and pairing an answer with the question that started it is
    /// the one thing they would otherwise each do differently.
    public static func read(_ messages: [ChatMessage], at index: Int) -> ResponseStats? {
        guard messages.indices.contains(index) else { return nil }
        var promptedAt: Date?
        var walk = index - 1
        while walk >= 0 {
            if messages[walk].role == .user {
                promptedAt = messages[walk].createdAt
                break
            }
            walk -= 1
        }
        return ResponseStats(turn: messages[index], promptedAt: promptedAt)
    }

    /// The turn identified by id, for a client that renders rows rather than indices.
    public static func read(_ messages: [ChatMessage], id: String) -> ResponseStats? {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        return read(messages, at: index)
    }

    /// How long the whole wait was. The server's own measure wins; otherwise the turn's stamps,
    /// starting from the prompt where the client knows it, because the queue and the model's first
    /// thought are part of the wait a person had.
    private static func elapsed(of turn: ChatMessage, promptedAt: Date?) -> TimeInterval? {
        if let reported = turn.duration, reported > 0 { return reported }
        guard let completed = turn.completedAt else { return nil }
        let start = min(promptedAt ?? turn.createdAt, turn.createdAt)
        let span = completed.timeIntervalSince(start)
        return span > 0 ? span : nil
    }

    /// When the model's first output token landed, read off the server's own part stamps. Only
    /// the parts the model wrote carry one — a tool part's clock times the tool — and the
    /// earliest of them is the seam between waiting and reading.
    private static func firstOutputAt(_ turn: ChatMessage) -> Date? {
        turn.parts.compactMap(\.startedAt).min()
    }

    /// The wait before the first output token, against the same start the elapsed uses. Nil where
    /// the server stamped no parts, and nil rather than nonsense where the stamps disagree with
    /// the message clock.
    private static func firstToken(of turn: ChatMessage, promptedAt: Date?) -> TimeInterval? {
        guard let first = firstOutputAt(turn) else { return nil }
        let start = min(promptedAt ?? turn.createdAt, turn.createdAt)
        let span = first.timeIntervalSince(start)
        return span > 0 ? span : nil
    }

    /// The generating span alone: first output token to the turn settling, both the server's own
    /// stamps. Nil where either stamp is missing, and the rate falls back to the whole wait.
    private static func generation(of turn: ChatMessage) -> TimeInterval? {
        guard let first = firstOutputAt(turn), let completed = turn.completedAt else { return nil }
        let span = completed.timeIntervalSince(first)
        return span > 0 ? span : nil
    }

    private static func readDetail(_ usage: MessageUsage) -> String {
        guard usage.cacheRead > 0 else {
            return Localized.text("Tokens this turn was handed, all of them fresh.")
        }
        let share = Int((Double(usage.cacheRead) / Double(usage.read) * 100).rounded())
        return Localized.text(
            "%d%% of it read back out of cache, which costs a tenth of fresh input.", share)
    }

    /// Below this, a duration is too short for a rate to mean anything: a turn that answered in
    /// two hundred milliseconds divides into a figure that is arithmetically true and says only
    /// that the clock had no resolution.
    private static let rateFloor: TimeInterval = 0.5

    /// A rate at the precision it is worth reading. Tokens a second is a two-digit number for
    /// every model anyone runs, so decimals below ten and none above.
    static func rate(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
    }

    /// A turn's clock, which is finer than a conversation's: seconds matter here, and a turn that
    /// took eleven and a half seconds must not read the same as one that took eleven.
    static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let whole = Int(seconds.rounded())
        if whole < 3600 { return "\(whole / 60)m \(whole % 60)s" }
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }
}

/// One number in the strip, with everything three clients need to draw it and nothing about how.
///
/// The symbol is for the Apple clients and the glyph for the text ones, which is the same division
/// every other shared surface makes. `value` is what is drawn; `label` is what it is; `detail` is
/// the sentence a tooltip or a screen reader gets, and is the only place a caveat may live — a
/// number that needs an asterisk beside it is a number the strip should not be showing.
public struct ResponseStat: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case speed
        case firstToken
        case elapsed
        case written
        case read
        case cost
        case model
    }

    public let kind: Kind
    public let symbol: String
    public let glyph: String
    public let value: String
    public let label: String
    public let detail: String

    public var id: String { kind.rawValue }

    public init(
        kind: Kind, symbol: String, glyph: String, value: String, label: String, detail: String
    ) {
        self.kind = kind
        self.symbol = symbol
        self.glyph = glyph
        self.value = value
        self.label = label
        self.detail = detail
    }
}

/// Whether answers wear their own numbers. Off until somebody turns it on: a transcript is for
/// reading, and a rail of figures under every answer is a tax on the reading it is supposed to
/// inform. Device-local, like every other thing about how this app looks.
public enum ResponseStatsSetting {
    public static let defaultsKey = "tailscode.responseStats"
    public static let didChange = Notification.Name("tailscode.responseStats.didChange")

    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    public static func setEnabled(_ value: Bool) {
        if value {
            UserDefaults.standard.set(true, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static var title: String { Localized.text("Answer statistics") }

    public static var explanation: String {
        Localized.text(
            "Puts what each answer took under it — speed, time to first token, elapsed, tokens, estimated cost, and which model wrote it. Every figure is the server's own; nothing is timed here.")
    }
}

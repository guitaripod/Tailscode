import Foundation

/// A notice as it travels: what happened, in facts and the server's own words, never in
/// sentences.
///
/// A bridge speaks no language but its own, and a push is written while the phone sits in a pocket,
/// so what crosses the wire is the numbers and the quotes, and the device that shows it writes the
/// words in its reader's language (`NoticeWords`). The same shape is what the app puts in a local
/// notification's `userInfo`, so the notification service, the long-look extension and the app all
/// read one thing. This file imports nothing but Foundation, because the extensions compile it
/// by path rather than link the package.
public struct NoticeWire: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case done, failed, approval, question, usage
    }

    public struct Option: Codable, Sendable, Equatable {
        public var label: String
        public var detail: String?

        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }
    }

    /// The `userInfo` key a notice travels under.
    public static let key = "notice"
    /// The newest shape this build reads; a later one is read as far as its fields are known.
    public static let version = 1

    public var v: Int
    public var kind: Kind
    /// How long the turn took, whole seconds.
    public var seconds: Int?
    public var tools: Int?
    public var added: Int?
    public var removed: Int?
    /// The one passage the notice is about, raw: the answer, the error, the command, the question.
    public var text: String?
    /// Who or what it concerns beyond the chat: the tool an approval is for.
    public var subject: String?
    /// The words that began the turn, ready to be sent again after a failure.
    public var prompt: String?
    /// The options of a question that asked exactly one thing.
    public var options: [Option]?
    /// Whether that question takes more than one of them.
    public var multiple: Bool?
    /// Whether that question takes an answer of the person's own.
    public var free: Bool?
    public var server: String?
    public var agent: String?
    /// The head the turn left, as counts: which zones its steps were in, which failed, where it
    /// stopped. Added after version 1 and optional, so a sender that never heard of it still
    /// reads, and a notice without it wears the symbol it always did.
    public var glyph: NeuralGlyphWire?

    public init(
        kind: Kind, seconds: Int? = nil, tools: Int? = nil, added: Int? = nil,
        removed: Int? = nil, text: String? = nil, subject: String? = nil, prompt: String? = nil,
        options: [Option]? = nil, multiple: Bool? = nil, free: Bool? = nil,
        server: String? = nil, agent: String? = nil, glyph: NeuralGlyphWire? = nil
    ) {
        self.v = Self.version
        self.kind = kind
        self.seconds = seconds
        self.tools = tools
        self.added = added
        self.removed = removed
        self.text = text
        self.subject = subject
        self.prompt = prompt
        self.options = options
        self.multiple = multiple
        self.free = free
        self.server = server
        self.agent = agent
        self.glyph = glyph
    }

    /// The same notice, said to come from `server` and `agent`.
    public func located(on server: String?, agent: String?) -> NoticeWire {
        var copy = self
        copy.server = server?.isEmpty == false ? server : nil
        copy.agent = agent
        return copy
    }

    /// The notice as a property list a notification can carry.
    public func userInfoValue() -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(self),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// The notice a notification carries, or nil when it carries none or one that is not read.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let object = userInfo[Self.key] as? [String: Any],
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            let wire = try? JSONDecoder().decode(NoticeWire.self, from: data)
        else { return nil }
        self = wire
    }
}

/// A notice read into the words and the few things it can be answered with.
///
/// Words and facts rather than markup: each client draws them as its platform allows. A client
/// that cannot draw buttons or a reply field ignores `choices` and `replyPlaceholder`, and the
/// notice is still a better sentence than "Your agent finished."
public struct NoticeReading: Sendable, Equatable {
    public let headline: String
    public let facts: [String]
    public let excerpt: String
    public let detail: String
    /// The answers a question can be given at one press, in the words the agent offered. Empty
    /// unless exactly one question was asked, takes exactly one answer, and every option is short
    /// enough to be a button.
    public let choices: [String]
    /// What the reply field asks for, or nil where a reply would have nowhere to go.
    public let replyPlaceholder: String?
    /// The words that began a turn that failed, ready to be sent again.
    public let retryPrompt: String?
    /// The passage at the length a long look can hold, where `excerpt` is the length a banner can.
    public let passage: String
    /// Every option a question offered, with the reason the agent gave for each.
    public let options: [NoticeWire.Option]
    public let subject: String?
    /// What a finished turn did, as one sentence: "25 tools in 8m 25s: ran 18 commands, read 3
    /// files, edited 2 files (+5 −2)". Empty where the notice carries no counts to write it from.
    public let summary: String
    /// The same sentence without the count and the time before it, which the long look's tiles
    /// already show, set as a sentence of its own: "Ran 18 commands, read 3 files, ...".
    public let touched: String

    public init(
        headline: String, facts: [String] = [], excerpt: String = "", detail: String = "",
        choices: [String] = [], replyPlaceholder: String? = nil, retryPrompt: String? = nil,
        passage: String = "", options: [NoticeWire.Option] = [], subject: String? = nil,
        summary: String = "", touched: String = ""
    ) {
        self.headline = headline
        self.facts = facts
        self.excerpt = excerpt
        self.detail = detail
        self.choices = choices
        self.replyPlaceholder = replyPlaceholder
        self.retryPrompt = retryPrompt
        self.passage = passage.isEmpty ? excerpt : passage
        self.options = options
        self.subject = subject
        self.summary = summary
        self.touched = touched
    }

    /// The first line: what it is, then what it took.
    public var lead: String { ([headline] + facts).joined(separator: " · ") }

    /// The lines under the lead, in order, none of them empty.
    public var rest: [String] { [excerpt, detail].filter { !$0.isEmpty } }
}

/// The words of every notice, written once.
///
/// The server's quotes are cut and tidied here and the sentences around them are the catalogue's,
/// so a notice made on a bridge, on this device while the app ran, and by the Linux client reads
/// the same word for word, in the language of whoever is reading it.
public enum NoticeWords {
    public static let excerptLimit = 220
    public static let passageLimit = 600
    public static let choiceLimit = 3
    public static let choiceWidth = 32
    /// The shortest turn that is worth saying how long it took.
    public static let durationFloor = 5

    public static func reading(_ wire: NoticeWire) -> NoticeReading {
        switch wire.kind {
        case .done: return done(wire)
        case .failed: return failed(wire)
        case .approval: return approval(wire)
        case .question: return question(wire)
        case .usage:
            let words = collapse(wire.text ?? "")
            return NoticeReading(
                headline: wire.subject ?? "", excerpt: cut(words, to: excerptLimit),
                passage: cut(words, to: passageLimit))
        }
    }

    private static func done(_ wire: NoticeWire) -> NoticeReading {
        var facts = turnFacts(wire)
        if let added = wire.added, let removed = wire.removed, added + removed > 0 {
            facts.append("+\(added) −\(removed)")
        }
        let words = plain(wire.text ?? "")
        let account = account(of: wire)
        return NoticeReading(
            headline: sentence(Localized.text("finished")), facts: facts,
            excerpt: cut(words, to: excerptLimit),
            replyPlaceholder: Localized.text("Message your agent…"),
            passage: cut(words, to: passageLimit), summary: account.summary,
            touched: account.touched)
    }

    /// What a finished turn did, written from the counts its glyph carries. Both lines are empty
    /// for a notice that carries none, because the tool count alone says how much and not what.
    public static func account(of wire: NoticeWire) -> (summary: String, touched: String) {
        guard
            let counts = NeuralNoticeCounts(
                glyph: wire.glyph, tools: wire.tools, added: wire.added, removed: wire.removed)
        else { return ("", "") }
        let seconds = wire.seconds.map { TimeInterval($0) }
        let summary = NeuralNoticeLine.sentence(counts, seconds: seconds)
        return (summary, NeuralNoticeLine.clauses(counts).map(sentence) ?? "")
    }

    private static func failed(_ wire: NoticeWire) -> NoticeReading {
        let words = collapse(wire.text ?? "")
        let prompt = wire.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NoticeReading(
            headline: sentence(Localized.text("failed")), facts: turnFacts(wire),
            excerpt: cut(words, to: excerptLimit),
            replyPlaceholder: Localized.text("Message your agent…"),
            retryPrompt: prompt?.isEmpty == false ? prompt : nil,
            passage: cut(words, to: passageLimit))
    }

    private static func approval(_ wire: NoticeWire) -> NoticeReading {
        let tool = wire.subject ?? Localized.text("a tool")
        let words = collapse(wire.text ?? "")
        return NoticeReading(
            headline: sentence(Localized.text("needs approval")), facts: [tool],
            excerpt: cut(words, to: excerptLimit), passage: cut(words, to: passageLimit),
            subject: tool)
    }

    private static func question(_ wire: NoticeWire) -> NoticeReading {
        let options = wire.options ?? []
        let labels = options.map(\.label)
        let fits =
            wire.multiple != true && !labels.isEmpty && Set(labels).count == labels.count
            && labels.allSatisfy { !$0.isEmpty && $0.count <= choiceWidth }
        let words = collapse(wire.text ?? "")
        return NoticeReading(
            headline: sentence(Localized.text("has a question")),
            excerpt: cut(words, to: excerptLimit),
            detail: labels.count > choiceLimit
                ? cut(labels.joined(separator: " · "), to: excerptLimit) : "",
            choices: fits ? Array(labels.prefix(choiceLimit)) : [],
            replyPlaceholder: wire.free == true ? Localized.text("Your answer") : nil,
            passage: cut(words, to: passageLimit), options: options)
    }

    /// How long it took and how many tools it ran, in the words of whoever reads it.
    public static func turnFacts(_ wire: NoticeWire) -> [String] {
        var facts: [String] = []
        if let seconds = wire.seconds, seconds >= durationFloor {
            facts.append(duration(TimeInterval(seconds)))
        }
        switch wire.tools ?? 0 {
        case 0: break
        case 1: facts.append(Localized.text("1 tool"))
        case let count: facts.append(Localized.text("%lld tools", count))
        }
        return facts
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return Localized.text("%@s", "\(Int(seconds.rounded()))")
        }
        if seconds < 3_600 {
            return Localized.text("%@m", "\(Int((seconds / 60).rounded()))")
        }
        let hours = seconds / 3_600
        return hours < 10
            ? Localized.text("%@h", String(format: "%.1f", hours))
            : Localized.text("%@h", "\(Int(hours.rounded()))")
    }

    /// A word as the first of a sentence.
    public static func sentence(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    /// Markdown read as the words it holds: fenced code left out, the marks that only shape a page
    /// taken off, a link left as its label, and the lines run into one.
    public static func plain(_ markdown: String) -> String {
        var kept: [String] = []
        var fenced = false
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                fenced.toggle()
                continue
            }
            guard !fenced, !line.isEmpty else { continue }
            line = line.replacingOccurrences(
                of: #"^(#{1,6}\s+|>\s*|[-*•]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(
                of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
            kept.append(line)
        }
        return collapse(kept.joined(separator: " "))
    }

    public static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Cut at a word, and marked.
    public static func cut(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        let whole = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        return whole.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}

/// How a kind of notice is delivered and dressed, as names and numbers a platform maps onto its
/// own: the category it answers to, how loudly it may interrupt, how much it matters beside the
/// other things waiting, and the face it wears.
public struct NoticePresentation: Sendable, Equatable {
    public enum Interruption: String, Sendable {
        case passive, active, timeSensitive
    }

    public enum Tone: String, Sendable {
        case live, attention, danger, quiet
    }

    public let category: String
    public let interruption: Interruption
    public let relevance: Double
    public let symbol: String
    public let tone: Tone
    /// What the system says in place of the body where the person hides previews.
    public let hiddenBody: String

    public static func of(_ kind: NoticeWire.Kind) -> NoticePresentation {
        switch kind {
        case .done:
            return NoticePresentation(
                category: "tailscode.turn", interruption: .active, relevance: 0.5,
                symbol: "checkmark.circle", tone: .live,
                hiddenBody: Localized.text("Your agent finished."))
        case .failed:
            return NoticePresentation(
                category: "tailscode.turn.failed", interruption: .active, relevance: 0.7,
                symbol: "exclamationmark.triangle", tone: .danger,
                hiddenBody: Localized.text("The turn failed."))
        case .approval:
            return NoticePresentation(
                category: "tailscode.approval", interruption: .timeSensitive, relevance: 1.0,
                symbol: "hand.raised", tone: .attention,
                hiddenBody: Localized.text("Approval needed."))
        case .question:
            return NoticePresentation(
                category: "tailscode.question", interruption: .timeSensitive, relevance: 0.9,
                symbol: "questionmark.bubble", tone: .attention,
                hiddenBody: Localized.text("Your agent has a question."))
        case .usage:
            return NoticePresentation(
                category: "tailscode.usage", interruption: .active, relevance: 0.3,
                symbol: "gauge.with.dots.needle.67percent", tone: .attention,
                hiddenBody: Localized.text("Usage update."))
        }
    }
}

import CodingAgentKit
import Foundation

/// Which house a model comes from, read off its own name rather than off whichever gateway resells
/// it. A catalog that lists two hundred models from one provider key is not organised by that key —
/// "opencode-go" under every row says nothing — so the sections are families and the provider
/// becomes a fact on the row, which is the only arrangement that survives a second provider.
public struct ModelFamily: Sendable, Hashable, Comparable {
    public let key: String
    public let title: String
    public let rank: Int

    public init(key: String, title: String, rank: Int) {
        self.key = key
        self.title = title
        self.rank = rank
    }

    public static func < (lhs: ModelFamily, rhs: ModelFamily) -> Bool {
        lhs.rank == rhs.rank ? lhs.title < rhs.title : lhs.rank < rhs.rank
    }

    static let other = ModelFamily(key: "·other", title: Localized.text("Other"), rank: 900)

    /// Needles are matched against whole words, so "gpt" finds "GPT-5.6" without "o3" finding
    /// "Command-R O3xx". Order is the order of the sections a person reads.
    private static let table: [(needles: [String], title: String)] = [
        (["claude", "fable", "opus", "sonnet", "haiku"], "Claude"),
        (["gpt", "codex", "o1", "o3", "o4"], "GPT"),
        (["gemini"], "Gemini"),
        (["grok"], "Grok"),
        (["deepseek"], "DeepSeek"),
        (["qwen", "qwq"], "Qwen"),
        (["kimi"], "Kimi"),
        (["glm", "chatglm"], "GLM"),
        (["llama"], "Llama"),
        (["mistral", "codestral", "devstral", "magistral", "mixtral", "ministral"], "Mistral"),
        (["gemma"], "Gemma"),
        (["command", "cohere"], "Command"),
        (["phi"], "Phi"),
        (["nova"], "Nova"),
        (["minimax"], "MiniMax"),
        (["hunyuan"], "Hunyuan"),
    ]

    public static func of(name: String, id: String) -> ModelFamily {
        let words = Set(tokens(name) + tokens(id))
        for (rank, entry) in table.enumerated() {
            guard entry.needles.contains(where: words.contains) else { continue }
            return ModelFamily(key: entry.title.lowercased(), title: entry.title, rank: rank)
        }
        return other
    }

    /// A name breaks into the words a family is named by: letters and digits part company, so
    /// "GPT-5.6" and "deepseek-v4" both yield the bare word the table looks for.
    static func tokens(_ raw: String) -> [String] {
        var words: [String] = []
        var current = ""
        var lastWasDigit = false
        for character in raw.lowercased() {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            if character.isNumber != lastWasDigit, !current.isEmpty {
                words.append(current)
                current = ""
            }
            lastWasDigit = character.isNumber
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

/// One provider's willingness to run a model: the same model reached through a different door.
public struct ModelOffer: Sendable, Hashable {
    public let model: ModelInfo
    public let providerName: String
    public let isLocal: Bool

    public init(model: ModelInfo) {
        self.model = model
        self.providerName = ProviderIdentity.displayName(model.providerID)
        self.isLocal = ProviderIdentity.isLocal(model.providerID)
    }

    public var selection: ModelSelection { model.selection }
    public var providerID: String { model.providerID }
}

/// One connected server's catalog, as the chooser sees it. A model is not a thing you own, it is a
/// thing a particular machine will run for you: which machine is part of the answer, so the list is
/// built from every server you have rather than from the one whose chat happens to be open.
public struct ModelSource: Sendable, Equatable {
    public let profileID: String
    public let name: String
    public let backend: AgentType
    public let models: [ModelInfo]
    /// The server the chooser was opened from. Its models are the ones a pick applies to directly;
    /// everything else is a chat that doesn't exist yet.
    public let isCurrent: Bool
    /// Whether "let the server decide" is a real answer here.
    public let allowsServerDefault: Bool
    /// Whether this server will run a model it never listed. The Claude CLI takes whatever `--model`
    /// it is handed — an alias it gained yesterday, a dated release, a context variant — so its
    /// catalog is a shortlist rather than the set of legal answers.
    public let acceptsAnyModelID: Bool

    public init(
        profileID: String, name: String, backend: AgentType, models: [ModelInfo],
        isCurrent: Bool, allowsServerDefault: Bool, acceptsAnyModelID: Bool
    ) {
        self.profileID = profileID
        self.name = name
        self.backend = backend
        self.models = models
        self.isCurrent = isCurrent
        self.allowsServerDefault = allowsServerDefault
        self.acceptsAnyModelID = acceptsAnyModelID
    }

    public var title: String { ServerLabel.display(name: name, backend: backend) }

    /// The provider a typed-in model id belongs to: whoever this server's own catalog names, which
    /// for a CLI that answers to one house is that house.
    var literalProviderID: String { models.first?.providerID ?? "anthropic" }
}

/// What picking a row means: a model, and the machine that would run it. The two travel together
/// because on every screen but Home they are one decision — a model that lives on the other server
/// is a chat on the other server.
public struct ModelPick: Sendable, Hashable {
    public let profileID: String
    /// `nil` is that server's own default, which is a real answer.
    public let selection: ModelSelection?
    /// True when the model lives on a server other than the one the chooser was opened from, so the
    /// client must move the work rather than change this chat.
    public let isElsewhere: Bool
    /// The server's name, for the sentence a client has to write before moving anything.
    public let serverName: String
    /// The model as a person would say it, for that same sentence.
    public let modelName: String

    public init(
        profileID: String, selection: ModelSelection?, isElsewhere: Bool, serverName: String,
        modelName: String = ""
    ) {
        self.profileID = profileID
        self.selection = selection
        self.isElsewhere = isElsewhere
        self.serverName = serverName
        self.modelName = modelName
    }
}

/// A model as a person means it — one name, and every provider that will run it. Two gateways
/// listing the same model is a fact about routing, not two different models to scroll past, so the
/// catalog collapses them into one row that says how many doors it has. A model running on the
/// server's own machine never collapses into a hosted one: where it runs is the whole difference.
/// Two servers offering the same model never collapse either, for the same reason at a larger
/// scale: the machine is the difference.
public struct ModelCandidate: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let family: ModelFamily
    public let offers: [ModelOffer]
    public let profileID: String
    public let serverName: String
    /// True when this candidate belongs to a server other than the one the chooser was opened from.
    public let isElsewhere: Bool

    public init(
        id: String, name: String, family: ModelFamily, offers: [ModelOffer],
        profileID: String = "", serverName: String = "", isElsewhere: Bool = false
    ) {
        self.id = id
        self.name = name
        self.family = family
        self.offers = offers
        self.profileID = profileID
        self.serverName = serverName
        self.isElsewhere = isElsewhere
    }

    public var primary: ModelOffer { offers[0] }
    public var selection: ModelSelection { primary.selection }
    public var isLocal: Bool { primary.isLocal }
    public var variants: [String] { primary.model.variants ?? [] }
    public var capabilities: ModelCapabilities? { primary.model.capabilities }
    public var providerNames: [String] { offers.map(\.providerName) }

    public func offer(for selection: ModelSelection) -> ModelOffer? {
        offers.first { $0.selection == selection }
    }

    public func carries(_ selection: ModelSelection?) -> Bool {
        guard let selection else { return false }
        return offers.contains { $0.selection == selection }
    }
}

/// A short, true thing about a model, worth knowing before picking it. Each client draws these its
/// own way — a symbol on Apple, a pill on GTK — but never invents its own list.
///
/// They come in two weights, because they answer two different questions and a row that draws them
/// alike is the row nobody can read. A **badge** changes the pick — which machine runs it, whether
/// that machine is your own, how many doors it has, how many effort levels it takes — and is worth
/// a word in colour. A **mark** is a capability, which is worth a glyph in the margin and nothing
/// louder: three bordered pills saying *vision pdf files* on every row of a Claude catalog is a
/// wall of ink that distinguishes nothing.
public enum ModelFact: Sendable, Hashable {
    case vision
    case pdf
    case attachments
    case effort(Int)
    case local
    case providers(Int)
    /// The machine that would run it, said only when it is not the machine you are already on.
    case server(String)

    public var tag: String {
        switch self {
        case .vision: return Localized.text("vision")
        case .pdf: return Localized.text("pdf")
        case .attachments: return Localized.text("files")
        case .effort(let count): return Localized.text("%@ levels", "\(count)")
        case .local: return Localized.text("local")
        case .providers(let count): return Localized.text("%@ providers", "\(count)")
        case .server(let name): return name
        }
    }

    public var symbol: String {
        switch self {
        case .vision: return "photo"
        case .pdf: return "doc.richtext"
        case .attachments: return "paperclip"
        case .effort: return "gauge.with.dots.needle.50percent"
        case .local: return "desktopcomputer"
        case .providers: return "arrow.triangle.branch"
        case .server: return "arrow.turn.down.right"
        }
    }

    public var label: String {
        switch self {
        case .vision: return Localized.text("Reads images")
        case .pdf: return Localized.text("Reads PDFs")
        case .attachments: return Localized.text("Takes attachments")
        case .effort(let count): return Localized.text("%@ effort levels", "\(count)")
        case .local: return Localized.text("Runs on your server's machine")
        case .providers(let count): return Localized.text("Offered by %@ providers", "\(count)")
        case .server(let name): return Localized.text("Runs on %@ — picking it starts a chat there", name)
        }
    }

    /// Whether this is something the model can read rather than something about where it runs.
    /// Clients draw the two in different registers and in that order: badges lead, marks follow.
    public var isCapability: Bool {
        switch self {
        case .vision, .pdf, .attachments: return true
        case .effort, .local, .providers, .server: return false
        }
    }

    /// The facts that belong on a candidate's row, in one order everywhere: what would move the
    /// work first, then what it reads.
    public static func of(
        _ candidate: ModelCandidate, policy: ModelFactPolicy = .everything
    ) -> [ModelFact] {
        var facts: [ModelFact] = []
        if candidate.isElsewhere { facts.append(.server(candidate.serverName)) }
        if candidate.isLocal, policy.showsLocal { facts.append(.local) }
        if candidate.variants.count > 1 { facts.append(.effort(candidate.variants.count)) }
        if candidate.offers.count > 1 { facts.append(.providers(candidate.offers.count)) }
        if let capabilities = candidate.capabilities {
            if capabilities.imageInput, policy.showsVision { facts.append(.vision) }
            if capabilities.pdfInput, policy.showsPDF { facts.append(.pdf) }
            if capabilities.attachment, policy.showsAttachments { facts.append(.attachments) }
        }
        return facts
    }
}

/// Which facts are worth saying about *this* catalog. A fact every row shares is not a fact about
/// any row — a list where all two hundred models read images learns nothing from two hundred labels
/// saying so, and the labels cost the eye more than the capability was ever worth. So the policy is
/// worked out once over the whole catalog and the rows that survive a query keep saying the same
/// things, because a badge that appears and disappears as you type is a badge you stop trusting.
///
/// It is deliberately blind to models that describe nothing: a gateway that publishes no
/// capabilities cannot make its silence evidence that everyone else's `vision` is redundant.
public struct ModelFactPolicy: Sendable, Equatable {
    public let showsVision: Bool
    public let showsPDF: Bool
    public let showsAttachments: Bool
    public let showsLocal: Bool

    public static let everything = ModelFactPolicy(
        showsVision: true, showsPDF: true, showsAttachments: true, showsLocal: true)

    public init(showsVision: Bool, showsPDF: Bool, showsAttachments: Bool, showsLocal: Bool) {
        self.showsVision = showsVision
        self.showsPDF = showsPDF
        self.showsAttachments = showsAttachments
        self.showsLocal = showsLocal
    }

    /// The capability marks this catalog can put on a row, in the one order they are drawn. A
    /// client that wants a column rather than a ragged edge lays out a slot per entry and leaves
    /// the ones a model lacks empty, which is what makes the marks scannable down the list.
    public var capabilitySlots: [ModelFact] {
        var slots: [ModelFact] = []
        if showsVision { slots.append(.vision) }
        if showsPDF { slots.append(.pdf) }
        if showsAttachments { slots.append(.attachments) }
        return slots
    }

    public static func over(_ candidates: [ModelCandidate]) -> ModelFactPolicy {
        let described = candidates.compactMap(\.capabilities)
        func worthSaying(_ has: (ModelCapabilities) -> Bool) -> Bool {
            guard described.count > 1 else { return true }
            return !described.allSatisfy(has)
        }
        return ModelFactPolicy(
            showsVision: worthSaying(\.imageInput),
            showsPDF: worthSaying(\.pdfInput),
            showsAttachments: worthSaying(\.attachment),
            showsLocal: !candidates.isEmpty && !candidates.allSatisfy(\.isLocal))
    }
}

/// A standing narrowing of the catalog, chosen rather than typed. Search answers "which model",
/// and it answers it well; it is a poor way to ask "only the ones I can reach without moving this
/// chat" or "only the ones running on my own hardware", which are the two questions a fleet makes
/// people ask constantly. Those are one press, always visible, never a syntax to remember.
public enum ModelChooserScope: Sendable, Hashable, Identifiable {
    case all
    /// The server the chooser was opened from — a pick that keeps the chat where it is.
    case here
    /// Models the server runs on its own machine.
    case local

    public var id: String {
        switch self {
        case .all: return "all"
        case .here: return "here"
        case .local: return "local"
        }
    }

    public var title: String {
        switch self {
        case .all: return Localized.text("All")
        case .here: return Localized.text("This server")
        case .local: return Localized.text("Local")
        }
    }

    public var detail: String {
        switch self {
        case .all: return Localized.text("Every model on every server you have")
        case .here: return Localized.text("Only models this chat can switch to in place")
        case .local: return Localized.text("Only models running on your server's own machine")
        }
    }
}

/// Why a row survived the query, in the same tiers the slash palette ranks by, so the two lists
/// the composer opens behave like one idea.
public enum ModelMatch: Int, Sendable, Comparable {
    case exact = 0
    case prefix = 1
    case word = 2
    case inner = 3
    case scattered = 4
    /// The name says nothing; the provider, the family or the raw id is what matched.
    case elsewhere = 5

    public static func < (lhs: ModelMatch, rhs: ModelMatch) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ModelChooserRow: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Let the server decide — the row that has no model in it.
        case auto
        case candidate(ModelCandidate)
        /// One of a collapsed candidate's other doors, revealed under it.
        case alternate(ModelCandidate, ModelOffer)
        /// A model id typed rather than found: a server whose CLI takes any name will take this one.
        case literal(ModelSelection)
    }

    public let kind: Kind
    /// The server that would run this row.
    public let profileID: String
    public let serverName: String
    /// True when that server is not the one the chooser was opened from.
    public let isElsewhere: Bool
    /// Which section drew this row. A model you reached for recently is listed twice — once under
    /// Recent and once in its own family — so the section is part of a row's identity; a list keyed
    /// by identity has to be able to tell the two apart.
    public let sectionID: String
    public let title: String
    public let detail: String
    /// Offsets into `title` the query landed on, for the client to weight.
    public let highlight: [Int]
    public let facts: [ModelFact]
    public let isSelected: Bool
    /// True while this candidate's other providers are showing under it.
    public let isExpanded: Bool
    public let canExpand: Bool
    /// An alternate is drawn inset under the row it belongs to.
    public let isNested: Bool
    /// The used-up window standing between this row and a send, when one is. A walled row is drawn
    /// spent — dimmed, wearing what ran out and when it comes back — and stays pickable, because a
    /// window resets and a wall is not a reason to refuse someone the model they came for.
    public let wall: QuotaExhaustion?

    /// Unique across the whole list, which is what a diffable list demands of an identifier.
    public var id: String { "\(sectionID)/\(anchor)" }

    /// What this row is about, the same wherever it is listed — two rows sharing an anchor are one
    /// model in two places, and expanding either opens both.
    public var anchor: String {
        switch kind {
        case .auto: return "·default/\(profileID)"
        case .candidate(let candidate): return candidate.id
        case .alternate(let candidate, let offer): return "\(candidate.id)|\(offer.selection.rawValue)"
        case .literal(let selection): return "·literal/\(profileID)/\(selection.rawValue)"
        }
    }

    /// What picking this row means. `nil` is the server's own choice, which is a real answer.
    public var selection: ModelSelection? {
        switch kind {
        case .auto: return nil
        case .candidate(let candidate): return candidate.selection
        case .alternate(_, let offer): return offer.selection
        case .literal(let selection): return selection
        }
    }

    /// The whole answer: the model, and the machine that would run it.
    public var pick: ModelPick {
        ModelPick(
            profileID: profileID, selection: selection, isElsewhere: isElsewhere,
            serverName: serverName, modelName: title)
    }

    public var isAuto: Bool {
        if case .auto = kind { return true }
        return false
    }

    public var isLiteral: Bool {
        if case .literal = kind { return true }
        return false
    }
}

public struct ModelChooserSection: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let rows: [ModelChooserRow]
}

public enum ModelChooserCommand: Sendable, Equatable {
    case up
    case down
    case top
    case bottom
    case activate
    case expand
    case collapse
    /// The nth standing filter, counted from zero — ⌃1 is the whole catalog wherever it is offered.
    case scope(Int)
    case dismiss
}

/// The one model list in the app: every provider's catalog, folded into families, searched by one
/// query and walked by one set of keys. Toolkit-free so the phone, GTK and AppKit render the same
/// decision rather than three lists that drifted apart.
///
/// The shape of the answer is the point. A flat menu of two hundred rows, each repeating the same
/// provider key underneath it, is not a choice a person can make; a family heading, a name, and the
/// facts that would change the pick — reads images, has effort levels, runs on your own machine,
/// reachable through two providers — is.
public struct ModelChooser: Sendable, Equatable {
    public static let recentLimit = 5

    public let candidates: [ModelCandidate]
    public let sources: [ModelSource]
    public let allowsServerDefault: Bool
    public let selected: ModelSelection?
    /// Which facts this catalog is worth wearing, decided once over the whole of it.
    public let policy: ModelFactPolicy
    /// The standing filters this catalog can be asked for, in the order they are offered. Empty
    /// when the catalog is one server with nothing local in it: a filter bar that can only say
    /// "all" is chrome pretending to be a control.
    public let scopes: [ModelChooserScope]
    private let recents: [ModelSelection]
    /// Whether a row has to name who runs it. One provider behind the whole catalog is a fact
    /// about the server, said once at the top, not a word repeated under two hundred names.
    private let showsProviders: Bool
    /// One wall per candidate that has one, worked out once: a used-up window does not change
    /// while a list is open, and a search that re-ranks two hundred rows per keystroke must not
    /// re-read every gauge to draw them.
    private let walls: [String: QuotaExhaustion]

    public private(set) var query = ""
    public private(set) var scope: ModelChooserScope = .all
    public private(set) var cursor = 0
    public private(set) var expanded: Set<String> = []
    public private(set) var sections: [ModelChooserSection] = []
    public private(set) var rows: [ModelChooserRow] = []
    /// How many models answered the query and the filter, for the header's count.
    private var matched = 0

    /// Whether a model survives the standing filter.
    private func inScope(_ candidate: ModelCandidate) -> Bool {
        switch scope {
        case .all: return true
        case .here: return !candidate.isElsewhere
        case .local: return candidate.isLocal
        }
    }

    /// One server's list — the shape every screen that only ever meant this machine still asks for.
    public init(
        models: [ModelInfo], selected: ModelSelection?, allowsServerDefault: Bool = true,
        recents: [ModelSelection] = RecentModelsStore.all(), quotas: [UsageQuota] = []
    ) {
        self.init(
            sources: [
                ModelSource(
                    profileID: "", name: "", backend: .openCode, models: models, isCurrent: true,
                    allowsServerDefault: allowsServerDefault, acceptsAnyModelID: false)
            ], selected: selected, recents: recents, quotas: quotas)
    }

    /// Every server you have, as one list. The machine a model runs on is a fact on its row rather
    /// than a list you have to leave and re-enter, and the pick that comes back says which machine
    /// it meant.
    ///
    /// `quotas` are the walls in front of *this* server, already narrowed to its provider family by
    /// the caller that knows which backend it opened — the chooser marks a model spent, it does not
    /// decide whose account a machine spends from. A model on another machine is never marked: the
    /// same name reached through another gateway is metered by that gateway, and a mark this list
    /// cannot stand behind is worse than none.
    public init(
        sources: [ModelSource], selected: ModelSelection?,
        recents: [ModelSelection] = RecentModelsStore.all(), quotas: [UsageQuota] = []
    ) {
        self.sources = sources
        let candidates = sources.flatMap { Self.fold(source: $0, preferred: selected) }
        self.candidates = candidates
        self.selected = selected
        self.allowsServerDefault = sources.first { $0.isCurrent }?.allowsServerDefault ?? false
        self.recents = recents
        self.walls = Self.walls(for: candidates, quotas: quotas)
        self.policy = .over(candidates)
        self.showsProviders = Set(candidates.flatMap { $0.offers.map(\.providerID) }).count > 1
        self.scopes = Self.scopes(for: candidates, sources: sources)
        rebuild()
        cursor = rows.firstIndex { $0.isSelected } ?? 0
    }

    /// The filters this catalog can honestly offer. A filter that would change nothing — "this
    /// server" with one server, "local" with nothing local — is not offered, so a bar that appears
    /// at all is a bar where every press does something.
    private static func scopes(
        for candidates: [ModelCandidate], sources: [ModelSource]
    ) -> [ModelChooserScope] {
        var scopes: [ModelChooserScope] = []
        if candidates.contains(where: \.isElsewhere) { scopes.append(.here) }
        if candidates.contains(where: \.isLocal), !candidates.allSatisfy(\.isLocal) {
            scopes.append(.local)
        }
        return scopes.isEmpty ? [] : [.all] + scopes
    }

    private static func walls(
        for candidates: [ModelCandidate], quotas: [UsageQuota]
    ) -> [String: QuotaExhaustion] {
        guard !quotas.isEmpty else { return [:] }
        var found: [String: QuotaExhaustion] = [:]
        for candidate in candidates where !candidate.isElsewhere {
            guard let hit = wall(for: candidate, quotas: quotas) else { continue }
            found[candidate.id] = hit
        }
        return found
    }

    /// The used-up window in front of one model, for the pill's shortlist — the same reading the
    /// full chooser draws, so a menu and the list behind it never disagree about what is spent.
    /// Only walls whose provider actually bills the model count: a Claude wall is not a fact
    /// about a DeepSeek row, whatever their fractions.
    public static func wall(
        for candidate: ModelCandidate, quotas: [UsageQuota]
    ) -> QuotaExhaustion? {
        let billers = quotas.filter { QuotaBinding.bills($0, candidate: candidate) }
        guard !billers.isEmpty else { return nil }
        return QuotaSurface.hottestExhausted(
            in: billers, model: candidate.primary.model.id, named: candidate.name)
    }

    public var isEmpty: Bool { candidates.isEmpty }

    private var current: ModelSource? { sources.first { $0.isCurrent } }

    /// Whether anything is standing between the reader and the whole catalog.
    public var isNarrowed: Bool { !query.isEmpty || scope != .all }

    /// What the list amounts to right now: the whole catalog when nothing is narrowing it, and
    /// otherwise how much of it survived — a count that moves as you type is the only honest way
    /// for a header to answer "is it still looking".
    public var summary: String {
        guard !candidates.isEmpty else { return Localized.text("This server lists no models") }
        guard !isNarrowed else {
            var parts = [Localized.text("%@ of %@ models", "\(matched)", "\(candidates.count)")]
            if scope != .all { parts.append(scope.title.lowercased()) }
            return parts.joined(separator: " · ")
        }
        return catalogSummary
    }

    /// What the whole catalog amounts to, said once at the top instead of implied by scrolling.
    public var catalogSummary: String {
        guard !candidates.isEmpty else { return Localized.text("This server lists no models") }
        var parts = [Self.modelCount(candidates.count)]
        let servers = Set(candidates.map(\.profileID))
        if servers.count > 1 {
            parts.append(Self.serverCount(servers.count))
        } else {
            let providers = Set(candidates.flatMap { $0.offers.map(\.providerID) })
            if providers.count > 1 { parts.append(Self.providerCount(providers.count)) }
        }
        let local = candidates.filter(\.isLocal).count
        if local > 0 { parts.append(Localized.text("%@ on your machine", "\(local)")) }
        if !walls.isEmpty { parts.append(Localized.text("%@ used up", "\(walls.count)")) }
        return parts.joined(separator: " · ")
    }

    static func serverCount(_ count: Int) -> String {
        count == 1 ? Localized.text("1 server") : Localized.text("%@ servers", "\(count)")
    }

    static func modelCount(_ count: Int) -> String {
        count == 1 ? Localized.text("1 model") : Localized.text("%@ models", "\(count)")
    }

    static func providerCount(_ count: Int) -> String {
        count == 1 ? Localized.text("1 provider") : Localized.text("%@ providers", "\(count)")
    }

    public var hint: String {
        guard scopes.count > 1 else {
            return Localized.text("↑↓ chooses · ⌃→ other providers · enter picks · esc closes")
        }
        return Localized.text(
            "↑↓ chooses · ⌃→ other providers · ⌃1–%@ filters · enter picks · esc closes",
            "\(scopes.count)")
    }

    /// Said when nothing survived, naming what did the narrowing rather than shrugging — a query,
    /// a filter, or both, since a reader who forgot the filter is on will otherwise read an empty
    /// list as a catalog that lost a model.
    public var emptyResult: String? {
        guard rows.isEmpty else { return nil }
        switch (query.isEmpty, scope) {
        case (true, .all): return nil
        case (true, let scope): return Localized.text("No model here is %@", scope.title.lowercased())
        case (false, .all): return Localized.text("No model matches “%@”", query)
        case (false, let scope):
            return Localized.text(
                "No model matches “%@” under %@", query, scope.title.lowercased())
        }
    }

    /// The one press that would undo the narrowing, when a filter is what emptied the list — an
    /// empty result should hand back the way out rather than leave it to be remembered.
    public var emptyEscape: ModelChooserScope? { rows.isEmpty && scope != .all ? .all : nil }

    public var focused: ModelChooserRow? {
        rows.indices.contains(cursor) ? rows[cursor] : nil
    }

    public mutating func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed != query else { return }
        query = trimmed
        if !trimmed.isEmpty { expanded.removeAll() }
        rebuild()
        cursor = rows.isEmpty ? 0 : min(cursor, rows.count - 1)
        if !trimmed.isEmpty { cursor = 0 }
    }

    /// Narrows the catalog to one standing filter. The cursor goes back to the top rather than
    /// trying to follow the row it was on: a filter is a new question, and the answer to a new
    /// question starts at its first line.
    @discardableResult
    public mutating func setScope(_ next: ModelChooserScope) -> Bool {
        guard next != scope, scopes.contains(next) || next == .all else { return false }
        scope = next
        expanded.removeAll()
        rebuild()
        cursor = rows.firstIndex { $0.isSelected } ?? 0
        return true
    }

    public mutating func focus(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        cursor = index
    }

    public mutating func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        cursor = max(0, min(rows.count - 1, cursor + delta))
    }

    /// Reveals or hides the other providers under the focused candidate. Answers whether anything
    /// happened, so a client can let the key mean what it usually means when it did not.
    @discardableResult
    public mutating func setExpanded(_ shown: Bool, at index: Int? = nil) -> Bool {
        let target = index ?? cursor
        guard let row = rows.indices.contains(target) ? rows[target] : nil else { return false }
        let candidate: ModelCandidate
        switch row.kind {
        case .candidate(let value) where value.offers.count > 1: candidate = value
        case .alternate(let value, _): candidate = value
        default: return false
        }
        let anchor = candidate.id
        let section = row.sectionID
        guard expanded.contains(anchor) != shown else { return false }
        if shown {
            expanded.insert(anchor)
        } else {
            expanded.remove(anchor)
        }
        rebuild()
        cursor =
            rows.firstIndex { $0.anchor == anchor && $0.sectionID == section }
            ?? min(target, max(0, rows.count - 1))
        return true
    }

    /// Applies a keystroke. Answers what the client must act on and whether the key was the
    /// chooser's at all — an unclaimed key goes on to the app's own table.
    public mutating func handle(
        _ command: ModelChooserCommand
    ) -> (handled: Bool, pick: ModelPick?, dismissed: Bool) {
        switch command {
        case .up:
            move(by: -1)
            return (true, nil, false)
        case .down:
            move(by: 1)
            return (true, nil, false)
        case .top:
            cursor = 0
            return (true, nil, false)
        case .bottom:
            cursor = max(0, rows.count - 1)
            return (true, nil, false)
        case .expand:
            return (setExpanded(true), nil, false)
        case .collapse:
            return (setExpanded(false), nil, false)
        case .scope(let index):
            guard scopes.indices.contains(index) else { return (false, nil, false) }
            return (setScope(scopes[index]), nil, false)
        case .activate:
            guard let row = focused else { return (true, nil, false) }
            return (true, row.pick, false)
        case .dismiss:
            return (true, nil, true)
        }
    }

    private static let left: UInt32 = 0xFF51
    private static let right: UInt32 = 0xFF53
    private static let pageUp: UInt32 = 0xFF55
    private static let pageDown: UInt32 = 0xFF56

    /// Only the keys a list owns while something else is being typed into. Every client puts a
    /// search field at the top of this chooser, so letters, space and the bare arrows that move a
    /// caret all belong to the field: walking is ↑↓, and opening a row onto its other providers is
    /// ⌃→, which no text field wants.
    public static func command(for chord: KeyChord) -> ModelChooserCommand? {
        if chord.control {
            switch chord.keyval {
            case right: return .expand
            case left: return .collapse
            default: break
            }
            if let digit = Keymap.digit(chord.keyval), digit > 0 { return .scope(digit - 1) }
            switch Keymap.scalar(chord.keyval) {
            case "n": return .down
            case "p": return .up
            default: return nil
            }
        }
        guard !chord.alt else { return nil }
        switch chord.keyval {
        case Keymap.up: return .up
        case Keymap.down: return .down
        case Keymap.enter: return .activate
        case Keymap.escape: return .dismiss
        case pageUp: return .top
        case pageDown: return .bottom
        default: return nil
        }
    }

    private mutating func rebuild() {
        var sections: [ModelChooserSection] = []
        let matches = self.matches()
        matched = matches.count

        if query.isEmpty {
            sections += currentSection()
            let inUse = candidates.first { !$0.isElsewhere && $0.carries(selected) }
            let recent = recents.compactMap { selection in
                candidates.first { !$0.isElsewhere && $0.carries(selection) }
                    ?? candidates.first { $0.carries(selection) }
            }
            var seen = Set<String>()
            if let inUse { seen.insert(inUse.id) }
            let unique =
                recent
                .filter { inScope($0) }
                .filter { seen.insert($0.id).inserted }
                .prefix(Self.recentLimit)
            if !unique.isEmpty {
                sections.append(
                    ModelChooserSection(
                        id: "·recent", title: Localized.text("Recent"),
                        detail: Localized.text("What you reach for"),
                        rows: unique.flatMap { rows(for: $0, section: "·recent", highlight: []) }))
            }
        }

        var byFamily: [ModelFamily: [(ModelCandidate, [Int])]] = [:]
        for (candidate, highlight) in matches {
            byFamily[candidate.family, default: []].append((candidate, highlight))
        }
        for family in byFamily.keys.sorted() {
            let entries = byFamily[family] ?? []
            var detail = Self.modelCount(entries.count)
            let servers = Set(entries.map { $0.0.profileID })
            if servers.count > 1 {
                detail += " · " + Self.serverCount(servers.count)
            } else {
                let providers = Set(entries.flatMap { $0.0.offers.map(\.providerID) })
                if providers.count > 1 { detail += " · " + Self.providerCount(providers.count) }
            }
            let oneHouse = Set(entries.map { $0.0.primary.providerID }).count < 2
            sections.append(
                ModelChooserSection(
                    id: family.key, title: family.title, detail: detail,
                    rows: entries.flatMap {
                        rows(
                            for: $0.0, section: family.key, highlight: $0.1,
                            namesProvider: !oneHouse)
                    }))
        }

        sections += literalSections()
        self.sections = sections
        rows = sections.flatMap(\.rows)
    }

    /// What this chat is running, and the one alternative that is not a model at all. Both used to
    /// be implied — a tick somewhere down the list, an untitled row at the top — which is how the
    /// same model came to be drawn twice with a tick each and no way to tell which one was the
    /// answer. Named, it reads as the state it is, and Recent stops repeating it.
    private func currentSection() -> [ModelChooserSection] {
        var rows: [ModelChooserRow] = []
        if let selected, let candidate = candidates.first(where: {
            !$0.isElsewhere && $0.carries(selected) && inScope($0)
        }) {
            rows += self.rows(for: candidate, section: "·current", highlight: [])
        }
        if allowsServerDefault, let current {
            rows.append(
                ModelChooserRow(
                    kind: .auto, profileID: current.profileID, serverName: current.name,
                    isElsewhere: false, sectionID: "·current",
                    title: Localized.text("Server default"),
                    detail: Localized.text("Whatever this server runs"), highlight: [],
                    facts: [], isSelected: selected == nil, isExpanded: false, canExpand: false,
                    isNested: false, wall: nil))
        }
        guard !rows.isEmpty else { return [] }
        return [
            ModelChooserSection(
                id: "·current", title: Localized.text("Current"),
                detail: Localized.text("What this chat runs"), rows: rows)
        ]
    }

    /// A catalog is a shortlist where the server will take any name, so a word it does not contain
    /// is not necessarily a mistake — it may be the model that shipped this morning, a dated
    /// release, or a context variant. The list says so and offers to use it rather than shrugging.
    private func literalSections() -> [ModelChooserSection] {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard typed.count > 1, !typed.contains(" ") else { return [] }
        guard scope != .local else { return [] }
        let takers = sources.filter { source in
            guard source.acceptsAnyModelID, scope != .here || source.isCurrent else { return false }
            return !source.models.contains { $0.id.lowercased() == typed.lowercased() }
        }
        guard !takers.isEmpty else { return [] }
        let rows = takers.map { source in
            ModelChooserRow(
                kind: .literal(
                    ModelSelection(providerID: source.literalProviderID, modelID: typed)),
                profileID: source.profileID, serverName: source.name,
                isElsewhere: !source.isCurrent, sectionID: "·literal",
                title: typed,
                detail: source.isCurrent
                    ? Localized.text("Hand this name to the CLI as it is")
                    : Localized.text("Hand this name to %@ as it is", source.name),
                highlight: [], facts: source.isCurrent ? [] : [.server(source.name)],
                isSelected: false, isExpanded: false, canExpand: false, isNested: false,
                wall: nil)
        }
        return [
            ModelChooserSection(
                id: "·literal", title: Localized.text("Not in the catalog"),
                detail: Localized.text("Use it anyway"), rows: rows)
        ]
    }

    private func rows(
        for candidate: ModelCandidate, section: String, highlight: [Int],
        namesProvider: Bool = true
    ) -> [ModelChooserRow] {
        var result = [
            row(for: candidate, section: section, highlight: highlight, namesProvider: namesProvider)
        ]
        guard expanded.contains(candidate.id) else { return result }
        result += candidate.offers.map { offer in
            ModelChooserRow(
                kind: .alternate(candidate, offer), profileID: candidate.profileID,
                serverName: candidate.serverName, isElsewhere: candidate.isElsewhere,
                sectionID: section,
                title: offer.providerName,
                detail: offer.model.id, highlight: [],
                facts: offer.isLocal ? [.local] : [],
                isSelected: !candidate.isElsewhere && selected == offer.selection,
                isExpanded: false, canExpand: false,
                isNested: true, wall: walls[candidate.id])
        }
        return result
    }

    private func row(
        for candidate: ModelCandidate, section: String, highlight: [Int],
        namesProvider: Bool = true
    ) -> ModelChooserRow {
        ModelChooserRow(
            kind: .candidate(candidate), profileID: candidate.profileID,
            serverName: candidate.serverName, isElsewhere: candidate.isElsewhere,
            sectionID: section, title: candidate.name,
            detail: detail(for: candidate, namesProvider: namesProvider),
            highlight: highlight, facts: ModelFact.of(candidate, policy: policy),
            isSelected: !candidate.isElsewhere && candidate.carries(selected),
            isExpanded: expanded.contains(candidate.id),
            canExpand: candidate.offers.count > 1, isNested: false,
            wall: walls[candidate.id])
    }

    /// Under the name: who runs it, and the id the server actually knows it by — the one string
    /// that settles which of two similarly named models this is.
    ///
    /// Both halves are dropped when they say nothing. A house that runs every model under a heading
    /// names itself under every row for no reason — *Anthropic* six times down the Claude section is
    /// the heading again in smaller type — and an id that is only the name with the spaces taken
    /// out (`Opus` over `opus`) is a second line for a row that has one thing to say. What is left
    /// is a name alone, which is what most rows should have been all along.
    ///
    /// A folded row names one door: the one a pick would actually go through. How many others there
    /// are is already a badge on the row, and the list of them is one keystroke below it — spelling
    /// them all out here is the same fact three times, in the line least able to hold it.
    private func detail(for candidate: ModelCandidate, namesProvider: Bool = true) -> String {
        var parts: [String] = []
        let names = candidate.providerNames
        if candidate.offers.count > 1 {
            parts.append(names[0])
        } else if (showsProviders && namesProvider) || candidate.isLocal {
            parts.append(names.joined(separator: " · "))
        }
        let id = candidate.primary.model.id
        if candidate.offers.count == 1, Self.saysMoreThanTheName(id, name: candidate.name) {
            parts.append(id)
        }
        return parts.joined(separator: "  ·  ")
    }

    /// Whether an id distinguishes the model from its own name — a gateway path, a revision tag, a
    /// dated release or a different word entirely, rather than the name respelled. A row with two
    /// doors spends its second line naming them instead: each door's own id is one keystroke away
    /// under the row, and a line that tried to carry both is a line that carries neither.
    static func saysMoreThanTheName(_ id: String, name: String) -> Bool {
        ModelFamily.tokens(id).joined() != ModelFamily.tokens(name).joined()
    }

    /// The catalog ordered by how well each name answers the query. Ties inside a tier break on
    /// what the person picked recently, then alphabetically, so the list never reshuffles itself
    /// for reasons nobody can see.
    private func matches() -> [(ModelCandidate, [Int])] {
        let recency = Dictionary(
            uniqueKeysWithValues: recents.enumerated().map { ($0.element, $0.offset) })
        func rank(_ candidate: ModelCandidate) -> Int {
            candidate.offers.compactMap { recency[$0.selection] }.min() ?? Int.max
        }
        let candidates = self.candidates.filter(inScope)
        guard !query.isEmpty else {
            return
                candidates
                .sorted { lhs, rhs in
                    if lhs.isElsewhere != rhs.isElsewhere { return !lhs.isElsewhere }
                    let (walledL, walledR) = (walls[lhs.id] != nil, walls[rhs.id] != nil)
                    if walledL != walledR { return !walledL }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                .map { ($0, []) }
        }
        let needle = query.lowercased()
        return
            candidates
            .compactMap { candidate -> (ModelCandidate, ModelMatch, [Int])? in
                guard let (kind, highlight) = classify(candidate, needle: needle) else { return nil }
                return (candidate, kind, highlight)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.isElsewhere != rhs.0.isElsewhere { return !lhs.0.isElsewhere }
                let (walledL, walledR) = (walls[lhs.0.id] != nil, walls[rhs.0.id] != nil)
                if walledL != walledR { return !walledL }
                let (a, b) = (rank(lhs.0), rank(rhs.0))
                if a != b { return a < b }
                return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
            }
            .map { ($0.0, $0.2) }
    }

    /// Tried best-first over the name, then over everything else the person might have typed —
    /// a provider, a family, the raw id — so "ollama", "claude" and "sonnet-4-5" all find rows,
    /// but a name that answers the query outranks a provider that merely carries it.
    private func classify(_ candidate: ModelCandidate, needle: String) -> (ModelMatch, [Int])? {
        let name = Array(candidate.name.lowercased())
        let letters = Array(needle)
        if name == letters { return (.exact, Array(0..<name.count)) }
        if let start = run(of: letters, in: name) {
            if start == 0 { return (.prefix, Array(start..<(start + letters.count))) }
            let boundary = !name[start - 1].isLetter && !name[start - 1].isNumber
            return (boundary ? .word : .inner, Array(start..<(start + letters.count)))
        }
        if let scattered = subsequence(of: letters, in: name) { return (.scattered, scattered) }
        let elsewhere =
            candidate.offers.contains {
                $0.providerName.lowercased().contains(needle)
                    || $0.providerID.lowercased().contains(needle)
                    || $0.model.id.lowercased().contains(needle)
            } || candidate.family.title.lowercased().contains(needle)
            || candidate.serverName.lowercased().contains(needle)
        return elsewhere ? (.elsewhere, []) : nil
    }

    private func run(of letters: [Character], in name: [Character]) -> Int? {
        guard !letters.isEmpty, letters.count <= name.count else { return nil }
        for start in 0...(name.count - letters.count)
        where Array(name[start..<(start + letters.count)]) == letters {
            return start
        }
        return nil
    }

    private func subsequence(of letters: [Character], in name: [Character]) -> [Int]? {
        var hits: [Int] = []
        var index = 0
        for letter in letters {
            guard let found = name[index...].firstIndex(of: letter) else { return nil }
            hits.append(found)
            index = found + 1
        }
        return hits
    }

    /// Folds a flat catalog into candidates. Identity is the model's own name where it has one and
    /// its id otherwise, normalised so "Claude Sonnet 4.5" and "claude-sonnet-4-5" are one model
    /// reached two ways; a local model never folds into a hosted one.
    public static func fold(_ models: [ModelInfo], preferred: ModelSelection? = nil) -> [ModelCandidate] {
        fold(
            source: ModelSource(
                profileID: "", name: "", backend: .openCode, models: models, isCurrent: true,
                allowsServerDefault: true, acceptsAnyModelID: false),
            preferred: preferred)
    }

    /// Folds one server's catalog. Identity carries the server, because the same model on two
    /// machines is two answers to "where does this run" and only one of them keeps the chat where
    /// it is.
    ///
    /// Which door a collapsed row picks is decided here: the door the chat is already on wins —
    /// a re-pick must not silently move the billing — then the model's own house over a reseller
    /// fronting it, because someone who configured a key for a model and picks that model wants
    /// their key, not the plan's. Everything else keeps catalog order.
    static func fold(source: ModelSource, preferred: ModelSelection? = nil) -> [ModelCandidate] {
        var order: [String] = []
        var groups: [String: [ModelInfo]] = [:]
        for model in source.models {
            let key = identity(model)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(model)
        }
        return order.compactMap { key -> ModelCandidate? in
            guard let entries = groups[key], let first = entries.first else { return nil }
            let offers = entries.map(ModelOffer.init(model:)).sorted { lhs, rhs in
                if lhs.isLocal != rhs.isLocal { return lhs.isLocal }
                if let preferred {
                    let lh = lhs.selection == preferred, rh = rhs.selection == preferred
                    if lh != rh { return lh }
                }
                let lhDirect = ProviderIdentity.slug(lhs.providerID) != "opencode"
                let rhDirect = ProviderIdentity.slug(rhs.providerID) != "opencode"
                if lhDirect != rhDirect { return lhDirect }
                if described(lhs) != described(rhs) { return described(lhs) }
                return lhs.providerName.localizedCaseInsensitiveCompare(rhs.providerName)
                    == .orderedAscending
            }
            let name = entries.map(\.name).max { $0.count < $1.count } ?? first.id
            return ModelCandidate(
                id: source.profileID.isEmpty ? key : "\(source.profileID)·\(key)",
                name: name.isEmpty ? first.id : name,
                family: ModelFamily.of(name: name, id: first.id), offers: offers,
                profileID: source.profileID, serverName: source.name,
                isElsewhere: !source.isCurrent)
        }
    }

    /// Whether an offer's own catalog entry says anything about the model beyond its name. The
    /// gateway that bothered to describe capabilities and effort levels is the one the folded row
    /// should speak for.
    private static func described(_ offer: ModelOffer) -> Bool {
        offer.model.capabilities != nil || !(offer.model.variants ?? []).isEmpty
    }

    private static func identity(_ model: ModelInfo) -> String {
        let scope = ProviderIdentity.isLocal(model.providerID) ? "local:" : "hosted:"
        let name = ModelFamily.tokens(model.name).joined()
        guard name.isEmpty else { return scope + name }
        return scope + ModelFamily.tokens(bareID(model.id)).joined()
    }

    /// The part of an id that names the model: gateways prefix their own vendor path, Ollama tags
    /// a revision, and a dated release carries the date — none of which distinguish the model from
    /// itself reached elsewhere.
    static func bareID(_ raw: String) -> String {
        var id = raw.split(separator: "/").last.map(String.init) ?? raw
        if let colon = id.firstIndex(of: ":") {
            let tag = String(id[id.index(after: colon)...]).lowercased()
            if tag == "latest" { id = String(id[..<colon]) }
        }
        let parts = id.split(separator: "-")
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            id = parts.dropLast().joined(separator: "-")
        }
        return id
    }

    /// The models worth offering without opening the whole thing: what the person picked recently,
    /// whatever is picked now, and — for a catalog small enough to read in one glance — all of it.
    /// The quick menu and the full chooser are the same list at two lengths, never two lists.
    public static func shortlist(
        _ models: [ModelInfo], selected: ModelSelection?, limit: Int = 8,
        recents: [ModelSelection] = RecentModelsStore.all()
    ) -> [ModelCandidate] {
        let candidates = fold(models, preferred: selected)
        guard candidates.count > limit else { return candidates }
        var result: [ModelCandidate] = []
        if let selected, let match = candidates.first(where: { $0.carries(selected) }) {
            result.append(match)
        }
        for selection in recents {
            guard result.count < limit,
                let match = candidates.first(where: { $0.carries(selection) }),
                !result.contains(where: { $0.id == match.id })
            else { continue }
            result.append(match)
        }
        return result
    }
}

/// The chooser's rules, proved headlessly in the Kit rather than in one client — all three run this
/// from their own `--selftest`, so folding, ranking and the keys are checked once.
public enum ModelChooserCheck {
    public static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let catalog = [
            ModelInfo(
                id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", providerID: "anthropic",
                capabilities: ModelCapabilities(attachment: true, imageInput: true, pdfInput: true),
                variants: ["low", "medium", "high"]),
            ModelInfo(
                id: "anthropic/claude-sonnet-4.5", name: "Claude Sonnet 4.5",
                providerID: "openrouter"),
            ModelInfo(id: "gpt-5.6-luna", name: "GPT-5.6 Luna", providerID: "opencode-go"),
            ModelInfo(id: "deepseek-v4-flash", name: "DeepSeek V4 Flash", providerID: "opencode-go"),
            ModelInfo(
                id: "deepseek-v4-flash-direct", name: "DeepSeek V4 Flash", providerID: "deepseek"),
            ModelInfo(id: "qwen3:latest", name: "Qwen3", providerID: "ollama"),
            ModelInfo(id: "qwen3-coder", name: "Qwen3 Coder", providerID: "opencode-go"),
        ]

        let folded = ModelChooser.fold(catalog)
        expect(folded.count == 5, "the same model from two providers folds into one row")
        guard let sonnet = folded.first(where: { $0.name == "Claude Sonnet 4.5" }) else {
            return failures + ["the folded catalog lost Claude Sonnet"]
        }
        expect(sonnet.offers.count == 2, "both doors survive the fold")
        expect(sonnet.family.title == "Claude", "a model is filed under its own house")
        expect(
            sonnet.capabilities?.imageInput == true,
            "the fold keeps the offer that actually described itself first")
        expect(
            folded.first { $0.name == "Qwen3" }?.isLocal == true,
            "a local model stays local")
        expect(
            folded.filter { $0.family.title == "Qwen" }.count == 2,
            "local and hosted namesakes never fold together")
        expect(ModelChooser.bareID("anthropic/claude-sonnet-4-5-20250219") == "claude-sonnet-4-5",
            "a gateway prefix and a release date are not part of a model's name")
        expect(ModelChooser.bareID("qwen3:latest") == "qwen3", "a latest tag is not a revision")

        var chooser = ModelChooser(models: catalog, selected: nil, recents: [])
        expect(chooser.rows.first?.isAuto == true, "the server's own choice leads")
        expect(chooser.rows.first?.isSelected == true, "and is checked when nothing is picked")
        expect(
            chooser.sections.first?.id == "·current",
            "what the chat runs is a named section rather than an untitled row")
        expect(chooser.sections.count == 5, "current, then one section per family")
        expect(chooser.summary.contains("5"), "the summary counts the folded catalog")
        expect(
            chooser.rows.first { $0.title == "GPT-5.6 Luna" }?.detail.contains("gpt-5.6-luna")
                == false,
            "an id that only respells the name is not a second line")
        expect(
            chooser.rows.first { $0.title == "Qwen3" }?.detail.contains("qwen3:latest") == true,
            "an id that says more than the name stays")

        chooser.search("sonnet")
        expect(chooser.rows.count == 1, "a query narrows to what it names")
        expect(chooser.rows.first?.highlight.isEmpty == false, "and says which letters it read")
        expect(chooser.rows.first?.facts.contains(.providers(2)) == true, "two doors is a fact")
        expect(
            chooser.rows.first?.facts.contains(.effort(3)) == true, "so are its effort levels")

        chooser.search("openrouter")
        expect(chooser.rows.count == 1, "a provider nobody's model is named after still finds it")
        expect(chooser.rows.first?.highlight.isEmpty == true, "with nothing in the name to weight")

        chooser.search("qw3")
        expect(chooser.rows.count == 2, "scattered letters still reach a name")

        chooser.search("zzz")
        expect(chooser.rows.isEmpty, "a word the catalog lacks matches nothing")
        expect(chooser.emptyResult?.contains("zzz") == true, "and says so, naming the word")

        chooser.search("")
        expect(chooser.rows.count > 5, "clearing the query restores the catalog")
        let sonnetIndex = chooser.rows.firstIndex { $0.title == "Claude Sonnet 4.5" }
        expect(sonnetIndex != nil, "the folded row is in the list")
        if let sonnetIndex {
            chooser.focus(sonnetIndex)
            expect(chooser.setExpanded(true), "a folded row opens onto its providers")
            expect(chooser.rows.count > 6, "and the alternates take rows of their own")
            expect(chooser.rows[sonnetIndex + 1].isNested, "drawn under the row they belong to")
            let pick = chooser.rows[sonnetIndex + 1].selection
            expect(pick != nil, "an alternate picks a concrete provider")
            expect(chooser.setExpanded(false), "and closes again")
        }

        var picking = ModelChooser(models: catalog, selected: nil, recents: [])
        _ = picking.handle(.down)
        let outcome = picking.handle(.activate)
        expect(outcome.handled, "enter is the chooser's key")
        expect(outcome.pick != nil, "and answers with a pick")

        let auto = ModelChooser(
            models: catalog, selected: nil, allowsServerDefault: false, recents: [])
        expect(auto.rows.first?.isAuto == false, "a backend with no server default offers none")

        let empty = ModelChooser(models: [], selected: nil, recents: [])
        expect(empty.isEmpty, "an empty catalog is empty")
        expect(empty.summary == Localized.text("This server lists no models"), "and says so")

        let selection = ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-4-5")
        let opened = ModelChooser(models: catalog, selected: selection, recents: [])
        expect(
            opened.focused?.title == "Claude Sonnet 4.5",
            "the chooser opens on the model already chosen")

        var recent = ModelChooser(models: catalog, selected: nil, recents: [selection])
        expect(
            recent.sections.contains { $0.id == "·recent" },
            "what you reached for last leads the list")
        expect(
            Set(recent.rows.map(\.id)).count == recent.rows.count,
            "a model listed under Recent and again under its family is two rows, not one id twice")
        if let index = recent.rows.firstIndex(where: {
            $0.sectionID == "claude" && $0.canExpand
        }) {
            expect(recent.setExpanded(true, at: index), "the family copy opens onto its providers")
            expect(
                Set(recent.rows.map(\.id)).count == recent.rows.count,
                "and its alternates stay distinct from the recent copy's")
            expect(
                recent.focused?.sectionID == "claude",
                "expanding a row leaves the cursor on the row that was expanded")
        } else {
            failures.append("the recent catalog lost the expandable Claude row")
        }

        let short = ModelChooser.shortlist(
            catalog, selected: selection, limit: 3, recents: [selection])
        expect(short.count == 1, "a shortlist is what you reached for, not a prefix of the catalog")
        expect(
            ModelChooser.shortlist(catalog, selected: nil, limit: 99, recents: []).count == 5,
            "a catalog that fits is shown whole")

        let studio = ModelSource(
            profileID: "studio", name: "studio", backend: .claudeCode,
            models: [
                ModelInfo(id: "opus", name: "Opus", providerID: "anthropic"),
                ModelInfo(id: "sonnet", name: "Sonnet", providerID: "anthropic"),
            ], isCurrent: true, allowsServerDefault: true, acceptsAnyModelID: true)
        let homelab = ModelSource(
            profileID: "homelab", name: "homelab", backend: .openCode, models: catalog,
            isCurrent: false, allowsServerDefault: true, acceptsAnyModelID: false)

        var fleet = ModelChooser(sources: [studio, homelab], selected: nil, recents: [])
        expect(fleet.candidates.count == 7, "every server's catalog is in the one list")
        expect(
            Set(fleet.rows.map(\.id)).count == fleet.rows.count,
            "two servers offering the same model are two rows, not one id twice")
        expect(
            fleet.summary.contains(ModelChooser.serverCount(2)),
            "and the summary says how many machines are in it")
        guard let mine = fleet.rows.firstIndex(where: { $0.title == "Opus" }),
            let theirs = fleet.rows.firstIndex(where: { $0.title == "Claude Sonnet 4.5" })
        else {
            return failures + ["the fleet list lost a server's models"]
        }
        expect(mine < theirs, "this machine's models lead their family")
        expect(fleet.rows[mine].isElsewhere == false, "a model here is not elsewhere")
        expect(fleet.rows[theirs].isElsewhere, "a model on the other machine says so")
        expect(
            fleet.rows[theirs].facts.contains(.server("homelab")),
            "and names the machine that would run it")
        expect(
            fleet.rows[theirs].pick.profileID == "homelab",
            "picking it answers with that machine")
        expect(
            fleet.rows[theirs].pick.isElsewhere,
            "and says the work has to move rather than the chat change")
        expect(fleet.rows[mine].isSelected == false, "nothing is picked yet")

        fleet.search("homelab")
        expect(
            !fleet.rows.isEmpty && fleet.rows.allSatisfy { $0.isElsewhere || $0.isLiteral },
            "a server's name finds what it runs")

        fleet.search("claude-opus-4-5-20260101")
        expect(fleet.emptyResult == nil, "a name the catalog lacks is not the end of the list")
        let literals = fleet.rows.filter(\.isLiteral)
        expect(literals.count == 1, "only the server that takes any name offers to take this one")
        expect(literals.first?.profileID == "studio", "and it is the one whose CLI does")
        expect(
            literals.first?.pick.selection?.modelID == "claude-opus-4-5-20260101",
            "typing an id is a way of picking it")

        fleet.search("sonnet")
        expect(
            fleet.rows.contains { !$0.isElsewhere } && fleet.rows.contains { $0.isElsewhere },
            "one query reaches both machines")
        expect(
            fleet.rows.first?.isElsewhere == false,
            "with this machine's answer first")
        expect(
            fleet.rows.contains { $0.isLiteral } == false,
            "a name the catalog already has is not offered as a typed id")

        let alone = ModelChooser(models: catalog, selected: nil, recents: [])
        expect(
            alone.rows.allSatisfy { !$0.isElsewhere },
            "one server's list has nowhere else in it")
        expect(
            alone.rows.first?.pick.isElsewhere == false,
            "and every pick stays where it is")

        expect(
            ModelChooser(models: studio.models, selected: nil, recents: []).scopes.isEmpty,
            "a catalog with one machine and nothing local offers no filters")
        expect(
            alone.scopes == [.all, .local],
            "a catalog with a local model can be asked for only those")

        var filtered = ModelChooser(sources: [studio, homelab], selected: nil, recents: [])
        expect(
            filtered.scopes == [.all, .here, .local],
            "a fleet with local models offers both narrowings, whole catalog first")
        expect(filtered.setScope(.here), "a filter narrows the list")
        expect(
            filtered.rows.allSatisfy { !$0.isElsewhere },
            "and nothing from another machine survives it")
        expect(
            filtered.summary.contains(Localized.text("This server").lowercased()),
            "the header says what is standing in the way")
        expect(filtered.summary.contains("of"), "and how much of the catalog is left")
        filtered.search("qwen coder")
        expect(filtered.rows.isEmpty, "a query inside a filter is both at once")
        expect(
            filtered.emptyResult?.contains(Localized.text("This server").lowercased()) == true,
            "and an empty answer names the filter as well as the query")
        expect(filtered.emptyEscape == .all, "with the way out of it")
        expect(filtered.setScope(.all), "which restores the catalog")
        expect(!filtered.rows.isEmpty, "and finds what the filter was hiding")
        filtered.search("")
        expect(filtered.setScope(.local), "local is a filter of its own")
        expect(filtered.rows.allSatisfy { !$0.isAuto ? $0.facts.contains(.local) : true },
            "and holds only what runs on a machine of yours")

        var keyed = ModelChooser(models: catalog, selected: nil, recents: [])
        expect(keyed.handle(.scope(1)).handled, "⌃2 takes the filter it names")
        expect(keyed.scope == .local, "which is the second one offered")
        expect(
            !keyed.handle(.scope(5)).handled,
            "and a filter nobody offered leaves the key to whoever wants it")

        let described = [
            ModelInfo(
                id: "a-one", name: "A One", providerID: "anthropic",
                capabilities: ModelCapabilities(attachment: true, imageInput: true, pdfInput: true)),
            ModelInfo(
                id: "a-two", name: "A Two", providerID: "anthropic",
                capabilities: ModelCapabilities(attachment: true, imageInput: true, pdfInput: false)),
        ]
        let uniform = ModelChooser(models: described, selected: nil, recents: [])
        expect(
            uniform.rows.allSatisfy { !$0.facts.contains(.vision) },
            "a capability every model in the catalog has is a fact about none of them")
        expect(
            uniform.rows.contains { $0.facts.contains(.pdf) },
            "the one that tells two models apart is still worn")

        let ownModel = ModelSelection(providerID: "ollama", modelID: "qwen3:latest")
        let inUse = ModelChooser(
            models: catalog, selected: ownModel, recents: [ownModel, selection])
        expect(inUse.sections.first?.id == "·current", "the model in use leads its own section")
        expect(inUse.rows.first?.isSelected == true, "and is the row the chooser opens on")
        let recentRows = inUse.sections.first { $0.id == "·recent" }?.rows ?? []
        expect(
            !recentRows.contains { $0.title == "Qwen3" },
            "Recent stops repeating what the section above it already said")
        expect(!recentRows.isEmpty, "while what else you reached for is still there")

        func window(_ label: String, _ fraction: Double) -> UsageQuota.Gauge {
            UsageQuota.Gauge(
                key: label, label: label, fraction: fraction,
                resetsAt: Date().addingTimeInterval(7_200), trustedReset: true)
        }
        func account(_ gauges: [UsageQuota.Gauge]) -> UsageQuota {
            UsageQuota(
                providerName: "Claude", subtitle: "", source: "selftest", live: true,
                gauges: gauges, details: [])
        }

        let scoped = ModelChooser(
            models: catalog, selected: nil, recents: [],
            quotas: [account([window("Weekly · Opus 4.1", 1), window("5-hour session", 0.3)])])
        expect(
            scoped.rows.allSatisfy { $0.wall == nil },
            "a wall around a model the catalog does not carry marks nothing")

        let walled = ModelChooser(
            models: catalog, selected: nil, recents: [],
            quotas: [account([window("Weekly · Sonnet 4.5", 1), window("5-hour session", 0.3)])])
        let sonnetRow = walled.rows.first { $0.title == "Claude Sonnet 4.5" }
        expect(sonnetRow?.wall != nil, "the model the window names is marked spent")
        expect(sonnetRow?.wall?.isAccountWide == false, "and knows the wall is its own")
        expect(
            walled.rows.filter { $0.title.hasPrefix("GPT") }.allSatisfy { $0.wall == nil },
            "a model the window never mentioned is left alone")
        expect(walled.summary.contains(Localized.text("%@ used up", "1")), "and the count says so")

        let ranked = ModelChooser(
            models: studio.models, selected: nil, recents: [],
            quotas: [account([window("Weekly · Opus 4.1", 1)])])
        let opusAt = ranked.rows.firstIndex { $0.title == "Opus" }
        let sonnetAt = ranked.rows.firstIndex { $0.title == "Sonnet" }
        expect(
            opusAt != nil && sonnetAt != nil && sonnetAt! < opusAt!,
            "a spent model sinks under the ones in its family that can still answer")
        if let wall = sonnetRow?.wall {
            expect(
                QuotaSurface.rowNote(wall).contains(Localized.text("Used up")),
                "the row says what it is")
            expect(QuotaSurface.rowNote(wall).contains("h "), "and when it comes back")
        }

        let stopped = ModelChooser(
            models: catalog, selected: nil, recents: [],
            quotas: [account([window("5-hour session", 1)])])
        expect(
            stopped.rows.filter { $0.title == "Claude Sonnet 4.5" }.allSatisfy { $0.wall != nil },
            "a window metered against the account stops the models its provider bills")
        expect(
            stopped.rows.first { !$0.isAuto && $0.wall != nil }?.wall?.isAccountWide == true,
            "and says it is the account's rather than the model's")
        expect(
            stopped.rows.filter { $0.title != "Claude Sonnet 4.5" && !$0.isAuto }
                .allSatisfy { $0.wall == nil },
            "a Claude wall is not a fact about models billed somewhere else")

        func quota(_ provider: String, _ gauges: [UsageQuota.Gauge]) -> UsageQuota {
            UsageQuota(
                providerName: provider, subtitle: "", source: "selftest", live: true,
                gauges: gauges, details: [])
        }

        let goWall = ModelChooser(
            models: catalog, selected: nil, recents: [],
            quotas: [quota("opencode go", [window("5-hour session", 1)])])
        expect(
            goWall.rows.filter { !$0.isAuto }.allSatisfy { row in
                let hosted = row.title != "Qwen3" && row.title != "Claude Sonnet 4.5"
                return (row.wall != nil) == hosted
            },
            "a reseller's account-wide wall holds every hosted model it fronts — and never one "
                + "another house's door runs")

        let deepWall = ModelChooser(
            models: catalog, selected: nil, recents: [],
            quotas: [quota("DeepSeek", [window("Balance", 1)])])
        expect(
            deepWall.rows.filter { $0.title == "DeepSeek V4 Flash" }.allSatisfy { $0.wall != nil },
            "a prepaid balance wall holds the models billed from it")
        expect(
            deepWall.rows.filter { $0.title != "DeepSeek V4 Flash" && !$0.isAuto }
                .allSatisfy { $0.wall == nil },
            "and leaves every other house alone")

        let keys: [(UInt32, UInt32, ModelChooserCommand?)] = [
            (Keymap.down, 0, .down),
            (Keymap.up, 0, .up),
            (Keymap.enter, 0, .activate),
            (Keymap.escape, 0, .dismiss),
            (0xFF53, Keymap.control, .expand),
            (0xFF51, Keymap.control, .collapse),
            (0xFF55, 0, .top),
            (UInt32(UnicodeScalar("1").value), Keymap.control, .scope(0)),
            (UInt32(UnicodeScalar("3").value), Keymap.control, .scope(2)),
            (UInt32(UnicodeScalar("1").value), 0, nil),
            (UInt32(UnicodeScalar("n").value), Keymap.control, .down),
            (UInt32(UnicodeScalar("j").value), 0, nil),
            (0xFF53, 0, nil),
            (UInt32(UnicodeScalar(" ").value), 0, nil),
        ]
        for (keyval, state, expected) in keys {
            guard let chord = KeyChord.canonical(keyval: keyval, state: state) else {
                failures.append("chord \(keyval) does not canonicalize")
                continue
            }
            expect(ModelChooser.command(for: chord) == expected, "key \(keyval)/\(state)")
        }
        return failures
    }
}

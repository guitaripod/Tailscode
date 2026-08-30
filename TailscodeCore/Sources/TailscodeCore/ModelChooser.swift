import CodingAgentKit
import Foundation
import Synchronization

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
    /// Whether the server answered the ask that produced this list. `nil` while the ask is out or
    /// nobody asked; `false` means the server refused and `models` is the last one known. A server
    /// that is down is a state, not an empty catalog, and the two must never read as one another.
    public let isReachable: Bool?

    public init(
        profileID: String, name: String, backend: AgentType, models: [ModelInfo],
        isCurrent: Bool, allowsServerDefault: Bool, acceptsAnyModelID: Bool,
        isReachable: Bool? = nil
    ) {
        self.profileID = profileID
        self.name = name
        self.backend = backend
        self.models = models
        self.isCurrent = isCurrent
        self.allowsServerDefault = allowsServerDefault
        self.acceptsAnyModelID = acceptsAnyModelID
        self.isReachable = isReachable
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
    case local
    /// The machine that would run it, said only when it is not the machine you are already on.
    case server(String)

    public var tag: String {
        switch self {
        case .vision: return Localized.text("vision")
        case .pdf: return Localized.text("pdf")
        case .attachments: return Localized.text("files")
        case .local: return Localized.text("local")
        case .server(let name): return name
        }
    }

    public var symbol: String {
        switch self {
        case .vision: return "photo"
        case .pdf: return "doc.richtext"
        case .attachments: return "paperclip"
        case .local: return "desktopcomputer"
        case .server: return "arrow.turn.down.right"
        }
    }

    public var label: String {
        switch self {
        case .vision: return Localized.text("Reads images")
        case .pdf: return Localized.text("Reads PDFs")
        case .attachments: return Localized.text("Takes attachments")
        case .local: return Localized.text("Runs on your server's machine")
        case .server(let name): return Localized.text("Runs on %@ — picking it starts a chat there", name)
        }
    }

    /// Whether this is something the model can read rather than something about where it runs.
    /// Clients draw the two in different registers and in that order: badges lead, marks follow.
    public var isCapability: Bool {
        switch self {
        case .vision, .pdf, .attachments: return true
        case .local, .server: return false
        }
    }

    /// The facts that belong on a candidate's row, in one order everywhere: what would move the
    /// work first, then what it reads. Effort levels and door counts are not facts here any more —
    /// effort is chosen after the pick and every model of a house has it, and the doors are counted
    /// in the row's own second line.
    public static func of(
        _ candidate: ModelCandidate, policy: ModelFactPolicy = .everything,
        namesLocal: Bool = true, namesMachine: Bool = false
    ) -> [ModelFact] {
        var facts: [ModelFact] = []
        if namesMachine { facts.append(.server(candidate.serverName)) }
        if candidate.isLocal, policy.showsLocal, namesLocal { facts.append(.local) }
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

/// One machine's standing in the chooser. A model is a thing a particular machine will run for
/// you, so the machine is the first question and a tab rather than a filter: the list under it is
/// one server's catalog, whole, and a pick on another tab is a chat that does not exist yet. The
/// old arrangement merged every server into one alphabet and offered "this server" and "local" as
/// standing filters over the merge, which is how the same model came to be listed once per
/// machine with the machine as a badge on each.
public struct ModelMachine: Sendable, Hashable, Identifiable {
    public let profileID: String
    public let title: String
    public let backend: AgentType
    /// Folded models this machine offers, local ones included.
    public let count: Int
    /// How many of them run on the machine's own hardware.
    public let localCount: Int
    /// The server the chooser was opened from — the one whose chat a pick changes in place.
    public let isCurrent: Bool
    public let isReachable: Bool?

    public init(
        profileID: String, title: String, backend: AgentType, count: Int, localCount: Int,
        isCurrent: Bool, isReachable: Bool?
    ) {
        self.profileID = profileID
        self.title = title
        self.backend = backend
        self.count = count
        self.localCount = localCount
        self.isCurrent = isCurrent
        self.isReachable = isReachable
    }

    public var id: String { profileID }

    /// The state the tab is in, as one word with a tone — the dot a chip wears and the line a
    /// briefing leads with. Answering needs no dot; a machine that has not answered yet is quiet
    /// rather than wrong; one that refused is danger, and what it shows is named as remembered.
    public var state: ModelMachineState {
        switch isReachable {
        case .some(true): return .answering
        case .none: return count == 0 ? .asking : .answering
        case .some(false): return count == 0 ? .notAnswering : .remembered
        }
    }

    /// Under the name: what the machine amounts to, or the state it is in when it cannot say.
    public var detail: String {
        if isReachable == false {
            return count == 0
                ? Localized.text("Not answering")
                : Localized.text("Not answering · last known list")
        }
        if isReachable == nil, count == 0 { return Localized.text("Asking…") }
        var parts = [ModelChooser.modelCount(count)]
        if localCount > 0 { parts.append(Localized.text("%@ local", "\(localCount)")) }
        return parts.joined(separator: " · ")
    }

    /// What a pick on this tab does, said once above the list rather than repeated on every row.
    /// Nothing on the current machine, because changing this chat is what a chooser is for.
    public var consequence: String? {
        isCurrent ? nil : Localized.text("A pick here starts a new chat on %@", title)
    }
}

/// Why a row survived the query, in the same tiers the slash palette ranks by, so the two lists
/// the composer opens behave like one idea.
/// One door the shown machine reaches its models through — a subscription, a key, a gateway — as
/// a filter over the list rather than a word repeated under every row. A person who pays for
/// Ollama Cloud and for OpenCode Go asks what each of them will run, and a catalog folded by
/// family answers that only one row at a time; narrowing to a door answers it whole, and a pick
/// made under a door goes through that door.
public struct ModelDoor: Sendable, Hashable, Identifiable {
    public let providerID: String
    public let title: String
    /// How many of the machine's models this door runs.
    public let count: Int
    public let isLocal: Bool

    public init(providerID: String, title: String, count: Int, isLocal: Bool) {
        self.providerID = providerID
        self.title = title
        self.count = count
        self.isLocal = isLocal
    }

    public var id: String { providerID }

    /// What kind of door this is — where the request goes and who bills it.
    public var kind: ModelDoorKind { isLocal ? .local : ModelDoorKind.classify(providerID) }

    public var detail: String {
        isLocal
            ? Localized.text("%@ on the server's own hardware", ModelChooser.modelCount(count))
            : ModelChooser.modelCount(count)
    }
}

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

    /// Whether you starred this model, wherever it is listed — a star follows the model
    /// through every section it appears in.
    public var isPinned: Bool = false

    public var isAuto: Bool {
        if case .auto = kind { return true }
        return false
    }

    public var isLiteral: Bool {
        if case .literal = kind { return true }
        return false
    }
}

/// A heading and what it holds — which, past a certain size, is a thing you open rather than a
/// thing you scroll. A hundred models is twenty screens of names nobody reads on the way to the one
/// they came for; the same hundred under headings that answer to a press is one screen you look at
/// and then aim into.
public struct ModelChooserSection: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let rows: [ModelChooserRow]
    /// Whether this heading is a control. Current, Recent and the typed-id offer are never closed:
    /// they are short by construction and they are what the list is for.
    public let canCollapse: Bool
    /// True when the rows are held back. `rows` is then empty, so nothing downstream has to know.
    public let isCollapsed: Bool
    /// How many models are under the heading whether or not they are showing.
    public let count: Int

    public init(
        id: String, title: String, detail: String, rows: [ModelChooserRow],
        canCollapse: Bool = false, isCollapsed: Bool = false, count: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.rows = rows
        self.canCollapse = canCollapse
        self.isCollapsed = isCollapsed
        self.count = count ?? rows.count
    }
}

public enum ModelChooserCommand: Sendable, Equatable {
    case up
    case down
    case top
    case bottom
    case activate
    case expand
    case collapse
    /// The nth machine's tab, counted from zero — ⌃1 is the server the chooser opened from.
    case machine(Int)
    /// The nth door, counted from zero; `nil` is every door — ⌥0.
    case door(Int?)
    /// Open every heading, or shut every one that answers to a press.
    case expandAll
    case collapseAll
    case dismiss
}

/// The one model list in the app: every server's catalog, one machine at a time, folded into
/// families, searched by one query and walked by one set of keys. Toolkit-free so the phone, GTK
/// and AppKit render the same decision rather than three lists that drifted apart.
///
/// The shape of the answer is the point. First the machine, as a tab, because which machine runs
/// a model is a different kind of question from which model — and a list that answers both at once
/// answers neither. Then, for that machine, what is yours before what exists: the model this chat
/// runs, the ones you starred, the ones you reached for, in one short section rather than three;
/// then what runs on the machine's own hardware, which is a class of its own; then the families.
/// A row is a name, and under it only what settles which model this is. What a row wears is what
/// would stop a send — a used-up window — or what the whole catalog does not share.
public struct ModelChooser: Sendable, Equatable {
    public static let recentLimit = 5
    /// How many of your own the Yours section holds before it stops being short.
    public static let yoursLimit = 8

    public let candidates: [ModelCandidate]
    public let sources: [ModelSource]
    public let allowsServerDefault: Bool
    public let selected: ModelSelection?
    /// Which facts this catalog is worth wearing, decided once over the whole of it.
    public let policy: ModelFactPolicy
    /// Every machine in the fleet, the one the chooser opened from first. One entry when there is
    /// one machine; a client draws the strip only past that, since a tab bar with one tab is chrome
    /// pretending to be a control.
    public let machines: [ModelMachine]
    private let recents: [ModelSelection]
    private var favorites: [ModelSelection]
    private var favoriteKeys: Set<String>
    /// Whether a row has to name who runs it. One provider behind the whole catalog is a fact
    /// about the server, said once at the top, not a word repeated under two hundred names.
    private let showsProviders: Bool
    /// One wall per candidate that has one, worked out once: a used-up window does not change
    /// while a list is open, and a search that re-ranks two hundred rows per keystroke must not
    /// re-read every gauge to draw them.
    private let walls: [String: QuotaExhaustion]

    /// Past this many hosted models a family heading opens rather than scrolls, and the list
    /// arrives shut except for what you are on and what you reach for. Under it, a closed heading
    /// would be a press standing between a person and a list they could already see whole.
    public static let foldFrom = 24

    public private(set) var query = ""
    /// The machine whose catalog is showing, by profile id.
    public private(set) var machine = ""
    /// The door the list is narrowed to, by provider id; `nil` is every door the machine has.
    public private(set) var door: String?
    public private(set) var cursor = 0
    public private(set) var expanded: Set<String> = []
    public private(set) var collapsed: Set<String> = []
    public private(set) var sections: [ModelChooserSection] = []
    public private(set) var rows: [ModelChooserRow] = []
    /// How many models on this machine answered the query, for the header's count.
    private var matched = 0
    /// How many answered it on other machines, listed under their own heading.
    private var elsewhereMatched = 0
    /// How many are held behind shut headings, so the header band can offer to open them.
    public private(set) var hidden = 0

    /// One server's list — the shape every screen that only ever meant this machine still asks for.
    public init(
        models: [ModelInfo], selected: ModelSelection?, allowsServerDefault: Bool = true,
        recents: [ModelSelection] = RecentModelsStore.all(), quotas: [UsageQuota] = [],
        isReachable: Bool? = nil
    ) {
        self.init(
            sources: [
                ModelSource(
                    profileID: "", name: "", backend: .openCode, models: models, isCurrent: true,
                    allowsServerDefault: allowsServerDefault, acceptsAnyModelID: false,
                    isReachable: isReachable)
            ], selected: selected, recents: recents, quotas: quotas)
    }

    /// Every server you have, one tab each. The machine a model runs on is the first choice rather
    /// than a badge on every row, and the pick that comes back says which machine it meant.
    ///
    /// `quotas` are the walls the account is up against, already narrowed to the backend's provider
    /// family by the caller that knows which one it opened — the chooser marks a model spent, it
    /// does not decide whose account a machine spends from.
    ///
    /// A wall is a fact about the *account*, not about the machine that would send the request, so
    /// it marks every row the same provider bills wherever that row is listed. Two machines signed
    /// into one Claude plan share one weekly window; leaving the copy on the other machine unmarked
    /// said the opposite, and a list that contradicts itself between two rows of the same model is
    /// worse than one that overstates a wall by a machine.
    public init(
        sources: [ModelSource], selected: ModelSelection?,
        recents: [ModelSelection] = RecentModelsStore.all(),
        favorites: [ModelSelection] = ModelFavoritesStore.all(), quotas: [UsageQuota] = []
    ) {
        let ordered = sources.sorted { lhs, rhs in lhs.isCurrent && !rhs.isCurrent }
        self.sources = ordered
        let candidates = ordered.flatMap { Self.fold(source: $0, preferred: selected) }
        self.candidates = candidates
        self.selected = selected
        self.allowsServerDefault = ordered.first { $0.isCurrent }?.allowsServerDefault ?? false
        self.recents = recents
        self.favorites = favorites
        self.favoriteKeys = Set(favorites.map(\.rawValue))
        self.walls = Self.walls(for: candidates, quotas: quotas)
        self.policy = .over(candidates)
        self.showsProviders = Set(candidates.flatMap { $0.offers.map(\.providerID) }).count > 1
        self.machines = Self.machines(for: ordered, candidates: candidates)
        self.machine = machines.first?.profileID ?? ""
        self.collapsed = Self.shutOnArrival(
            candidates: candidates.filter { $0.profileID == machine }, selected: selected)
        rebuild()
        cursor = rows.firstIndex { $0.isSelected } ?? 0
    }

    private static func machines(
        for sources: [ModelSource], candidates: [ModelCandidate]
    ) -> [ModelMachine] {
        sources.map { source in
            let mine = candidates.filter { $0.profileID == source.profileID }
            return ModelMachine(
                profileID: source.profileID, title: source.title, backend: source.backend,
                count: mine.count, localCount: mine.filter(\.isLocal).count,
                isCurrent: source.isCurrent, isReachable: source.isReachable)
        }
    }

    /// Which headings a big catalog opens on. Everything folds except the family the chat is
    /// already running from — you arrive next to what you have, not at the top of an alphabet.
    private static func shutOnArrival(
        candidates: [ModelCandidate], selected: ModelSelection?
    ) -> Set<String> {
        let hosted = candidates.filter { !$0.isLocal }
        guard hosted.count > foldFrom else { return [] }
        let mine = selected.flatMap { pick in
            hosted.first { $0.carries(pick) }?.family.key
        }
        return Set(hosted.map(\.family.key)).subtracting(mine.map { [$0] } ?? [])
    }

    private static func walls(
        for candidates: [ModelCandidate], quotas: [UsageQuota]
    ) -> [String: QuotaExhaustion] {
        guard !quotas.isEmpty else { return [:] }
        var found: [String: QuotaExhaustion] = [:]
        for candidate in candidates {
            for offer in candidate.offers {
                let key = offer.selection.rawValue
                guard found[key] == nil else { continue }
                guard let hit = wall(for: offer, named: candidate.name, quotas: quotas) else {
                    continue
                }
                found[key] = hit
            }
        }
        return found
    }

    /// The used-up window in front of one model, for the pill's shortlist — the same reading the
    /// full chooser draws, so a menu and the list behind it never disagree about what is spent.
    /// Only walls whose provider actually bills the door a pick would take count: a Go wall is
    /// not a fact about a row that would send through xAI, whatever their fractions.
    public static func wall(
        for candidate: ModelCandidate, quotas: [UsageQuota]
    ) -> QuotaExhaustion? {
        wall(for: candidate.primary, named: candidate.name, quotas: quotas)
    }

    /// The wall on one door of a folded model — what a nested alternate wears.
    public static func wall(
        for offer: ModelOffer, named name: String?, quotas: [UsageQuota]
    ) -> QuotaExhaustion? {
        let billers = quotas.filter { QuotaBinding.bills($0, offer: offer, named: name) }
        guard !billers.isEmpty else { return nil }
        return QuotaSurface.hottestExhausted(
            in: billers, model: offer.model.id, named: name)
    }

    public var isEmpty: Bool { candidates.isEmpty }

    /// The server the chooser was opened from.
    private var current: ModelSource? { sources.first { $0.isCurrent } }

    /// The server whose tab is showing.
    private var shown: ModelSource? { sources.first { $0.profileID == machine } }

    /// The tab that is showing, whole.
    public var shownMachine: ModelMachine? { machines.first { $0.profileID == machine } }

    /// Where the strip's highlight sits.
    public var machineIndex: Int { machines.firstIndex { $0.profileID == machine } ?? 0 }

    /// Whether a strip is worth drawing at all.
    public var showsMachines: Bool { machines.count > 1 }

    /// Every model on the shown machine, whatever door it comes through.
    private var wholeMachine: [ModelCandidate] { candidates.filter { $0.profileID == machine } }

    /// The shown machine's models, narrowed to the chosen door: a candidate keeps only the offer
    /// that door makes, so the row names one door and a pick goes through it.
    private var onShownMachine: [ModelCandidate] {
        guard let door else { return wholeMachine }
        return wholeMachine.compactMap { candidate in
            guard let offer = candidate.offers.first(where: { $0.providerID == door }) else {
                return nil
            }
            return ModelCandidate(
                id: candidate.id, name: candidate.name, family: candidate.family, offers: [offer],
                profileID: candidate.profileID, serverName: candidate.serverName,
                isElsewhere: candidate.isElsewhere)
        }
    }

    /// The doors the shown machine has, biggest first — one chip each, drawn only past one door,
    /// because a filter with one answer is chrome pretending to be a control.
    public var doors: [ModelDoor] {
        var counts: [String: Int] = [:]
        var local: Set<String> = []
        for candidate in wholeMachine {
            for offer in candidate.offers {
                counts[offer.providerID, default: 0] += 1
                if offer.isLocal { local.insert(offer.providerID) }
            }
        }
        return counts.map { id, count in
            ModelDoor(
                providerID: id, title: ProviderIdentity.displayName(id), count: count,
                isLocal: local.contains(id))
        }
        .sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs.title < rhs.title : lhs.count > rhs.count
        }
    }

    public var showsDoors: Bool { doors.count > 1 }

    /// The door showing, whole.
    public var shownDoor: ModelDoor? { doors.first { $0.providerID == door } }

    /// Where a door strip's highlight sits: 0 is every door, then the doors in `doors` order.
    public var doorIndex: Int { doors.firstIndex { $0.providerID == door }.map { $0 + 1 } ?? 0 }

    /// Narrows the list to one door, or opens it to every door with `nil`. A door is a fact about
    /// the shown machine, so a tab change lets it go.
    @discardableResult
    public mutating func setDoor(_ providerID: String?) -> Bool {
        guard providerID != door else { return false }
        if let providerID {
            guard doors.contains(where: { $0.providerID == providerID }) else { return false }
        }
        door = providerID
        expanded.removeAll()
        collapsed = Self.shutOnArrival(candidates: onShownMachine, selected: selected)
        rebuild()
        cursor = rows.firstIndex { $0.isSelected } ?? 0
        return true
    }

    /// What a server that is not answering amounts to, said in place of a claim about its catalog.
    /// A restart is a state, not an empty list: the words the header and the empty body show must
    /// name the state, or a reader who restarted the server is told it has no models while the
    /// answer is on the way back up.
    public var serverReading: String? {
        guard let shown else { return nil }
        switch shown.isReachable {
        case nil where shown.models.isEmpty:
            return Localized.text("Asking the server for its models…")
        case false where shown.models.isEmpty:
            return Localized.text("Server is not answering — models will appear when it comes back")
        case false:
            return Localized.text("Server is not answering — showing the last known list")
        default:
            return nil
        }
    }

    /// Whether anything is standing between the reader and the whole catalog.
    public var isNarrowed: Bool { !query.isEmpty || door != nil }

    /// What the list amounts to right now: the shown machine's whole catalog when nothing is
    /// narrowing it, and otherwise how much of it survived — a count that moves as you type is
    /// the only honest way for a header to answer "is it still looking".
    public var summary: String {
        let whole = wholeMachine
        guard !whole.isEmpty else {
            return serverReading ?? Localized.text("This server lists no models")
        }
        guard !isNarrowed else {
            var parts = [Localized.text("%@ of %@ models", "\(matched)", "\(whole.count)")]
            if let shownDoor { parts.append(Localized.text("via %@", shownDoor.title)) }
            if elsewhereMatched > 0 {
                parts.append(Localized.text("%@ elsewhere", "\(elsewhereMatched)"))
            }
            return parts.joined(separator: " · ")
        }
        return catalogSummary
    }

    /// What the shown machine's catalog amounts to, said once at the top instead of implied by
    /// scrolling.
    public var catalogSummary: String {
        let mine = wholeMachine
        guard !mine.isEmpty else {
            return serverReading ?? Localized.text("This server lists no models")
        }
        var parts = [Self.modelCount(mine.count)]
        if let reading = serverReading { parts.append(reading.lowercased()) }
        let providers = Set(mine.flatMap { $0.offers.map(\.providerID) })
        if providers.count > 1 { parts.append(Self.providerCount(providers.count)) }
        let local = mine.filter(\.isLocal).count
        if local > 0 { parts.append(Localized.text("%@ on its own machine", "\(local)")) }
        let walled = mine.filter { walls[$0.selection.rawValue] != nil }.count
        if walled > 0 { parts.append(Localized.text("%@ used up", "\(walled)")) }
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
        var parts = [Localized.text("↑↓ chooses")]
        parts.append(Localized.text("⌃→ opens · ⌃← folds"))
        if showsMachines {
            parts.append(Localized.text("⌃1–%@ servers", "\(machines.count)"))
        }
        if showsDoors {
            parts.append(Localized.text("⌥1–%@ providers · ⌥0 all", "\(min(doors.count, 9))"))
        }
        parts.append(Localized.text("enter picks · esc closes"))
        return parts.joined(separator: " · ")
    }

    /// Said when nothing survived, naming the machine as well as the word — a reader who forgot
    /// which tab is showing would otherwise read an empty list as a catalog that lost a model.
    ///
    /// Empty means nothing under any heading — not no rows: past `foldFrom` the families arrive
    /// shut and `rows` is legitimately empty while a dozen headings each say how many they hold,
    /// and a chooser that read that as "runs none of these models" drew the refusal over the
    /// very list it was refusing.
    public var emptyResult: String? {
        guard sections.allSatisfy({ $0.count == 0 }) else { return nil }
        guard !query.isEmpty else {
            if let shownDoor {
                return Localized.text("%@ runs none of these models", shownDoor.title)
            }
            return serverReading
        }
        if let shownDoor {
            return Localized.text("No model via %@ matches “%@”", shownDoor.title, query)
        }
        guard showsMachines, let shownMachine else {
            return Localized.text("No model matches “%@”", query)
        }
        return Localized.text("No model on %@ matches “%@”", shownMachine.title, query)
    }

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

    /// Shows another machine's catalog. The cursor lands on whatever that machine already runs
    /// for this chat, else at the top: a tab is a new question, and its answer starts at its first
    /// line. The query stays — a person who typed "sonnet" and switched machines is still asking
    /// about sonnet.
    @discardableResult
    public mutating func setMachine(_ profileID: String) -> Bool {
        guard profileID != machine, machines.contains(where: { $0.profileID == profileID }) else {
            return false
        }
        machine = profileID
        door = nil
        expanded.removeAll()
        collapsed = Self.shutOnArrival(candidates: onShownMachine, selected: selected)
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
            if setExpanded(true) { return (true, nil, false) }
            guard let section = focused?.sectionID else { return (false, nil, false) }
            return (setCollapsed(false, section: section), nil, false)
        case .collapse:
            if setExpanded(false) { return (true, nil, false) }
            guard let section = focused?.sectionID else { return (false, nil, false) }
            return (setCollapsed(true, section: section), nil, false)
        case .expandAll:
            return (setAllCollapsed(false), nil, false)
        case .collapseAll:
            return (setAllCollapsed(true), nil, false)
        case .machine(let index):
            guard showsMachines, machines.indices.contains(index) else {
                return (false, nil, false)
            }
            return (setMachine(machines[index].profileID), nil, false)
        case .door(let index):
            guard showsDoors else { return (false, nil, false) }
            guard let index else { return (setDoor(nil), nil, false) }
            guard doors.indices.contains(index) else { return (false, nil, false) }
            return (setDoor(doors[index].providerID), nil, false)
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
            case right: return chord.shift ? .expandAll : .expand
            case left: return chord.shift ? .collapseAll : .collapse
            default: break
            }
            if let digit = Keymap.digit(chord.keyval), digit > 0 { return .machine(digit - 1) }
            switch Keymap.scalar(chord.keyval) {
            case "n": return .down
            case "p": return .up
            default: return nil
            }
        }
        guard !chord.alt else {
            guard let digit = Keymap.digit(chord.keyval) else { return nil }
            return .door(digit == 0 ? nil : digit - 1)
        }
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
        var hiding = 0
        let mine = onShownMachine
        let matches = self.matches(in: mine)
        matched = matches.count
        if query.isEmpty {
            sections += yoursSection(in: mine)
        }
        sections += localSection(from: matches)
        var byFamily: [ModelFamily: [(ModelCandidate, [Int])]] = [:]
        for (candidate, highlight) in matches where !candidate.isLocal {
            byFamily[candidate.family, default: []].append((candidate, highlight))
        }
        for family in byFamily.keys.sorted() {
            let entries = byFamily[family] ?? []
            var detail = Self.modelCount(entries.count)
            let providers = Set(entries.flatMap { $0.0.offers.map(\.providerID) })
            if providers.count > 1 { detail += " · " + Self.providerCount(providers.count) }
            let oneHouse = Set(entries.map { $0.0.primary.providerID }).count < 2
            let shut = query.isEmpty && collapsed.contains(family.key)
            if shut { hiding += entries.count }
            sections.append(
                ModelChooserSection(
                    id: family.key, title: family.title, detail: detail,
                    rows: shut
                        ? []
                        : entries.flatMap {
                            rows(
                                for: $0.0, section: family.key, highlight: $0.1,
                                namesProvider: !oneHouse)
                        },
                    canCollapse: query.isEmpty, isCollapsed: shut, count: entries.count))
        }
        let elsewhere = elsewhereSection()
        elsewhereMatched = elsewhere.reduce(0) { $0 + $1.count }
        sections += elsewhere
        sections += literalSections()
        self.sections = sections
        self.hidden = hiding
        rows = sections.flatMap(\.rows)
    }

    /// What is yours on this machine, in one short section: the model this chat runs, named
    /// rather than implied by a tick somewhere down the page; the ones you starred; the ones you
    /// reached for lately; and the server's own default, which is a real answer. Three headings
    /// used to say this — Current, Pinned, Recent — and a person opening the list read three
    /// headings before the first model they had not already chosen.
    private func yoursSection(in mine: [ModelCandidate]) -> [ModelChooserSection] {
        var picked: [ModelCandidate] = []
        var seen = Set<String>()
        func admit(_ candidate: ModelCandidate?) {
            guard let candidate, picked.count < Self.yoursLimit, seen.insert(candidate.id).inserted
            else { return }
            picked.append(candidate)
        }
        if let selected, let inUse = mine.first(where: { !$0.isElsewhere && $0.carries(selected) }) {
            admit(inUse)
        }
        for favorite in favorites { admit(mine.first { $0.carries(favorite) }) }
        for recent in recents.prefix(Self.recentLimit) { admit(mine.first { $0.carries(recent) }) }
        var rows = picked.flatMap { self.rows(for: $0, section: "·yours", highlight: []) }
        if allowsServerDefault, let current, current.profileID == machine {
            rows.append(
                ModelChooserRow(
                    kind: .auto, profileID: current.profileID, serverName: current.name,
                    isElsewhere: false, sectionID: "·yours",
                    title: Localized.text("Server default"),
                    detail: Localized.text("Whatever this server runs"), highlight: [],
                    facts: [], isSelected: selected == nil, isExpanded: false, canExpand: false,
                    isNested: false, wall: nil))
        }
        guard !rows.isEmpty else { return [] }
        return [
            ModelChooserSection(
                id: "·yours", title: Localized.text("Yours"),
                detail: Localized.text("Running, starred, recent"), rows: rows)
        ]
    }

    /// What runs on the machine's own hardware, as a section rather than a badge. Where a model
    /// runs is the whole difference between two models of the same name, so the local ones are
    /// listed here and only here — a family heading never mixes a model on your GPU with one on
    /// somebody's cloud.
    private func localSection(from matches: [(ModelCandidate, [Int])]) -> [ModelChooserSection] {
        let local = matches.filter { $0.0.isLocal }
        guard !local.isEmpty else { return [] }
        let title = shownMachine.map { machine in
            showsMachines
                ? Localized.text("On %@", machine.title) : Localized.text("On this machine")
        } ?? Localized.text("On this machine")
        return [
            ModelChooserSection(
                id: "·local", title: title,
                detail: Localized.text("Runs on the server's own hardware"),
                rows: local.flatMap {
                    rows(for: $0.0, section: "·local", highlight: $0.1, namesLocal: false)
                })
        ]
    }

    /// A query is asked of the machine that is showing, and answered from the others too — under
    /// their own heading, with the machine named on each row, because a person who typed a name
    /// wants to know it exists somewhere more than they want the tab respected.
    private func elsewhereSection() -> [ModelChooserSection] {
        guard !query.isEmpty, showsMachines else { return [] }
        let others = candidates.filter { $0.profileID != machine }
        let found = matches(in: others)
        guard !found.isEmpty else { return [] }
        let servers = Set(found.map { $0.0.profileID })
        return [
            ModelChooserSection(
                id: "·elsewhere", title: Localized.text("On other servers"),
                detail: Self.serverCount(servers.count),
                rows: found.flatMap {
                    rows(for: $0.0, section: "·elsewhere", highlight: $0.1, namesMachine: true)
                })
        ]
    }

    /// A catalog is a shortlist where the server will take any name, so a word it does not contain
    /// is not necessarily a mistake — it may be the model that shipped this morning, a dated
    /// release, or a context variant. The list says so and offers to use it rather than shrugging.
    private func literalSections() -> [ModelChooserSection] {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard typed.count > 1, !typed.contains(" ") else { return [] }
        let takers = sources.filter { source in
            guard source.acceptsAnyModelID else { return false }
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
        namesProvider: Bool = true, namesLocal: Bool = true, namesMachine: Bool = false
    ) -> [ModelChooserRow] {
        var result = [
            row(
                for: candidate, section: section, highlight: highlight,
                namesProvider: namesProvider, namesLocal: namesLocal, namesMachine: namesMachine)
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
                isNested: true,
                wall: walls[offer.selection.rawValue],
                isPinned: favoriteKeys.contains(offer.selection.rawValue))
        }
        return result
    }

    private func row(
        for candidate: ModelCandidate, section: String, highlight: [Int],
        namesProvider: Bool, namesLocal: Bool, namesMachine: Bool
    ) -> ModelChooserRow {
        ModelChooserRow(
            kind: .candidate(candidate), profileID: candidate.profileID,
            serverName: candidate.serverName, isElsewhere: candidate.isElsewhere,
            sectionID: section, title: candidate.name,
            detail: detail(for: candidate, namesProvider: namesProvider),
            highlight: highlight,
            facts: ModelFact.of(
                candidate, policy: policy, namesLocal: namesLocal, namesMachine: namesMachine),
            isSelected: !candidate.isElsewhere && candidate.carries(selected),
            isExpanded: expanded.contains(candidate.id),
            canExpand: candidate.offers.count > 1, isNested: false,
            wall: walls[candidate.selection.rawValue],
            isPinned: favoriteKeys.contains(candidate.selection.rawValue))
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
    /// A folded row names the door a pick would go through and counts the rest — `Anthropic +1` —
    /// which used to be a pill on the right; the list of them is one keystroke below the row.
    private func detail(for candidate: ModelCandidate, namesProvider: Bool) -> String {
        var parts: [String] = []
        let names = candidate.providerNames
        if candidate.offers.count > 1 {
            parts.append("\(names[0]) +\(candidate.offers.count - 1)")
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

    /// The given candidates ordered by how well each name answers the query. Ties inside a tier
    /// break on what the person picked recently, then alphabetically, so the list never reshuffles
    /// itself for reasons nobody can see.
    private func matches(in candidates: [ModelCandidate]) -> [(ModelCandidate, [Int])] {
        let recency = Dictionary(
            uniqueKeysWithValues: recents.enumerated().map { ($0.element, $0.offset) })
        func rank(_ candidate: ModelCandidate) -> Int {
            candidate.offers.compactMap { recency[$0.selection] }.min() ?? Int.max
        }
        guard !query.isEmpty else {
            return
                candidates
                .sorted { lhs, rhs in
                    let (walledL, walledR) = (
                        walls[lhs.selection.rawValue] != nil, walls[rhs.selection.rawValue] != nil
                    )
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
                let (walledL, walledR) = (
                    walls[lhs.0.selection.rawValue] != nil, walls[rhs.0.selection.rawValue] != nil
                )
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

    /// Whether a star is on this model right now.
    public func isFavorite(_ selection: ModelSelection) -> Bool {
        favoriteKeys.contains(selection.rawValue)
    }

    /// Stars or unstars a model and re-renders: the Yours section answers immediately, so the
    /// press feels like moving the list rather than filing a preference away somewhere.
    public mutating func togglePin(_ selection: ModelSelection) {
        ModelFavoritesStore.toggle(selection)
        favorites = ModelFavoritesStore.all()
        favoriteKeys = Set(favorites.map(\.rawValue))
        rebuild()
        cursor = min(cursor, max(0, rows.count - 1))
    }

    /// Opens or shuts one heading. Answers whether anything happened, so a key that finds nothing
    /// to fold can go on meaning what it usually means.
    @discardableResult
    public mutating func setCollapsed(_ shut: Bool, section id: String) -> Bool {
        guard query.isEmpty, sections.first(where: { $0.id == id })?.canCollapse == true else {
            return false
        }
        guard collapsed.contains(id) != shut else { return false }
        let anchor = focused?.anchor
        if shut { collapsed.insert(id) } else { collapsed.remove(id) }
        rebuild()
        cursor =
            rows.firstIndex { $0.sectionID == id && (!shut || $0.anchor == anchor) }
            ?? rows.firstIndex { $0.anchor == anchor }
            ?? min(cursor, max(0, rows.count - 1))
        return true
    }

    @discardableResult
    public mutating func toggleSection(_ id: String) -> Bool {
        setCollapsed(!collapsed.contains(id), section: id)
    }

    /// Every heading at once — the two presses a long list is worth having.
    @discardableResult
    public mutating func setAllCollapsed(_ shut: Bool) -> Bool {
        guard query.isEmpty else { return false }
        let foldable = Set(sections.filter(\.canCollapse).map(\.id))
        let next = shut ? collapsed.union(foldable) : collapsed.subtracting(foldable)
        guard next != collapsed else { return false }
        let anchor = focused?.anchor
        collapsed = next
        rebuild()
        cursor = rows.firstIndex { $0.anchor == anchor } ?? 0
        return true
    }

    /// Whether anything is folded right now, so a client can name the press it is offering.
    public var hasCollapsedSections: Bool {
        sections.contains { $0.isCollapsed }
    }

    /// What the one press at the top of the list would do, and to how much. `nil` when there is
    /// nothing to fold either way — a control that cannot change anything is not offered.
    public var foldAction: (title: String, collapses: Bool)? {
        guard sections.contains(where: \.canCollapse) else { return nil }
        if hidden > 0 {
            return (Localized.text("Show %@ more", "\(hidden)"), false)
        }
        guard sections.filter({ $0.canCollapse }).count > 1 else { return nil }
        return (Localized.text("Fold all"), true)
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
    /// The quick menu's answer, over every server you have: what this chat runs, then your
    /// stars, then what you reached for lately, then the local floor. The same order the full
    /// directory opens on, cut to menu length — two surfaces, one list.
    public static func shortlist(
        sources: [ModelSource], selected: ModelSelection?, limit: Int = 8,
        recents: [ModelSelection] = RecentModelsStore.all(),
        favorites: [ModelSelection] = ModelFavoritesStore.all()
    ) -> [ModelCandidate] {
        let candidates = sources.flatMap { fold(source: $0, preferred: selected) }
        var result: [ModelCandidate] = []
        func admit(_ candidate: ModelCandidate?) {
            guard let candidate, result.count < limit,
                !result.contains(where: { $0.id == candidate.id })
            else { return }
            result.append(candidate)
        }
        if let selected { admit(candidates.first { !$0.isElsewhere && $0.carries(selected) }) }
        for selection in favorites { admit(candidates.first { $0.carries(selection) }) }
        for selection in recents { admit(candidates.first { $0.carries(selection) }) }
        for candidate in candidates where candidate.isLocal { admit(candidate) }
        return result
    }

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
public enum ModelChooserCheck {
    /// `run()` flips `ModelFavoritesStore` — real device state, not a copy — so two callers
    /// running at once (Swift Testing runs suites concurrently) steal each other's toggles and
    /// both report stars that did not land. One check at a time.
    private static let gate = Synchronization.Mutex<Bool>(false)

    public static func run() -> [String] {
        gate.withLock { _ in runLocked() }
    }

    private static func runLocked() -> [String] {
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
            chooser.sections.first?.id == "·yours",
            "what the chat runs is a named section rather than an untitled row")
        expect(
            chooser.sections.contains { $0.id == "·local" },
            "what runs on the machine's own hardware is a section of its own")
        expect(
            chooser.sections.first { $0.id == "qwen" }?.rows.allSatisfy { !$0.facts.contains(.local) }
                == true,
            "and never sits in a family beside a hosted namesake")
        expect(chooser.sections.count == 6, "yours, local, then one section per hosted family")
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
        expect(
            chooser.rows.first?.detail.contains("+1") == true,
            "two doors is counted in the second line rather than worn as a pill")
        expect(
            chooser.rows.first?.facts.allSatisfy(\.isCapability) == true,
            "and effort levels are not a fact about the pick")

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

        let empty = ModelChooser(models: [], selected: nil, recents: [], isReachable: true)
        expect(empty.isEmpty, "an empty catalog is empty")
        expect(empty.summary == Localized.text("This server lists no models"), "and says so, once the server has said it")

        let asking = ModelChooser(models: [], selected: nil, recents: [])
        expect(asking.summary.contains("Asking"), "before an answer arrives the list says it is asking")

        let refused = ModelChooser(models: [], selected: nil, recents: [], isReachable: false)
        expect(refused.summary.contains("not answering"), "a refused ask is a state, never an empty claim")

        let selection = ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-4-5")
        let opened = ModelChooser(models: catalog, selected: selection, recents: [])
        expect(
            opened.focused?.title == "Claude Sonnet 4.5",
            "the chooser opens on the model already chosen")

        var recent = ModelChooser(models: catalog, selected: nil, recents: [selection])
        expect(
            recent.sections.first { $0.id == "·yours" }?.rows.contains { $0.title == "Claude Sonnet 4.5" }
                == true,
            "what you reached for last leads the list")
        expect(
            Set(recent.rows.map(\.id)).count == recent.rows.count,
            "a model listed under Yours and again under its family is two rows, not one id twice")
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

        var fleet = ModelChooser(sources: [homelab, studio], selected: nil, recents: [])
        expect(fleet.candidates.count == 7, "every server's catalog is folded")
        expect(fleet.machines.count == 2 && fleet.showsMachines, "and each machine is a tab")
        expect(fleet.machines.first?.profileID == "studio", "the one the chooser opened from first")
        expect(fleet.machine == "studio", "and it is the tab showing")
        expect(fleet.machines[1].count == 5, "a tab counts what its machine offers")
        expect(fleet.machines[1].localCount == 1, "and how much of it is local")
        expect(fleet.machines[1].consequence != nil, "another machine's tab says a pick starts a chat there")
        expect(fleet.machines[0].consequence == nil, "this one's does not")
        expect(
            fleet.rows.allSatisfy { !$0.isElsewhere },
            "the list under a tab is one machine's catalog and nothing else's")
        expect(
            !fleet.rows.contains { $0.title == "Claude Sonnet 4.5" },
            "the other machine's models are not in it")
        expect(fleet.summary.contains(ModelChooser.modelCount(2)), "the summary counts this machine")
        expect(fleet.handle(.machine(1)).handled, "⌃2 shows the second machine")
        expect(fleet.machine == "homelab", "which is the one it names")
        guard let theirs = fleet.rows.firstIndex(where: { $0.title == "Claude Sonnet 4.5" }) else {
            return failures + ["the other machine's tab lost its models"]
        }
        expect(fleet.rows[theirs].isElsewhere, "a model on the other machine says so")
        expect(
            !fleet.rows[theirs].facts.contains(.server("homelab")),
            "without wearing the machine's name on every row under its own tab")
        expect(
            fleet.rows[theirs].pick.profileID == "homelab",
            "picking it answers with that machine")
        expect(
            fleet.rows[theirs].pick.isElsewhere,
            "and says the work has to move rather than the chat change")
        expect(
            !fleet.rows.contains { $0.isAuto },
            "the server default is this chat's server's answer, not another machine's")
        expect(!fleet.handle(.machine(5)).handled, "a tab nobody offered leaves the key alone")
        expect(fleet.setMachine("studio"), "and the tab goes back")

        var pinned = ModelChooser(sources: [studio, homelab], selected: nil, recents: [], favorites: [
            ModelSelection(providerID: "ollama", modelID: "qwen3:latest"),
        ])
        _ = pinned.setMachine("homelab")
        expect(
            pinned.sections.first { $0.id == "·yours" }?.rows.first?.title == "Qwen3",
            "a starred model leads Yours on the machine that runs it")
        expect(
            pinned.rows.first { $0.sectionID == "·yours" }?.isPinned == true,
            "and the row says it is pinned")
        pinned.togglePin(ModelSelection(providerID: "anthropic", modelID: "opus"))
        expect(pinned.isFavorite(ModelSelection(providerID: "anthropic", modelID: "opus")), "the star is on")
        pinned.togglePin(ModelSelection(providerID: "anthropic", modelID: "opus"))
        expect(!pinned.isFavorite(ModelSelection(providerID: "anthropic", modelID: "opus")), "and toggles off")

        let quick = ModelChooser.shortlist(
            sources: [studio, homelab], selected: nil, limit: 4,
            favorites: [ModelSelection(providerID: "openrouter", modelID: "anthropic/claude-sonnet-4.5")])
        expect(quick.first?.name != nil && quick.count <= 4, "the quick list keeps its length")
        expect(
            quick.contains { $0.name == "Claude Sonnet 4.5" },
            "a star from another door still makes the quick list")

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
            fleet.sections.last { $0.id == "·elsewhere" }?.rows.allSatisfy {
                $0.facts.contains(.server("homelab"))
            } == true,
            "and the other machine's answers under their own heading, each naming its machine")
        expect(fleet.summary.contains(Localized.text("%@ elsewhere", "1")), "the header counts them")
        expect(
            fleet.rows.contains { $0.isLiteral } == false,
            "a name the catalog already has is not offered as a typed id")
        fleet.search("qwen coder")
        expect(fleet.rows.count == 1 && fleet.rows.first?.isElsewhere == true,
            "a name only the other machine has is still found there")
        expect(fleet.emptyResult == nil, "so the list is not empty")
        fleet.search("zzz nowhere")
        expect(
            fleet.emptyResult?.contains("studio") == true,
            "an empty answer names the machine as well as the word")
        fleet.search("")

        let alone = ModelChooser(models: catalog, selected: nil, recents: [])
        expect(
            alone.rows.allSatisfy { !$0.isElsewhere },
            "one server's list has nowhere else in it")
        expect(
            alone.rows.first?.pick.isElsewhere == false,
            "and every pick stays where it is")

        expect(
            ModelChooser(models: studio.models, selected: nil, recents: []).showsMachines == false,
            "a catalog with one machine draws no strip")
        expect(
            alone.sections.first { $0.id == "·local" }?.title == Localized.text("On this machine"),
            "and its local section is named for the only machine there is")
        var keyed = ModelChooser(models: catalog, selected: nil, recents: [])
        expect(
            !keyed.handle(.machine(0)).handled,
            "a tab key with one machine leaves the key to whoever wants it")

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

        var big: [ModelInfo] = []
        for index in 0..<40 {
            big.append(
                ModelInfo(
                    id: "gpt-\(index)", name: "GPT \(index)", providerID: "openai",
                    capabilities: ModelCapabilities(
                        attachment: true, imageInput: true, pdfInput: index.isMultiple(of: 2))))
        }
        big.append(ModelInfo(id: "claude-x", name: "Claude X", providerID: "anthropic"))
        let picked = ModelSelection(providerID: "anthropic", modelID: "claude-x")
        var shelf = ModelChooser(models: big, selected: picked, recents: [])
        expect(
            shelf.sections.first { $0.id == "gpt" }?.isCollapsed == true,
            "a catalog too long to read arrives shelf")
        expect(
            shelf.sections.first { $0.id == "claude" }?.isCollapsed == false,
            "except where the model in use lives")
        expect(shelf.hidden == 40, "and says how much it is holding back")
        expect(
            shelf.sections.first { $0.id == "gpt" }?.count == 40,
            "a shut heading still counts what is under it")
        expect(shelf.rows.count < 10, "so the list is a screen rather than a scroll")
        expect(shelf.foldAction?.collapses == false, "the one press on offer is the opening one")
        expect(shelf.toggleSection("gpt"), "a heading opens")
        expect(shelf.rows.count > 40, "onto everything it held")
        expect(shelf.focused?.sectionID == "gpt", "with the cursor inside what just opened")
        expect(shelf.setAllCollapsed(true), "and every heading shuts at once")
        expect(shelf.rows.allSatisfy { $0.sectionID.hasPrefix("·") }, "leaving only the headings")
        shelf.search("gpt 3")
        expect(
            shelf.sections.allSatisfy { !$0.isCollapsed },
            "a query is never answered from behind a shut heading")
        expect(!shelf.rows.isEmpty, "and finds what folding was hiding")
        shelf.search("")
        expect(shelf.hidden > 0, "clearing the query gives the folding back")

        let tiny = ModelChooser(models: studio.models, selected: nil, recents: [])
        expect(
            tiny.sections.allSatisfy { !$0.isCollapsed },
            "a catalog you can read whole is never shelf")
        expect(tiny.foldAction == nil, "and offers no press for it")

        let ownModel = ModelSelection(providerID: "ollama", modelID: "qwen3:latest")
        let inUse = ModelChooser(
            models: catalog, selected: ownModel, recents: [ownModel, selection])
        expect(inUse.sections.first?.id == "·yours", "the model in use leads the list")
        expect(inUse.rows.first?.isSelected == true, "and is the row the chooser opens on")
        let yours = inUse.sections.first { $0.id == "·yours" }?.rows ?? []
        expect(
            yours.filter { $0.title == "Qwen3" }.count == 1,
            "a model both running and recent is one row, not two")
        expect(yours.contains { $0.title == "Claude Sonnet 4.5" }, "while what else you reached for is still there")
        expect(yours.last?.isAuto == true, "and the server's own default closes the section")

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
                // Only the door a pick would take. Dual-door DeepSeek prefers deepseek, so Go's
                // wall is not on the parent row; Claude and local never are.
                let goOnly = row.title == "GPT-5.6 Luna" || row.title == "Qwen3 Coder"
                return (row.wall != nil) == goOnly
            },
            "a reseller's wall holds models whose primary door is Go — never a dual-door "
                + "row that would send through another house, and never local")
        var goOpened = goWall
        if let index = goOpened.rows.firstIndex(where: { $0.title == "DeepSeek V4 Flash" }) {
            _ = goOpened.setExpanded(true, at: index)
        }
        expect(
            goOpened.rows.first { $0.isNested && $0.title == "OpenCode Go" }?.wall != nil,
            "the Go alternate under a dual-door row still names Go's spent window")
        expect(
            goOpened.rows.first { $0.isNested && $0.title == "DeepSeek" }?.wall == nil,
            "and the direct alternate does not")

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
            (UInt32(UnicodeScalar("1").value), Keymap.control, .machine(0)),
            (UInt32(UnicodeScalar("3").value), Keymap.control, .machine(2)),
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


/// The state a machine's tab is in, with the tone a chip paints its dot in. Every client reads
/// the same four faces so a server that stopped answering looks the same on three desks.
public enum ModelMachineState: Sendable, Hashable {
    case answering
    case asking
    case notAnswering
    /// Refused the ask, but a list from before is still on show.
    case remembered

    public enum Tone: Sendable, Hashable { case live, quiet, danger, attention }

    public var tone: Tone {
        switch self {
        case .answering: return .live
        case .asking: return .quiet
        case .notAnswering: return .danger
        case .remembered: return .attention
        }
    }

    /// Whether a chip should wear a dot at all: an answering machine needs no mark.
    public var wearsDot: Bool { self != .answering }

    public var word: String {
        switch self {
        case .answering: return Localized.text("Answering")
        case .asking: return Localized.text("Asking…")
        case .notAnswering: return Localized.text("Not answering")
        case .remembered: return Localized.text("Not answering · last known list")
        }
    }

    /// What the state means for a person about to pick, said once in the briefing.
    public var explanation: String {
        switch self {
        case .answering:
            return Localized.text(
                "This server answered the last ask for its catalog, so the list is what it will run right now.")
        case .asking:
            return Localized.text(
                "The catalog has been asked for and has not come back yet. The list fills in the moment it does.")
        case .notAnswering:
            return Localized.text(
                "The server refused or could not be reached, and nothing is remembered from before. Check that it is running and on the tailnet; models appear when it comes back.")
        case .remembered:
            return Localized.text(
                "The server refused or could not be reached, so this is the list it gave last time. A pick here goes out when it is back — a model it has since lost will be refused then.")
        }
    }
}

/// Where a door leads. The provider keys a server names are config words ("opencode-go",
/// "openrouter"); a person choosing between two doors to the same model wants to know which one
/// is the plan they pay for monthly, which is a key that bills per token, which is a gateway
/// fronting somebody else's house, and which runs on the machine itself.
public enum ModelDoorKind: Sendable, Hashable {
    case local
    case subscription
    case key
    case gateway
    case free

    public static func classify(_ providerID: String) -> ModelDoorKind {
        switch providerID.lowercased() {
        case "ollama", "arch", "vllm", "lmstudio", "llamacpp": return .local
        case "opencode-go", "kimi-code", "claude", "anthropic-plan", "bonsai", "github-copilot":
            return .subscription
        case "openrouter", "ollama-cloud", "together", "groq", "fireworks": return .gateway
        case "opencode", "opencode-free", "server": return .free
        default: return .key
        }
    }

    public var title: String {
        switch self {
        case .local: return Localized.text("Runs on the server")
        case .subscription: return Localized.text("Subscription")
        case .key: return Localized.text("API key")
        case .gateway: return Localized.text("Gateway")
        case .free: return Localized.text("Free tier")
        }
    }

    public var symbol: String {
        switch self {
        case .local: return "desktopcomputer"
        case .subscription: return "creditcard"
        case .key: return "key"
        case .gateway: return "arrow.triangle.branch"
        case .free: return "gift"
        }
    }

    /// One-column glyph for the text desks.
    public var glyph: String {
        switch self {
        case .local: return "⌂"
        case .subscription: return "◉"
        case .key: return "⚿"
        case .gateway: return "⇶"
        case .free: return "○"
        }
    }

    public var explanation: String {
        switch self {
        case .local:
            return Localized.text(
                "The model runs in a process on the server's own hardware. Nothing leaves the machine and nothing is billed; speed is the machine's, and the list is whatever is pulled onto it.")
        case .subscription:
            return Localized.text(
                "A plan paid for monthly. Requests spend from its windows rather than per token, so a wall here is a window used up, not money gone — it opens again on its own clock.")
        case .key:
            return Localized.text(
                "A key the server holds for this provider's own API. Every request is billed per token to that account, and the catalog is whatever the provider offers to it.")
        case .gateway:
            return Localized.text(
                "One key, many houses: the gateway routes each request to the provider that actually runs the model and bills it on one account. The same model may also be reachable through its own door, which is usually cheaper or faster.")
        case .free:
            return Localized.text(
                "No key and no plan: the provider offers these models without an account, usually rate-limited and sometimes retired without notice.")
        }
    }
}

/// One card that explains a tab or a door: what it is, the state it is in, and exactly what is
/// behind it. The words are Core's so the three clients cannot disagree; a client draws headings,
/// lines and a footnote, and adds nothing.
public struct ChooserBriefing: Sendable, Hashable {
    public struct Line: Sendable, Hashable {
        public let label: String
        public let value: String
        /// An SF Symbol name where the platform has symbols; the text desks draw `glyph`.
        public let symbol: String?
        public let glyph: String?

        public init(label: String, value: String, symbol: String? = nil, glyph: String? = nil) {
            self.label = label
            self.value = value
            self.symbol = symbol
            self.glyph = glyph
        }
    }

    public struct Section: Sendable, Hashable {
        public let heading: String
        public let lines: [Line]
        public let footnote: String?

        public init(heading: String, lines: [Line], footnote: String? = nil) {
            self.heading = heading
            self.lines = lines
            self.footnote = footnote
        }
    }

    public let title: String
    public let subtitle: String
    public let tone: ModelMachineState.Tone?
    public let lead: String
    public let sections: [Section]

    public init(
        title: String, subtitle: String, tone: ModelMachineState.Tone?, lead: String,
        sections: [Section]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tone = tone
        self.lead = lead
        self.sections = sections
    }
}

extension ModelChooser {
    /// The card behind a machine's tab.
    public func briefing(machine profileID: String) -> ChooserBriefing? {
        guard let machine = machines.first(where: { $0.profileID == profileID }),
            let source = sources.first(where: { $0.profileID == profileID })
        else { return nil }
        let mine = candidates.filter { $0.profileID == profileID }
        var sections: [ChooserBriefing.Section] = []

        var state = [
            ChooserBriefing.Line(
                label: Localized.text("State"), value: machine.state.word,
                symbol: "circle.fill", glyph: "●")
        ]
        if machine.isCurrent {
            state.append(
                ChooserBriefing.Line(
                    label: Localized.text("This chat"),
                    value: Localized.text("A pick here changes this conversation in place"),
                    symbol: "bubble.left", glyph: "▸"))
        } else {
            state.append(
                ChooserBriefing.Line(
                    label: Localized.text("A pick here"),
                    value: Localized.text("Starts a new chat on %@", machine.title),
                    symbol: "plus.bubble", glyph: "+"))
        }
        sections.append(
            ChooserBriefing.Section(
                heading: Localized.text("Now"), lines: state,
                footnote: machine.state.explanation))

        var catalog = [
            ChooserBriefing.Line(
                label: Localized.text("Models"), value: Self.modelCount(mine.count),
                symbol: "cpu", glyph: "#")
        ]
        let families = Set(mine.filter { !$0.isLocal }.map(\.family.key)).count
        if families > 0 {
            catalog.append(
                ChooserBriefing.Line(
                    label: Localized.text("Families"), value: "\(families)",
                    symbol: "square.stack.3d.up", glyph: "≡"))
        }
        if machine.localCount > 0 {
            catalog.append(
                ChooserBriefing.Line(
                    label: Localized.text("On its own hardware"),
                    value: Self.modelCount(machine.localCount), symbol: "desktopcomputer",
                    glyph: "⌂"))
        }
        let vision = mine.filter { $0.capabilities?.imageInput == true }.count
        if vision > 0 {
            catalog.append(
                ChooserBriefing.Line(
                    label: Localized.text("See pictures"), value: Self.modelCount(vision),
                    symbol: "eye", glyph: "◉"))
        }
        let pdf = mine.filter { $0.capabilities?.pdfInput == true }.count
        if pdf > 0 {
            catalog.append(
                ChooserBriefing.Line(
                    label: Localized.text("Read PDFs"), value: Self.modelCount(pdf),
                    symbol: "doc.text", glyph: "▤"))
        }
        let levelled = mine.filter { !$0.variants.isEmpty }.count
        if levelled > 0 {
            catalog.append(
                ChooserBriefing.Line(
                    label: Localized.text("Take an effort level"), value: Self.modelCount(levelled),
                    symbol: "dial.medium", glyph: "◔"))
        }
        let walled = mine.filter { walls[$0.selection.rawValue] != nil }.count
        if walled > 0 {
            catalog.append(
                ChooserBriefing.Line(
                    label: Localized.text("Used up"), value: Self.modelCount(walled),
                    symbol: "exclamationmark.octagon", glyph: "!"))
        }
        sections.append(
            ChooserBriefing.Section(
                heading: Localized.text("Catalog"), lines: catalog,
                footnote: Self.catalogFootnote(source)))

        let doorsHere = doors(on: profileID)
        if !doorsHere.isEmpty {
            sections.append(
                ChooserBriefing.Section(
                    heading: Localized.text("Doors"),
                    lines: doorsHere.map { door in
                        ChooserBriefing.Line(
                            label: door.title,
                            value: Self.modelCount(door.count) + " · " + door.kind.title,
                            symbol: door.kind.symbol, glyph: door.kind.glyph)
                    },
                    footnote: Localized.text(
                        "A door is the account a request goes through — a plan, a key, a gateway, or the machine itself. The same model behind two doors is one row with a chevron; a pick made under a door goes through that door.")))
        }
        return ChooserBriefing(
            title: machine.title, subtitle: Self.backendLine(source.backend),
            tone: machine.state.tone, lead: Self.backendStory(source.backend), sections: sections)
    }

    /// The card behind a door's chip.
    public func briefing(door providerID: String) -> ChooserBriefing? {
        guard let door = doors.first(where: { $0.providerID == providerID }),
            let machine = shownMachine
        else { return nil }
        let through = wholeMachine.compactMap { candidate in
            candidate.offers.first { $0.providerID == providerID }.map { (candidate, $0) }
        }
        var lines = [
            ChooserBriefing.Line(
                label: Localized.text("Kind"), value: door.kind.title, symbol: door.kind.symbol,
                glyph: door.kind.glyph),
            ChooserBriefing.Line(
                label: Localized.text("Models"), value: Self.modelCount(door.count), symbol: "cpu",
                glyph: "#"),
        ]
        let alsoElsewhere = through.filter { $0.0.offers.count > 1 }.count
        if alsoElsewhere > 0 {
            lines.append(
                ChooserBriefing.Line(
                    label: Localized.text("Also behind another door"),
                    value: Self.modelCount(alsoElsewhere), symbol: "arrow.triangle.swap",
                    glyph: "⇄"))
        }
        let walled = through.filter { walls[$0.1.selection.rawValue] != nil }.count
        if walled > 0 {
            lines.append(
                ChooserBriefing.Line(
                    label: Localized.text("Used up"), value: Self.modelCount(walled),
                    symbol: "exclamationmark.octagon", glyph: "!"))
        }
        var sections = [
            ChooserBriefing.Section(
                heading: Localized.text("This door"), lines: lines,
                footnote: door.kind.explanation)
        ]
        var byFamily: [ModelFamily: Int] = [:]
        for (candidate, _) in through { byFamily[candidate.family, default: 0] += 1 }
        let families = byFamily.keys.sorted().prefix(8)
        if !families.isEmpty {
            sections.append(
                ChooserBriefing.Section(
                    heading: Localized.text("Behind it"),
                    lines: families.map { family in
                        ChooserBriefing.Line(
                            label: family.title, value: Self.modelCount(byFamily[family] ?? 0))
                    },
                    footnote: byFamily.count > families.count
                        ? Localized.text("and %@ more families", "\(byFamily.count - families.count)")
                        : nil))
        }
        return ChooserBriefing(
            title: door.title,
            subtitle: Localized.text("on %@", machine.title), tone: nil,
            lead: Localized.text(
                "Narrowing to this door lists only what %@ runs through it, and a pick goes through it.",
                machine.title), sections: sections)
    }

    /// The doors of any machine, not only the shown one, for a briefing opened on another tab.
    private func doors(on profileID: String) -> [ModelDoor] {
        var counts: [String: Int] = [:]
        var local: Set<String> = []
        for candidate in candidates where candidate.profileID == profileID {
            for offer in candidate.offers {
                counts[offer.providerID, default: 0] += 1
                if offer.isLocal { local.insert(offer.providerID) }
            }
        }
        return counts.map { id, count in
            ModelDoor(
                providerID: id, title: ProviderIdentity.displayName(id), count: count,
                isLocal: local.contains(id))
        }
        .sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs.title < rhs.title : lhs.count > rhs.count
        }
    }

    static func backendLine(_ backend: AgentType) -> String {
        switch backend {
        case .openCode: return Localized.text("opencode server")
        case .claudeCode: return Localized.text("Claude Code, through claude-bridge")
        case .omp: return Localized.text("Oh My Pi server")
        }
    }

    /// Where this kind of server gets its catalog, said once so a missing model is a fact about
    /// configuration rather than a mystery about the app.
    static func backendStory(_ backend: AgentType) -> String {
        switch backend {
        case .openCode:
            return Localized.text(
                "opencode lists every provider configured on that machine — its opencode.json, the keys in its environment, and any local runtime it found — and every model each of them offers. A model missing here is missing from that machine's configuration, not from Tailscode.")
        case .claudeCode:
            return Localized.text(
                "Claude Code answers to one account, so the catalog is a shortlist of Anthropic's models rather than every legal answer: the CLI runs whatever --model it is handed, and a model id typed into the search is offered as-is.")
        case .omp:
            return Localized.text(
                "Oh My Pi lists the providers its own configuration reaches. A model missing here is missing from that machine's setup.")
        }
    }

    static func catalogFootnote(_ source: ModelSource) -> String? {
        guard source.acceptsAnyModelID else { return nil }
        return Localized.text(
            "This server also runs model ids it never listed — type one into the search and it is offered as-is.")
    }
}

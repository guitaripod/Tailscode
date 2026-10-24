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

    /// The section is the house ``ModelNeedles`` reads, so the list and the pill's hue never
    /// disagree about whose a model is.
    public static func of(name: String, id: String) -> ModelFamily {
        of(name: name, id: id, providerID: nil)
    }

    public static func of(name: String, id: String, providerID: String?) -> ModelFamily {
        guard let rank = ModelNeedles.house(id: id, name: name, providerID: providerID) else {
            return other
        }
        let title = ModelNeedles.houses[rank].title
        return ModelFamily(key: title.lowercased(), title: title, rank: rank)
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
    /// The pinned pair this pick came from, resolved to the door the machine takes, so a caller
    /// sets the model and its level together. Nil for a model picked on its own.
    public let preset: ModelPreset?

    public init(
        profileID: String, selection: ModelSelection?, isElsewhere: Bool, serverName: String,
        modelName: String = "", preset: ModelPreset? = nil
    ) {
        self.profileID = profileID
        self.selection = selection
        self.isElsewhere = isElsewhere
        self.serverName = serverName
        self.modelName = modelName
        self.preset = preset
    }
}

/// What the person is aiming with when the chooser opens: the level the composer carries and the
/// levels the agent offers where a model names none. Told to a chooser, it lets every row say the
/// level a pick of it would run at.
public struct ChooserAim: Sendable, Equatable {
    public let effort: String?
    public let agentOptions: [String]

    public init(effort: String?, agentOptions: [String]) {
        self.effort = effort
        self.agentOptions = agentOptions
    }
}

/// Where the chooser was opened from, which decides what a pick on another machine means.
public enum ChooserContext: Sendable {
    /// A conversation in hand: a pick elsewhere starts a chat there.
    case chat
    /// A message not yet sent: a pick elsewhere aims that message at the other machine.
    case composer
    /// A server's own default: there is no other machine to be moved to.
    case serverDefault
    /// A question in a conversation in hand, asked again: every pick, on this machine or another,
    /// branches the chat from that question into a new one.
    case branch
    /// A hollow or held party slot being filled: every pick, on any machine, goes into the slot.
    case party
}

/// The level a pick of one row would run at, read on the same meter the pill wears. `level` nil
/// is the server deciding; `moved` says the level asked for is not one this model takes, and
/// `hint` says how it moved in two words.
public struct ModelRowLevel: Sendable, Hashable {
    public let level: String?
    public let word: String?
    public let heat: Int
    public let isPower: Bool
    public let isServer: Bool
    public let isEmber: Bool
    public let asked: String?
    public let moved: Bool
    public let takesLevels: Bool
    public let hint: String?

    public init(
        level: String?, word: String?, heat: Int, isPower: Bool, isServer: Bool, isEmber: Bool,
        asked: String?, moved: Bool, takesLevels: Bool, hint: String?
    ) {
        self.level = level
        self.word = word
        self.heat = heat
        self.isPower = isPower
        self.isServer = isServer
        self.isEmber = isEmber
        self.asked = asked
        self.moved = moved
        self.takesLevels = takesLevels
        self.hint = hint
    }

    /// The reading for a model whose levels are `options`, at `level` as the pick would send it.
    /// Nil where the model takes no level, because then there is nothing to draw.
    static func of(
        level: String?, asked: String?, moved: Bool, options: [String]
    ) -> ModelRowLevel? {
        guard ModelEffort.isOffered(options: options) else { return nil }
        let face = ModelDial.face(modelWord: "", effort: level, options: options)
        let word = face.effortWord
        let hint = moved
            ? asked.map { Localized.text("%@ → %@", spelled($0), word ?? Localized.text("server")) }
            : nil
        return ModelRowLevel(
            level: ModelEffort.surviving(level, options: options), word: word, heat: face.heat,
            isPower: face.isPower, isServer: face.isServer, isEmber: face.isEmber, asked: asked,
            moved: moved, takesLevels: true, hint: hint)
    }

    /// A row that is not the chat's own model, at the level the aim carries onto it.
    static func carried(_ asked: String?, options: [String]) -> ModelRowLevel? {
        let carry = ModelEffort.carry(asked, options: options)
        return of(level: carry.level, asked: carry.asked, moved: carry.moved, options: options)
    }

    private static func spelled(_ level: String) -> String {
        ModelDial.isPower(level) ? Ultracode.menuTitle.lowercased() : level
    }
}

/// Where a row stands among the person's pins, and the one pin a press on its star would toggle.
public struct RowPinning: Sendable, Hashable {
    /// Any pin on this model through this door — its star, or a pair at any level.
    public let isPinned: Bool
    /// The level the pin a press would make, or the pair a pinned-pair row is.
    public let level: PresetEffort
    /// The pin a press on this row toggles; nil on a row that cannot be pinned.
    public let preset: ModelPreset?

    public init(isPinned: Bool, level: PresetEffort, preset: ModelPreset?) {
        self.isPinned = isPinned
        self.level = level
        self.preset = preset
    }

    public static let none = RowPinning(isPinned: false, level: .keep, preset: nil)
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

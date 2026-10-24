import CodingAgentKit
import Foundation

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
    public var consequence: String? { consequence(for: .chat) }

    /// The same sentence for where the chooser was opened: a conversation is moved by a pick on
    /// another machine, a message waiting to be sent is only re-aimed, and a server's own default
    /// has nowhere else to go.
    public func consequence(for context: ChooserContext) -> String? {
        if context == .branch {
            return Localized.text("A pick here branches this chat from that question on %@", title)
        }
        guard !isCurrent else { return nil }
        switch context {
        case .chat: return Localized.text("A pick here starts a new chat on %@", title)
        case .composer: return Localized.text("A pick here aims this message at %@", title)
        case .serverDefault, .branch: return nil
        }
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

    /// Ollama Cloud is a plan rather than a gateway: it is metered by a session window and a
    /// weekly one and billed a flat month, which is the subscription's shape and not the
    /// per-token routing a gateway does.
    public static func classify(_ providerID: String) -> ModelDoorKind {
        if ProviderIdentity.isLocal(providerID) { return .local }
        switch providerID.lowercased() {
        case "opencode-go", "kimi-code", "claude", "anthropic-plan", "bonsai", "github-copilot",
            "ollama-cloud":
            return .subscription
        case "openrouter", "together", "groq", "fireworks": return .gateway
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

import CodingAgentKit
import Foundation

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
        case .local: return Localized.text("Runs on the server's own hardware")
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

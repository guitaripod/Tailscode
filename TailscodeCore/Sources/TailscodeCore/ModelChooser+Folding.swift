import CodingAgentKit
import Foundation

extension ModelChooser {
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
                family: ModelFamily.of(name: name, id: first.id, providerID: first.providerID), offers: offers,
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

    /// The quick menu's answer, over every server you have: what this chat runs, then your stars,
    /// then what you reached for lately — and nothing else. A menu is a record of the person's own
    /// reaching, so it is exactly as long as that record: padding the remaining slots with whatever
    /// the machines happen to run themselves buried two models somebody uses under six they never
    /// picked, and made the same model appear twice because a second server also offers it. The
    /// full directory is one row away and is where a model nobody has picked yet is found. The
    /// same order the full directory opens on, cut to menu length — two surfaces, one list.
    public static func shortlist(
        sources: [ModelSource], selected: ModelSelection?, limit: Int = 8,
        recents: [ModelSelection] = RecentModelsStore.all(),
        favorites: [ModelSelection] = ModelFavoritesStore.all()
    ) -> [ModelCandidate] {
        shortlistEntries(
            sources: sources, selected: selected, limit: limit, recents: recents,
            favorites: favorites
        ).map(\.candidate)
    }

    /// The same shortlist, each row carrying the door it was remembered through. A recent or a star
    /// is a selection — a model *and* the provider it went through — and a row that answered with
    /// the folded candidate's preferred door instead would move the bill on a re-pick nobody asked
    /// to move.
    public static func shortlistEntries(
        sources: [ModelSource], selected: ModelSelection?, limit: Int = 8,
        recents: [ModelSelection] = RecentModelsStore.all(),
        favorites: [ModelSelection] = ModelFavoritesStore.all(),
        excluding skip: (ModelCandidate) -> Bool = { _ in false }
    ) -> [ModelMenuEntry] {
        let candidates = sources.flatMap { fold(source: $0, preferred: selected) }
        var result: [ModelMenuEntry] = []
        func admit(_ candidate: ModelCandidate?, _ door: ModelSelection?) {
            guard let candidate, result.count < limit, !skip(candidate),
                !result.contains(where: { $0.candidate.id == candidate.id })
            else { return }
            result.append(ModelMenuEntry(candidate: candidate, selection: door ?? candidate.selection))
        }
        if let selected {
            admit(candidates.first { !$0.isElsewhere && $0.carries(selected) }, selected)
        }
        for selection in favorites { admit(candidates.first { $0.carries(selection) }, selection) }
        for selection in recents { admit(candidates.first { $0.carries(selection) }, selection) }
        if result.isEmpty { seedUntouched(candidates) { admit($0, nil) } }
        return result
    }

    /// What a menu offers a device that has picked nothing yet. There is no history to show and an
    /// empty menu teaches nothing, so it opens on the models the machines run themselves — the ones
    /// that cost nothing to try — one per model rather than one per server offering it. A fleet
    /// that runs nothing itself (a Claude bridge serves only Anthropic's models) opens on the aimed
    /// machine's own catalog instead, because a menu holding nothing but "Server default" read as
    /// a machine with no models at all.
    private static func seedUntouched(
        _ candidates: [ModelCandidate], admit: (ModelCandidate?) -> Void
    ) {
        var seen: Set<String> = []
        for candidate in candidates where candidate.isLocal {
            guard seen.insert(candidate.name.lowercased()).inserted else { continue }
            admit(candidate)
        }
        guard seen.isEmpty else { return }
        for candidate in candidates where !candidate.isElsewhere { admit(candidate) }
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

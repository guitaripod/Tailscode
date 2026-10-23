import CodingAgentKit
import Foundation

extension ModelChooser {
    /// The keys of every model that wears a lit star: a bare star, or a pair at any level.
    var pinnedKeys: Set<String> {
        favoriteKeys.union(pins.map(\.selection.rawValue))
    }

    /// The levels one row's model takes, read the way the composer reads them.
    private func options(of row: ModelChooserRow, agentOptions: [String]) -> [String] {
        let model: ModelInfo?
        switch row.kind {
        case .auto: return []
        case .candidate(let candidate): model = candidate.primary.model
        case .alternate(_, let offer): model = offer.model
        case .literal: model = nil
        }
        return ModelEffort.options(
            models: model.map { [$0] } ?? [], selection: row.selection, agentOptions: agentOptions)
    }

    /// The facts every row carries beyond its words: the level a pick would run at, the chip, the
    /// pin its star toggles, and the word for where it runs. A Pinned row arrives with its own
    /// reading and pin already set, because its level is the pair's rather than the aim's.
    func decorated(
        _ row: ModelChooserRow, pinned keys: Set<String>, catalog: [ModelInfo]
    ) -> ModelChooserRow {
        var row = row
        row.chip = ModelBadge.chip(selection: row.selection, effort: nil, catalog: catalog)
        row.place = place(of: row)
        guard row.pair == nil else { return row }
        guard let selection = row.selection else { return row }
        if let aim {
            let options = options(of: row, agentOptions: aim.agentOptions)
            row.reading = row.isSelected
                ? ModelRowLevel.of(
                    level: ModelEffort.surviving(aim.effort, options: options), asked: aim.effort,
                    moved: false, options: options)
                : ModelRowLevel.carried(aim.effort, options: options)
        }
        let level: PresetEffort = row.reading.map { $0.level.map(PresetEffort.level) ?? .server } ?? .keep
        row.isPinned = keys.contains(selection.rawValue)
        row.pinning = RowPinning(
            isPinned: row.isPinned, level: level,
            preset: ModelPreset(selection: selection, effort: level))
        return row
    }

    private func place(of row: ModelChooserRow) -> String? {
        if row.isAuto { return nil }
        if row.isElsewhere { return Localized.text("on %@", row.serverName) }
        switch row.kind {
        case .candidate(let candidate) where candidate.isLocal: return Localized.text("local")
        case .alternate(_, let offer) where offer.isLocal: return Localized.text("local")
        default: return nil
        }
    }

    /// The pinned pairs the shown machine can run, one row each at the pair's own level, ahead of
    /// everything else: a pair is a decision already made, and the list should open on it. A pair
    /// that lives on another machine is not listed here — this list is one machine's catalog.
    func pinnedSection(in mine: [ModelCandidate]) -> [ModelChooserSection] {
        guard let shown else { return [] }
        var rows: [ModelChooserRow] = []
        var seen: Set<String> = []
        for pin in pins {
            guard let resolved = ModelPresetCycle.resolve(pin, on: shown),
                let candidate = mine.first(where: { $0.carries(resolved.selection) }),
                let offer = candidate.offer(for: resolved.selection),
                seen.insert(resolved.id).inserted
            else { continue }
            let leading = ModelCandidate(
                id: candidate.id, name: candidate.name, family: candidate.family,
                offers: [offer] + candidate.offers.filter { $0.selection != offer.selection },
                profileID: candidate.profileID, serverName: candidate.serverName,
                isElsewhere: candidate.isElsewhere)
            let options = ModelEffort.options(
                models: [offer.model], selection: offer.selection,
                agentOptions: aim?.agentOptions ?? [])
            let reading: ModelRowLevel?
            switch pin.effort {
            case .server: reading = ModelRowLevel.of(level: nil, asked: nil, moved: false, options: options)
            case .level(let level): reading = ModelRowLevel.carried(level, options: options)
            case .keep: reading = aim.flatMap { ModelRowLevel.carried($0.effort, options: options) }
            }
            let running = aim.map {
                !candidate.isElsewhere && resolved.matches(model: selected, effort: $0.effort)
            } ?? false
            var row = ModelChooserRow(
                kind: .candidate(leading), profileID: candidate.profileID,
                serverName: candidate.serverName, isElsewhere: candidate.isElsewhere,
                sectionID: "·pinned", title: candidate.name,
                detail: detail(for: leading, namesProvider: true), highlight: [],
                facts: ModelFact.of(leading, policy: policy), isSelected: running,
                isExpanded: false, canExpand: false, isNested: false,
                wall: walls[offer.selection.rawValue], isPinned: true)
            row.reading = reading
            row.pinning = RowPinning(isPinned: true, level: pin.effort, preset: pin)
            row.pair = resolved
            rows.append(row)
        }
        guard !rows.isEmpty else { return [] }
        return [
            ModelChooserSection(
                id: "·pinned", title: Localized.text("Pinned"),
                detail: Localized.text("A model and a level together"), rows: rows)
        ]
    }

    /// What is yours on this machine, in one short section: the model this chat runs, named
    /// rather than implied by a tick somewhere down the page; the ones you starred; the ones you
    /// reached for lately; and the server's own default, which is a real answer. Three headings
    /// used to say this — Current, Pinned, Recent — and a person opening the list read three
    /// headings before the first model they had not already chosen.
    func yoursSection(
        in mine: [ModelCandidate], covered: Set<String> = [], runningCovered: Bool = false
    ) -> [ModelChooserSection] {
        var picked: [ModelCandidate] = []
        var seen = Set<String>()
        func admit(_ candidate: ModelCandidate?) {
            guard let candidate, picked.count < Self.yoursLimit, seen.insert(candidate.id).inserted
            else { return }
            picked.append(candidate)
        }
        if !runningCovered, let selected,
            let inUse = mine.first(where: { !$0.isElsewhere && $0.carries(selected) })
        {
            admit(inUse)
        }
        seen.formUnion(covered)
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
    func localSection(from matches: [(ModelCandidate, [Int])]) -> [ModelChooserSection] {
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
    func elsewhereSection() -> [ModelChooserSection] {
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
    func literalSections() -> [ModelChooserSection] {
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

    func rows(
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
}

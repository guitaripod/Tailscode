import CodingAgentKit
import Foundation

/// The popover's whole state: the model column with its cursor and query, the ladder with the
/// level it currently sends, and the keys. The client draws it and forwards presses.
///
/// The ladder follows the cursor. On the model this chat runs it is the live control it always
/// was; on any other row it is a preview of that model's own levels with the level the pair would
/// take selected, and stepping it there is part of the pick rather than a change to the chat — so
/// the person sees, before committing, that a level will carry over or that a model has fewer.
public struct ModelDialState: Sendable {
    public enum Column: Sendable, Equatable {
        case models
        case ladder
    }

    public private(set) var rows: [ModelDialRow]
    public private(set) var cursor: Int
    public private(set) var query: String
    public private(set) var column: Column
    /// The level the composer carries now. Not what the ladder shows while a preview is up — that
    /// is `ladderEffort`.
    public private(set) var effort: String?
    public let catalogSummary: String
    /// How many models the catalog holds beyond what the column shows, for the row that opens it.
    public let catalogCount: Int

    private let sources: [ModelSource]
    private let selected: ModelSelection?
    private let quotas: [UsageQuota]
    private let options: [String]
    private let agentOptions: [String]
    private let catalog: [ModelInfo]
    private let modelWord: String
    private let recents: [ModelSelection]
    private var pinned: [ModelPreset]
    private var stepped: (rowID: String, level: String?)?

    static let shortlistLimit = 9

    public init(
        sources: [ModelSource], selected: ModelSelection?, effort: String?, options: [String],
        modelWord: String, quotas: [UsageQuota] = [],
        recents: [ModelSelection] = RecentModelsStore.all(),
        presets: [ModelPreset] = ModelPresetStore.all(), agentOptions: [String]? = nil
    ) {
        self.sources = sources
        self.selected = selected
        self.quotas = quotas
        self.options = options
        self.agentOptions = agentOptions ?? options
        self.catalog = sources.flatMap(\.models)
        self.modelWord = modelWord
        self.recents = recents
        self.pinned = presets
        self.effort = ModelEffort.surviving(effort, options: options)
        let chooser = ModelChooser(
            sources: sources, selected: selected, recents: recents, quotas: quotas)
        self.catalogSummary = chooser.summary
        self.catalogCount = sources.reduce(0) { $0 + $1.models.count }
        self.query = ""
        self.column = .models
        self.rows = []
        self.cursor = 0
        rebuild()
        cursor = rows.firstIndex { $0.isCurrent } ?? firstSelectable
    }

    public var focused: ModelDialRow? {
        rows.indices.contains(cursor) ? rows[cursor] : nil
    }

    /// Whether the ladder is the live control of this chat's model. On any other row it is a
    /// preview, and a step on it travels with the pick instead.
    public var effortIsLive: Bool {
        guard let row = focused, let candidate = row.candidate else { return true }
        if row.preset != nil { return false }
        return !candidate.isElsewhere && candidate.carries(selected)
    }

    /// The levels of the model the ladder is drawn for: the cursor's, which is this chat's own
    /// whenever the cursor rests there.
    public var focusedOptions: [String] {
        guard !effortIsLive, let candidate = focused?.candidate else { return options }
        return ModelEffort.options(
            models: catalog, selection: candidate.selection, agentOptions: agentOptions)
    }

    public var rungs: [EffortRung] { ModelDial.rungs(options: focusedOptions) }

    public var headline: String {
        let name = effortIsLive ? modelWord : (focused?.candidate?.name ?? modelWord)
        return ModelDial.headline(modelName: name, options: focusedOptions)
    }

    /// The level the ladder lights: the live one on this chat's model, and on any other row the
    /// level that row's pair would take — a preset's own, a stepped one, or the current level
    /// carried onto that model.
    public var ladderEffort: String? {
        if effortIsLive { return effort }
        guard let row = focused, row.candidate != nil else { return effort }
        if let stepped, stepped.rowID == row.id {
            return ModelEffort.surviving(stepped.level, options: focusedOptions)
        }
        let asked = row.preset.map { $0.asks(current: effort) } ?? effort
        return ModelEffort.carry(asked, options: focusedOptions).level
    }

    /// Whether the ladder is showing a level that is not the chat's own, for the client to say so:
    /// a preview of another model, or of a pair the chat is not at. The pair the chat runs right
    /// now is just the chat, and wears no tag.
    public var ladderIsPreview: Bool {
        if effortIsLive { return false }
        guard let row = focused else { return false }
        return !(row.isCurrent && stepped?.rowID != row.id)
    }

    /// The rung the composer will send with, for the client to light.
    public var currentRung: EffortRung? { rungs.first { $0.level == ladderEffort } }

    /// What would become of the level if the cursor's row were taken as it stands, when that is
    /// not nothing: said under the ladder so a level that will move is never a surprise. A model
    /// that takes no level is already the headline's whole sentence, and is not said twice.
    public var carryNotice: String? {
        guard !effortIsLive, let row = focused, row.preset == nil,
            stepped?.rowID != row.id, let candidate = row.candidate, let asked = effort,
            ModelEffort.isOffered(options: focusedOptions)
        else { return nil }
        return ModelEffort.carry(asked, options: focusedOptions)
            .forecast(modelName: candidate.name)
    }

    /// The sentence a client says after a pick that moved the level on its own — the model has no
    /// such level — read from the state the pick was taken in. Nil where the person chose the level
    /// (a pair, a step on the preview) or nothing moved.
    public var pickNotice: String? {
        guard !effortIsLive, let row = focused, row.preset == nil, stepped?.rowID != row.id,
            let candidate = row.candidate, let asked = effort
        else { return nil }
        return ModelEffort.carry(asked, options: focusedOptions).notice(modelName: candidate.name)
    }

    /// Digits pick rungs only while the search field is empty: a model's name has digits in it,
    /// and a person typing "gpt-5" is naming a model, not asking for five bars.
    public var digitsPickEffort: Bool { query.isEmpty }

    public mutating func search(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        rebuild()
        cursor = rows.firstIndex { $0.candidate != nil } ?? firstSelectable
        cursorMoved()
    }

    /// A level chosen by hand on the ladder: live on this chat's model, part of the pending pick on
    /// any other row.
    @discardableResult
    public mutating func setEffort(_ level: String?) -> ModelDialOutcome {
        guard ModelEffort.isOffered(options: focusedOptions) else { return .unhandled }
        let level = ModelEffort.surviving(level, options: focusedOptions)
        if effortIsLive {
            effort = level
            return .effort(level)
        }
        guard let row = focused else { return .unhandled }
        stepped = (row.id, level)
        return .previewed(level)
    }

    public mutating func move(to index: Int) {
        guard rows.indices.contains(index), !rows[index].isMessage else { return }
        cursor = index
        cursorMoved()
    }

    public mutating func handle(_ command: ModelDialCommand) -> ModelDialOutcome {
        switch command {
        case .up:
            if column == .ladder { return stepLadder(by: 1) }
            guard !rows.isEmpty else { return .unhandled }
            cursor = previousSelectable(from: cursor)
            cursorMoved()
            return .moved
        case .down:
            if column == .ladder { return stepLadder(by: -1) }
            guard !rows.isEmpty else { return .unhandled }
            cursor = nextSelectable(from: cursor)
            cursorMoved()
            return .moved
        case .top:
            cursor = firstSelectable
            cursorMoved()
            return .moved
        case .bottom:
            cursor = max(0, rows.count - 1)
            cursorMoved()
            return .moved
        case .hotter:
            return stepLadder(by: 1)
        case .colder:
            return stepLadder(by: -1)
        case .digit(let key):
            guard digitsPickEffort, let rung = ModelDial.rung(forKey: key, options: focusedOptions)
            else { return .unhandled }
            return setEffort(rung.level)
        case .switchColumn:
            column =
                column == .models && ModelEffort.isOffered(options: focusedOptions)
                ? .ladder : .models
            return .moved
        case .activate:
            guard let row = focused else { return .dismiss }
            if row.opensCatalog { return .openCatalog }
            if row.isMessage { return .unhandled }
            guard let pick = row.pick else { return .dismiss }
            return .pick(pick, effort: effortAsk(for: row))
        case .dismiss:
            return .dismiss
        case .pin:
            guard let row = focused, let candidate = row.candidate else { return .unhandled }
            let preset = row.preset ?? ModelPreset(
                selection: candidate.selection, effort: pairedEffort(for: row, candidate: candidate))
            pinned = ModelPresetStore.toggled(pinned, preset)
            rebuild()
            if let moved = rows.firstIndex(where: { $0.candidate?.id == candidate.id }) {
                cursor = moved
            }
            cursorMoved()
            return .pinned(preset)
        case .openAll:
            return .openCatalog
        }
    }

    /// The chord grammar, shared with the chooser window where the keys mean the same thing.
    /// `digitsLive` is the search field being empty: with words in it, a digit is part of a
    /// model's name and a bare arrow moves the caret, so both step the ladder only with ⌃ held.
    public static func command(for chord: KeyChord, digitsLive: Bool) -> ModelDialCommand? {
        if chord.keyval == Keymap.escape { return .dismiss }
        if chord.keyval == Keymap.enter { return chord.control ? .openAll : .activate }
        if chord.keyval == Keymap.tab || chord.keyval == 0xFE20 { return .switchColumn }
        if chord.keyval == Keymap.up { return chord.control ? .top : .up }
        if chord.keyval == Keymap.down { return chord.control ? .bottom : .down }
        if chord.keyval == 0xFF51, digitsLive || chord.control { return .colder }
        if chord.keyval == 0xFF53, digitsLive || chord.control { return .hotter }
        if chord.control, Keymap.scalar(chord.keyval) == "s" { return .pin }
        if chord.control, Keymap.scalar(chord.keyval) == "n" { return .down }
        if chord.control, Keymap.scalar(chord.keyval) == "p" { return .up }
        if digitsLive, !chord.control, !chord.alt, let digit = Keymap.digit(chord.keyval) {
            return .digit(digit)
        }
        return nil
    }

    private mutating func stepLadder(by delta: Int) -> ModelDialOutcome {
        guard ModelEffort.isOffered(options: focusedOptions) else { return .unhandled }
        return setEffort(ModelDial.step(ladderEffort, by: delta, options: focusedOptions))
    }

    private mutating func cursorMoved() {
        if let stepped, stepped.rowID != focused?.id { self.stepped = nil }
        if column == .ladder, !ModelEffort.isOffered(options: focusedOptions) { column = .models }
    }

    private func effortAsk(for row: ModelDialRow) -> EffortAsk {
        if row.kind == .serverDefault || effortIsLive { return .unchanged }
        return .set(ladderEffort)
    }

    private func pairedEffort(for row: ModelDialRow, candidate: ModelCandidate) -> PresetEffort {
        let levels = ModelEffort.options(
            models: catalog, selection: candidate.selection, agentOptions: agentOptions)
        guard ModelEffort.isOffered(options: levels) else { return .keep }
        let level = effortIsLive ? effort : ladderEffort
        return level.map { .level($0) } ?? .server
    }

    private var firstSelectable: Int { rows.firstIndex { !$0.isMessage } ?? 0 }

    private func nextSelectable(from index: Int) -> Int {
        guard let next = rows.indices.first(where: { $0 > index && !rows[$0].isMessage })
        else { return index }
        return next
    }

    private func previousSelectable(from index: Int) -> Int {
        guard let previous = rows.indices.last(where: { $0 < index && !rows[$0].isMessage })
        else { return index }
        return previous
    }

    /// The column: the pairs pinned, this chat's own model where no pair already says it, what the
    /// person reached for lately, then the other machines under their own names — a pick there
    /// opens a chat there, said once on the row rather than once per row's chips — then the
    /// server's own choice and the door to the catalog. A query answers from the whole fleet
    /// through the chooser's own search, so a model nobody pinned is still one typed name away
    /// without leaving the composer.
    private mutating func rebuild() {
        var built: [ModelDialRow] = []
        if query.isEmpty {
            built += shortlistRows()
        } else {
            var chooser = ModelChooser(
                sources: sources, selected: selected, recents: recents, quotas: quotas)
            chooser.search(query)
            let found = chooser.rows.compactMap { row -> ModelCandidate? in
                if case .candidate(let candidate) = row.kind { return candidate }
                return nil
            }
            var seen: Set<String> = []
            let unique = found.filter { seen.insert($0.id).inserted }.prefix(Self.shortlistLimit)
            if unique.isEmpty {
                built.append(noResultsRow())
            } else {
                let policy = ModelFactPolicy.over(Array(unique))
                built += unique.enumerated().map { index, candidate in
                    row(
                        candidate, preset: nil, section: index == 0 ? Localized.text("Found") : nil,
                        namesMachine: true, policy: policy)
                }
            }
        }
        if selected != nil || query.isEmpty {
            built.append(
                ModelDialRow(
                    kind: .serverDefault, section: nil, title: Localized.text("Server default"),
                    detail: Localized.text("the machine decides"), isStarred: false,
                    isCurrent: selected == nil, wall: nil, facts: [], level: nil))
        }
        built.append(
            ModelDialRow(
                kind: .allModels, section: nil, title: Localized.text("All models…"),
                detail: catalogSummary, isStarred: false, isCurrent: false, wall: nil, facts: [],
                level: nil))
        rows = built
        cursor = max(0, min(cursor, rows.count - 1))
    }

    private func shortlistRows() -> [ModelDialRow] {
        let candidates = sources.flatMap { ModelChooser.fold(source: $0, preferred: selected) }
        func find(_ selection: ModelSelection) -> ModelCandidate? {
            candidates.first { $0.carries(selection) }
        }
        var pairs: [(ModelPreset, ModelCandidate)] = pinned.compactMap { preset in
            find(preset.selection).map { (preset, $0) }
        }
        pairs = Array(pairs.prefix(Self.shortlistLimit))
        let pinnedModels = Set(pairs.map(\.1.id))
        let covered = pairs.contains { !$0.1.isElsewhere && $0.0.matches(model: selected, effort: effort) }

        var here: [ModelCandidate] = []
        var recent: [ModelCandidate] = []
        var budget = Self.shortlistLimit - pairs.count
        if let selected, !covered, budget > 0,
            let current = candidates.first(where: { !$0.isElsewhere && $0.carries(selected) })
        {
            here.append(current)
            budget -= 1
        }
        for selection in recents where budget > 0 {
            guard let candidate = find(selection), !pinnedModels.contains(candidate.id),
                !here.contains(where: { $0.id == candidate.id }),
                !recent.contains(where: { $0.id == candidate.id })
            else { continue }
            recent.append(candidate)
            budget -= 1
        }
        if pairs.isEmpty, here.isEmpty, recent.isEmpty {
            recent = ModelChooser.shortlist(
                sources: sources, selected: selected, limit: Self.shortlistLimit, recents: [],
                favorites: [])
        }

        let policy = ModelFactPolicy.over(pairs.map(\.1) + here + recent)
        var built: [ModelDialRow] = []
        func append(_ group: [ModelDialRow]) { built += group }

        append(
            labelled(
                pairs.filter { !$0.1.isElsewhere }.map { row($0.1, preset: $0.0, section: nil, policy: policy) },
                Localized.text("Pinned")))
        append(
            labelled(
                here.map { row($0, preset: nil, section: nil, policy: policy) },
                Localized.text("This chat")))
        append(
            labelled(
                recent.filter { !$0.isElsewhere }.map { row($0, preset: nil, section: nil, policy: policy) },
                Localized.text("Recent")))

        let elsewhere = pairs.filter { $0.1.isElsewhere }.map { (Optional($0.0), $0.1) }
            + recent.filter(\.isElsewhere).map { (Optional<ModelPreset>.none, $0) }
        for (profileID, group) in Dictionary(grouping: elsewhere, by: { $0.1.profileID })
            .sorted(by: { $0.key < $1.key })
        {
            let title = sources.first { $0.profileID == profileID }?.title
                ?? group.first?.1.serverName ?? ""
            append(
                labelled(
                    group.map { row($0.1, preset: $0.0, section: nil, policy: policy) },
                    Localized.text("Also on %@", title)))
        }
        return built
    }

    private func labelled(_ rows: [ModelDialRow], _ section: String) -> [ModelDialRow] {
        guard let first = rows.first else { return [] }
        return [first.withSection(section)] + rows.dropFirst()
    }

    /// `namesMachine` is for a list that mixes machines — a search — where a row from another
    /// server has no heading to say so and must say it itself; a search row keeps only the
    /// local mark, because a name typed is a name looked for and the catalog carries the rest.
    private func row(
        _ candidate: ModelCandidate, preset: ModelPreset?, section: String?,
        namesMachine: Bool = false, policy: ModelFactPolicy
    ) -> ModelDialRow {
        let providers = candidate.providerNames.joined(separator: " · ")
        let machine = sources.first { $0.profileID == candidate.profileID }?.title
            ?? candidate.serverName
        let detail =
            candidate.isElsewhere
            ? (namesMachine ? Localized.text("new chat on %@", machine) : Localized.text("new chat there"))
            : providers
        let starred = pinned.contains { candidate.carries($0.selection) }
        let facts = ModelFact.of(candidate, policy: policy).filter { !namesMachine || $0 == .local }
        let current: Bool
        let kind: ModelDialRow.Kind
        if let preset {
            current = !candidate.isElsewhere && preset.matches(model: selected, effort: effort)
            kind = .preset(preset, candidate)
        } else {
            current = !candidate.isElsewhere && candidate.carries(selected)
            kind = .candidate(candidate)
        }
        return ModelDialRow(
            kind: kind, section: section, title: candidate.name, detail: detail,
            isStarred: starred, isCurrent: current,
            wall: ModelChooser.wall(for: candidate, quotas: quotas), facts: facts,
            level: preset.flatMap { level(of: $0, on: candidate) })
    }

    private func level(of preset: ModelPreset, on candidate: ModelCandidate) -> ModelDialRow.Level? {
        let levels = ModelEffort.options(
            models: catalog, selection: candidate.selection, agentOptions: agentOptions)
        guard ModelEffort.isOffered(options: levels) else { return nil }
        let asked: String?
        switch preset.effort {
        case .keep: return nil
        case .server: asked = nil
        case .level(let level): asked = ModelEffort.carry(level, options: levels).level
        }
        let face = ModelDial.face(modelWord: candidate.name, effort: asked, options: levels)
        return ModelDialRow.Level(
            word: face.effortWord ?? Localized.text("server"), heat: face.heat,
            isPower: face.isPower, isServer: face.isServer, isEmber: face.isEmber)
    }

    private func noResultsRow() -> ModelDialRow {
        let asked = sources.filter { $0.isReachable != false }.map(\.title)
        let offline = sources.filter { $0.isReachable == false }.map(\.title)
        var detail = asked.isEmpty ? "" : Localized.text("Searched %@.", asked.joined(separator: ", "))
        if !offline.isEmpty {
            let note = Localized.text(
                "%@ is offline, so it was not searched.", offline.joined(separator: ", "))
            detail = detail.isEmpty ? note : detail + " " + note
        }
        return ModelDialRow(
            kind: .noResults, section: nil,
            title: Localized.text("No model matches “%@”", query), detail: detail,
            isStarred: false, isCurrent: false, wall: nil, facts: [], level: nil)
    }
}

extension ModelDialRow {
    fileprivate func withSection(_ section: String) -> ModelDialRow {
        ModelDialRow(
            kind: kind, section: section, title: title, detail: detail, isStarred: isStarred,
            isCurrent: isCurrent, wall: wall, facts: facts, level: level)
    }
}

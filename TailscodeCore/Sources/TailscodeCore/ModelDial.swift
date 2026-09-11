import CodingAgentKit
import Foundation

/// One rung of the effort ladder: a level the model takes, what it means, and how hot it is.
///
/// `level` is nil for the rung that sends no level at all — the server deciding — which is drawn
/// hollow rather than left out, because an empty meter is a real answer and a control with no
/// way to say "you choose" makes every chat carry a level somebody once picked.
public struct EffortRung: Sendable, Hashable, Identifiable {
    public let level: String?
    public let title: String
    public let caption: String
    /// The digit that picks this rung from the keyboard: 0 for the server, 1 upward from the
    /// coldest level, so the number reads as the heat.
    public let key: Int
    /// Bars lit out of `EffortMeter.bars`. A power lights every bar.
    public let heat: Int
    public let isPower: Bool

    public var id: String { level ?? "·server" }
    public var isServer: Bool { level == nil }

    public init(level: String?, title: String, caption: String, key: Int, heat: Int, isPower: Bool) {
        self.level = level
        self.title = title
        self.caption = caption
        self.key = key
        self.heat = heat
        self.isPower = isPower
    }
}

/// The meter every effort surface draws: the same five bars on the pill, the ladder and the
/// catalog's rows, so "high" looks the same wherever it is read.
public enum EffortMeter {
    public static let bars = 5
}

/// What the composer's one dial says about the next send: the model, the level, and the heat.
///
/// `effortWord` is nil where the model takes no level, and then no meter is drawn either — the
/// pill is the model alone, as it was before there was a dial. `isServer` is the hollow meter:
/// no level will be sent and the machine decides, which is drawn as five cold bars rather than
/// as a blank.
public struct DialFace: Sendable, Equatable {
    public let modelWord: String
    public let effortWord: String?
    public let heat: Int
    public let isPower: Bool
    public let isServer: Bool
    public let spoken: String

    public init(
        modelWord: String, effortWord: String?, heat: Int, isPower: Bool, isServer: Bool,
        spoken: String
    ) {
        self.modelWord = modelWord
        self.effortWord = effortWord
        self.heat = heat
        self.isPower = isPower
        self.isServer = isServer
        self.spoken = spoken
    }

    public var showsMeter: Bool { effortWord != nil }
}

/// Model and effort are one decision — which machine, and how hard — so the desktop composer
/// carries one pill for both, and the arithmetic behind the pill, its wheel and its popover is
/// here so the Mac and Linux draw the same ladder in the same order with the same words.
///
/// The ladder is ordered by heat rather than by the catalog: a server lists its levels in
/// whatever order it was written, and a ladder a person steps through with a wheel has to run
/// cold to hot every time. Known tiers take their place from `rank`; a level this table has not
/// met keeps the catalog's order after them; ultracode is a power rather than a level and sits
/// above everything, lighting every bar.
public enum ModelDial {
    /// Cold to hot. Synonyms share a rung: minimal and none are low's slate, thinking is medium's.
    public static func rank(_ level: String) -> Int? {
        switch level.lowercased() {
        case "minimal", "none", "low": return 1
        case "medium", "thinking": return 2
        case "high": return 3
        case "xhigh": return 4
        case "max": return 5
        default: return nil
        }
    }

    public static func isPower(_ level: String?) -> Bool {
        level?.lowercased() == Ultracode.effortLevel
    }

    /// The levels a model takes, cold to hot, the power last. This is the order a wheel or an
    /// arrow steps through, with the server's own choice below the coldest level.
    public static func ascending(options: [String]) -> [String] {
        let levels = options.enumerated().filter { !isPower($0.element) }
        let known = levels.filter { rank($0.element) != nil }
            .sorted { (rank($0.element) ?? 0, $0.offset) < (rank($1.element) ?? 0, $1.offset) }
        let unknown = levels.filter { rank($0.element) == nil }
        var ordered = (known + unknown).map(\.element)
        if options.contains(where: isPower) { ordered.append(Ultracode.effortLevel) }
        return ordered
    }

    /// Every stop the dial can rest on, the server first: what `step` walks.
    public static func stops(options: [String]) -> [String?] {
        [nil] + ascending(options: options).map { Optional($0) }
    }

    /// One notch of the wheel or one arrow. Pinned at both ends rather than wrapped — a wheel
    /// that flips from max back to the server's choice is a wheel that cannot be trusted at
    /// speed. A level the model does not take steps from the server's own stop.
    public static func step(_ level: String?, by delta: Int, options: [String]) -> String? {
        let stops = stops(options: options)
        guard stops.count > 1 else { return nil }
        let current = stops.firstIndex { $0 == level } ?? 0
        let next = max(0, min(stops.count - 1, current + delta))
        return stops[next]
    }

    /// Bars lit for a level, out of `EffortMeter.bars`. A known tier lights its rank so "high"
    /// is three bars on every model; a level the table has not met is placed by where it sits
    /// among the model's own levels; the power lights every bar; the server lights none.
    public static func heat(_ level: String?, options: [String]) -> Int {
        guard let level else { return 0 }
        if isPower(level) { return EffortMeter.bars }
        if let known = rank(level) { return min(EffortMeter.bars, known) }
        let ordered = ascending(options: options).filter { !isPower($0) }
        guard let index = ordered.firstIndex(of: level), !ordered.isEmpty else { return 1 }
        let position = Double(index + 1) / Double(ordered.count)
        return max(1, Int((position * Double(EffortMeter.bars)).rounded()))
    }

    /// What a level means, in a sentence short enough to sit under its word. The power keeps
    /// its own subtitle. A level the table has not met says nothing rather than something made up.
    public static func caption(_ level: String?) -> String {
        guard let level else { return Localized.text("no level sent") }
        if isPower(level) { return Ultracode.menuSubtitle }
        switch level.lowercased() {
        case "minimal", "none": return Localized.text("no thinking at all")
        case "low": return Localized.text("answers, not thinking")
        case "medium", "thinking": return Localized.text("everyday edits and reads")
        case "high": return Localized.text("thinks it through")
        case "xhigh": return Localized.text("hard problems, slower")
        case "max": return Localized.text("as long as it takes")
        default: return ""
        }
    }

    /// The ladder, top down: the power first, then the levels hottest first, the server last —
    /// the order a person reads heat in, which is the reverse of the order they step it in.
    public static func rungs(options: [String]) -> [EffortRung] {
        let ordered = ascending(options: options)
        var rungs: [EffortRung] = []
        for (index, level) in ordered.enumerated().reversed() {
            rungs.append(
                EffortRung(
                    level: level, title: isPower(level) ? Ultracode.menuTitle.lowercased() : level,
                    caption: caption(level), key: index + 1,
                    heat: heat(level, options: options), isPower: isPower(level)))
        }
        rungs.append(
            EffortRung(
                level: nil, title: Localized.text("server decides"), caption: caption(nil),
                key: 0, heat: 0, isPower: false))
        return rungs
    }

    /// The rung a digit picks, or nil for a digit past the ladder.
    public static func rung(forKey key: Int, options: [String]) -> EffortRung? {
        rungs(options: options).first { $0.key == key }
    }

    /// The line over the ladder: which model this is the ladder of, and how many levels it takes,
    /// so a level that is not on offer is visibly not on offer rather than missing.
    public static func headline(modelName: String, options: [String]) -> String {
        let count = ascending(options: options).count
        guard count > 0 else { return Localized.text("%@ takes no effort level", modelName) }
        return Localized.text("%@ takes %@", modelName, spelled(count))
    }

    private static func spelled(_ count: Int) -> String {
        let words = [
            Localized.text("one level"), Localized.text("two levels"),
            Localized.text("three levels"), Localized.text("four levels"),
            Localized.text("five levels"), Localized.text("six levels"),
            Localized.text("seven levels"), Localized.text("eight levels"),
            Localized.text("nine levels"),
        ]
        guard count >= 1, count <= words.count else { return Localized.text("%d levels", count) }
        return words[count - 1]
    }

    /// The pill, from what the composer already knows: the model's word and the level a send
    /// would carry, resolved against what the model takes. `effort` nil with levels on offer is
    /// the server deciding; no levels at all is no meter and no word.
    public static func face(modelWord: String, effort: String?, options: [String]) -> DialFace {
        guard ModelEffort.isOffered(options: options) else {
            return DialFace(
                modelWord: modelWord, effortWord: nil, heat: 0, isPower: false, isServer: false,
                spoken: Localized.text("%@, no effort level", modelWord))
        }
        let level = ModelEffort.surviving(effort, options: options)
        let word = level.map { isPower($0) ? Ultracode.menuTitle.lowercased() : $0 }
        let spoken =
            level.map { Localized.text("%@ at %@ effort", modelWord, $0) }
            ?? Localized.text("%@, effort left to the server", modelWord)
        return DialFace(
            modelWord: modelWord, effortWord: word ?? Localized.text("server"),
            heat: heat(level, options: options), isPower: isPower(level), isServer: level == nil,
            spoken: spoken)
    }

    /// The footer under the popover: every key it answers, in the order a hand finds them.
    public static var hint: String {
        Localized.text("↑↓ model · ←→ 0–9 effort · ⌃S star · ⏎ keep · ⌃⏎ all models · esc")
    }

    /// What the wheel over the closed pill says it did, for a toast or a tooltip.
    public static func stepped(to level: String?) -> String {
        guard let level else { return Localized.text("effort: server decides") }
        return Localized.text("effort: %@", isPower(level) ? Ultracode.menuTitle.lowercased() : level)
    }
}

/// One row of the dial's model column.
public struct ModelDialRow: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case serverDefault
        case candidate(ModelCandidate)
        case allModels
    }

    public let kind: Kind
    /// The heading this row sits under, on the first row of its section only.
    public let section: String?
    public let title: String
    public let detail: String
    public let isStarred: Bool
    public let isCurrent: Bool
    public let wall: QuotaExhaustion?
    public let facts: [ModelFact]

    public var id: String {
        switch kind {
        case .serverDefault: return "·server"
        case .candidate(let candidate): return candidate.id
        case .allModels: return "·all"
        }
    }

    public var candidate: ModelCandidate? {
        if case .candidate(let candidate) = kind { return candidate }
        return nil
    }

    /// What picking this row hands the composer. Nil for the row that opens the catalog.
    public var pick: ModelPick? {
        switch kind {
        case .serverDefault:
            return ModelPick(profileID: "", selection: nil, isElsewhere: false, serverName: "")
        case .candidate(let candidate):
            return ModelPick(
                profileID: candidate.profileID, selection: candidate.selection,
                isElsewhere: candidate.isElsewhere, serverName: candidate.serverName,
                modelName: candidate.name)
        case .allModels:
            return nil
        }
    }

    public var opensCatalog: Bool { kind == .allModels }
}

public enum ModelDialCommand: Sendable, Equatable {
    case up, down, top, bottom
    case hotter, colder
    case digit(Int)
    case activate
    case dismiss
    case star
    case openAll
}

/// What a command did, for the client to draw. Effort changes are live — the composer carries
/// the new level the moment it is stepped — while a model is committed by Enter or a click, so
/// walking the list with the arrows changes nothing until a row is taken.
public enum ModelDialOutcome: Sendable, Equatable {
    case unhandled
    case moved
    case effort(String?)
    case pick(ModelPick)
    case openCatalog
    case starred(ModelSelection)
    case dismiss
}

/// The popover's whole state: the model column with its cursor and query, the ladder with the
/// level it currently sends, and the keys. The client draws it and forwards presses.
public struct ModelDialState: Sendable {
    public private(set) var rows: [ModelDialRow]
    public private(set) var cursor: Int
    public private(set) var query: String
    public private(set) var rungs: [EffortRung]
    public private(set) var effort: String?
    public let headline: String
    public let catalogSummary: String
    /// How many models the catalog holds beyond what the column shows, for the row that opens it.
    public let catalogCount: Int

    private let sources: [ModelSource]
    private let selected: ModelSelection?
    private let quotas: [UsageQuota]
    private let options: [String]
    private let recents: [ModelSelection]
    private var starred: Set<String>

    public init(
        sources: [ModelSource], selected: ModelSelection?, effort: String?, options: [String],
        modelWord: String, quotas: [UsageQuota] = [],
        recents: [ModelSelection] = RecentModelsStore.all(),
        favorites: [ModelSelection] = ModelFavoritesStore.all()
    ) {
        self.sources = sources
        self.selected = selected
        self.quotas = quotas
        self.options = options
        self.recents = recents
        self.starred = Set(favorites.map(\.rawValue))
        self.effort = ModelEffort.surviving(effort, options: options)
        self.rungs = ModelDial.rungs(options: options)
        self.headline = ModelDial.headline(modelName: modelWord, options: options)
        let chooser = ModelChooser(
            sources: sources, selected: selected, recents: recents, quotas: quotas)
        self.catalogSummary = chooser.summary
        self.catalogCount = sources.reduce(0) { $0 + $1.models.count }
        self.query = ""
        self.rows = []
        self.cursor = 0
        rebuild()
        cursor = rows.firstIndex { $0.isCurrent } ?? 0
    }

    public var focused: ModelDialRow? {
        rows.indices.contains(cursor) ? rows[cursor] : nil
    }

    /// The rung the composer will send with, for the client to light.
    public var currentRung: EffortRung? { rungs.first { $0.level == effort } }

    /// Digits pick rungs only while the search field is empty: a model's name has digits in it,
    /// and a person typing "gpt-5" is naming a model, not asking for five bars.
    public var digitsPickEffort: Bool { query.isEmpty }

    public mutating func search(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        rebuild()
        cursor = rows.firstIndex { $0.candidate != nil } ?? 0
    }

    public mutating func setEffort(_ level: String?) {
        effort = ModelEffort.surviving(level, options: options)
    }

    public mutating func move(to index: Int) {
        guard rows.indices.contains(index) else { return }
        cursor = index
    }

    public mutating func handle(_ command: ModelDialCommand) -> ModelDialOutcome {
        switch command {
        case .up:
            guard !rows.isEmpty else { return .unhandled }
            cursor = max(0, cursor - 1)
            return .moved
        case .down:
            guard !rows.isEmpty else { return .unhandled }
            cursor = min(rows.count - 1, cursor + 1)
            return .moved
        case .top:
            cursor = 0
            return .moved
        case .bottom:
            cursor = max(0, rows.count - 1)
            return .moved
        case .hotter:
            guard !options.isEmpty else { return .unhandled }
            effort = ModelDial.step(effort, by: 1, options: options)
            return .effort(effort)
        case .colder:
            guard !options.isEmpty else { return .unhandled }
            effort = ModelDial.step(effort, by: -1, options: options)
            return .effort(effort)
        case .digit(let key):
            guard digitsPickEffort, let rung = ModelDial.rung(forKey: key, options: options) else {
                return .unhandled
            }
            effort = rung.level
            return .effort(effort)
        case .activate:
            guard let row = focused else { return .dismiss }
            if row.opensCatalog { return .openCatalog }
            guard let pick = row.pick else { return .dismiss }
            return .pick(pick)
        case .dismiss:
            return .dismiss
        case .star:
            guard let candidate = focused?.candidate else { return .unhandled }
            let key = candidate.selection.rawValue
            if starred.contains(key) { starred.remove(key) } else { starred.insert(key) }
            rebuild()
            return .starred(candidate.selection)
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
        if chord.keyval == Keymap.up { return chord.control ? .top : .up }
        if chord.keyval == Keymap.down { return chord.control ? .bottom : .down }
        if chord.keyval == 0xFF51, digitsLive || chord.control { return .colder }
        if chord.keyval == 0xFF53, digitsLive || chord.control { return .hotter }
        if chord.control, Keymap.scalar(chord.keyval) == "s" { return .star }
        if chord.control, Keymap.scalar(chord.keyval) == "n" { return .down }
        if chord.control, Keymap.scalar(chord.keyval) == "p" { return .up }
        if digitsLive, !chord.control, !chord.alt, let digit = Keymap.digit(chord.keyval) {
            return .digit(digit)
        }
        return nil
    }

    /// The column: this chat's model, then what the person reaches for, then the other machines
    /// under their own names — a pick there opens a chat there, said once on the row rather than
    /// once per row's chips — then the server's own choice and the door to the catalog. A query
    /// answers from the whole fleet through the chooser's own search, so a model nobody starred is
    /// still one typed name away without leaving the composer.
    private mutating func rebuild() {
        var built: [ModelDialRow] = []
        if query.isEmpty {
            let shortlist = ModelChooser.shortlist(
                sources: sources, selected: selected, limit: 9, recents: recents,
                favorites: starred.compactMap(ModelSelection.init(string:)))
            let here = shortlist.filter { !$0.isElsewhere }
            let elsewhere = shortlist.filter(\.isElsewhere)
            built += rowsFor(here, section: Localized.text("Yours"))
            for (profileID, group) in Dictionary(grouping: elsewhere, by: \.profileID)
                .sorted(by: { $0.key < $1.key })
            {
                let title = sources.first { $0.profileID == profileID }?.title
                    ?? group.first?.serverName ?? ""
                built += rowsFor(group, section: Localized.text("Also on %@", title))
            }
        } else {
            var chooser = ModelChooser(
                sources: sources, selected: selected, recents: recents, quotas: quotas)
            chooser.search(query)
            let found = chooser.rows.compactMap { row -> ModelCandidate? in
                if case .candidate(let candidate) = row.kind { return candidate }
                return nil
            }
            var seen: Set<String> = []
            let unique = found.filter { seen.insert($0.id).inserted }.prefix(9)
            built += rowsFor(Array(unique), section: Localized.text("Found"), namesMachine: true)
        }
        if selected != nil || query.isEmpty {
            built.append(
                ModelDialRow(
                    kind: .serverDefault, section: nil, title: Localized.text("Server default"),
                    detail: Localized.text("the machine decides"), isStarred: false,
                    isCurrent: selected == nil, wall: nil, facts: []))
        }
        built.append(
            ModelDialRow(
                kind: .allModels, section: nil, title: Localized.text("All models…"),
                detail: catalogSummary, isStarred: false, isCurrent: false, wall: nil, facts: []))
        rows = built
        cursor = max(0, min(cursor, rows.count - 1))
    }

    /// `namesMachine` is for a list that mixes machines — a search — where a row from another
    /// server has no heading to say so and must say it itself; a search row keeps only the
    /// local mark, because a name typed is a name looked for and the catalog carries the rest.
    private func rowsFor(
        _ candidates: [ModelCandidate], section: String, namesMachine: Bool = false
    ) -> [ModelDialRow] {
        let policy = ModelFactPolicy.over(candidates)
        return candidates.enumerated().map { index, candidate in
            let providers = candidate.providerNames.joined(separator: " · ")
            let machine = sources.first { $0.profileID == candidate.profileID }?.title
                ?? candidate.serverName
            let detail =
                candidate.isElsewhere
                ? (namesMachine ? Localized.text("new chat on %@", machine) : Localized.text("new chat there"))
                : providers
            return ModelDialRow(
                kind: .candidate(candidate), section: index == 0 ? section : nil,
                title: candidate.name, detail: detail,
                isStarred: starred.contains(candidate.selection.rawValue),
                isCurrent: !candidate.isElsewhere && candidate.carries(selected),
                wall: ModelChooser.wall(for: candidate, quotas: quotas),
                facts: ModelFact.of(candidate, policy: policy)
                    .filter { !namesMachine || $0 == .local })
        }
    }
}

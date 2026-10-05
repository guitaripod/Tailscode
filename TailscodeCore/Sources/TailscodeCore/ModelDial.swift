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
    /// True for a level below low — minimal, none — whose one bar is an ember rather than a
    /// flame: lit, but dimly, so the floor under low still has a face of its own.
    public let isEmber: Bool

    public var id: String { level ?? "·server" }
    /// The stop where the machine decides, drawn hollow: the rung that sends nothing, and a word
    /// such as auto that asks the model to choose for itself.
    public var isServer: Bool { level.map(EffortVocabulary.isAutomatic) ?? true }

    public init(
        level: String?, title: String, caption: String, key: Int, heat: Int, isPower: Bool,
        isEmber: Bool = false
    ) {
        self.level = level
        self.title = title
        self.caption = caption
        self.key = key
        self.heat = heat
        self.isPower = isPower
        self.isEmber = isEmber
    }
}

/// The meter every effort surface draws: the same five bars on the pill, the ladder and the
/// catalog's rows, so "high" looks the same wherever it is read.
public enum EffortMeter {
    public static let bars = 5
}

/// The words servers use for how hard a model thinks, read onto one scale.
///
/// Claude's low to max, OpenAI's none to xhigh, a local llama-server's think and nothink, Gemini's
/// low and high are different spellings of one question, so each word this table knows sits on a
/// tier from 0 — no thinking, or the least there is — to 5, as long as it takes. A word that asks
/// the model to decide for itself is no tier at all and sits with the server's own stop; the power
/// sits above every tier. A word nobody wrote down here is not guessed at: the dial places it by
/// where the model lists it. Every comparison goes through `key`, so a server that capitalises a
/// word is still saying that word, and every answer is the model's own spelling, because that is
/// what goes out on the wire.
public enum EffortVocabulary {
    public enum Role: Sendable, Equatable {
        case off
        case floor
        case level
        case automatic
        case power
    }

    public struct Entry: Sendable, Equatable {
        public let tier: Int?
        public let role: Role
    }

    private static let table: [String: Entry] = {
        var table: [String: Entry] = [:]
        func add(_ words: [String], _ tier: Int?, _ role: Role) {
            for word in words { table[word] = Entry(tier: tier, role: role) }
        }
        add(["none", "off", "nothink", "no-think", "disabled"], 0, .off)
        add(["minimal"], 0, .floor)
        add(["low", "fast", "instant", "quick"], 1, .level)
        add(["medium", "standard", "balanced", "normal", "think", "thinking", "on", "enabled"], 2, .level)
        add(["high", "deep", "thorough"], 3, .level)
        add(["xhigh", "extra-high"], 4, .level)
        add(["max", "maximum", "deepest"], 5, .level)
        add(["auto", "default"], nil, .automatic)
        add([Ultracode.effortLevel], nil, .power)
        return table
    }()

    /// The one spelling every comparison uses.
    public static func key(_ level: String) -> String {
        level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func entry(_ level: String) -> Entry? { table[key(level)] }

    /// The tier a word sits on, 0 to 5. Nil for the model deciding, the power, and a word the
    /// table has not met.
    public static func tier(_ level: String) -> Int? { entry(level)?.tier }

    public static func isAutomatic(_ level: String) -> Bool { entry(level)?.role == .automatic }

    public static func isOff(_ level: String) -> Bool { entry(level)?.role == .off }

    /// Whether two spellings name the same level.
    public static func same(_ one: String?, _ other: String?) -> Bool {
        switch (one, other) {
        case (nil, nil): return true
        case (let one?, let other?): return key(one) == key(other)
        default: return false
        }
    }

    /// The model's own spelling of a level it takes, or nil where it takes no such word.
    public static func spelling(of level: String?, in options: [String]) -> String? {
        guard let level else { return nil }
        let wanted = key(level)
        guard !wanted.isEmpty else { return nil }
        return options.first { key($0) == wanted }
    }

    /// How far up the scale a word reaches, for a carry that may never land hotter: off is the
    /// very bottom, the floor sits just above it, the tiers follow, and the power is above them
    /// all. Nil for the model deciding and for a word the table has not met.
    static func reach(_ level: String) -> Double? {
        guard let entry = entry(level) else { return nil }
        switch entry.role {
        case .off: return 0
        case .floor: return 0.5
        case .level: return entry.tier.map(Double.init)
        case .automatic: return nil
        case .power: return Double(EffortMeter.bars + 1)
        }
    }

    /// A word that reads as a number — a thinking budget in tokens.
    static func number(_ level: String) -> Double? {
        Double(key(level)).flatMap { $0.isFinite ? $0 : nil }
    }
}

/// What the composer's one dial says about the next send: the model, the level, and the heat.
///
/// `effortWord` is nil where the model takes no level, and then no meter is drawn either — the
/// pill is the model alone, as it was before there was a dial. `isServer` is the hollow meter:
/// the machine decides — no level will be sent, or the level is a word such as auto that asks the
/// model to choose — which is drawn as five cold bars rather than as a blank.
public struct DialFace: Sendable, Equatable {
    public let modelWord: String
    public let effortWord: String?
    public let heat: Int
    public let isPower: Bool
    public let isServer: Bool
    public let spoken: String
    /// The level sits below low: its one bar is drawn as an ember, dim rather than lit.
    public let isEmber: Bool
    /// Every word the effort slot may show for this model, so a client can size the slot once to
    /// the widest of them: a pill that grows and shrinks as the wheel turns is a pill that jumps
    /// under the pointer, and the words to the right of it with it.
    public let slotWords: [String]

    public init(
        modelWord: String, effortWord: String?, heat: Int, isPower: Bool, isServer: Bool,
        spoken: String, slotWords: [String] = [], isEmber: Bool = false
    ) {
        self.modelWord = modelWord
        self.effortWord = effortWord
        self.heat = heat
        self.isPower = isPower
        self.isServer = isServer
        self.spoken = spoken
        self.slotWords = slotWords
        self.isEmber = isEmber
    }

    /// The widest word the slot may hold, in characters — what a monospace client sizes with.
    public var slotWidth: Int { slotWords.map(\.count).max() ?? 0 }

    public var showsMeter: Bool { effortWord != nil }
}

/// Model and effort are one decision — which machine, and how hard — so the desktop composer
/// carries one pill for both, and the arithmetic behind the pill, its wheel and its popover is
/// here so the Mac and Linux draw the same ladder in the same order with the same words.
///
/// The ladder is ordered by heat rather than by the catalog: a server lists its levels in
/// whatever order it was written, and a ladder a person steps through with a wheel has to run
/// cold to hot every time. Known tiers take their place from `rank` (`EffortVocabulary`); a word
/// asking the model to decide sits first, beside the server's own stop; a level the table has not
/// met keeps the catalog's order after the known ones, or numeric order where every such word is a
/// number; ultracode is a power rather than a level and sits above everything, lighting every bar.
public enum ModelDial {
    /// Cold to hot, 0 to 5, through `EffortVocabulary`: none, off, nothink and minimal sit under
    /// low at rank zero — a level of their own, not a synonym for low — think and thinking are
    /// medium's. Nil for the model deciding, the power, and a word the table has not met.
    public static func rank(_ level: String) -> Int? {
        EffortVocabulary.tier(level)
    }

    public static func isPower(_ level: String?) -> Bool {
        level.map { EffortVocabulary.entry($0)?.role == .power } ?? false
    }

    /// The levels a model takes, cold to hot, the power last, each in the model's own spelling and
    /// each once. This is the order a wheel or an arrow steps through, with the server's own
    /// choice below the coldest level.
    public static func ascending(options: [String]) -> [String] {
        var seen: Set<String> = []
        let levels = options.filter {
            let key = EffortVocabulary.key($0)
            return !key.isEmpty && seen.insert(key).inserted
        }
        let automatic = levels.filter(EffortVocabulary.isAutomatic)
        let known = levels.enumerated()
            .compactMap { entry in rank(entry.element).map { (rank: $0, offset: entry.offset, level: entry.element) } }
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .map(\.level)
        let unknown = levels.filter {
            rank($0) == nil && !isPower($0) && !EffortVocabulary.isAutomatic($0)
        }
        let power = levels.filter(isPower)
        return automatic + known + inServerOrderOrByNumber(unknown) + power
    }

    /// Words the table has not met keep the order the server wrote them in — never an alphabet,
    /// which puts 100000 before 20000 — unless every one of them is a number, a budget in tokens,
    /// which is then read as one.
    private static func inServerOrderOrByNumber(_ levels: [String]) -> [String] {
        let numbers = levels.compactMap(EffortVocabulary.number)
        guard !levels.isEmpty, numbers.count == levels.count else { return levels }
        return zip(levels, numbers).enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
            .map(\.element.0)
    }

    /// One notch of the wheel or one arrow, along the model's own levels only. Pinned at both
    /// ends rather than wrapped — a wheel that flips from max back to low is a wheel that cannot
    /// be trusted at speed — and the coldest level is the floor: the server deciding is a stop the
    /// ladder offers by its own rung and its own digit, never one a wheel falls through to, since
    /// a hand scrolling down means "as little as it takes" and not "you choose". A word asking the
    /// model to decide is that same kind of stop. From either a step up lands on the coldest level
    /// and a step down stays put; a level the model does not take steps from the server's stop.
    public static func step(_ level: String?, by delta: Int, options: [String]) -> String? {
        let all = ascending(options: options)
        let levels = all.filter { !EffortVocabulary.isAutomatic($0) }
        let here = ModelEffort.surviving(level, options: options)
        guard !levels.isEmpty else { return here ?? (delta > 0 ? all.first : nil) }
        guard let here, let current = levels.firstIndex(where: { EffortVocabulary.same($0, here) })
        else {
            return delta > 0 ? levels[0] : here
        }
        let next = max(0, min(levels.count - 1, current + delta))
        return levels[next]
    }

    /// Bars lit for a level, out of `EffortMeter.bars`. A known tier lights its rank so "high"
    /// is three bars on every model; the levels under low light one bar as an ember (`isEmber`);
    /// a level the table has not met is placed by where it sits among the model's own levels and
    /// never cooler than a known level under it; the power lights every bar; the server, and a
    /// word asking the model to decide, light none.
    public static func heat(_ level: String?, options: [String]) -> Int {
        guard let level else { return 0 }
        if isPower(level) { return EffortMeter.bars }
        if EffortVocabulary.isAutomatic(level) { return 0 }
        if let known = rank(level) { return max(1, min(EffortMeter.bars, known)) }
        return placements(options: options)[EffortVocabulary.key(level)] ?? 1
    }

    /// The bars each of a model's levels lights, keyed by `EffortVocabulary.key`, for every level
    /// that is neither the power nor the model deciding. Running up the ladder the bars never
    /// fall: a word the table has not met is spread over the meter by its place in the ladder —
    /// one such word alone sits in the middle, claiming nothing — and lifted to the known level
    /// below it where its place would read cooler.
    static func placements(options: [String]) -> [String: Int] {
        let ladder = ascending(options: options).filter {
            !isPower($0) && !EffortVocabulary.isAutomatic($0)
        }
        var placed: [String: Int] = [:]
        var floor = 1
        for (index, level) in ladder.enumerated() {
            let bars: Int
            if let known = rank(level) {
                bars = max(1, min(EffortMeter.bars, known))
            } else {
                let position = ladder.count == 1 ? 0.5 : Double(index) / Double(ladder.count - 1)
                let spread = 1 + Int((position * Double(EffortMeter.bars - 1)).rounded())
                bars = max(floor, min(EffortMeter.bars, spread))
            }
            floor = max(floor, bars)
            placed[EffortVocabulary.key(level)] = bars
        }
        return placed
    }

    /// Whether a level's one bar is an ember: below low, lit but dim.
    public static func isEmber(_ level: String?) -> Bool {
        guard let level else { return false }
        return rank(level) == 0
    }

    /// What a level means, in a sentence short enough to sit under its word. A synonym says what
    /// its tier says, a word asking the model to decide says the machine decides, and the power
    /// keeps its own subtitle. A level the table has not met says nothing rather than something
    /// made up.
    public static func caption(_ level: String?) -> String {
        guard let level else { return Localized.text("no level sent") }
        guard let entry = EffortVocabulary.entry(level) else { return "" }
        switch entry.role {
        case .power: return Ultracode.menuSubtitle
        case .automatic: return Localized.text("the machine decides")
        case .off: return Localized.text("no thinking at all")
        case .floor: return Localized.text("the least it can think")
        case .level: break
        }
        switch entry.tier {
        case 1: return Localized.text("answers, not thinking")
        case 2: return Localized.text("everyday edits and reads")
        case 3: return Localized.text("thinks it through")
        case 4: return Localized.text("hard problems, slower")
        case 5: return Localized.text("as long as it takes")
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
                    heat: heat(level, options: options), isPower: isPower(level),
                    isEmber: isEmber(level)))
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
            heat: heat(level, options: options), isPower: isPower(level),
            isServer: level.map(EffortVocabulary.isAutomatic) ?? true,
            spoken: spoken, slotWords: slotWords(options: options), isEmber: isEmber(level))
    }

    /// Every word the pill's effort slot can show for these levels, the server's included.
    public static func slotWords(options: [String]) -> [String] {
        ascending(options: options).map { isPower($0) ? Ultracode.menuTitle.lowercased() : $0 }
            + [Localized.text("server")]
    }

    /// The footer under the popover: every key it answers, in the order a hand finds them.
    public static var hint: String {
        Localized.text("↑↓ model · ←→ 0–9 effort · ⇥ column · ⌃S pin the pair · ⏎ use · ⌃⏎ all models · esc")
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
        case preset(ModelPreset, ModelCandidate)
        case allModels
        case noResults
    }

    /// The level a pinned pair carries, drawn on its row as the same meter the pill wears. Nil on a
    /// row that is a model alone.
    public struct Level: Sendable, Hashable {
        public let word: String
        public let heat: Int
        public let isPower: Bool
        public let isServer: Bool
        public let isEmber: Bool
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
    public let level: Level?

    public var id: String {
        switch kind {
        case .serverDefault: return "·server"
        case .candidate(let candidate): return candidate.id
        case .preset(let preset, let candidate): return "·preset·" + candidate.id + "·" + preset.effort.raw
        case .allModels: return "·all"
        case .noResults: return "·none"
        }
    }

    public var candidate: ModelCandidate? {
        switch kind {
        case .candidate(let candidate), .preset(_, let candidate): return candidate
        default: return nil
        }
    }

    public var preset: ModelPreset? {
        if case .preset(let preset, _) = kind { return preset }
        return nil
    }

    /// What picking this row hands the composer. Nil for the row that opens the catalog.
    public var pick: ModelPick? {
        switch kind {
        case .serverDefault:
            return ModelPick(profileID: "", selection: nil, isElsewhere: false, serverName: "")
        case .candidate(let candidate), .preset(_, let candidate):
            return ModelPick(
                profileID: candidate.profileID, selection: candidate.selection,
                isElsewhere: candidate.isElsewhere, serverName: candidate.serverName,
                modelName: candidate.name)
        case .allModels, .noResults:
            return nil
        }
    }

    public var opensCatalog: Bool { kind == .allModels }
    public var isMessage: Bool { kind == .noResults }
}

public enum ModelDialCommand: Sendable, Equatable {
    case up, down, top, bottom
    case hotter, colder
    case digit(Int)
    case activate
    case dismiss
    case pin
    case openAll
    case switchColumn
}

/// What a pick does to the level, so a client applies the pair the person saw rather than the
/// model alone. `unchanged` is the cursor on the model this chat already runs, where the level is
/// live and already applied; `set` is a pair — a preset, a model with its carried level, or a level
/// stepped on the ladder before the row was taken — and nil in it is the server deciding.
public enum EffortAsk: Sendable, Equatable {
    case unchanged
    case set(String?)
}

/// What a command did, for the client to draw. Effort changes on the model this chat runs are live
/// — the composer carries the new level the moment it is stepped — while a model is committed by
/// Enter or a click together with the level the ladder showed for it, so walking the list with the
/// arrows changes nothing until a row is taken.
public enum ModelDialOutcome: Sendable, Equatable {
    case unhandled
    case moved
    case effort(String?)
    case previewed(String?)
    case pick(ModelPick, effort: EffortAsk)
    case openCatalog
    case pinned(ModelPreset)
    case dismiss
}

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

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

    /// What the wheel over the closed pill says it did, for a screen reader.
    public static func stepped(to level: String?) -> String {
        guard let level else { return Localized.text("effort: server decides") }
        return Localized.text("effort: %@", isPower(level) ? Ultracode.menuTitle.lowercased() : level)
    }

    /// One step of the wheel or one chord, read: where the level landed and whether it moved. A
    /// step that cannot go further is a fact worth saying — to a hand that cannot see the pill the
    /// wheel would otherwise turn mute at the end of the ladder.
    public static func notch(from level: String?, by delta: Int, options: [String]) -> EffortNotch {
        let here = ModelEffort.surviving(level, options: options)
        let next = step(level, by: delta, options: options)
        return EffortNotch(level: next, moved: next != here, direction: delta >= 0 ? 1 : -1)
    }
}

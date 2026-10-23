import CodingAgentKit
import Foundation
import Synchronization

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
    public static let recentLimit = 8
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
    let recents: [ModelSelection]
    var favorites: [ModelSelection]
    var favoriteKeys: Set<String>
    /// Whether a row has to name who runs it. One provider behind the whole catalog is a fact
    /// about the server, said once at the top, not a word repeated under two hundred names.
    let showsProviders: Bool
    /// One wall per candidate that has one, worked out once: a used-up window does not change
    /// while a list is open, and a search that re-ranks two hundred rows per keystroke must not
    /// re-read every gauge to draw them.
    let walls: [String: QuotaExhaustion]
    /// The explicit pairs pinned on this device, for the stars and, when shown, the Pinned section.
    var pins: [ModelPreset]
    /// Whether the pinned pairs are listed as rows of their own, ahead of Yours.
    private let showsPairs: Bool
    /// The level the chooser was opened with, which every row reads its own level from.
    public private(set) var aim: ChooserAim?

    /// Past this many hosted models a family heading opens rather than scrolls, and the list
    /// arrives shut except for what you are on and what you reach for. Under it, a closed heading
    /// would be a press standing between a person and a list they could already see whole.
    public static let foldFrom = 24

    public private(set) var query = ""
    /// The machine whose catalog is showing, by profile id.
    public private(set) var machine = ""
    /// The door the list is narrowed to, by provider id; `nil` is every door the machine has.
    public private(set) var door: String?
    public internal(set) var cursor = 0
    public private(set) var expanded: Set<String> = []
    public private(set) var collapsed: Set<String> = []
    public private(set) var sections: [ModelChooserSection] = []
    public private(set) var rows: [ModelChooserRow] = []
    /// How many models on this machine answered the query, for the header's count.
    var matched = 0
    /// How many answered it on other machines, listed under their own heading.
    var elsewhereMatched = 0
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
        favorites: [ModelSelection] = ModelFavoritesStore.all(), quotas: [UsageQuota] = [],
        showsPairs: Bool = false, pins: [ModelPreset] = ModelPresetStore.explicit(),
        aim: ChooserAim? = nil
    ) {
        self.pins = pins.filter { $0.effort != .keep }
        self.showsPairs = showsPairs
        self.aim = aim
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
    var current: ModelSource? { sources.first { $0.isCurrent } }

    /// The server whose tab is showing.
    var shown: ModelSource? { sources.first { $0.profileID == machine } }

    /// The tab that is showing, whole.
    public var shownMachine: ModelMachine? { machines.first { $0.profileID == machine } }

    /// Where the strip's highlight sits.
    public var machineIndex: Int { machines.firstIndex { $0.profileID == machine } ?? 0 }

    /// Whether a strip is worth drawing at all.
    public var showsMachines: Bool { machines.count > 1 }

    /// Every model on the shown machine, whatever door it comes through.
    var wholeMachine: [ModelCandidate] { candidates.filter { $0.profileID == machine } }

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

    /// What the strip's every-door chip counts: the shown machine's models, each once. The doors'
    /// own counts add up to more — a model two doors both reach is in each — and a chip that read
    /// 20 over a tab that read 18 would be two numbers for one list.
    public var allDoorsCount: Int { wholeMachine.count }

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
        guard let row = rows.indices.contains(target) ? rows[target] : nil, row.pair == nil else {
            return false
        }
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

    mutating func rebuild() {
        var sections: [ModelChooserSection] = []
        var hiding = 0
        let mine = onShownMachine
        let matches = self.matches(in: mine)
        matched = matches.count
        if query.isEmpty {
            let paired = showsPairs ? pinnedSection(in: mine) : []
            let covered = Set(paired.flatMap(\.rows).compactMap { row -> String? in
                if case .candidate(let candidate) = row.kind { return candidate.id }
                return nil
            })
            let runningCovered = paired.flatMap(\.rows).contains(where: \.isSelected)
            sections += paired
            sections += yoursSection(in: mine, covered: covered, runningCovered: runningCovered)
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
        let keys = pinnedKeys
        let catalog = sources.flatMap(\.models)
        self.sections = sections.map { section in
            ModelChooserSection(
                id: section.id, title: section.title, detail: section.detail,
                rows: section.rows.map { decorated($0, pinned: keys, catalog: catalog) },
                canCollapse: section.canCollapse,
                isCollapsed: section.isCollapsed, count: section.count)
        }
        self.hidden = hiding
        rows = self.sections.flatMap(\.rows)
    }

    /// Tells the chooser the level it is aiming with, so every row reads the level a pick would
    /// run at; nil takes the readings away.
    public mutating func setAim(_ aim: ChooserAim?) {
        guard aim != self.aim else { return }
        self.aim = aim
        rebuild()
    }

    /// Whether any row showing can be opened onto its other doors, for a hint that names the
    /// chevron only when there is one.
    public var canExpandAny: Bool { rows.contains(where: \.canExpand) }

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
}

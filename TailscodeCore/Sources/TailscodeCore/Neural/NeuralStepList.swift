import Foundation

/// The index of everything the agent did in one turn, as rows a client draws and walks: one per
/// step, in order, with the filters the person set, the cursor, and whether the list follows a
/// running turn. It is the data behind the step list beside the head; `NeuralBrowse` is what keys
/// and pointer events do to it.
///
/// Rows are built once per change in the steps and never per frame. What a window draws is
/// `rows(in:)`, which costs the size of the window and not of the turn, and every row's `id` is
/// its step's own identity, so a row drawn for a step stays the same row as the turn grows.
public struct NeuralStepList: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case tool
        case thought
        case note

        /// What a note is called in the list: a message the agent said.
        public static let said = Kind.note
    }

    /// What a row says about how its step stands, on the right: nothing for a step that is done.
    public enum Mark: Sendable, Equatable {
        case none
        case failed
        /// A failure a later step cleared, with the step that did.
        case retried(stepID: String, number: Int)
        case waiting
        case running
        case stopped
    }

    /// Where a call stands among the calls its message made together.
    public enum Bracket: Sendable, Equatable {
        case none
        case first
        case middle
        case last
    }

    /// How a row's argument is shortened to fit: a path keeps its file name, anything else keeps
    /// its start.
    public enum ArgumentKind: Sendable, Equatable {
        case path
        case command
        case words
    }

    /// Another step a row points at.
    public struct Related: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// The later run that cleared this failure.
            case retry
            /// The failure this run retried.
            case retriedFrom
            case sameFile
            case sameCommand
        }

        public let kind: Kind
        public let stepID: String
        /// One-based.
        public let number: Int
        /// "retried at 11", "same file as 3".
        public let label: String
    }

    public struct Row: Identifiable, Sendable, Equatable {
        /// The step's own id, `"messageID:partID"`: stable as the turn grows.
        public let id: String
        public let index: Int
        /// One-based.
        public let number: Int
        public let kind: Kind
        public let zone: NeuralZone
        public let title: String
        /// The argument on one line, whole: the command, the path, the pattern, the first line of
        /// a thought. `argument(fittingChars:)` shortens it.
        public let argument: String
        public let argumentKind: ArgumentKind
        public let status: NeuralStatus
        public let mark: Mark
        public let related: Related?
        public let bracket: Bracket
        /// The message the step came from: calls sharing one were made together.
        public let group: Int
        /// The call also draws a card of its own, which "Show in Rows" reveals.
        public let isCard: Bool
        /// The first two lines of a note's words, which its two-line row draws; one line for a
        /// thought; none for a call.
        public let lines: [String]

        public var isFailure: Bool { status == .failed }
        /// A note the agent said: a message, two lines tall.
        public var isSaid: Bool { kind == .note }
        /// A thought: one muted line.
        public var isMuted: Bool { kind == .thought }

        /// This row's height for an input: 28 (32 on touch), or 40 (48) for a said message.
        public func height(input: ChatInput = .pointer) -> Double {
            NeuralStepList.rowHeight(for: self, input: input)
        }

        /// The argument cut to `characters`: a path keeps its file name and gives up the middle of
        /// its directory (`Tailscode\u{2026}/Chat/TranscriptRows.swift`), anything else gives up
        /// its end.
        public func argument(fittingChars characters: Int) -> String {
            NeuralStepList.elide(argument, kind: argumentKind, to: characters)
        }
    }

    /// The filters on the list. A zone set is "any of these"; the rest narrow it further.
    public struct Filter: Sendable, Equatable {
        public var zones: Set<NeuralZone> = []
        public var failedOnly = false
        public var search = ""

        public init(zones: Set<NeuralZone> = [], failedOnly: Bool = false, search: String = "") {
            self.zones = zones
            self.failedOnly = failedOnly
            self.search = search
        }

        public var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
        public var isActive: Bool { !zones.isEmpty || failedOnly || !query.isEmpty }
    }

    /// A zone chip in the list's header.
    public struct ZoneChip: Sendable, Equatable {
        public let zone: NeuralZone
        public let label: String
        /// How many steps the turn has there, whatever the filters.
        public let count: Int
        public let isOn: Bool
    }

    public static let pageSize = 8

    public private(set) var rows: [Row] = []
    public private(set) var filter = Filter()
    /// The step the person has put the cursor on; the model's pin.
    public internal(set) var cursor: String?
    /// The turn is running: new rows arrive at the end.
    public private(set) var isLive = false
    /// A live list follows the newest step until the person scrolls up or sets a cursor.
    public internal(set) var following = true
    public private(set) var zoneCounts: [NeuralZone: Int] = [:]
    public private(set) var failedCount = 0

    /// The ganglia the head draws, by leader: a zone past its capacity gathers its later steps in
    /// one "+7" node, and a step inside one is rung through that node.
    private(set) var ganglia: [String: [String]] = [:]
    private var leaderOf: [String: String] = [:]

    private(set) var steps: [NeuralStep] = []
    private var visible: [Int] = []
    private var positions: [String: Int] = [:]
    private var signatures: [Int] = []
    private var pointerOffsets: [Double] = [0]
    private var touchOffsets: [Double] = [0]

    public init(steps: [NeuralStep] = [], live: Bool = false) {
        update(steps: steps, live: live)
    }

    /// Brings the rows to `steps`. Rows already built are kept while nothing a row says about its
    /// step changed, and only the new steps are read; a change in status, retry, group, tie or
    /// argument rebuilds them. A search is read again, because an output can grow.
    public mutating func update(steps newSteps: [NeuralStep], live: Bool? = nil) {
        if let live { isLive = live }
        var reusable = newSteps.count >= signatures.count
        var fresh: [Int] = []
        fresh.reserveCapacity(newSteps.count)
        for (index, step) in newSteps.enumerated() {
            let sign = Self.signature(of: step)
            fresh.append(sign)
            if reusable, index < signatures.count, signatures[index] != sign { reusable = false }
        }
        let same = reusable && newSteps.count == signatures.count
        steps = newSteps
        if same {
            if filter.query.isEmpty { return }
            refilter()
            return
        }
        signatures = fresh
        rebuild()
    }

    /// Tells the list which steps the head gathers in a ganglion (leader id to member ids).
    public mutating func setGanglia(_ ganglia: [String: [String]]) {
        self.ganglia = ganglia
        var leaders: [String: String] = [:]
        for (leader, members) in ganglia { for member in members { leaders[member] = leader } }
        leaderOf = leaders
    }

    /// The node the head draws a step as: its ganglion's leader, or itself.
    public func nodeID(of id: String) -> String { leaderOf[id] ?? id }

    /// The steps behind a "+7" node, leader first; empty for any other node.
    public func ganglionMembers(of node: String) -> [String] { ganglia[node] ?? [] }

    public var isFiltered: Bool { filter.isActive }
    public var total: Int { rows.count }
    public var visibleCount: Int { visible.count }

    /// Every visible row. A client that draws a window asks `rows(in:)`: this copies the lot.
    public var visibleRows: [Row] { visible.map { rows[$0] } }

    /// The rows at positions `range` of the visible list, clamped to it: the cost of a window.
    public func rows(in range: Range<Int>) -> [Row] {
        let low = max(range.lowerBound, 0)
        let high = min(range.upperBound, visible.count)
        guard low < high else { return [] }
        return visible[low..<high].map { rows[$0] }
    }

    // MARK: Heights

    /// A said message is two lines tall; every other row is one: 28 points for a pointer, 32 for a
    /// finger, and 40 and 48 for a message.
    public static func rowHeight(for row: Row, input: ChatInput = .pointer) -> Double {
        switch (row.isSaid, input) {
        case (true, .pointer): return saidRowHeight
        case (true, .touch): return saidRowHeightTouch
        case (false, .pointer): return 28
        case (false, .touch): return 32
        }
    }

    public static let saidRowHeight = 40.0
    public static let saidRowHeightTouch = 48.0

    private func offsets(_ input: ChatInput) -> [Double] {
        input == .touch ? touchOffsets : pointerOffsets
    }

    /// The height of every visible row together.
    public func contentHeight(input: ChatInput = .pointer) -> Double {
        offsets(input)[offsets(input).count - 1]
    }

    /// Where the visible row at `position` starts, from the top of the list.
    public func offset(ofVisible position: Int, input: ChatInput = .pointer) -> Double {
        let table = offsets(input)
        return table[min(max(position, 0), table.count - 1)]
    }

    /// The visible position whose row is under `offset`; the first or last for one outside.
    public func position(atOffset offset: Double, input: ChatInput = .pointer) -> Int {
        let table = offsets(input)
        guard table.count > 1 else { return 0 }
        var low = 0
        var high = table.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if table[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return min(max(low, 0), table.count - 2)
    }

    /// The positions of the rows a window of `height` points at `offset` shows, the partly shown
    /// ones included: found by binary search, so the cost is the window's and not the list's.
    public func visibleRange(
        offset: Double, height: Double, input: ChatInput = .pointer
    ) -> Range<Int> {
        guard !visible.isEmpty else { return 0..<0 }
        let first = position(atOffset: max(offset, 0), input: input)
        var last = position(atOffset: max(offset + height - 0.001, 0), input: input)
        last = max(last, first)
        return first..<min(last + 1, visible.count)
    }

    /// The rows a window shows, with per-row heights.
    public func rows(
        atOffset offset: Double, height: Double, input: ChatInput = .pointer
    ) -> [Row] {
        rows(in: visibleRange(offset: offset, height: height, input: input))
    }

    // MARK: Said

    /// How many notes the agent wrote in the whole turn.
    public var saidCount: Int { rows.reduce(0) { $0 + ($1.isSaid ? 1 : 0) } }

    /// The previous or next note among the visible rows after or before the cursor; nil at the
    /// ends, never wrapping.
    public func saidStep(from cursor: String?, forward: Bool) -> String? {
        guard !visible.isEmpty else { return nil }
        var position: Int
        if let cursor {
            let place = insertion(of: cursor)
            if positions[cursor] != nil {
                position = forward ? place + 1 : place - 1
            } else {
                position = forward ? place : place - 1
            }
        } else {
            position = forward ? 0 : visible.count - 1
        }
        while position >= 0, position < visible.count {
            if rows[visible[position]].isSaid { return steps[visible[position]].id }
            position += forward ? 1 : -1
        }
        return nil
    }

    /// Where a note stands among the notes of the turn: one-based, for "said 3 of 9".
    public func saidOrdinal(of id: String) -> Int? {
        guard let at = steps.firstIndex(where: { $0.id == id }), rows[at].isSaid else { return nil }
        return rows[..<at].reduce(1) { $0 + ($1.isSaid ? 1 : 0) }
    }

    /// The step waiting on the person, if one is: an approval or a question.
    public var pendingAskID: String? {
        steps.first { $0.status == .waitingApproval || $0.status == .waitingAnswer }?.id
    }

    /// The visible row at a position.
    public func row(atVisible position: Int) -> Row? {
        visible.indices.contains(position) ? rows[visible[position]] : nil
    }

    /// The row of a step, whether or not the filters show it.
    public func row(id: String) -> Row? {
        steps.firstIndex { $0.id == id }.map { rows[$0] }
    }

    /// Where a step is in the visible list; nil when the filters hide it or the turn lacks it.
    public func visibleIndex(of id: String) -> Int? { positions[id] }

    public func isVisible(_ id: String) -> Bool { positions[id] != nil }

    /// The ids the filters hide: the head dims their nodes to 28 percent.
    public var hiddenIDs: Set<String> {
        guard filter.isActive else { return [] }
        return Set(steps.filter { positions[$0.id] == nil }.map(\.id))
    }

    /// The cursor's row, if the turn still has it.
    public var cursorRow: Row? { cursor.flatMap(row(id:)) }

    /// "29 steps", or "5 of 29" while a filter narrows the list.
    public var countLabel: String {
        filter.isActive
            ? Localized.text("%1$lld of %2$lld", visible.count, rows.count)
            : NeuralNoticeLine.countText(tools: 0, steps: rows.count)
    }

    /// The chips for the zones the turn has steps in, SAID first and then in zone order.
    public var zoneChips: [ZoneChip] {
        NeuralZone.filterOrder.compactMap { zone in
            guard let count = zoneCounts[zone], count > 0 else { return nil }
            return ZoneChip(
                zone: zone, label: zone.displayLabel, count: count, isOn: filter.zones.contains(zone))
        }
    }

    /// Whether the "failed" toggle is offered: the turn has a failure.
    public var offersFailedFilter: Bool { failedCount > 0 }

    /// A live list that is not following: the pill "Following paused: jump to latest" shows.
    public var showsFollowPill: Bool { isLive && !following }

    /// A live list that follows: the newest step is kept in view.
    public var isFollowing: Bool { isLive && following }

    // MARK: Filters

    public mutating func setFilter(_ filter: Filter) {
        self.filter = filter
        refilter()
    }

    public mutating func setSearch(_ text: String) {
        filter.search = text
        refilter()
    }

    /// Turns a zone's filter on or off. A zone the turn has no step in is left alone.
    @discardableResult
    public mutating func toggleZone(_ zone: NeuralZone) -> Bool {
        guard (zoneCounts[zone] ?? 0) > 0 else { return false }
        if filter.zones.contains(zone) { filter.zones.remove(zone) } else { filter.zones.insert(zone) }
        refilter()
        return true
    }

    /// Shows only `zone`, or lets go of the filter when it is already the only one.
    public mutating func setSoloZone(_ zone: NeuralZone) {
        guard (zoneCounts[zone] ?? 0) > 0 else { return }
        filter.zones = [zone]
        refilter()
    }

    public mutating func soloZone(_ zone: NeuralZone) {
        guard (zoneCounts[zone] ?? 0) > 0 else { return }
        filter.zones = filter.zones == [zone] ? [] : [zone]
        refilter()
    }

    public mutating func clearZones() {
        filter.zones = []
        refilter()
    }

    @discardableResult
    public mutating func toggleFailedOnly() -> Bool {
        guard failedCount > 0 || filter.failedOnly else { return false }
        filter.failedOnly.toggle()
        refilter()
        return true
    }

    public mutating func clearFilters() {
        filter = Filter()
        refilter()
    }

    // MARK: Walking

    /// The visible position a step stands at, or the position it would take: where the walk
    /// continues from when the cursor is on a row the filters hide.
    private func insertion(of id: String) -> Int {
        if let position = positions[id] { return position }
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return 0 }
        var low = 0
        var high = visible.count
        while low < high {
            let mid = (low + high) / 2
            if visible[mid] < index { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The step `delta` places from the cursor in the visible list, stopping at the ends. With no
    /// cursor a walk down starts at the first row and a walk up at the last.
    public func step(from cursor: String?, by delta: Int) -> String? {
        guard !visible.isEmpty else { return nil }
        guard let cursor else {
            return steps[visible[delta < 0 ? visible.count - 1 : 0]].id
        }
        var target: Int
        if let position = positions[cursor] {
            target = position + delta
        } else {
            let place = insertion(of: cursor)
            target = delta > 0 ? place + delta - 1 : place + delta
        }
        target = min(max(target, 0), visible.count - 1)
        return steps[visible[target]].id
    }

    public var firstVisibleID: String? { visible.first.map { steps[$0].id } }
    public var lastVisibleID: String? { visible.last.map { steps[$0].id } }
    public var newestID: String? { steps.last?.id }

    /// The previous or next visible step in the cursor's zone; nil at the end of the zone, and
    /// never wrapping. With no cursor the first visible row.
    public func zoneStep(from cursor: String?, forward: Bool) -> String? {
        guard let cursor, let at = steps.firstIndex(where: { $0.id == cursor }) else {
            return firstVisibleID
        }
        let zone = steps[at].zone
        let place = insertion(of: cursor)
        var position = positions[cursor] != nil ? (forward ? place + 1 : place - 1) : (forward ? place : place - 1)
        while position >= 0, position < visible.count {
            if steps[visible[position]].zone == zone { return steps[visible[position]].id }
            position += forward ? 1 : -1
        }
        return nil
    }

    /// The previous or next failed step among the visible rows; nil at the ends, never wrapping.
    /// With no cursor, the first failed step going forward and the last going back.
    public func failedStep(from cursor: String?, forward: Bool) -> String? {
        guard !visible.isEmpty else { return nil }
        var position: Int
        if let cursor {
            let place = insertion(of: cursor)
            if positions[cursor] != nil {
                position = forward ? place + 1 : place - 1
            } else {
                position = forward ? place : place - 1
            }
        } else {
            position = forward ? 0 : visible.count - 1
        }
        while position >= 0, position < visible.count {
            if steps[visible[position]].status == .failed { return steps[visible[position]].id }
            position += forward ? 1 : -1
        }
        return nil
    }

    // MARK: Building

    private static func signature(of step: NeuralStep) -> Int {
        var hasher = Hasher()
        hasher.combine(step.id)
        hasher.combine(step.status)
        hasher.combine(step.recovered)
        hasher.combine(step.group)
        hasher.combine(step.zone)
        hasher.combine(step.tieKey)
        hasher.combine(step.tieIsCommand)
        hasher.combine(step.detail.utf8.count)
        hasher.combine(step.text.utf8.count)
        hasher.combine(step.isCard)
        return hasher.finalize()
    }

    private mutating func rebuild() {
        let built = Self.makeRows(steps)
        rows = built
        var counts: [NeuralZone: Int] = [:]
        var failed = 0
        for step in steps {
            counts[step.zone, default: 0] += 1
            if step.status == .failed { failed += 1 }
        }
        zoneCounts = counts
        failedCount = failed
        if failed == 0 { filter.failedOnly = false }
        refilter()
    }

    private mutating func refilter() {
        let query = filter.query
        var indices: [Int] = []
        indices.reserveCapacity(steps.count)
        for index in steps.indices {
            let step = steps[index]
            if !filter.zones.isEmpty, !filter.zones.contains(step.zone) { continue }
            if filter.failedOnly, step.status != .failed { continue }
            if !query.isEmpty, !Self.matches(step, row: rows[index], query: query) { continue }
            indices.append(index)
        }
        visible = indices
        var places: [String: Int] = [:]
        places.reserveCapacity(indices.count)
        for (position, index) in indices.enumerated() { places[steps[index].id] = position }
        positions = places
        rebuildOffsets()
    }

    private mutating func rebuildOffsets() {
        var pointer = [0.0]
        var touch = [0.0]
        pointer.reserveCapacity(visible.count + 1)
        touch.reserveCapacity(visible.count + 1)
        for index in visible {
            pointer.append(pointer[pointer.count - 1] + Self.rowHeight(for: rows[index], input: .pointer))
            touch.append(touch[touch.count - 1] + Self.rowHeight(for: rows[index], input: .touch))
        }
        pointerOffsets = pointer
        touchOffsets = touch
    }

    /// Whether a step answers a search: its title, its argument, the words of a thought or a
    /// note, what it printed, and the words the digest uses for it (its zone, its status, its
    /// retry).
    static func matches(_ step: NeuralStep, row: Row, query: String) -> Bool {
        func has(_ text: String) -> Bool {
            !text.isEmpty && text.range(of: query, options: .caseInsensitive) != nil
        }
        if has(row.title) || has(row.argument) || has(step.detail) || has(step.text) { return true }
        if has(step.zone.label) || has(step.zone.voiceLabel) || has(NeuralReading.statusWord(step.status)) { return true }
        if case .retried = row.mark, has(NeuralReading.retriedWord) { return true }
        for line in step.outputLines where has(line) { return true }
        if let output = step.call?.call.output, has(output) { return true }
        return false
    }

    private static func makeRows(_ steps: [NeuralStep]) -> [Row] {
        var uses: [UseKey: [Int]] = [:]
        var toolsInGroup: [Int: [Int]] = [:]
        for (index, step) in steps.enumerated() {
            if let key = step.tieKey { uses[UseKey(key: key, isCommand: step.tieIsCommand), default: []].append(index) }
            if NeuralReading.isTool(step) { toolsInGroup[step.group, default: []].append(index) }
        }
        return steps.enumerated().map { index, step in
            let tool = NeuralReading.isTool(step)
            let kind: Kind = tool ? .tool : NeuralReading.isNote(step) ? .note : .thought
            let related = related(of: step, at: index, in: steps, uses: uses)
            return Row(
                id: step.id, index: index, number: index + 1, kind: kind, zone: step.zone,
                title: NeuralReading.title(of: step), argument: argument(of: step, kind: kind),
                argumentKind: tool ? NeuralReadoutBuilder.subjectKind(of: step).argumentKind : .words,
                status: step.status, mark: mark(of: step, related: related), related: related,
                bracket: tool ? bracket(of: index, group: toolsInGroup[step.group] ?? []) : .none,
                group: step.group, isCard: step.isCard, lines: lines(of: step, kind: kind))
        }
    }

    /// A note's first two lines, a thought's first; a call has none.
    private static func lines(of step: NeuralStep, kind: Kind) -> [String] {
        switch kind {
        case .tool: return []
        case .note: return NeuralReadoutText.firstLines(step.text, 2)
        case .thought: return NeuralReadoutText.firstLines(step.text, 1)
        }
    }

    private struct UseKey: Hashable {
        let key: String
        let isCommand: Bool
    }

    private static func argument(of step: NeuralStep, kind: Kind) -> String {
        switch kind {
        case .tool: return step.detail
        case .thought, .note:
            return NeuralReadoutText.oneLine(NeuralReadoutText.firstLine(step.text), limit: 160)
        }
    }

    private static func mark(of step: NeuralStep, related: Related?) -> Mark {
        switch step.status {
        case .ok: return .none
        case .failed:
            if step.recovered, let related, related.kind == .retry {
                return .retried(stepID: related.stepID, number: related.number)
            }
            return .failed
        case .running: return .running
        case .stopped: return .stopped
        case .waitingApproval, .waitingAnswer, .stalled: return .waiting
        }
    }

    private static func bracket(of index: Int, group: [Int]) -> Bracket {
        guard group.count > 1, let position = group.firstIndex(of: index) else { return .none }
        if position == 0 { return .first }
        return position == group.count - 1 ? .last : .middle
    }

    /// The step a row points at: a failure's retry, the failure a retry answers, or the next
    /// other use of the same file or command (the previous when none follows).
    private static func related(
        of step: NeuralStep, at index: Int, in steps: [NeuralStep], uses: [UseKey: [Int]]
    ) -> Related? {
        guard let key = step.tieKey else { return nil }
        let others = uses[UseKey(key: key, isCommand: step.tieIsCommand)] ?? []
        func make(_ kind: Related.Kind, _ target: Int) -> Related {
            let number = target + 1
            let label: String
            switch kind {
            case .retry: label = NeuralReading.retriedAt(number)
            case .retriedFrom, .sameCommand: label = NeuralReading.sameCommand([number])
            case .sameFile: label = NeuralReading.sameFile([number])
            }
            return Related(kind: kind, stepID: steps[target].id, number: number, label: label)
        }
        if step.tieIsCommand, step.status == .failed, step.recovered,
            let later = others.first(where: { $0 > index && steps[$0].status == .ok })
        {
            return make(.retry, later)
        }
        if step.tieIsCommand, step.status == .ok,
            let earlier = others.last(where: { $0 < index && steps[$0].status == .failed })
        {
            return make(.retriedFrom, earlier)
        }
        guard others.count > 1 else { return nil }
        let target = others.first(where: { $0 > index }) ?? others.last(where: { $0 < index })
        guard let target else { return nil }
        return make(step.tieIsCommand ? .sameCommand : .sameFile, target)
    }

    // MARK: Ellipsis

    static let ellipsis = "\u{2026}"

    /// `text` cut to `characters` by the rule of its kind.
    static func elide(_ text: String, kind: ArgumentKind, to characters: Int) -> String {
        let limit = max(characters, 0)
        guard text.count > limit else { return text }
        if limit == 0 { return "" }
        if limit == 1 { return ellipsis }
        switch kind {
        case .command, .words:
            return String(text.prefix(limit - 1)) + ellipsis
        case .path:
            return elidePath(text, to: limit)
        }
    }

    private static func elidePath(_ path: String, to limit: Int) -> String {
        let parts = NeuralReadoutText.split(path: path)
        let file = parts.file
        if file.count + 2 > limit {
            return ellipsis + String(file.suffix(limit - 1))
        }
        let directories = parts.directory.split(separator: "/", omittingEmptySubsequences: true)
        let lastDirectory = directories.last.map { "/" + $0 + "/" } ?? "/"
        let room = limit - 1 - file.count
        if directories.count > 1, room - lastDirectory.count >= 3 {
            let head = String(parts.directory.prefix(room - lastDirectory.count))
            return head + ellipsis + lastDirectory + file
        }
        let head = String(parts.directory.prefix(max(room - 1, 0)))
        return head + ellipsis + "/" + file
    }
}

extension NeuralReadout.Subject.Kind {
    var argumentKind: NeuralStepList.ArgumentKind {
        switch self {
        case .path: return .path
        case .command: return .command
        case .pattern, .url, .agent, .thought, .note, .other: return .words
        }
    }
}

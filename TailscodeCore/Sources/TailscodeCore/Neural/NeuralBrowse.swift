import Foundation

/// What keys and the pointer do to the step list, written once: a pure reducer from a state and
/// an action to the next state and the effects a client draws or performs. A client maps its own
/// events to `Action`s and its toolkit to `Effect`s, so the key table, the mouse rules, the order
/// Esc undoes things in and the walk's edges are the same on every desk and are tested here.
///
/// There is one cursor, the model's pin. Hover is a preview and never moves it. Filters dim the
/// head's other nodes, so the head always shows what the list shows. Walks stop at the ends and
/// never wrap.
public enum NeuralBrowse {
    public enum Key: Sendable, Equatable {
        case up
        case down
        case pageUp
        case pageDown
        case home
        case end
        case left
        case right
        case enter
        case space
        case escape
        case tab
        /// A printable key as the client sees it: shifted letters arrive as capitals.
        case character(Character)
    }

    public struct Modifiers: OptionSet, Sendable, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let alt = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
        /// A chord that belongs to the platform or the app, not to the list.
        static let reserved: Modifiers = [.control, .alt, .command]
    }

    /// Where the keyboard is: the list (and the stage, which shares its keys), the readout's
    /// buttons, or the search field.
    public enum Focus: Sendable, Equatable {
        case list
        case readout
        case search
    }

    public enum MenuItem: Sendable, Equatable, CaseIterable {
        case copySubject
        case copyOutput
        case copyMarkdown
        case showOnlyThisZone
        case goToRelated
        case showInRows
    }

    public enum Action: Sendable, Equatable {
        case key(Key, Modifiers = [])
        /// A row was clicked.
        case click(String, double: Bool)
        /// A node of the head was clicked. A "+7" node selects the ganglion's first failed
        /// member, else its first, and solos that zone's filter; any other node is a row's click.
        case clickNode(String, double: Bool)
        case hover(String?)
        case hoverLeft
        case zoneChip(NeuralZone, solo: Bool)
        case failedToggle
        case searchText(String)
        /// The list was scrolled; only a person's scroll pauses following.
        case scrolled(manual: Bool)
        /// A new step arrived at the end of a running turn.
        case liveStepArrived
        /// The pill "Following paused: jump to latest".
        case jumpToLatest
        case contextMenu(String)
        case menu(MenuItem, String)
        /// Copy what an account item says: a said or thought step's whole words, a call's command
        /// or path. The text comes back through `copyOutput` or `copySubject`.
        case copyItem(String)
        /// Reply to an account item: a quote of it is offered to the composer, nothing is sent.
        case reply(String)
    }

    /// Where the head rings: the step, the node that draws it (a "+7" node for a member of a
    /// ganglion), and the number its callout shows beside the ring, because at the head's size the
    /// numbers inside the nodes do not read.
    public struct Ring: Sendable, Equatable {
        public let stepID: String
        public let nodeID: String
        public let calloutNumber: Int
    }

    /// What the account asks of a client beyond the list's own effects. They ride in the state's
    /// outbox (`State.outbox`, drained by `NeuralBrainModel.drainAccountEffects()`) so that a client
    /// that switches over `Effect` keeps compiling as the account grows.
    public enum AccountEffect: Sendable, Equatable {
        /// Scroll the transcript to the card that carries the pending ask.
        case goToAsk(String)
        /// Put `quote` in the composer ("> " before each line) and focus it; send nothing.
        case reply(quote: String)
    }

    public enum Effect: Sendable, Equatable {
        case scrollTo(String)
        case copySubject(String)
        case copyOutput(String)
        case copyMarkdown(String)
        case focusReadout
        case focusList
        case focusSearch
        case expandOutputToggle
        case showLegend
        case hideLegend
        case collapseBrain
        /// The head's ring and the leader's target; nil for none.
        case ring(Ring?)
        /// The nodes the filters hide, which the head draws at 28 percent.
        case dim(Set<String>)
        case announce(String)
        case showMenu(String, [MenuItem])
        case showInRows(String)
    }

    public struct State: Sendable, Equatable {
        public var list: NeuralStepList
        public var focus: Focus = .list
        public var legend = false
        public var hovered: String?
        /// The readout's long output or diff is expanded; it folds again when the cursor moves.
        public var outputExpanded = false
        /// The search field is open rather than an icon.
        public var searchOpen = false
        /// Account effects the reducer raised and no client has taken yet.
        public var outbox: [AccountEffect] = []

        public init(list: NeuralStepList) {
            self.list = list
        }

        public init(steps: [NeuralStep], live: Bool = false) {
            list = NeuralStepList(steps: steps, live: live)
        }

        public var cursor: String? {
            get { list.cursor }
            set { list.cursor = newValue }
        }

        /// The step the readout previews: the hovered row, or the cursor when the hover ends.
        public var previewed: String? { hovered ?? list.cursor }
    }

    // MARK: Reducer

    public static func reduce(state: State, action: Action) -> (State, [Effect]) {
        var state = state
        var effects: [Effect] = []
        switch action {
        case .key(let key, let modifiers):
            guard modifiers.isDisjoint(with: .reserved) else { return (state, []) }
            handle(key, in: &state, effects: &effects)
        case .click(let id, let double):
            click(id, double: double, in: &state, effects: &effects)
        case .clickNode(let id, let double):
            clickNode(id, double: double, in: &state, effects: &effects)
        case .hover(let id):
            guard let id, state.list.row(id: id) != nil else {
                hoverLeft(in: &state, effects: &effects)
                break
            }
            state.hovered = id
            effects.append(ring(id, state.list))
        case .hoverLeft:
            hoverLeft(in: &state, effects: &effects)
        case .zoneChip(let zone, let solo):
            if solo { state.list.soloZone(zone) } else { state.list.toggleZone(zone) }
            filtersChanged(&state, &effects)
        case .failedToggle:
            toggleFailed(&state, &effects)
        case .searchText(let text):
            guard text != state.list.filter.search else { break }
            state.list.setSearch(text)
            state.searchOpen = state.searchOpen || !text.isEmpty
            filtersChanged(&state, &effects)
        case .scrolled(let manual):
            if manual { state.list.following = false }
        case .liveStepArrived:
            if state.list.isFollowing, let newest = newestVisible(state.list) {
                effects.append(.scrollTo(newest))
            }
        case .jumpToLatest:
            resumeFollowing(&state, &effects)
        case .contextMenu(let id):
            guard let row = state.list.row(id: id) else { break }
            effects.append(.showMenu(id, menuItems(for: row)))
        case .copyItem(let id):
            copyItem(id, in: &state, effects: &effects)
        case .reply(let id):
            replyTo(id, in: &state)
        case .menu(let item, let id):
            perform(item, on: id, in: &state, effects: &effects)
        }
        return (state, effects)
    }

    /// The menu a right-click offers on a row: Go to related only where the row has one.
    public static func menuItems(for row: NeuralStepList.Row) -> [MenuItem] {
        MenuItem.allCases.filter { $0 != .goToRelated || row.related != nil }
    }

    // MARK: Keys

    private static func handle(_ key: Key, in state: inout State, effects: inout [Effect]) {
        switch state.focus {
        case .search: searchKey(key, in: &state, effects: &effects)
        case .readout: readoutKey(key, in: &state, effects: &effects)
        case .list: listKey(key, in: &state, effects: &effects)
        }
    }

    private static func listKey(_ key: Key, in state: inout State, effects: inout [Effect]) {
        switch key {
        case .up: move(&state, &effects, by: -1)
        case .down: move(&state, &effects, by: 1)
        case .pageUp: move(&state, &effects, by: -NeuralStepList.pageSize)
        case .pageDown: move(&state, &effects, by: NeuralStepList.pageSize)
        case .home: go(to: state.list.firstVisibleID, &state, &effects)
        case .end: end(&state, &effects)
        case .left: go(to: state.list.zoneStep(from: state.cursor, forward: false), &state, &effects)
        case .right: go(to: state.list.zoneStep(from: state.cursor, forward: true), &state, &effects)
        case .enter: enterReadout(&state, &effects)
        case .space: toggleOutput(&state, &effects)
        case .escape: escape(&state, &effects)
        case .tab: break
        case .character(let character): characterKey(character, in: &state, effects: &effects)
        }
    }

    private static func characterKey(_ character: Character, in state: inout State, effects: inout [Effect]) {
        switch character {
        case "j": move(&state, &effects, by: 1)
        case "k": move(&state, &effects, by: -1)
        case "g": go(to: state.list.firstVisibleID, &state, &effects)
        case "G": end(&state, &effects)
        case "h": go(to: state.list.zoneStep(from: state.cursor, forward: false), &state, &effects)
        case "l": go(to: state.list.zoneStep(from: state.cursor, forward: true), &state, &effects)
        case "]", "n": failedWalk(&state, &effects, forward: true)
        case "[", "p": failedWalk(&state, &effects, forward: false)
        case "r": related(&state, &effects)
        case "1", "2", "3", "4", "5", "6":
            guard let digit = character.wholeNumberValue else { return }
            if state.list.toggleZone(NeuralZone.filterOrder[digit - 1]) { filtersChanged(&state, &effects) }
        case "0":
            guard !state.list.filter.zones.isEmpty else { return }
            state.list.clearZones()
            filtersChanged(&state, &effects)
        case "!", "x": toggleFailed(&state, &effects)
        case "/": openSearch(&state, &effects)
        case "c": copy(&state, &effects, output: false)
        case "C": copy(&state, &effects, output: true)
        case "o": toggleOutput(&state, &effects)
        case "s": saidWalk(&state, &effects, forward: true)
        case "S": saidWalk(&state, &effects, forward: false)
        case "a": goToAsk(&state, &effects)
        case "?": toggleLegend(&state, &effects)
        default: break
        }
    }

    /// In the search field the client types; the list's keys that still apply are the ones that
    /// leave it and the ones that walk the matches.
    private static func searchKey(_ key: Key, in state: inout State, effects: inout [Effect]) {
        switch key {
        case .enter:
            state.focus = .list
            if let first = state.list.firstVisibleID {
                setCursor(first, &state, &effects)
            } else {
                effects.append(.focusList)
            }
        case .escape:
            let hadText = !state.list.filter.query.isEmpty
            if hadText { state.list.setSearch("") }
            state.searchOpen = false
            state.focus = .list
            effects.append(.focusList)
            if hadText { filtersChanged(&state, &effects) }
        case .up: move(&state, &effects, by: -1)
        case .down: move(&state, &effects, by: 1)
        default: break
        }
    }

    /// In the readout the list's keys are the readout's own; what still applies is leaving it,
    /// the copy and expand keys, and the legend.
    private static func readoutKey(_ key: Key, in state: inout State, effects: inout [Effect]) {
        switch key {
        case .enter, .escape:
            state.focus = .list
            effects.append(.focusList)
        case .space: toggleOutput(&state, &effects)
        case .character("c"): copy(&state, &effects, output: false)
        case .character("C"): copy(&state, &effects, output: true)
        case .character("o"): toggleOutput(&state, &effects)
        case .character("?"): toggleLegend(&state, &effects)
        default: break
        }
    }

    // MARK: Moves

    private static func move(_ state: inout State, _ effects: inout [Effect], by delta: Int) {
        guard let target = state.list.step(from: state.cursor, by: delta) else { return }
        go(to: target, &state, &effects)
    }

    /// Puts the cursor on `id`; nothing at the end of a walk or when it is already there.
    private static func go(to id: String?, _ state: inout State, _ effects: inout [Effect]) {
        guard let id, id != state.cursor else { return }
        setCursor(id, &state, &effects)
    }

    private static func setCursor(_ id: String, _ state: inout State, _ effects: inout [Effect]) {
        state.cursor = id
        state.outputExpanded = false
        state.list.following = false
        effects.append(.scrollTo(id))
        effects.append(ring(id, state.list))
        if let index = state.list.steps.firstIndex(where: { $0.id == id }) {
            effects.append(
                .announce(NeuralReading.announcement(for: state.list.steps[index], of: state.list.total)))
        }
    }

    /// The ring for a step: nil for none.
    static func ring(_ id: String?, _ list: NeuralStepList) -> Effect {
        guard let id, let row = list.row(id: id) else { return .ring(nil) }
        return .ring(Ring(stepID: id, nodeID: list.nodeID(of: id), calloutNumber: row.number))
    }

    private static func end(_ state: inout State, _ effects: inout [Effect]) {
        guard let last = state.list.lastVisibleID else { return }
        if state.cursor != last { setCursor(last, &state, &effects) }
        if state.list.isLive {
            state.list.following = true
            if state.cursor == last { effects.append(.scrollTo(last)) }
        }
    }

    private static func resumeFollowing(_ state: inout State, _ effects: inout [Effect]) {
        guard state.list.isLive else { return }
        state.list.following = true
        if let newest = newestVisible(state.list) { effects.append(.scrollTo(newest)) }
    }

    private static func newestVisible(_ list: NeuralStepList) -> String? { list.lastVisibleID }

    private static func failedWalk(_ state: inout State, _ effects: inout [Effect], forward: Bool) {
        guard state.list.failedCount > 0 else {
            effects.append(.announce(NeuralBrowse.noFailedWords))
            return
        }
        guard let target = state.list.failedStep(from: state.cursor, forward: forward) else { return }
        setCursor(target, &state, &effects)
    }

    private static func related(_ state: inout State, _ effects: inout [Effect]) {
        guard let related = state.list.cursorRow?.related else {
            effects.append(.announce(NeuralBrowse.noRelatedWords))
            return
        }
        reveal(related.stepID, &state, &effects)
        setCursor(related.stepID, &state, &effects)
    }

    /// Clears the filters when they hide a step the person is going to.
    private static func reveal(_ id: String, _ state: inout State, _ effects: inout [Effect]) {
        guard !state.list.isVisible(id), state.list.row(id: id) != nil, state.list.isFiltered else {
            return
        }
        state.list.clearFilters()
        state.searchOpen = false
        filtersChanged(&state, &effects)
    }

    // MARK: Actions

    private static func enterReadout(_ state: inout State, _ effects: inout [Effect]) {
        guard state.cursor != nil else { return }
        state.focus = .readout
        effects.append(.focusReadout)
    }

    private static func toggleOutput(_ state: inout State, _ effects: inout [Effect]) {
        guard state.cursor != nil else { return }
        state.outputExpanded.toggle()
        effects.append(.expandOutputToggle)
    }

    private static func toggleLegend(_ state: inout State, _ effects: inout [Effect]) {
        state.legend.toggle()
        effects.append(state.legend ? .showLegend : .hideLegend)
    }

    private static func openSearch(_ state: inout State, _ effects: inout [Effect]) {
        state.searchOpen = true
        state.focus = .search
        effects.append(.focusSearch)
    }

    private static func copy(_ state: inout State, _ effects: inout [Effect], output: Bool) {
        guard let id = state.cursor else { return }
        effects.append(output ? .copyOutput(id) : .copySubject(id))
    }

    private static func toggleFailed(_ state: inout State, _ effects: inout [Effect]) {
        if state.list.toggleFailedOnly() {
            filtersChanged(&state, &effects)
        } else {
            effects.append(.announce(noFailedWords))
        }
    }

    private static func filtersChanged(_ state: inout State, _ effects: inout [Effect]) {
        effects.append(.dim(state.list.hiddenIDs))
        effects.append(.announce(state.list.countLabel))
    }

    private static func hoverLeft(in state: inout State, effects: inout [Effect]) {
        guard state.hovered != nil else { return }
        state.hovered = nil
        effects.append(ring(state.cursor, state.list))
    }

    private static func click(
        _ id: String, double: Bool, in state: inout State, effects: inout [Effect]
    ) {
        guard state.list.row(id: id) != nil else { return }
        reveal(id, &state, &effects)
        state.hovered = nil
        if state.cursor != id { setCursor(id, &state, &effects) } else {
            state.list.following = false
            effects.append(.scrollTo(id))
            effects.append(ring(id, state.list))
        }
        state.focus = double ? .readout : .list
        effects.append(double ? .focusReadout : .focusList)
    }

    private static func clickNode(
        _ id: String, double: Bool, in state: inout State, effects: inout [Effect]
    ) {
        let members = state.list.ganglionMembers(of: id)
        guard !members.isEmpty else {
            click(id, double: double, in: &state, effects: &effects)
            return
        }
        let chosen =
            members.first { state.list.row(id: $0)?.isFailure == true } ?? members[0]
        if let zone = state.list.row(id: chosen)?.zone {
            let before = state.list.filter
            state.list.clearFilters()
            state.list.setSoloZone(zone)
            state.searchOpen = false
            if state.list.filter != before { filtersChanged(&state, &effects) }
        }
        click(chosen, double: double, in: &state, effects: &effects)
    }

    private static func saidWalk(_ state: inout State, _ effects: inout [Effect], forward: Bool) {
        guard let target = state.list.saidStep(from: state.cursor, forward: forward) else { return }
        setCursor(target, &state, &effects)
        if let ordinal = state.list.saidOrdinal(of: target) {
            effects.append(.announce(NeuralReading.saidOrdinal(ordinal, of: state.list.saidCount)))
        }
    }

    private static func goToAsk(_ state: inout State, _ effects: inout [Effect]) {
        guard let id = state.list.pendingAskID else {
            effects.append(.announce(NeuralReading.nothingWaiting))
            return
        }
        reveal(id, &state, &effects)
        setCursor(id, &state, &effects)
        state.outbox.append(.goToAsk(id))
    }

    private static func copyItem(_ id: String, in state: inout State, effects: inout [Effect]) {
        guard let row = state.list.row(id: id) else { return }
        effects.append(row.kind == .tool ? .copySubject(id) : .copyOutput(id))
    }

    private static func replyTo(_ id: String, in state: inout State) {
        guard let row = state.list.row(id: id), row.kind != .tool,
            let step = state.list.steps.first(where: { $0.id == id })
        else { return }
        state.outbox.append(.reply(quote: replyQuote(of: step)))
    }

    /// What Reply puts in the composer: every line of the words behind a "> ", then a blank line
    /// to write under.
    public static func replyQuote(of step: NeuralStep) -> String {
        let lines = step.text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let quoted = lines.map { $0.isEmpty ? ">" : "> " + $0 }
        var out = quoted.joined(separator: "\n")
        while out.hasSuffix("\n>") { out.removeLast(2) }
        return out + "\n\n"
    }

    private static func perform(
        _ item: MenuItem, on id: String, in state: inout State, effects: inout [Effect]
    ) {
        guard let row = state.list.row(id: id) else { return }
        switch item {
        case .copySubject: effects.append(.copySubject(id))
        case .copyOutput: effects.append(.copyOutput(id))
        case .copyMarkdown: effects.append(.copyMarkdown(id))
        case .showOnlyThisZone:
            state.list.soloZone(row.zone)
            filtersChanged(&state, &effects)
        case .goToRelated:
            guard let related = row.related else { return }
            reveal(related.stepID, &state, &effects)
            setCursor(related.stepID, &state, &effects)
        case .showInRows: effects.append(.showInRows(id))
        }
    }

    private static func escape(_ state: inout State, _ effects: inout [Effect]) {
        if state.legend {
            state.legend = false
            effects.append(.hideLegend)
        } else if !state.list.filter.query.isEmpty {
            state.list.setSearch("")
            state.searchOpen = false
            filtersChanged(&state, &effects)
        } else if !state.list.filter.zones.isEmpty || state.list.filter.failedOnly {
            state.list.clearFilters()
            filtersChanged(&state, &effects)
        } else if state.cursor != nil {
            state.cursor = nil
            state.outputExpanded = false
            effects.append(.ring(nil))
        } else {
            effects.append(.collapseBrain)
        }
    }

    // MARK: Text a client copies

    /// The step's command, path, pattern or address, whole.
    public static func subjectText(of step: NeuralStep) -> String { NeuralReadout.fullSubject(of: step) }

    /// Everything the step printed, or its thought's words.
    public static func outputText(of step: NeuralStep) -> String {
        if let output = step.call?.call.output, !output.isEmpty { return output }
        if !step.outputLines.isEmpty { return step.outputLines.joined(separator: "\n") }
        return step.text
    }

    /// The step as a Markdown block: its number and title, its subject, and its output.
    public static func markdown(of step: NeuralStep) -> String {
        var out = "### \(step.index + 1). \(NeuralReading.title(of: step))\n"
        let subject = subjectText(of: step)
        if !subject.isEmpty && !(NeuralReading.isThought(step) || NeuralReading.isNote(step)) {
            out += "\n```\n\(subject)\n```\n"
        }
        let output = outputText(of: step)
        if !output.isEmpty {
            out += NeuralReading.isThought(step) || NeuralReading.isNote(step)
                ? "\n\(output)\n" : "\n```\n\(output)\n```\n"
        }
        return out
    }
}

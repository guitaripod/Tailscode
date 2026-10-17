import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

enum BrowseFixtures {
    typealias Effect = NeuralBrowse.Effect

    static func state(_ turn: NeuralTurn? = nil, live: Bool = false) -> NeuralBrowse.State {
        NeuralBrowse.State(steps: (turn ?? BrainFixtures.buildFix()).steps, live: live)
    }

    static func key(_ key: NeuralBrowse.Key, _ modifiers: NeuralBrowse.Modifiers = []) -> NeuralBrowse.Action {
        .key(key, modifiers)
    }

    static func char(_ character: Character) -> NeuralBrowse.Action { .key(.character(character)) }

    @discardableResult
    static func run(
        _ state: inout NeuralBrowse.State, _ actions: NeuralBrowse.Action...
    ) -> [Effect] {
        var all: [Effect] = []
        for action in actions {
            let (next, effects) = NeuralBrowse.reduce(state: state, action: action)
            state = next
            all += effects
        }
        return all
    }

    static func id(_ state: NeuralBrowse.State, _ index: Int) -> String { state.list.rows[index].id }

    static func ring(_ state: NeuralBrowse.State, _ index: Int) -> Effect {
        NeuralBrowse.ring(id(state, index), state.list)
    }

    static func at(_ state: NeuralBrowse.State, _ index: Int) -> Bool { state.cursor == id(state, index) }
}

@Suite("Neural browse keys")
struct NeuralBrowseKeyTests {
    typealias B = BrowseFixtures

    @Test("down and up, j and k, set the cursor and stop at the ends")
    func upDown() {
        var state = B.state()
        let effects = B.run(&state, .key(.down))
        #expect(B.at(state, 0))
        #expect(effects.contains(.scrollTo(B.id(state, 0))))
        #expect(effects.contains(B.ring(state, 0)))
        B.run(&state, .key(.down), B.char("j"))
        #expect(B.at(state, 2))
        B.run(&state, B.char("k"), .key(.up))
        #expect(B.at(state, 0))
        let atTop = B.run(&state, .key(.up))
        #expect(B.at(state, 0))
        #expect(atTop.isEmpty)
        B.run(&state, .key(.end))
        let atEnd = B.run(&state, .key(.down))
        #expect(B.at(state, 13))
        #expect(atEnd.isEmpty)
    }

    @Test("with no cursor up starts at the last step")
    func upFromNothing() {
        var state = B.state()
        B.run(&state, .key(.up))
        #expect(B.at(state, 13))
    }

    @Test("page up and page down move eight steps and stop at the ends")
    func pages() {
        var state = B.state()
        B.run(&state, .key(.pageDown))
        #expect(B.at(state, 0))
        B.run(&state, .key(.pageDown))
        #expect(B.at(state, 8))
        B.run(&state, .key(.pageDown))
        #expect(B.at(state, 13))
        B.run(&state, .key(.pageUp))
        #expect(B.at(state, 5))
        B.run(&state, .key(.pageUp), .key(.pageUp))
        #expect(B.at(state, 0))
    }

    @Test("home, end, g and G go to the first and last step")
    func homeEnd() {
        var state = B.state()
        B.run(&state, .key(.end))
        #expect(B.at(state, 13))
        B.run(&state, .key(.home))
        #expect(B.at(state, 0))
        B.run(&state, B.char("G"))
        #expect(B.at(state, 13))
        B.run(&state, B.char("g"))
        #expect(B.at(state, 0))
    }

    @Test("left and right, h and l, go to the previous and next step in the same zone")
    func zoneWalk() {
        var state = B.state()
        B.run(&state, .key(.home), .key(.down))
        #expect(B.at(state, 1))
        B.run(&state, .key(.right))
        #expect(B.at(state, 2))
        B.run(&state, B.char("l"))
        #expect(B.at(state, 3))
        B.run(&state, B.char("l"))
        #expect(B.at(state, 7))
        let atEnd = B.run(&state, .key(.right))
        #expect(B.at(state, 7))
        #expect(atEnd.isEmpty)
        B.run(&state, .key(.left), B.char("h"))
        #expect(B.at(state, 2))
        B.run(&state, .key(.left), .key(.left))
        #expect(B.at(state, 1))
    }

    @Test("the zone walk walks the filtered list")
    func zoneWalkFiltered() {
        var state = B.state()
        B.run(&state, B.char("5"), .key(.down), .key(.right))
        #expect(B.at(state, 10))
    }

    @Test("[ and p, ] and n walk the failed steps; they stop at the ends and never wrap")
    func failedWalk() {
        let messages = [
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [NeuralTurnFixtures.bash("a", out: ["x"], status: .error)]),
            NeuralTurnFixtures.message(2, [NeuralTurnFixtures.bash("b", out: ["x"])]),
            NeuralTurnFixtures.message(3, [NeuralTurnFixtures.bash("c", out: ["x"], status: .error)]),
            NeuralTurnFixtures.message(4, [NeuralTurnFixtures.bash("d", out: ["x"])]),
        ]
        var state = B.state(NeuralTurns.partition(messages: messages, running: false)[0])
        B.run(&state, B.char("]"))
        #expect(B.at(state, 0))
        B.run(&state, B.char("n"))
        #expect(B.at(state, 2))
        let stuck = B.run(&state, B.char("]"))
        #expect(B.at(state, 2))
        #expect(stuck.isEmpty)
        B.run(&state, B.char("["))
        #expect(B.at(state, 0))
        let atStart = B.run(&state, B.char("p"))
        #expect(B.at(state, 0))
        #expect(atStart.isEmpty)
        B.run(&state, .key(.end), B.char("["))
        #expect(B.at(state, 2))
    }

    @Test("a turn with no failure says so")
    func noFailures() {
        var state = B.state(NeuralTurns.partition(messages: [
            NeuralTurnFixtures.user(0), NeuralTurnFixtures.message(1, [NeuralTurnFixtures.bash("a", out: ["x"])]),
        ], running: false)[0])
        let effects = B.run(&state, B.char("]"), B.char("!"))
        #expect(effects == [.announce("No failed steps"), .announce("No failed steps")])
        #expect(state.cursor == nil)
        #expect(!state.list.filter.failedOnly)
    }

    @Test("r goes to the related step: a failure's retry, a retry's failure, a file's other use")
    func related() {
        var state = B.state()
        B.run(&state, .key(.home))
        for _ in 0..<4 { B.run(&state, .key(.down)) }
        #expect(B.at(state, 4))
        B.run(&state, B.char("j"))
        #expect(B.at(state, 5))
        B.run(&state, B.char("r"))
        #expect(B.at(state, 10))
        B.run(&state, B.char("r"))
        #expect(B.at(state, 5))
        B.run(&state, .key(.home), B.char("r"))
        #expect(B.at(state, 0))
        var none = B.state()
        B.run(&none, .key(.home))
        let said = B.run(&none, B.char("r"))
        #expect(said == [.announce("No related step")])
    }

    @Test("r reveals a related step the filters hide by clearing them")
    func relatedHidden() {
        var state = B.state()
        B.run(&state, B.char("5"), .key(.down))
        #expect(B.at(state, 5))
        B.run(&state, B.char("4"))
        #expect(state.list.filter.zones == [.shell, .act])
        B.run(&state, B.char("r"))
        #expect(B.at(state, 10))
    }

    @Test("1 to 6 toggle the zone filters and 0 clears them")
    func zoneKeys() {
        var state = B.state()
        let effects = B.run(&state, B.char("5"))
        #expect(state.list.filter.zones == [.shell])
        #expect(effects.contains(.dim(state.list.hiddenIDs)))
        #expect(effects.contains(.announce("4 of 14")))
        B.run(&state, B.char("4"))
        #expect(state.list.filter.zones == [.shell, .act])
        B.run(&state, B.char("5"))
        #expect(state.list.filter.zones == [.act])
        let ignored = B.run(&state, B.char("1"))
        #expect(ignored.isEmpty)
        #expect(state.list.filter.zones == [.act])
        let cleared = B.run(&state, B.char("0"))
        #expect(state.list.filter.zones.isEmpty)
        #expect(cleared.contains(.dim([])))
        #expect(B.run(&state, B.char("0")).isEmpty)
        for (digit, zone) in zip("23456", [NeuralZone.think, .sense, .act, .shell, .delegate]) {
            var fresh = B.state()
            B.run(&fresh, B.char(digit))
            #expect(fresh.list.filter.zones == [zone])
        }
    }

    @Test("! and x toggle failed only")
    func failedOnly() {
        var state = B.state()
        B.run(&state, B.char("!"))
        #expect(state.list.filter.failedOnly)
        #expect(state.list.visibleCount == 1)
        B.run(&state, B.char("x"))
        #expect(!state.list.filter.failedOnly)
        #expect(state.list.visibleCount == 14)
    }

    @Test("/ focuses the search, typing filters, enter takes the first match, escape clears it")
    func search() {
        var state = B.state()
        let opened = B.run(&state, B.char("/"))
        #expect(opened == [.focusSearch])
        #expect(state.focus == .search && state.searchOpen)
        B.run(&state, .searchText("parity"))
        #expect(state.list.visibleCount == 4)
        let entered = B.run(&state, .key(.enter))
        #expect(state.focus == .list)
        #expect(B.at(state, 3))
        #expect(entered.contains(.scrollTo(state.cursor!)))
        B.run(&state, B.char("/"), .key(.escape))
        #expect(state.list.filter.search.isEmpty)
        #expect(state.focus == .list && !state.searchOpen)
        #expect(state.list.visibleCount == 14)
    }

    @Test("search finds a step by what it printed")
    func searchOutput() {
        var state = B.state()
        B.run(&state, B.char("/"), .searchText("switch must be exhaustive"), .key(.enter))
        #expect(B.at(state, 5))
    }

    @Test("with the search focused the letters are the field's, not the list's")
    func searchFocusKeys() {
        var state = B.state()
        B.run(&state, B.char("/"), B.char("j"), B.char("4"), B.char("c"))
        #expect(state.cursor == nil)
        #expect(state.list.filter.zones.isEmpty)
        B.run(&state, .key(.down))
        #expect(B.at(state, 0))
    }

    @Test("enter moves focus into the readout and enter again returns, and nothing without a cursor")
    func enter() {
        var state = B.state()
        #expect(B.run(&state, .key(.enter)).isEmpty)
        #expect(state.focus == .list)
        B.run(&state, .key(.down))
        let into = B.run(&state, .key(.enter))
        #expect(into == [.focusReadout])
        #expect(state.focus == .readout)
        let back = B.run(&state, .key(.enter))
        #expect(back == [.focusList])
        #expect(state.focus == .list)
    }

    @Test("in the readout the list's keys are not handled, and escape comes back to the list")
    func readoutFocus() {
        var state = B.state()
        B.run(&state, .key(.down), .key(.enter))
        let before = state.cursor
        #expect(B.run(&state, .key(.down)).isEmpty)
        #expect(B.run(&state, B.char("j")).isEmpty)
        #expect(state.cursor == before)
        B.run(&state, .key(.escape))
        #expect(state.focus == .list)
        #expect(state.cursor == before)
        B.run(&state, .key(.enter))
        #expect(B.run(&state, B.char("c")) == [.copySubject(before!)])
    }

    @Test("space and o expand or fold the output, and it folds when the cursor moves")
    func expand() {
        var state = B.state()
        #expect(B.run(&state, .key(.space)).isEmpty)
        B.run(&state, .key(.down))
        #expect(B.run(&state, .key(.space)) == [.expandOutputToggle])
        #expect(state.outputExpanded)
        #expect(B.run(&state, B.char("o")) == [.expandOutputToggle])
        #expect(!state.outputExpanded)
        B.run(&state, B.char("o"), .key(.down))
        #expect(!state.outputExpanded)
    }

    @Test("c copies the command or path, C the output, and neither without a cursor")
    func copy() {
        var state = B.state()
        #expect(B.run(&state, B.char("c"), B.char("C")).isEmpty)
        B.run(&state, .key(.down))
        let id = state.cursor!
        #expect(B.run(&state, B.char("c")) == [.copySubject(id)])
        #expect(B.run(&state, B.char("C")) == [.copyOutput(id)])
    }

    @Test("? shows the legend and shows it away, and escape closes it first")
    func legend() {
        var state = B.state()
        #expect(B.run(&state, B.char("?")) == [.showLegend])
        #expect(state.legend)
        #expect(B.run(&state, B.char("?")) == [.hideLegend])
        B.run(&state, .key(.down), B.char("?"))
        let closed = B.run(&state, .key(.escape))
        #expect(closed == [.hideLegend])
        #expect(!state.legend)
        #expect(state.cursor != nil)
    }

    @Test("a chord with control, alt or command is not the list's")
    func chords() {
        var state = B.state()
        for modifier in [NeuralBrowse.Modifiers.control, .alt, .command] {
            #expect(B.run(&state, B.key(.down, modifier)).isEmpty)
            #expect(B.run(&state, .key(.character("j"), modifier)).isEmpty)
        }
        #expect(state.cursor == nil)
        B.run(&state, B.key(.down, .shift))
        #expect(B.at(state, 0))
    }

    @Test("tab and keys that mean nothing change nothing")
    func idleKeys() {
        var state = B.state()
        #expect(B.run(&state, .key(.tab), B.char("z"), B.char("7"), B.char("9"), B.char(" ")).isEmpty)
        #expect(state.cursor == nil)
    }
}

@Suite("Neural browse escape order")
struct NeuralBrowseEscapeTests {
    typealias B = BrowseFixtures

    @Test("escape clears the search, then the filters, then the cursor, and a fourth press collapses")
    func ladder() {
        var state = B.state()
        B.run(&state, .key(.down), .key(.down), B.char("4"), B.char("!"))
        B.run(&state, .searchText("build"))
        #expect(state.list.filter.isActive && state.cursor != nil)

        let first = B.run(&state, .key(.escape))
        #expect(state.list.filter.search.isEmpty)
        #expect(!state.list.filter.zones.isEmpty && state.list.filter.failedOnly)
        #expect(state.cursor != nil)
        #expect(first.contains(.announce(state.list.countLabel)))

        let second = B.run(&state, .key(.escape))
        #expect(!state.list.filter.isActive)
        #expect(second.contains(.dim([])))
        #expect(state.cursor != nil)

        let third = B.run(&state, .key(.escape))
        #expect(state.cursor == nil)
        #expect(third == [.ring(nil)])

        let fourth = B.run(&state, .key(.escape))
        #expect(fourth == [.collapseBrain])
    }

    @Test("escape with nothing to undo collapses at once")
    func collapse() {
        var state = B.state()
        #expect(B.run(&state, .key(.escape)) == [.collapseBrain])
    }

    @Test("escape from the search field clears it and returns to the list before the ladder goes on")
    func searchEscape() {
        var state = B.state()
        B.run(&state, .key(.down), B.char("/"), .searchText("zzz"))
        #expect(state.list.visibleCount == 0)
        B.run(&state, .key(.escape))
        #expect(state.focus == .list && state.list.visibleCount == 14)
        #expect(state.cursor != nil)
        B.run(&state, .key(.escape))
        #expect(state.cursor == nil)
    }
}

@Suite("Neural browse mouse")
struct NeuralBrowseMouseTests {
    typealias B = BrowseFixtures

    @Test("a click sets the cursor, rings the node, scrolls to the row and focuses the list")
    func click() {
        var state = B.state()
        let id = B.id(state, 4)
        let effects = B.run(&state, .click(id, double: false))
        #expect(state.cursor == id)
        #expect(effects.contains(.scrollTo(id)) && effects.contains(NeuralBrowse.ring(id, state.list)) && effects.contains(.focusList))
        #expect(state.focus == .list)
    }

    @Test("a double click sets the cursor and moves focus into the readout")
    func doubleClick() {
        var state = B.state()
        let id = B.id(state, 4)
        let effects = B.run(&state, .click(id, double: true))
        #expect(state.cursor == id && state.focus == .readout)
        #expect(effects.contains(.focusReadout))
    }

    @Test("a click on a step the turn lacks does nothing")
    func clickUnknown() {
        var state = B.state()
        #expect(B.run(&state, .click("nope", double: false)).isEmpty)
        #expect(state.cursor == nil)
    }

    @Test("a click on a node the filters dim clears the filters so the row shows")
    func clickDimmed() {
        var state = B.state()
        B.run(&state, B.char("4"))
        let hidden = B.id(state, 0)
        let effects = B.run(&state, .click(hidden, double: false))
        #expect(!state.list.filter.isActive)
        #expect(state.cursor == hidden)
        #expect(effects.contains(.dim([])))
    }

    @Test("hover is a preview: it rings its node and never moves the cursor, and leaving rings the cursor again")
    func hover() {
        var state = B.state()
        B.run(&state, .click(B.id(state, 2), double: false))
        let cursor = state.cursor
        let entered = B.run(&state, .hover(B.id(state, 7)))
        #expect(entered == [B.ring(state, 7)])
        #expect(state.cursor == cursor)
        #expect(state.hovered == B.id(state, 7))
        #expect(state.previewed == B.id(state, 7))
        let left = B.run(&state, .hoverLeft)
        #expect(left == [NeuralBrowse.ring(cursor, state.list)])
        #expect(state.hovered == nil && state.previewed == cursor)
        #expect(B.run(&state, .hoverLeft).isEmpty)
        var bare = B.state()
        B.run(&bare, .hover(B.id(bare, 3)))
        #expect(B.run(&bare, .hoverLeft) == [.ring(nil)])
        #expect(B.run(&bare, .hover("nope")).isEmpty)
    }

    @Test("a zone chip toggles its filter, and solos it with shift or a double click")
    func zoneChip() {
        var state = B.state()
        B.run(&state, .zoneChip(.shell, solo: false), .zoneChip(.act, solo: false))
        #expect(state.list.filter.zones == [.shell, .act])
        B.run(&state, .zoneChip(.sense, solo: true))
        #expect(state.list.filter.zones == [.sense])
        B.run(&state, .zoneChip(.sense, solo: true))
        #expect(state.list.filter.zones.isEmpty)
        B.run(&state, .zoneChip(.shell, solo: false), .zoneChip(.shell, solo: false))
        #expect(state.list.filter.zones.isEmpty)
    }

    @Test("the failed toggle and the search field filter, and each change dims the head and counts")
    func filters() {
        var state = B.state()
        let failed = B.run(&state, .failedToggle)
        #expect(failed == [.dim(state.list.hiddenIDs), .announce("1 of 14")])
        let typed = B.run(&state, .searchText("make"))
        #expect(state.searchOpen)
        #expect(typed.contains(.dim(state.list.hiddenIDs)))
        #expect(B.run(&state, .searchText("make")).isEmpty)
    }

    @Test("filters dim exactly the head's other nodes")
    func dimming() {
        var state = B.state()
        let effects = B.run(&state, B.char("5"))
        let hidden = Set([0, 1, 2, 3, 4, 6, 7, 8, 9, 12].map { B.id(state, $0) })
        #expect(effects.contains(.dim(hidden)))
    }

    @Test("a context menu offers the six items, Go to related only where there is one")
    func contextMenu() {
        var state = B.state()
        let withRelated = B.run(&state, .contextMenu(B.id(state, 5)))
        #expect(withRelated == [.showMenu(B.id(state, 5), NeuralBrowse.MenuItem.allCases)])
        let without = B.run(&state, .contextMenu(B.id(state, 11)))
        #expect(without == [.showMenu(B.id(state, 11), [.copySubject, .copyOutput, .copyMarkdown, .showOnlyThisZone, .showInRows])])
        #expect(state.cursor == nil)
        #expect(B.run(&state, .contextMenu("nope")).isEmpty)
    }

    @Test("each menu item does what it names")
    func menu() {
        var state = B.state()
        let id = B.id(state, 5)
        #expect(B.run(&state, .menu(.copySubject, id)) == [.copySubject(id)])
        #expect(B.run(&state, .menu(.copyOutput, id)) == [.copyOutput(id)])
        #expect(B.run(&state, .menu(.copyMarkdown, id)) == [.copyMarkdown(id)])
        #expect(B.run(&state, .menu(.showInRows, id)) == [.showInRows(id)])
        B.run(&state, .menu(.showOnlyThisZone, id))
        #expect(state.list.filter.zones == [.shell])
        B.run(&state, .menu(.goToRelated, id))
        #expect(state.cursor == B.id(state, 10))
    }

    @Test("the words a menu and the legend speak are real and the legend lists every key")
    func words() {
        for item in NeuralBrowse.MenuItem.allCases { #expect(!NeuralBrowse.title(of: item).isEmpty) }
        #expect(NeuralBrowse.legend.count == 16)
        #expect(NeuralBrowse.legend.allSatisfy { !$0.keys.isEmpty && !$0.does.isEmpty })
        #expect(NeuralBrowse.hint == "up down browse \u{00B7} / filter \u{00B7} c copy \u{00B7} ? keys")
    }

    @Test("the text a copy puts on the pasteboard is the step's subject, output and Markdown")
    func copyText() {
        let model = BrainFixtures.model(BrainFixtures.buildFix())
        let build = model.steps[5]
        #expect(NeuralBrowse.subjectText(of: build) == "swift build -c release 2>&1 | tail -20")
        #expect(NeuralBrowse.outputText(of: build).contains("error: switch must be exhaustive"))
        let markdown = NeuralBrowse.markdown(of: build)
        #expect(markdown.hasPrefix("### 6. Bash\n"))
        #expect(markdown.contains("```\nswift build -c release 2>&1 | tail -20\n```"))
        #expect(markdown.contains("note: add missing case"))
        let thought = NeuralBrowse.markdown(of: model.steps[0])
        #expect(thought.contains("Thinking") && !thought.contains("```"))
    }
}

@Suite("Neural browse following")
struct NeuralBrowseFollowingTests {
    typealias B = BrowseFixtures

    private func live() -> NeuralBrowse.State {
        B.state(NeuralTurn(id: "t", steps: StepListFixtures.synthetic(12, running: true), outcome: .running), live: true)
    }

    @Test("a live list follows, scrolls to the newest step when one arrives, and a settled one does not")
    func follows() {
        var state = live()
        #expect(state.list.isFollowing)
        let effects = B.run(&state, .liveStepArrived)
        #expect(effects == [.scrollTo(state.list.rows[11].id)])
        var settled = B.state()
        #expect(B.run(&settled, .liveStepArrived).isEmpty)
    }

    @Test("a manual scroll pauses following and a programmatic one does not")
    func scrollPauses() {
        var state = live()
        #expect(B.run(&state, .scrolled(manual: false)).isEmpty)
        #expect(state.list.isFollowing)
        B.run(&state, .scrolled(manual: true))
        #expect(!state.list.isFollowing && state.list.showsFollowPill)
        #expect(B.run(&state, .liveStepArrived).isEmpty)
    }

    @Test("setting a cursor pauses following, by key or by click")
    func cursorPauses() {
        var state = live()
        B.run(&state, .key(.down))
        #expect(state.list.showsFollowPill)
        var clicked = live()
        B.run(&clicked, .click(B.id(clicked, 3), double: false))
        #expect(clicked.list.showsFollowPill)
    }

    @Test("End and the pill resume following and go to the newest step")
    func resume() {
        var state = live()
        B.run(&state, .scrolled(manual: true))
        let end = B.run(&state, .key(.end))
        #expect(state.list.isFollowing)
        #expect(end.contains(.scrollTo(state.list.rows[11].id)))
        B.run(&state, .key(.up))
        #expect(state.list.showsFollowPill)
        let pill = B.run(&state, .jumpToLatest)
        #expect(state.list.isFollowing)
        #expect(pill == [.scrollTo(state.list.rows[11].id)])
        B.run(&state, .key(.home))
        B.run(&state, .scrolled(manual: true))
        B.run(&state, B.char("G"))
        #expect(state.list.isFollowing)
    }

    @Test("End on a settled turn goes to the last step and follows nothing")
    func settledEnd() {
        var state = B.state()
        B.run(&state, .key(.end))
        #expect(B.at(state, 13))
        #expect(!state.list.isFollowing && !state.list.showsFollowPill)
        #expect(B.run(&state, .jumpToLatest).isEmpty)
    }

    @Test("while following with a filter the newest visible row is the one scrolled to")
    func followFiltered() {
        var state = live()
        B.run(&state, B.char("2"))
        B.run(&state, .jumpToLatest)
        let effects = B.run(&state, .liveStepArrived)
        #expect(effects == [.scrollTo(state.list.lastVisibleID!)])
    }
}

@Suite("Neural browse and the model")
struct NeuralBrowseModelTests {
    typealias F = ReadoutFixtures

    @Test("the cursor is the model's pin, so the head's ring, the leader and the readout follow the list")
    func cursorIsPin() {
        var model = F.model()
        let effects = model.browse(.key(.down))
        #expect(model.pinned == model.steps[0].id)
        #expect(model.pinnedStep == model.steps[0].id)
        #expect(effects.contains(NeuralBrowse.ring(model.steps[0].id, model.stepList)))
        model.browse(.key(.down))
        #expect(model.pinnedStep == model.steps[1].id)
        #expect(model.readoutSubject(now: 0) == .step(model.steps[1].id))
        model.browse(.key(.escape))
        #expect(model.pinned == nil)
        #expect(model.readoutSubject(now: 0) == .digest)
    }

    @Test("a pin made by the old toggle is the list's cursor")
    func pinIsCursor() {
        var model = F.model()
        model.togglePin(model.steps[6].id)
        model.browse(.key(.down))
        #expect(model.pinnedStep == model.steps[7].id)
        model.togglePin(model.steps[7].id)
        #expect(model.pinned == nil)
        model.browse(.key(.up))
        #expect(model.pinnedStep == model.steps[13].id)
    }

    @Test("a hover previews its step in the readout and leaving returns to the cursor, then to the digest")
    func hoverPreview() {
        var model = F.model()
        model.browse(.click(model.steps[2].id, double: false))
        model.browse(.hover(model.steps[8].id))
        #expect(model.pinnedStep == model.steps[2].id)
        #expect(model.previewedStep == model.steps[8].id)
        #expect(model.readoutSubject(now: 0) == .step(model.steps[8].id))
        model.browse(.hoverLeft)
        #expect(model.readoutSubject(now: 0) == .step(model.steps[2].id))
        model.browse(.key(.escape))
        #expect(model.readoutSubject(now: 0) == .digest)
    }

    @Test("with the pointer's grace driving the hover, the cursor returns when it ends")
    func graceReturnsToCursor() {
        var model = F.model()
        model.browse(.click(model.steps[2].id, double: false))
        model.pointer(over: model.steps[8].id, at: 0)
        #expect(model.readoutSubject(now: 0.1) == .step(model.steps[8].id))
        model.pointer(over: nil, at: 1)
        #expect(model.readoutSubject(now: 1.2) == .step(model.steps[8].id))
        #expect(model.readoutSubject(now: 1.5) == .step(model.steps[2].id))
    }

    @Test("a live turn raises the scroll-to-newest effect when a step arrives, and drains it once")
    func liveArrives() {
        let turn = { (count: Int) in
            NeuralTurns.partition(
                messages: [NeuralTurnFixtures.user(0)] + (1...count).map { n in
                    NeuralTurnFixtures.message(n, [NeuralTurnFixtures.bash("c\(n)", out: ["x"])], streaming: n == count)
                }, running: true)[0]
        }
        var model = F.model(turn(3))
        #expect(model.drainBrowseEffects().isEmpty)
        model.update(turn: turn(4), context: .none)
        let effects = model.drainBrowseEffects()
        #expect(effects == [.scrollTo(model.steps[3].id)])
        #expect(model.drainBrowseEffects().isEmpty)
        model.browse(.key(.down))
        model.update(turn: turn(5), context: .none)
        #expect(model.drainBrowseEffects().isEmpty)
        #expect(model.stepList.total == 5)
    }

    @Test("a hover on a step that leaves the turn is forgotten")
    func vanishing() {
        var model = F.model()
        model.browse(.hover(model.steps[3].id))
        model.update(turn: BrainFixtures.turn(), context: .none)
        #expect(model.browseState.hovered == nil)
    }
}


@Suite("Neural browse callouts and ganglia")
struct NeuralBrowseGangliaTests {
    typealias B = BrowseFixtures

    private func model() -> NeuralBrainModel { ReadoutFixtures.model(BrainFixtures.turn()) }

    @Test("the ring names the step, its node and the number the callout shows")
    func callout() {
        var state = B.state()
        let effects = B.run(&state, .click(B.id(state, 6), double: false))
        let ring = effects.compactMap { effect -> NeuralBrowse.Ring? in
            if case .ring(let ring) = effect { return ring }
            return nil
        }.first
        #expect(ring == NeuralBrowse.Ring(stepID: B.id(state, 6), nodeID: B.id(state, 6), calloutNumber: 7))
        let hovered = B.run(&state, .hover(B.id(state, 12)))
        #expect(hovered == [.ring(NeuralBrowse.Ring(stepID: B.id(state, 12), nodeID: B.id(state, 12), calloutNumber: 13))])
    }

    @Test("a cursor on a member of a ganglion rings the '+7' node but numbers its own step")
    func memberRing() throws {
        var model = model()
        let ganglion = try #require(model.layout.ganglia.first { $0.zone == .shell })
        let member = ganglion.members[4]
        let number = try #require(model.stepList.row(id: member)?.number)
        let effects = model.browse(.click(member, double: false))
        #expect(effects.contains(.ring(NeuralBrowse.Ring(stepID: member, nodeID: ganglion.leader, calloutNumber: number))))
        #expect(model.pinned == ganglion.leader && model.pinnedStep == member)
        let hover = model.browse(.hover(ganglion.members[2]))
        #expect(hover.count == 1)
        guard case .ring(let ring?) = hover[0] else {
            Issue.record("expected a ring")
            return
        }
        #expect(ring.nodeID == ganglion.leader && ring.stepID == ganglion.members[2])
    }

    @Test("clicking the '+7' node selects the first failed member and solos that zone")
    func clickGanglionFailed() throws {
        var model = model()
        let ganglion = try #require(model.layout.ganglia.first { $0.zone == .shell })
        let failed = try #require(ganglion.members.first { model.stepList.row(id: $0)?.isFailure == true })
        let effects = model.browse(.clickNode(ganglion.leader, double: false))
        #expect(model.pinnedStep == failed)
        #expect(model.pinned == ganglion.leader)
        #expect(model.stepList.filter.zones == [.shell])
        #expect(effects.contains(.scrollTo(failed)))
        #expect(effects.contains(.dim(model.stepList.hiddenIDs)))
        #expect(model.readoutSubject(now: 0) == .step(failed))
        #expect(failed != ganglion.leader)
    }

    @Test("a ganglion with no failed member selects its first, and the list is the road to the others")
    func clickGanglionFirst() throws {
        var state = B.state(NeuralTurn(id: "t", steps: StepListFixtures.synthetic(60)))
        let members = ["m4:p0", "m4:p1", "m5:p0"]
        let clean = members.filter { id in state.list.row(id: id)?.isFailure == false }
        #expect(clean.count == 3)
        state.list.setGanglia(["m4:p0": members])
        B.run(&state, .clickNode("m4:p0", double: false))
        #expect(state.cursor == "m4:p0")
        #expect(state.list.filter.zones == [state.list.row(id: "m4:p0")!.zone])
        B.run(&state, .click("m5:p0", double: false))
        #expect(state.cursor == "m5:p0")
        #expect(state.list.isVisible("m5:p0") || state.list.row(id: "m5:p0") != nil)
    }

    @Test("a click on an ordinary node is a row's click, and a row click on the leader selects only the leader")
    func ordinary() throws {
        var model = model()
        let ganglion = try #require(model.layout.ganglia.first { $0.zone == .shell })
        model.browse(.clickNode(model.steps[0].id, double: false))
        #expect(model.pinnedStep == model.steps[0].id)
        #expect(!model.stepList.isFiltered)
        model.browse(.click(ganglion.leader, double: false))
        #expect(model.pinnedStep == ganglion.leader)
        #expect(!model.stepList.isFiltered)
    }

    @Test("the model hands its ganglia to the list, and a hit on the '+7' node is the leader")
    func hit() throws {
        let model = model()
        let ganglion = try #require(model.layout.ganglia.first { $0.zone == .shell })
        #expect(model.stepList.ganglionMembers(of: ganglion.leader) == ganglion.members)
        #expect(model.stepList.nodeID(of: ganglion.members[3]) == ganglion.leader)
        #expect(model.stepList.nodeID(of: model.steps[0].id) == model.steps[0].id)
        let metrics = NeuralStageMetrics.make(width: 1280, density: .comfortable)
        let row = metrics.point(forDesign: try #require(model.point(of: ganglion.leader)))
        #expect(model.hit(atRow: row, in: metrics, slopPoints: 2) == ganglion.leader)
    }
}

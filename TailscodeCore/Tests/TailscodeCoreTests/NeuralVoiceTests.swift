import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural voice: browse")
struct NeuralVoiceBrowseTests {
    typealias A = AccountFixtures
    typealias B = BrowseFixtures

    private func state() -> (NeuralBrowse.State, NeuralBrainModel) {
        let model = A.model()
        return (B.state(model.turn), model)
    }

    @Test("s and S jump to the next and previous thing it said, announce 'said N of M', and never wrap")
    func saidKeys() {
        var (state, model) = state()
        let first = model.steps[3].id
        let second = model.steps[7].id
        let effects = B.run(&state, B.char("s"))
        #expect(state.cursor == first)
        #expect(effects.contains(.announce("said 1 of 2")))
        #expect(effects.contains(.scrollTo(first)))
        B.run(&state, B.char("s"))
        #expect(state.cursor == second)
        let atEnd = B.run(&state, B.char("s"))
        #expect(state.cursor == second && atEnd.isEmpty)
        B.run(&state, B.char("S"))
        #expect(state.cursor == first)
        let atStart = B.run(&state, B.char("S"))
        #expect(state.cursor == first && atStart.isEmpty)
        B.run(&state, .key(.end), B.char("S"))
        #expect(state.cursor == second)
    }

    @Test("s walks the visible rows: with SAID soloed it is the transcript of what it said")
    func saidSolo() {
        var (state, model) = state()
        B.run(&state, .zoneChip(.say, solo: true))
        #expect(state.list.visibleCount == 2)
        B.run(&state, B.char("j"))
        #expect(state.cursor == model.steps[3].id)
        B.run(&state, B.char("j"))
        #expect(state.cursor == model.steps[7].id)
        B.run(&state, B.char("1"))
        #expect(state.list.filter.zones.isEmpty)
        B.run(&state, B.char("1"))
        #expect(state.list.filter.zones == [.say])
    }

    @Test("a goes to the ask when one is pending, raising goToAsk, and says so when none is")
    func askKey() {
        let (turn, id) = ReadoutFixtures.waitingTurn()
        var state = B.state(turn, live: true)
        let effects = B.run(&state, B.char("a"))
        #expect(state.cursor == id)
        #expect(effects.contains(.scrollTo(id)))
        #expect(state.outbox == [.goToAsk(id)])
        var calm = B.state(A.model().turn)
        let none = B.run(&calm, B.char("a"))
        #expect(none == [.announce("Nothing is waiting on you")])
        #expect(calm.cursor == nil && calm.outbox.isEmpty)
        var hidden = B.state(turn, live: true)
        B.run(&hidden, B.char("2"))
        B.run(&hidden, B.char("a"))
        #expect(hidden.cursor == id)
        #expect(!hidden.list.filter.isActive)
    }

    @Test("copy(item) copies a said or thought item's whole words and a call's subject")
    func copyItem() {
        var (state, model) = state()
        let said = model.steps[3].id
        let tool = model.steps[1].id
        #expect(B.run(&state, .copyItem(said)) == [.copyOutput(said)])
        #expect(B.run(&state, .copyItem(model.steps[0].id)) == [.copyOutput(model.steps[0].id)])
        #expect(B.run(&state, .copyItem(tool)) == [.copySubject(tool)])
        #expect(B.run(&state, .copyItem("nope")).isEmpty)
        #expect(NeuralBrowse.outputText(of: model.steps[3]) == model.steps[3].text)
    }

    @Test("reply(item) offers a quote to the composer and sends nothing, only for words the agent said")
    func reply() {
        var (state, model) = state()
        let effects = B.run(&state, .reply(model.steps[3].id))
        #expect(effects.isEmpty)
        #expect(state.outbox == [.reply(quote: "> Building it from the existing film rig; checking the iOS footage first.\n\n")])
        state.outbox = []
        B.run(&state, .reply(model.steps[0].id))
        #expect(state.outbox == [.reply(quote: "> Plan it.\n> Second line.\n\n")])
        state.outbox = []
        B.run(&state, .reply(model.steps[1].id), .reply("nope"))
        #expect(state.outbox.isEmpty)
        let blank = NeuralStep(id: "a:b", index: 0, zone: .say, group: 0, messageID: "a", title: "Said", text: "one\n\ntwo\n")
        #expect(NeuralBrowse.replyQuote(of: blank) == "> one\n>\n> two\n\n")
    }

    @Test("the model drains the account effects once")
    func drain() {
        var model = A.model()
        model.browse(.reply(model.steps[3].id))
        #expect(model.drainAccountEffects() == [.reply(quote: "> Building it from the existing film rig; checking the iOS footage first.\n\n")])
        #expect(model.drainAccountEffects().isEmpty)
        let (turn, id) = ReadoutFixtures.waitingTurn()
        var waiting = BrainFixtures.model(turn)
        waiting.browse(.key(.character("a")))
        #expect(waiting.drainAccountEffects() == [.goToAsk(id)])
        #expect(waiting.pinnedStep == id)
    }

    @Test("the legend names s S and a, and the keys stay in a model that was never given an account")
    func legend() {
        let keys = NeuralBrowse.legend.map(\.keys)
        #expect(keys.contains("s S") && keys.contains("a"))
        #expect(NeuralBrowse.legend.first { $0.keys == "s S" }?.does == "Next, previous thing it said")
        #expect(NeuralBrowse.legend.first { $0.keys == "a" }?.does == "Go to what it is waiting for")
    }
}

@Suite("Neural voice: the cursor on an utterance")
struct NeuralVoiceCursorTests {
    typealias A = AccountFixtures

    @Test("a said or thought step is a first-class step: cursor, ring, readout and account agree")
    func cursorOnSaid() throws {
        var model = A.model()
        let said = model.steps[3].id
        let effects = model.browse(.click(said, double: false))
        #expect(model.pinnedStep == said)
        #expect(effects.contains(.ring(NeuralBrowse.Ring(stepID: said, nodeID: said, calloutNumber: 4))))
        #expect(model.readoutSubject(now: 0) == .step(said))
        let readout = model.readout(now: Date(), tz: A.utc)
        #expect(readout.step?.subject.kind == .note)
        #expect(readout.step?.header.zone == .say)
        #expect(readout.leaderStepID == said)
        let account = model.account(tz: A.utc)
        #expect(account.item(containing: said)?.id == "said:" + said)
        #expect(model.stepList.row(id: said)?.isSaid == true)
        #expect(model.point(of: said) != nil)
        model.browse(.click(model.steps[0].id, double: false))
        #expect(model.account(tz: A.utc).item(containing: model.pinnedStep ?? "")?.id == "thought:" + model.steps[0].id)
    }

    @Test("the SAY node can be hit, hovered and walked to like any node")
    func sayNode() throws {
        var model = A.model()
        let said = model.steps[3].id
        let metrics = NeuralStageMetrics.make(width: 1280, density: .comfortable)
        let row = metrics.point(forDesign: try #require(model.point(of: said)))
        #expect(model.hit(atRow: row, in: metrics, slopPoints: 2) == said)
        let hover = model.browse(.hover(said))
        #expect(hover == [.ring(NeuralBrowse.Ring(stepID: said, nodeID: said, calloutNumber: 4))])
        model.browse(.hoverLeft)
        model.browse(.key(.character("s")))
        #expect(model.pinnedStep == said)
    }
}

@Suite("Neural voice: labels")
struct NeuralVoiceLabelTests {
    @Test("the voice is SAID wherever it names itself as a filter, chip or bar, and SAY on the head")
    func labels() {
        #expect(NeuralZone.say.voiceLabel == "SAID")
        #expect(NeuralZone.say.label == "SAY")
        for zone in NeuralZone.allCases where zone != .say {
            #expect(zone.voiceLabel == zone.label)
            #expect(zone.displayLabel == zone.label)
        }
        let model = BrainFixtures.model(BrainFixtures.turn())
        #expect(model.stepList.zoneChips.first { $0.zone == .say }?.label == "SAID")
        #expect(model.brainCard(now: Date()).chips.first { $0.zone == .say }?.label == "SAID")
        let digest = model.readout(now: Date(), tz: AccountFixtures.utc).digest
        #expect(digest?.zoneBars.first { $0.zone == .say }?.label == "SAID")
        var list = model.stepList
        list.setSearch("said")
        #expect(list.visibleCount >= model.steps.filter { $0.zone == .say }.count)
    }
}

@Suite("Neural voice: the card's quote")
struct NeuralVoiceCardTests {
    typealias A = AccountFixtures

    @Test("a turn that said something has the agent's first words as its quote, with the speaker")
    func quote() {
        let model = A.model()
        let card = model.brainCard(now: Date())
        #expect(card.hasQuote)
        #expect(card.quote?.speaker == "Fable")
        #expect(card.quote?.words == "Building it from the existing film rig; checking the iOS footage first.")
        #expect(card.quoteLine(fittingChars: 200) == "Fable: Building it from the existing film rig; checking the iOS footage first.")
        #expect(card.thirdLine(fittingChars: 200) == card.quoteLine(fittingChars: 200))
        let cut = card.quoteLine(fittingChars: 40) ?? ""
        #expect(cut.hasPrefix("Fable: ") && cut.hasSuffix("\u{2026}") && cut.count <= 41)
        let words = cut.dropFirst(7).dropLast()
        #expect("Building it from the existing film rig; checking the iOS footage first.".hasPrefix(String(words)))
        #expect(!cut.contains("\n"))
    }

    @Test("a turn that said nothing keeps the generated sentence as its third line")
    func fallback() {
        let card = BrainFixtures.model(BrainFixtures.buildFix()).brainCard(now: Date())
        #expect(!card.hasQuote && card.quoteLine(fittingChars: 80) == nil)
        #expect(card.thirdLine(fittingChars: 200) == card.digest)
        #expect(card.thirdLine(fittingChars: 29) == "Ran 4 commands, read 3 files.")
    }

    @Test("the quote is fitted like the digest: it goes under 380, with the picture, headline, Replay and Rows staying")
    func fit() {
        let card = A.model().brainCard(now: Date())
        let always: Set<NeuralBrainCard.Part> = [.picture, .headline, .replay, .rows]
        #expect(card.fit(width: 800) == always.union([.zoneStrip, .digest]))
        #expect(card.fit(width: 380) == always.union([.digest]))
        #expect(card.fit(width: 379) == always)
        let silent = BrainFixtures.model(BrainFixtures.buildFix()).brainCard(now: Date())
        #expect(silent.fit(width: 800).contains(.digest))
    }
}

@Suite("Neural voice: said rows")
struct NeuralVoiceListTests {
    typealias A = AccountFixtures
    typealias F = StepListFixtures

    private func list() -> NeuralStepList { NeuralStepList(steps: A.model().turn.steps) }

    @Test("a said row is a message two lines tall with its first two lines, a thought one muted line")
    func rows() {
        let list = list()
        let said = list.rows[3]
        #expect(said.kind == .said && said.kind == .note && said.isSaid)
        #expect(said.height() == 40 && said.height(input: .touch) == 48)
        #expect(said.lines == ["Building it from the existing film rig; checking the iOS footage first."])
        let long = list.rows[7]
        #expect(long.lines == ["line 1 of the second note", "line 2 of the second note"])
        let thought = list.rows[0]
        #expect(thought.isMuted && !thought.isSaid && thought.lines == ["Plan it."])
        #expect(thought.height() == 28 && thought.height(input: .touch) == 32)
        #expect(list.rows[1].lines.isEmpty && list.rows[1].height() == 28)
        #expect(NeuralStepList.rowHeight(for: said) == 40)
    }

    @Test("offsets add the rows' own heights, and a binary search finds the rows of a window")
    func offsets() {
        let list = list()
        let heights = list.rows.map { $0.height() }
        #expect(list.contentHeight() == heights.reduce(0, +))
        #expect(list.contentHeight(input: .touch) == list.rows.map { $0.height(input: .touch) }.reduce(0, +))
        var running = 0.0
        for (position, height) in heights.enumerated() {
            #expect(list.offset(ofVisible: position) == running)
            #expect(list.position(atOffset: running) == position)
            #expect(list.position(atOffset: running + height - 0.5) == position)
            running += height
        }
        #expect(list.position(atOffset: -10) == 0)
        #expect(list.position(atOffset: 10_000) == heights.count - 1)
        let range = list.visibleRange(offset: list.offset(ofVisible: 2) + 5, height: 100)
        #expect(range.lowerBound == 2)
        let covered = (list.offset(ofVisible: range.upperBound - 1) + heights[range.upperBound - 1])
        #expect(covered >= list.offset(ofVisible: 2) + 5 + 100 - 0.01 || range.upperBound == heights.count)
        #expect(list.rows(atOffset: 0, height: 60).map(\.index) == Array(list.visibleRange(offset: 0, height: 60)))
        #expect(list.visibleRange(offset: 0, height: 0).count <= 1)
    }

    @Test("filters rebuild the offsets over the rows that show")
    func filtered() {
        var list = list()
        list.soloZone(.say)
        #expect(list.visibleCount == 2)
        #expect(list.contentHeight() == 80)
        #expect(list.offset(ofVisible: 1) == 40)
        #expect(list.position(atOffset: 41) == 1)
        list.clearFilters()
        #expect(list.visibleCount == 9)
        #expect(NeuralStepList(steps: []).contentHeight() == 0)
        #expect(NeuralStepList(steps: []).visibleRange(offset: 0, height: 100) == 0..<0)
    }

    @Test("said counts and the walk over the visible rows, and the pending ask")
    func said() {
        let list = list()
        #expect(list.saidCount == 2)
        #expect(list.saidStep(from: nil, forward: true) == list.rows[3].id)
        #expect(list.saidStep(from: nil, forward: false) == list.rows[7].id)
        #expect(list.saidStep(from: list.rows[3].id, forward: true) == list.rows[7].id)
        #expect(list.saidStep(from: list.rows[7].id, forward: true) == nil)
        #expect(list.saidStep(from: list.rows[3].id, forward: false) == nil)
        #expect(list.saidOrdinal(of: list.rows[7].id) == 2)
        #expect(list.saidOrdinal(of: list.rows[1].id) == nil)
        #expect(list.pendingAskID == nil)
        #expect(NeuralStepList(steps: ReadoutFixtures.waitingTurn().turn.steps).pendingAskID == "m2:p0")
    }

    @Test("a 2,000-step turn with messages in it windows by offset in the time of the window")
    func microbenchmark() {
        let steps = F.synthetic(2_000)
        let list = NeuralStepList(steps: steps)
        let total = list.contentHeight()
        #expect(total > 2_000 * 28 && total < 2_000 * 40)
        let clock = ContinuousClock()
        var sink = 0
        let rounds = 2_000
        let elapsed = clock.measure {
            for round in 0..<rounds {
                let offset = Double((round * 37) % 40_000) + 3
                sink &+= list.rows(atOffset: offset, height: 840).count
            }
        }
        #expect(sink > rounds * 15)
        let parts = elapsed.components
        let each = (Double(parts.seconds) + Double(parts.attoseconds) / 1e18) / Double(rounds)
        #expect(each < 0.002, "debug build: \(each * 1000) ms per window")
        print("NEURAL-OFFSETS rows(atOffset:) 840-point window of 2000 steps with messages: \(each * 1000) ms")
        let window = list.rows(atOffset: 20_000, height: 840)
        let bottom = list.offset(ofVisible: window.count > 0 ? list.position(atOffset: 20_000) + window.count : 0)
        #expect(bottom >= 20_000 + 840 - 0.01)
        #expect(window.first.map { list.offset(ofVisible: $0.index) <= 20_000 } == true)
    }
}

@Suite("Neural voice: the filters put SAID first")
struct NeuralVoiceFilterTests {
    @Test("1 is SAID and 2 to 6 are PLAN, SENSE, ACT, SHELL and DELEGATE, and the chips take the same order")
    func keysAndChips() {
        #expect(NeuralZone.filterOrder == [.say, .think, .sense, .act, .shell, .delegate])
        #expect(NeuralZone.filterOrder.map(\.filterKey) == [1, 2, 3, 4, 5, 6])
        #expect(NeuralZone.say.filterKey == 1 && NeuralZone.delegate.filterKey == 6)
        let turn = BrainFixtures.turn()
        for (digit, zone) in zip("123456", NeuralZone.filterOrder) {
            var state = BrowseFixtures.state(turn)
            BrowseFixtures.run(&state, BrowseFixtures.char(digit))
            #expect(state.list.filter.zones == [zone], "key \(digit)")
        }
        let model = BrainFixtures.model(turn)
        #expect(model.stepList.zoneChips.map(\.zone) == NeuralZone.filterOrder)
        #expect(model.stepList.zoneChips.first?.label == "SAID")
        #expect(model.stepList.zoneChips.first?.count == model.steps.filter { $0.zone == .say }.count)
        #expect(model.brainCard(now: Date()).chips.map(\.zone) == NeuralZone.filterOrder)
        let silent = BrainFixtures.model(BrainFixtures.buildFix())
        #expect(silent.stepList.zoneChips.map(\.zone) == [.think, .sense, .act, .shell, .delegate])
        var state = BrowseFixtures.state(BrainFixtures.buildFix())
        #expect(BrowseFixtures.run(&state, BrowseFixtures.char("1")).isEmpty)
    }

    @Test("the SAY label box is wide enough for SAID")
    func labelBox() {
        #expect(NeuralZone.say.labelHalfWidth == 28)
        #expect(NeuralZone.say.labelRect.width == 56)
    }
}

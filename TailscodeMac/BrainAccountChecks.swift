import AppKit
import CodingAgentKit
import TailscodeCore

/// The checks of the account: its layout at every width, its wiring to the model and the host, its
/// keys through Core's reducer, what it says, and what it costs on a turn of two thousand steps.
@MainActor
enum BrainAccountChecks {
    typealias Expect = (Bool, String) throws -> Void

    static func run(_ expect: Expect) throws -> Int {
        var count = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ label: String) throws {
            if condition { count += 1 } else { failures.append(label) }
        }
        try layouts(check)
        try wiring(check)
        try keys(check)
        try words(check)
        try live(check)
        try scale(check)
        try takeover(check)
        try paintsAfterMove(check)
        try expect(failures.isEmpty, "account: " + failures.joined(separator: " | "))
        return count
    }


    private static func rowWidth(_ fixture: BrainFixture) -> CGFloat { fixture.root.frame.width - 48 }

    private static func opened(_ fixture: BrainFixture, _ index: Int) -> (BrainRowView, BrainAccountView)? {
        guard let row = fixture.open(index), let account = row.account else { return nil }
        settle(row)
        return (row, account)
    }

    /// Lets the row lay out and the account read and make what is near its viewport.
    private static func settle(_ row: BrainRowView) {
        row.superview?.layoutSubtreeIfNeeded()
        row.layoutSubtreeIfNeeded()
        guard let account = row.account else { return }
        account.refresh(immediate: true)
        account.layoutSubtreeIfNeeded()
        account.realize()
        account.layoutSubtreeIfNeeded()
    }

    /// The reveal a cursor asked for, settled: the items near it made and measured, the offset put on
    /// their real place.
    private static func reveal(_ account: BrainAccountView) {
        account.holdAnchor = nil
        for _ in 0..<4 {
            account.realize()
            account.settleReveal()
        }
        account.realize()
        account.pendingReveal = nil
    }

    private static func spin(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func key(_ characters: String, code: UInt16 = 0, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private enum Named {
        static let up: (String, UInt16) = ("\u{F700}", 126)
        static let down: (String, UInt16) = ("\u{F701}", 125)
        static let pageDown: (String, UInt16) = ("\u{F72D}", 121)
        static let end: (String, UInt16) = ("\u{F72B}", 119)
        static let home: (String, UInt16) = ("\u{F729}", 115)
        static let space: (String, UInt16) = (" ", 49)
        static let escape: (String, UInt16) = ("\u{1B}", 53)
        static let enter: (String, UInt16) = ("\r", 36)
    }

    @discardableResult
    private static func press(_ named: (String, UInt16), on account: BrainAccountView) -> Bool {
        guard let window = account.window else { return false }
        account.focus()
        let event = key(named.0, code: named.1, in: window)
        return account.handleKey(event)
    }

    @discardableResult
    private static func press(_ character: String, on account: BrainAccountView) -> Bool {
        guard let window = account.window else { return false }
        account.focus()
        return account.handleKey(key(character, in: window))
    }

    private static func views(in view: NSView) -> Int {
        view.subviews.reduce(1) { $0 + views(in: $1) }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for child in view.subviews { found.append(contentsOf: find(type, in: child)) }
        return found
    }

    private static func firstStep(of entry: AccountEntry?) -> String? { entry?.stepIDs.first }

    private static func workValue(_ entry: AccountEntry) -> AccountEntry.Work {
        if case .work(let value) = entry.kind { return value }
        fatalError("not a work line")
    }

    private static func isThought(_ entry: AccountEntry) -> Bool {
        if case .thought = entry.kind { return true }
        return false
    }


    private static func layouts(_ check: (Bool, String) throws -> Void) throws {
        let wide = BrainFixture(width: 1420)
        defer { wide.tearDown() }
        guard let (row, account) = opened(wide, 0) else {
            try check(false, "the brain opens at 1420")
            return
        }
        let m = row.currentMetrics
        let frame = account.frame
        try check(
            abs(frame.width - m.readout.width) < 0.6 && abs(frame.minX - m.readout.x) < 0.6,
            "the account stands where Core puts the readout (\(frame) for \(m.readout))")
        try check(m.accountLayout == .split && account.isTwoColumns, "from 924 points the account has two columns")
        try check(account.detail != nil, "the detail column exists beside the story")
        if let detail = account.detailRect {
            try check(detail.width >= NeuralStageMetrics.detailMin - 0.6, "the detail column is at least 460 wide (\(detail.width))")
            try check(
                abs(account.storyRect.width - m.story.width) < 0.6
                    && m.story.width >= NeuralStageMetrics.storyMin && m.story.width <= NeuralStageMetrics.storySplitMax,
                "the story column is Core's (\(account.storyRect.width) for \(m.story.width))")
        }
        try check(abs(account.header.frame.height - 40) < 0.6, "the header is one 40 point row at 1420")
        try check(account.header.frame.width == frame.width, "the header spans the account")
        try check(!account.entries.isEmpty && !account.cells.isEmpty, "the story has items and some of them exist")
        try check(!account.footerStrip.isHidden, "a wide account keeps its key hints")
        try check(account.boxWidth <= m.story.width, "the story's measure fits its column")

        wide.resize(to: 1180)
        settle(row)
        let single = row.currentMetrics
        try check(
            single.arrangement == .split && single.accountLayout == .single && !account.isTwoColumns,
            "at 1180 the account is one column")
        try check(account.detail == nil, "one column holds the card in place and builds no detail")
        try check(
            abs(account.boxWidth - (min(single.readout.width, NeuralStageMetrics.storyMax) - 32)) < 0.6,
            "the story is held to 760 less its padding (\(account.boxWidth))")

        wide.resize(to: 1048)
        settle(row)
        try check(
            abs(account.frame.width - row.currentMetrics.readout.width) < 0.6,
            "at 1000 the account takes what the left column leaves")

        wide.resize(to: 700)
        settle(row)
        let narrow = row.currentMetrics
        try check(narrow.arrangement == .accordion && account.isAccordion, "under 860 the account is the list")
        try check(!account.narrowBar.isHidden, "a narrow account carries the list's search and count")
        try check(account.footerStrip.isHidden, "a narrow account drops the key hints")
        try check(abs(account.frame.width - narrow.width) < 0.6, "the narrow account fills the row's width")
        try check(abs(account.frame.height - row.narrowAccountHeight(narrow)) < 0.6, "the narrow account is as tall as the window allows")
        try check(account.header.frame.height > 40, "a narrow header wraps onto rows (\(account.header.frame.height))")
        try check(account.detail == nil, "a narrow account has no detail column")
        try check(account.scroll.frame.minY >= account.narrowBar.frame.maxY - 0.6, "the story sits under the narrow bar")

        wide.resize(to: 568)
        settle(row)
        try check(
            account.header.frame.height > 40 && account.boxWidth >= 120,
            "at 520 the header and the story still lay out (header \(account.header.frame.height), box \(account.boxWidth), row \(row.bounds.width))")
        let overflowing = find(AccountTextView.self, in: account).filter { $0.frame.maxX > account.bounds.width + 0.6 }
        try check(overflowing.isEmpty, "no words run past the account's edge at 520")

        wide.resize(to: 428)
        settle(row)
        try check(
            account.header.frame.height > 40 && account.boxWidth >= 120,
            "at 380 the header and the story still lay out (header \(account.header.frame.height), box \(account.boxWidth), row \(row.bounds.width))")
        let overflowing380 = find(AccountTextView.self, in: account).filter { $0.frame.maxX > account.bounds.width + 0.6 }
        try check(overflowing380.isEmpty, "no words run past the account's edge at 380")
        let clipped = account.cells.values.filter { $0.frame.maxX > account.document.bounds.width + 0.6 }
        try check(clipped.isEmpty, "no item of the story is wider than its document at 380 (\(clipped.count))")
    }


    private static func wiring(_ check: (Bool, String) throws -> Void) throws {
        let fixture = BrainFixture(width: 1200)
        defer { fixture.tearDown() }
        guard let (row, account) = opened(fixture, 1) else {
            try check(false, "the second brain opens")
            return
        }
        let model = row.model
        let reads = model.accountReads
        account.refresh(immediate: true)
        account.refresh(immediate: true)
        try check(row.model.accountReads == reads, "an unchanged model is not read again")
        let builds = account.buildCount
        account.refresh(immediate: true)
        account.realize()
        try check(account.buildCount == builds, "an unchanged account makes nothing again")

        let said = account.entries.compactMap { entry -> NeuralAccount.Said? in
            if case .said(let value) = entry.kind { return value }
            return nil
        }
        try check(!said.isEmpty, "the second turn has notes in its story")
        if let first = said.first {
            account.choose(first.stepID, fromAccount: true)
            try check(row.model.pinnedStep == first.stepID, "a press on a note sets the cursor to its step")
            account.hover(first.stepID)
            try check(row.model.browseState.hovered == first.stepID, "the pointer over a note previews its step")
            account.hover(nil)
            spin(0.05)
            try check(row.model.browseState.hovered == nil, "the pointer leaving a note lets go of the preview")
            if let cell = account.cells[first.id] as? AccountSaidCell {
                let buttons = find(AccountButton.self, in: cell).map(\.title)
                try check(
                    buttons.contains(NeuralReading.copyLabel) && buttons.contains(NeuralReading.replyLabel),
                    "the cursor note offers Copy and Reply (\(buttons))")
                let selectable = find(AccountTextView.self, in: cell).first
                try check(selectable?.isSelectable == true, "a note's words can be selected")
            } else {
                try check(false, "the cursor note exists as a cell")
            }

            let saved = NSPasteboard.general.string(forType: .string)
            account.copyItem(first.stepID)
            try check(
                NSPasteboard.general.string(forType: .string) == NeuralBrowse.outputText(of: row.model.step(id: first.stepID)!),
                "Copy puts the note's whole words on the pasteboard")
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }

            var quoted: String?
            fixture.store.replyQuote = { quoted = $0 }
            account.replyItem(first.stepID)
            try check(quoted?.hasPrefix("> ") == true, "Reply puts a quote in the composer and sends nothing")
            fixture.store.replyQuote = nil
        }

        if let step = account.entries.first(where: \.isWork)?.stepIDs.first {
            let before = account.scrollY
            account.choose(step, fromAccount: true)
            spin(0.3)
            try check(abs(account.scrollY - before) < 0.6, "a press inside the account does not scroll it")
        }

        account.host?.browse(.zoneChip(.say, solo: true), grabFocus: false)
        account.refresh(immediate: true)
        try check(
            account.entries.allSatisfy { $0.isSaid || isThought($0) || $0.isResult },
            "SAID solo makes the account the transcript of what the agent told you")
        account.host?.browse(.key(.escape), grabFocus: false)
        account.refresh(immediate: true)
        try check(account.entries.contains(where: \.isWork), "Esc clears the filter and the work comes back")
        account.host?.browse(.searchText("ffmpeg"), grabFocus: false)
        account.refresh(immediate: true)
        let searched = account.entries.filter { $0.isStory }.count
        try check(searched > 0 && searched < account.account.story.count, "a search narrows the story")
        account.host?.browse(.searchText(""), grabFocus: false)
        account.refresh(immediate: true)

        try check(
            account.followPill.accessibilityRole() == .button && account.accessibilityLabel() == AccountWords.accountLabel,
            "the account and its pill are labelled for a screen reader")
        let chips = find(AccountButton.self, in: account).filter { $0.style == .step }
        try check(!chips.isEmpty && chips.allSatisfy { $0.accessibilityLabel()?.isEmpty == false }, "step chips are labelled")

        let first = account.cells.values.compactMap { $0 as? AccountSaidCell }.first
        try check(first?.hoverStepID != nil && first?.pressStepID != nil, "a note answers hover and press")
    }


    private static func keys(_ check: (Bool, String) throws -> Void) throws {
        let fixture = BrainFixture(width: 1200)
        defer { fixture.tearDown() }
        guard let (row, account) = opened(fixture, 1) else {
            try check(false, "the brain opens for the keys")
            return
        }
        let story = account.entries.filter(\.isStory)
        guard story.count >= 3 else {
            try check(false, "the story has three items to walk")
            return
        }
        try check(press("j", on: account), "j is taken by the account")
        try check(row.model.pinnedStep == firstStep(of: story[0]), "j walks to the first item")
        press(Named.down, on: account)
        try check(row.model.pinnedStep == firstStep(of: story[1]), "Down walks to the next item")
        press("j", on: account)
        try check(row.model.pinnedStep == firstStep(of: story[2]), "j walks on")
        press(Named.up, on: account)
        try check(row.model.pinnedStep == firstStep(of: story[1]), "Up walks back")
        press("k", on: account)
        try check(row.model.pinnedStep == firstStep(of: story[0]), "k walks back")
        press("G", on: account)
        try check(row.model.pinnedStep == firstStep(of: story.last), "G goes to the last item")
        press("g", on: account)
        try check(row.model.pinnedStep == firstStep(of: story.first), "g goes to the first item")
        press(Named.pageDown, on: account)
        try check(row.model.pinnedStep == firstStep(of: story[min(3, story.count - 1)]), "PageDown walks three items")
        press(Named.end, on: account)
        try check(row.model.pinnedStep == firstStep(of: story.last), "End goes to the last item")
        press(Named.home, on: account)
        try check(row.model.pinnedStep == firstStep(of: story.first), "Home goes to the first item")

        press(Named.escape, on: account)
        try check(row.model.pinnedStep == nil, "Esc lets go of the cursor")

        press("s", on: account)
        let afterS = row.model.pinnedStep.flatMap { row.model.step(id: $0) }
        try check(afterS.map { NeuralReading.isNote($0) } == true, "s jumps to the next thing it said")
        let firstSaid = row.model.pinnedStep
        press("s", on: account)
        try check(row.model.pinnedStep != firstSaid, "s jumps again")
        press("S", on: account)
        try check(row.model.pinnedStep == firstSaid, "S jumps back")
        let hasAsk = row.model.stepList.pendingAskID != nil
        try check(!hasAsk, "a settled turn has nothing to ask")
        press("a", on: account)

        press("0", on: account)
        press("3", on: account)
        account.refresh(immediate: true)
        try check(row.model.stepList.filter.zones.count == 1, "1 to 6 toggle the zone filters through the account")
        press("0", on: account)
        account.refresh(immediate: true)
        try check(row.model.stepList.filter.zones.isEmpty, "0 clears them")
        press("!", on: account)
        account.refresh(immediate: true)
        try check(row.model.stepList.filter.failedOnly, "! filters to the failed steps")
        press("!", on: account)

        if let note = story.first(where: \.isSaid), let id = firstStep(of: note) {
            account.choose(id, fromAccount: false)
            let was = account.expandedText.contains(note.id)
            try check(press(Named.space, on: account), "Space is taken by the account")
            try check(account.expandedText.contains(note.id) != was, "Space unfolds the note under the cursor")
            press(Named.space, on: account)
        }
        if let work = story.first(where: \.isWork), let id = firstStep(of: work) {
            account.choose(id, fromAccount: false)
            account.realize()
            try check(account.isOpen(work, work: workValue(work)), "the line holding the cursor is open")
            press(Named.enter, on: account)
            try check(
                account.window?.firstResponder is AccountButton,
                "Enter goes on to the open card's buttons")
            account.focus()
        }
        var escapes = 0
        while row.phase == .open, escapes < 8 {
            press(Named.escape, on: account)
            escapes += 1
        }
        try check(
            row.phase != .open && escapes > 0,
            "Esc undoes the cursor, the filters and the search, and the last one closes the brain (\(escapes) presses, phase \(row.phase), cursor \(row.model.pinnedStep ?? "-"), filter \(row.model.stepList.filter), focus \(row.model.browseFocus), dive \(String(describing: row.model.divedZone)))")
        let tab = account.window.map { key("\t", code: 48, in: $0) }.map(account.handleKey) ?? false
        try check(!tab, "Tab is left to the window")
    }


    private static func words(_ check: (Bool, String) throws -> Void) throws {
        let fixture = BrainFixture(width: 1200)
        defer { fixture.tearDown() }
        guard let (row, account) = opened(fixture, 0) else {
            try check(false, "the build-fix turn opens")
            return
        }
        var text = account.visibleText
        try check(text.contains("fixed 1 error on the way"), "the header names what it fixed in words")
        try check(text.contains(AccountWords.asked), "the person's question is the first item")
        try check(account.header.accessibilityLabel()?.contains(NeuralReading.verdictDone) == true, "the verdict pill says Done")
        try check(!account.account.header.isRunning, "a settled turn is not running")
        try check(account.secondTimer == nil, "a settled account owns no clock")
        try check(!account.isAnimating, "a settled account is not animating")
        try check(account.nowView == nil && account.askView == nil, "a settled turn has no Now line and no ask")
        try check(account.entries.last?.isResult == true, "the result closes the story")

        account.scrollToEnd(jump: true)
        account.realize()
        text = account.visibleText
        try check(text.contains(AccountWords.result), "the result block is drawn")
        try check(text.contains(AccountWords.changed), "CHANGED lists the files")
        try check(text.contains(AccountWords.checks), "CHECKS lists the build")
        try check(
            text.contains("passed after 1 retry") || text.contains(Localized.text("passed after 1 retry")),
            "the build says it passed after one retry")
        try check(text.contains(NeuralReading.thenItAnswered.uppercased()), "the answer closes it")
        try check(!text.contains(NeuralReading.verdictFailed.uppercased()), "a fixed error is never a red FAILED chip")

        let failedStep = row.model.steps.first { $0.status == .failed }
        guard let failed = failedStep else {
            try check(false, "the turn has a step that failed and was fixed")
            return
        }
        account.choose(failed.id, fromAccount: false)
        account.scrollTo(0, animated: false)
        account.realize()
        let cards = account.cells.values.compactMap { ($0 as? AccountWorkCell)?.cursorPage }
        try check(cards.count == 1, "the step under the cursor opens its card under its row")
        if let card = cards.first {
            let page = card.visibleText
            try check(page.contains(NeuralReading.verdictFixed.uppercased()), "the card says FIXED ON RETRY")
            try check(page.contains("It failed here") || page.contains(Localized.text("It failed here")), "the card says what failed")
            try check(card.frame.minX >= 36 - 0.6, "the card hangs off its row")
            try check(page.contains(NeuralReading.copyLabel), "the card offers Copy")
        }
        try check(
            account.cells.values.contains { ($0 as? AccountWorkCell)?.drawnWords.isEmpty == false },
            "a work line says what ran")

        fixture.resize(to: 1420)
        settle(row)
        guard let detail = account.detail else {
            try check(false, "two columns have a detail")
            return
        }
        try check(detail.visibleText.contains(NeuralReading.verdictFixed.uppercased()), "the detail reads the step under the cursor")
        row.updateModel { $0.clearSelection() }
        row.updateModel { $0.pointer(over: nil, at: BrainClock.now - 10) }
        account.refresh(immediate: true)
        try check(
            detail.visibleText.contains(AccountWords.whereTheWorkWent),
            "with no cursor the detail is the turn's digest")
        try check(!detail.moreBelow || detail.scroll != nil, "the detail column scrolls inside itself")

    }


    private static func running() -> [ChatMessage] {
        var messages =
            NeuralDemo.buildFix(prefix: "a-", origin: 1_792_000_000)
            + NeuralDemo.turn(prefix: "b-", origin: 1_792_003_600, answer: false)
        if let index = messages.lastIndex(where: { $0.role == .assistant }) {
            messages[index].isStreaming = true
            messages[index].completedAt = nil
            for part in messages[index].parts.indices.reversed() {
                guard case .tool(var call) = messages[index].parts[part].kind else { continue }
                call.status = .running
                call.output = nil
                messages[index].parts[part].kind = .tool(call)
                break
            }
        }
        return messages
    }

    private static func live(_ check: (Bool, String) throws -> Void) throws {
        let messages = running()
        let fixture = BrainFixture(messages: messages, running: true, width: 1200)
        defer { fixture.tearDown() }
        guard let (row, account) = opened(fixture, 1) else {
            try check(false, "the running turn opens")
            return
        }
        try check(account.account.header.isRunning, "the account knows the turn runs")
        try check(account.nowView != nil, "a running turn has a Now line")
        try check(account.secondTimer != nil, "a running account ticks once a second")
        let words = account.visibleText
        try check(words.contains(NeuralReading.nowLabel), "the Now line says NOW")
        try check(account.account.live?.title.isEmpty == false, "the Now line has the plain title of the step in flight")
        let vitals = account.account.vitals(now: Date(), lastActivity: Date().addingTimeInterval(-45))
        try check(vitals.isSilent && vitals.silentWords != nil, "after 40 seconds of silence the Now line says so")
        let quiet = account.account.vitals(now: Date(), lastActivity: Date().addingTimeInterval(-3))
        try check(!quiet.isSilent && quiet.lastOutputWords != nil, "a little silence says how long since it last spoke")
        try check(account.header.accessibilityLabel()?.contains(NeuralReading.verdictWorking) == true, "the pill says WORKING")
        try check(
            abs(account.scrollY - account.maxScroll) < 2 || account.maxScroll == 0,
            "a running turn's account follows its newest item")

        if let last = account.entries.last, let step = last.stepIDs.first {
            account.userScrolled()
            try check(!row.model.stepList.isFollowing, "a person's scroll pauses following")
            account.refresh(immediate: true)
            try check(!account.followPill.isHidden, "the pill offers the way back")
            _ = step
            let held = account.scrollY
            account.refresh(immediate: true)
            try check(abs(account.scrollY - held) < 0.6, "a paused account does not move")
            account.jumpToLatest()
            try check(row.model.stepList.isFollowing, "the pill resumes following")
        }

        fixture.replace(messages: NeuralDemo.conversation(), running: false)
        settle(row)
        try check(account.secondTimer == nil, "a turn that ends stops the account's clock")
        try check(account.nowView == nil, "a turn that ends takes the Now line away")
    }


    private static func scale(_ check: (Bool, String) throws -> Void) throws {
        let big = NeuralDemo.buildFix(prefix: "a-", origin: 1_792_000_000)
            + NeuralDemo.largeTurn(steps: 2000, prefix: "b-", origin: 1_792_003_600, answer: true)
        let fixture = BrainFixture(messages: big, running: false, width: 1200)
        defer { fixture.tearDown() }
        guard let (row, account) = opened(fixture, 1) else {
            try check(false, "the two-thousand step turn opens")
            return
        }
        try check(row.model.steps.count >= 1000, "the big turn has its steps (\(row.model.steps.count))")
        try check(account.entries.count > 100, "the story has an item for each run (\(account.entries.count))")
        try check(account.cells.count <= 40, "only the items near the viewport exist (\(account.cells.count))")
        let total = views(in: account)
        try check(total < 1500, "the account owns what a screenful costs (\(total) views)")
        for _ in 0..<6 {
            account.refresh(immediate: true)
            account.realize()
        }
        let builds = account.buildCount
        for _ in 0..<3 {
            account.refresh(immediate: true)
            account.realize()
        }
        try check(account.buildCount == builds, "a token that changed nothing rebuilds nothing")

        let longest = row.model.steps.filter { NeuralReading.isTool($0) }.max {
            NeuralReadout.fullOutput(of: $0).count < NeuralReadout.fullOutput(of: $1).count
        }
        if let longest, NeuralReadout.fullOutput(of: longest).count > 12 {
            account.choose(longest.id, fromAccount: false)
            reveal(account)
            let cell = account.cells.values.compactMap { $0 as? AccountWorkCell }.first { $0.cursorPage != nil }
            let before = cell?.measuredHeight ?? 0
            try check(cell?.cursorPage?.outputs.contains(where: { $0.canExpand }) == true, "a long output can be unfolded")
            let buildsBefore = account.buildCount
            let toggled = account.toggleCardOutput()
            account.realize()

            let rebuilt = account.buildCount - buildsBefore
            let grown = cell?.measuredHeight ?? 0
            try check(
                toggled && grown > before,
                "Space or o unfolds the output and the item grows (\(before) to \(grown), toggled \(toggled), lines \(NeuralReadout.fullOutput(of: longest).count), blocks \(cell?.cursorPage?.outputs.count ?? -1))")
            let still = cell.map { account.cells[$0.entryID] === $0 } ?? false
            let again = account.toggleCardOutput()
            account.realize()
            try check(
                abs((cell?.measuredHeight ?? 0) - before) < 1,
                "folding it again gives the height back (\(before), \(grown), \(cell?.measuredHeight ?? 0), rebuilt \(rebuilt), same cell \(still), toggled again \(again))")
            account.host?.browse(.key(.escape), grabFocus: false)
        } else {
            try check(false, "the big turn has a step with a long output")
        }

        account.scrollTo(account.maxScroll / 2, animated: false)
        account.realize()
        try check(account.cells.count <= 40, "scrolling to the middle keeps the same few items")
        try check(
            account.cells.keys.allSatisfy { account.entryIndex[$0] != nil }, "every item that exists is in the story")

        if let work = account.entries.filter(\.isWork).max(by: { lhs, rhs in
            if case .work(let a) = lhs.kind, case .work(let b) = rhs.kind { return a.stepIDs.count < b.stepIDs.count }
            return false
        }), case .work(let value) = work.kind {
            account.unfolded.insert(work.id)
            account.rowCaps[work.id] = BrainAccountView.rowMax
            if let at = account.entryIndex[work.id] {
                account.refresh(immediate: true)
                account.scrollTo(account.offsets[at] + 200, animated: false)
                account.realize()
                if let cell = account.cells[work.id] as? AccountWorkCell {
                    let canvases = find(AccountRowsView.self, in: cell).count
                    try check(canvases <= 8, "a work line of \(value.stepIDs.count) steps draws only the rows near the reader (\(canvases) canvases)")
                }
            }
        }

        let target = row.model.steps[row.model.steps.count - 3].id
        account.scrollTo(0, animated: false)
        account.choose(target, fromAccount: false)
        reveal(account)
        if let item = account.account.item(containing: target), let at = account.entryIndex[item.id] {
            var shown = account.offsets[at]
            if let cell = account.cells[item.id] as? AccountWorkCell, let card = cell.cursorPage {
                shown = account.offsets[at] + card.frame.minY
            }
            try check(
                shown >= account.scrollY - 40 && shown <= account.scrollY + account.viewHeight,
                "a cursor set from elsewhere brings its row into view (\(shown) in \(account.scrollY)...\(account.scrollY + account.viewHeight), item \(at) of \(account.entries.count) top \(account.offsets[at]) total \(account.total) cell \(String(describing: account.cells[item.id]?.frame)) pending \(String(describing: account.pendingReveal)) steps \(account.entries[at].stepIDs.count) kind \(account.entries[at].isWork))")
        } else {
            try check(false, "the far step belongs to an item")
        }
    }


    /// How many of the items the account holds are not in the window server's tree yet: a layer the
    /// render server has been given has a presentation layer, and one it was never given does not,
    /// which is how an item that was made and never drawn looks from inside the process.
    private static func uncommitted(_ account: BrainAccountView) -> Int {
        account.cells.values.filter { $0.layer?.presentation() == nil }.count
    }

    /// An account made while its brain was opening is handed to the render server once the move has
    /// landed, at the width a narrow window opens at and at the width that has two columns, with
    /// the window on screen the way the person's is.
    private static func paintsAfterMove(_ check: (Bool, String) throws -> Void) throws {
        for width in [700.0, 1420.0] {
            let fixture = BrainFixture(width: width)
            defer { fixture.tearDown() }
            let top = NSScreen.main?.visibleFrame.maxY ?? 800
            fixture.window.setFrameTopLeftPoint(NSPoint(x: 20, y: top))
            fixture.window.orderFrontRegardless()
            guard let row = fixture.view(0) else {
                try check(false, "a closed brain is there to open at \(Int(width))")
                continue
            }
            row.holdMove(direction: .open, at: 0.05)
            spin(0.1)
            row.finishMove(snapOpen: true)
            spin(0.6)
            guard let account = fixture.view(0)?.account else {
                try check(false, "the account exists after the move at \(Int(width))")
                continue
            }
            let missing = uncommitted(account)
            try check(
                !account.cells.isEmpty && missing == 0,
                "every item of the account reaches the screen after an opening move at \(Int(width)) (\(missing) of \(account.cells.count) never did)")
        }
    }

    private static func takeover(_ check: (Bool, String) throws -> Void) throws {
        let fixture = BrainFixture(width: 700)
        defer { fixture.tearDown() }
        guard let (row, account) = opened(fixture, 0) else {
            try check(false, "the brain opens narrow")
            return
        }
        row.updateModel { $0.setDive(zone: .shell) }
        account.refresh(immediate: true)
        account.layoutSubtreeIfNeeded()
        try check(account.holdsBody && account.detail != nil, "a dive in a narrow account lists the zone's steps in its body")
        try check(account.scroll.isHidden, "the story gives way to the zone's list")
        try check(account.detail?.visibleText.contains(NeuralZone.shell.label) == true, "the list names the zone")
        row.updateModel { $0.setDive(zone: nil) }
        account.refresh(immediate: true)
        account.layoutSubtreeIfNeeded()
        account.realize()
        try check(!account.holdsBody && account.detail == nil && !account.scroll.isHidden, "surfacing brings the story back")
        row.updateModel { $0.startReplay(now: BrainClock.now) }
        account.refresh(immediate: true)
        account.layoutSubtreeIfNeeded()
        try check(account.holdsBody && account.detail != nil, "a replay shows its log in the body")
        row.updateModel { $0.stopReplay() }
        account.refresh(immediate: true)
        account.layoutSubtreeIfNeeded()
        try check(!account.holdsBody, "a replay that ends gives the story back")

        let wide = BrainFixture(width: 1420)
        defer { wide.tearDown() }
        guard let (wideRow, wideAccount) = opened(wide, 0) else {
            try check(false, "the brain opens wide")
            return
        }
        wideRow.updateModel { $0.startReplay(now: BrainClock.now) }
        wideAccount.refresh(immediate: true)
        try check(
            wideAccount.detail?.shown.map { if case .replay = $0.mode { return true }; return false } == true,
            "in two columns a replay is the detail's subject")
        try check(!wideAccount.holdsBody && !wideAccount.scroll.isHidden, "in two columns a replay leaves the story in place")
    }
}

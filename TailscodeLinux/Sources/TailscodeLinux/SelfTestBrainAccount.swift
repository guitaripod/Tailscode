import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// The claims about the right side of an open brain, each on a real widget in a window: that the
    /// account is the turn told in its own words and agrees with Core's reading of it, that what the
    /// agent said is easy to find, that it scales with the window and keeps its place through a
    /// resize, that the cursor, the list, the head and the account are one thing, that Reply sends
    /// nothing, and that a turn of two thousand steps costs a screenful of widgets.
    static func checkBrainAccount(_ expect: (Bool, String) throws -> Void) throws {
        try timedBrain("account data") { try checkAccountData(expect) }
        try timedBrain("account surface") { try checkAccountSurface(expect) }
        try timedBrain("account moves") { try checkAccountMoves(expect) }
        try timedBrain("account live") { try checkAccountLive(expect) }
        try timedBrain("account huge") { try checkAccountHuge(expect) }
        try timedBrain("account reader") { try checkAccountReader(expect) }
    }

    static func accountRow(
        _ kind: String, settled: Bool = false, open: Bool = true
    ) throws -> (row: BrainRow, builder: TranscriptRowBuilder) {
        guard let script = BrainAccountDemo.script(kind: kind, now: Date()) else {
            throw SelfTestFailure("brain: no account demo named \(kind)")
        }
        let running = script.running && !settled
        var state = ConversationState(
            status: running ? .running : .idle, connection: .live, hasLoadedTranscript: true)
        state.messages = script.messages
        if script.waiting, !settled {
            state.pendingPermissions = [PermissionRequest(id: "call-wait", sessionID: "demo", toolName: "Bash")]
        }
        let builder = brainBuilder(style: .brain)
        let rows = builder.rows(state: state)
        var found: BrainRow?
        for row in rows {
            if case .brain(let brain) = row.kind { found = brain }
        }
        guard var brain = found else { throw SelfTestFailure("brain: the \(kind) demo made no brain") }
        brain.open = open
        return (brain, builder)
    }

    private static func settleAccount(_ view: BrainView, _ seconds: Double = 1.5) {
        _ = brainPump(seconds) {
            guard let account = view.account else { return false }
            return !account.isAnimating && !account.realizeScheduled && !account.cells.isEmpty
        }
        _ = brainPump(0.1)
    }

    private static func accountTag(_ entry: AccountEntry) -> String {
        switch entry.kind {
        case .said: return "said"
        case .thought: return "thought"
        case .work: return "work"
        case .asked: return "asked"
        case .plan: return "plan"
        case .result: return "result"
        }
    }


    private static func checkAccountData(_ expect: (Bool, String) throws -> Void) throws {
        let (row, builder) = try accountRow("account")
        let model = NeuralBrainModel(turn: row.turn, context: .none)
        let account = model.account(answer: row.answer.isEmpty ? nil : row.answer)
        let entries = AccountEntries.make(model: model, account: account, list: model.stepList)
        try expect(
            entries.map(accountTag)
                == ["plan", "thought", "work", "said", "work", "said", "work", "thought", "said", "work", "result"],
            "the account is the turn in order: its plan, thought, said, work, thought, said, work and the result (\(entries.map(accountTag).joined(separator: " ")))")
        let notes = model.steps.filter { NeuralReading.isNote($0) }
        try expect(
            entries.compactMap { entry -> String? in
                if case .said(let said) = entry.kind { return said.text }
                return nil
            } == notes.map(\.text) && account.utteranceCount == 3 && account.thoughtCount == 2,
            "the notes are the agent's own words, whole and untouched, three said and two thought")
        let tools = model.steps.filter { NeuralReading.isTool($0) }.map(\.id)
        try expect(
            entries.flatMap { entry -> [String] in
                if case .work(let work) = entry.kind { return work.stepIDs }
                return []
            } == tools,
            "and every tool step is in one work line, in the order it ran")
        let works = entries.compactMap { entry -> AccountEntry.Work? in
            if case .work(let work) = entry.kind { return work }
            return nil
        }
        if let work = works.first(where: { $0.fixedCount > 0 }) {
            try expect(
                work.fixedCount == 1 && work.unfixedCount == 0 && work.fixedWords.count == 1
                    && work.clauses.contains { $0.verdict == .fixed },
                "a work line says an error was fixed, in the amber words, and never calls it failed (\(work.fixedWords))")
        }
        if let work = works.first(where: { $0.zones == [.act, .shell, .sense, .delegate] }) {
            try expect(
                work.zones == [.act, .shell, .sense, .delegate] && !work.clauses.isEmpty,
                "and marks the zones in the order they were first used and says the work in clauses (\(work.zones))")
        }

        let list = model.stepList
        let heights = list.rows.map { ($0.kind, $0.height()) }
        try expect(
            heights.allSatisfy { $0.0 == .note ? $0.1 == 40 : $0.1 == 28 },
            "a said row is 40 points tall and every other row 28")
        try expect(
            list.zoneChips.first?.zone == .say && list.zoneChips.first?.count == 3
                && NeuralZone.say.displayLabel == "SAID" && NeuralZone.say.filterKey == 1
                && NeuralZone.filterOrder.map(\.filterKey) == [1, 2, 3, 4, 5, 6],
            "the SAID chip leads the filters with its count, and the digits are SAID then the rest")
        var solo = model
        solo.browse(.key(.character("1")))
        let filtered = AccountEntries.make(model: solo, account: solo.account(), list: solo.stepList)
        try expect(
            filtered.map(accountTag) == ["said", "said", "said", "result"],
            "SAID solo makes the account the transcript of what it said (\(filtered.map(accountTag).joined(separator: " ")))")
        solo.browse(.key(.character("2")))
        let both = AccountEntries.make(model: solo, account: solo.account(), list: solo.stepList)
        try expect(
            both.map(accountTag) == ["thought", "work", "said", "said", "thought", "said", "work", "result"],
            "and a second zone adds its steps to it (\(both.map(accountTag).joined(separator: " ")))")
        var failedOnly = model
        failedOnly.browse(.key(.character("x")))
        let failed = AccountEntries.make(model: failedOnly, account: failedOnly.account(), list: failedOnly.stepList)
        try expect(
            failed.map(accountTag) == ["work"] && !AccountEntries.showsResult(failedOnly.stepList.filter),
            "failed only leaves the work that failed and no answer")

        let quote = NeuralAccount.quote(of: notes[0].text, maxChars: 40)
        try expect(
            quote.count <= 41 && quote.hasSuffix("\u{2026}") && !quote.contains("\n"),
            "the quote line is cut at a word with an ellipsis (\(quote))")
        _ = builder
    }


    private static func checkAccountSurface(_ expect: (Bool, String) throws -> Void) throws {
        let (row, builder) = try accountRow("account")
        let bed = try BrainBed(row: row, width: 1440, key: "st-account", policy: { builder.brainPolicy })
        defer { bed.close() }
        _ = brainPump(10) { bed.view.stage?.hasPicture == true }
        settleAccount(bed.view)
        let view = bed.view
        guard let account = view.account, let list = view.list, let filters = view.filters else {
            throw SelfTestFailure("brain: no account")
        }
        let model = view.model
        try expect(
            account.entries.count >= 9 && !account.cells.isEmpty && account.cells.count <= account.entries.count,
            "the account exists beside the head with its items made (\(account.cells.count) of \(account.entries.count))")

        let chips = filters.chipSummary
        try expect(
            chips.first?.zone == .say && chips.first?.label == NeuralZone.say.displayLabel && chips.first?.count == 3
                && chips.dropFirst().allSatisfy { $0.label == nil },
            "the SAID chip leads the chips, is the only one that carries its word, and carries its count")

        let said = model.steps.filter { NeuralReading.isNote($0) }
        let metrics = view.currentMetrics
        let prose = account.proseProbe.em * 36
        if let first = account.account.items.compactMap({ item -> NeuralAccount.Said? in
            if case .said(let said) = item { return said }
            return nil
        }).first, let cell = account.cells[first.id] {
            var widest = 0.0
            func walk(_ node: UnsafeMutablePointer<GtkWidget>) {
                let instance = UnsafeMutableRawPointer(node).assumingMemoryBound(to: GTypeInstance.self)
                if g_type_check_instance_is_a(instance, gtk_label_get_type()) != 0,
                    gtk_widget_has_css_class(node, "bn-said-text") != 0
                {
                    widest = max(widest, Double(gtk_widget_get_width(node)))
                }
                var child = gtk_widget_get_first_child(node)
                while let held = child {
                    walk(held)
                    child = gtk_widget_get_next_sibling(held)
                }
            }
            walk(cell.widget)
            try expect(
                widest > 100 && widest <= min(prose, account.boxWidth) + 1,
                "a note's prose is held to 36 em, \(Int(prose)) points, however wide the item is (\(Int(widest)))")
        }
        try expect(metrics.accountLayout == .split, "at 1440 the account is two columns")

        for width in [700, 900, 1100, 1300, 1440, 1920] {
            gtk_widget_set_size_request(bed.holder, Int32(width), -1)
            gtk_window_set_default_size(ptr(bed.window), Int32(width + 40), 1000)
            _ = brainPump(1.0) { Int(gtk_widget_get_width(bed.widget)) == width }
            settleAccount(view, 1.0)
            let m = view.currentMetrics
            let place = bed.rect(of: account.root)
            let split = width >= 860
            let wantWidth = split ? Double(width) - 24 - NeuralStageMetrics.columnWidth(rowWidth: Double(width)) : Double(width)
            try expect(
                abs(place.w - wantWidth) <= 1.5 && (split ? abs(place.x - (Double(width) - wantWidth)) <= 1.5 : abs(place.x) <= 1.5),
                "at \(width) the account takes everything the column leaves, \(Int(wantWidth)) points, with no cap (\(Int(place.w)))")
            let two = split && wantWidth >= 924
            try expect(
                (m.accountLayout == .split) == two,
                "and is \(two ? "two columns" : "one") at \(Int(wantWidth)) points (the split is from 924)")
            let clip = view.readoutClip.map { bed.rect(of: $0) }
            if two, let detail = account.detailRect(), let clip {
                try expect(
                    abs(clip.x - (place.x + detail.x)) <= 1.5 && abs(clip.w - detail.width) <= 1.5
                        && detail.width >= NeuralStageMetrics.detailMin - 1,
                    "the open step's detail is the second column, at least 460 wide (\(Int(clip.w)))")
            }
            try expect(
                account.boxWidth <= (split ? NeuralStageMetrics.storyMax : Double(width)) && account.boxWidth >= 120,
                "and the items are \(Int(account.boxWidth)) wide inside it")
        }
        gtk_widget_set_size_request(bed.holder, 1440, -1)
        gtk_window_set_default_size(ptr(bed.window), 1480, 1000)
        _ = brainPump(1.0) { Int(gtk_widget_get_width(bed.widget)) == 1440 }
        settleAccount(view)

        let ids = said.map(\.id)
        view.browse(.click(ids[2], double: false))
        settleAccount(view)
        let item = account.account.item(containing: ids[2])
        try expect(
            view.model.pinnedStep == ids[2] && view.ringed(ids[2])?.number == (model.steps.firstIndex { $0.id == ids[2] } ?? -2) + 1
                && list.visibleIDs.contains(ids[2]) && item.flatMap({ account.cells[$0.id] }) != nil,
            "a cursor on a note rings its node with the number, scrolls the list to its row and the account to its item (pinned \(view.model.pinnedStep == ids[2]) ring \(view.ringed(ids[2])?.number ?? -1) list \(list.visibleIDs.contains(ids[2])) cell \(item.flatMap { account.cells[$0.id] } != nil) item \(item?.id ?? "-") cells \(account.cells.keys.sorted()))")
        if let cell = item.flatMap({ account.cells[$0.id] }) {
            let top = bed.rect(of: cell.widget).y - bed.rect(of: account.story).y
            try expect(
                top >= -2 && top < account.viewHeight,
                "and the item stands inside the story's window (\(Int(top)) of \(Int(account.viewHeight)))")
        }
        try expect(
            view.leaderState.current?.stepID == ids[2],
            "and the leader ties that node to the account")
        view.clearSelection()
        settleAccount(view)

        press(view, "s")
        try expect(view.model.pinnedStep == ids[0], "s goes to the first thing it said")
        press(view, "s")
        try expect(view.model.pinnedStep == ids[1], "and again to the next")
        press(view, "S")
        try expect(view.model.pinnedStep == ids[0], "S goes back")
        press(view, "S")
        try expect(view.model.pinnedStep == ids[0], "and stops at the first")
        view.clearSelection()

        account.focus()
        _ = brainPump(0.2)
        try expect(account.hasFocus, "the account takes the keyboard")
        _ = view.accountKey(keyval: UInt32(GDK_KEY_Down), state: 0)
        let walk = account.entries.filter { $0.isStory || $0.isResult }
        let first = walk[0].stepIDs.first
        try expect(view.model.pinnedStep == first, "Down in the account walks to its first item")
        _ = view.accountKey(keyval: UInt32(GDK_KEY_Down), state: 0)
        _ = view.accountKey(keyval: UInt32(GDK_KEY_Down), state: 0)
        try expect(
            view.model.pinnedStep == walk[2].stepIDs.first
                && account.account.item(containing: view.model.pinnedStep ?? "")?.id == walk[2].id,
            "and on down, an item at a time, a work line by its first step")
        _ = view.accountKey(keyval: UInt32(GDK_KEY_Up), state: 0)
        try expect(view.model.pinnedStep == walk[1].stepIDs.first, "Up walks back")
        _ = view.accountKey(keyval: UInt32(GDK_KEY_Return), state: 0)
        _ = brainPump(0.2)
        try expect(
            gtk_widget_has_focus(view.list!.canvas) != 0 || (!account.hasFocus && view.hasBrainFocus),
            "Enter goes on from the account, to the detail's buttons or back to the list")
        view.clearSelection()

        guard let first2 = account.entries.first(where: { $0.isSaid }), case .said(let note) = first2.kind else {
            throw SelfTestFailure("brain: the account holds no note")
        }
        var quoted: String?
        bed.host.reply = { quoted = $0 }
        view.accountReply(note.stepID)
        let wantQuote = NeuralBrowse.replyQuote(of: model.steps.first { $0.id == note.stepID }!)
        try expect(
            quoted == wantQuote && wantQuote.hasPrefix("> ") && wantQuote.hasSuffix("\n\n"),
            "Reply hands the composer a quote, every line behind a '> ' and a blank line to write under")
        let editor = PromptEditor(css: "composer", placeholder: "x")
        editor.setText("Fix", caretAtEnd: true)
        editor.vim.reset(to: "Fix", cursor: 3, mode: .normal)
        editor.insertReplyQuote(wantQuote)
        try expect(
            editor.text == "Fix\n" + wantQuote && editor.cursor == editor.text.count && editor.vim.mode == .insert,
            "which lands at the caret on a line of its own, with the caret under it in insert mode")
        editor.setText("", caretAtEnd: true)
        editor.insertReplyQuote(wantQuote)
        try expect(editor.text == wantQuote, "and in an empty box there is no blank line before it")
        try expect(
            view.model.browseState.outbox.isEmpty && bed.host.reply != nil,
            "and the quote is taken once: the brain keeps nothing waiting to be sent")

        view.accountCopy(note.stepID)
        _ = brainPump(0.1)
        try expect(
            account.cells[first2.id]?.copyButton.map { String(cString: gtk_button_get_label(ptr($0))) } == BrainWords.copied
                && clipboardText() == note.text,
            "Copy puts the note's words on the clipboard and says Copied (\(account.cells[first2.id]?.copyButton.map { String(cString: gtk_button_get_label(ptr($0))) } ?? "no button") / \(clipboardText()?.prefix(40) ?? "no clipboard"))")

        view.clearSelection()
        view.accountToggleText(first2.id)
        _ = brainPump(0.3)
        try expect(account.expandedText.contains(first2.id), "Show all opens a long note and Space does the same")
    }

    private static func clipboardText() -> String? {
        guard let display = gdk_display_get_default(), let clipboard = gdk_display_get_clipboard(display),
            let provider = gdk_clipboard_get_content(clipboard)
        else { return nil }
        var value = GValue()
        g_value_init(&value, g_type_from_name("gchararray"))
        defer { g_value_unset(&value) }
        guard gdk_content_provider_get_value(provider, &value, nil) != 0, let raw = g_value_get_string(&value)
        else { return nil }
        return String(cString: raw)
    }


    private static func checkAccountMoves(_ expect: (Bool, String) throws -> Void) throws {
        let (row, builder) = try accountRow("account")
        let bed = try BrainBed(row: row, width: 1100, key: "st-account-moves", policy: { builder.brainPolicy })
        defer { bed.close() }
        _ = brainPump(10) { bed.view.stage?.hasPicture == true }
        settleAccount(bed.view)
        let view = bed.view
        guard let account = view.account else { throw SelfTestFailure("brain: no account") }
        let model = view.model
        let steps = model.steps

        view.browse(.click(steps.first { $0.status == .failed }!.id, double: false))
        settleAccount(view)
        let cursor = view.model.pinnedStep
        let before = account.anchor()
        let workIDs = account.entries.filter(\.isWork).map(\.id)
        let other = workIDs.first { id in
            if case .work(let work)? = account.entryIndex[id].map({ account.entries[$0].kind }) {
                return !work.stepIDs.contains(cursor ?? "")
            }
            return false
        }
        if let other { view.accountToggleWork(other) }
        settleAccount(view)
        try expect(
            view.model.pinnedStep == cursor && other.map({ account.unfolded.contains($0) }) == true,
            "unfolding another work line keeps the cursor where it is")
        try expect(
            account.cells.values.contains { $0.cursorPage != nil },
            "and the cursor's own card is open under its row in one column")
        if let other { view.accountToggleWork(other) }
        settleAccount(view)
        try expect(
            view.model.pinnedStep == cursor && !account.unfolded.contains(other ?? ""),
            "folding it again keeps it too")

        try expect(account.maxScroll > 1, "the account has room to scroll")
        account.driveScroll(-1_000_000)
        try expect(
            !account.wheel(-1) && account.wheel(1),
            "a notch moving up from the top of the account goes on to the page, and one moving down is the account's")
        account.driveScroll(1_000_000)
        try expect(
            !account.wheel(1) && account.wheel(-1),
            "a notch moving down from the end goes on to the page, and one moving up is the account's")

        account.driveScroll(60)
        settleAccount(view)
        let held = account.anchor()
        let state = (cursor, account.unfolded)
        for width in [1440, 1100, 760, 1920, 1100] {
            gtk_widget_set_size_request(bed.holder, Int32(width), -1)
            gtk_window_set_default_size(ptr(bed.window), Int32(width + 40), 1000)
            _ = brainPump(1.0) { Int(gtk_widget_get_width(bed.widget)) == width }
            settleAccount(view, 1.2)
        }
        _ = brainPump(0.6)
        let after = account.anchor()
        try expect(
            view.model.pinnedStep == state.0 && account.unfolded == state.1 && view.phase == .open,
            "resizing across the split and the accordion keeps the cursor and what was unfolded")
        try expect(
            held?.index == after?.index || (held != nil && after != nil && abs(held!.index - after!.index) <= 1),
            "and the item at the top of the story (\(held?.index ?? -1) then \(after?.index ?? -1) of \(before?.index ?? -1))")

        BrainLogWatch.install()
        let complaints = BrainLogWatch.count
        let began = Date()
        var rounds = 0
        let ids = steps.map(\.id)
        var spent: [String: UInt64] = [:]
        func timed(_ name: String, _ body: () -> Void) {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            spent[name, default: 0] += DispatchTime.now().uptimeNanoseconds - start
        }
        let hardStop = began.addingTimeInterval(8)
        while Date().timeIntervalSince(began) < 1.5 || (rounds < 60 && Date() < hardStop) {
            let id = ids[rounds % ids.count]
            timed("hover") {
                view.accountHover(id)
                view.accountHover(ids[(rounds * 5) % ids.count])
            }
            if rounds % 3 == 0 { timed("wheel") { _ = account.wheel(rounds % 6 < 3 ? 1 : -1) } }
            if rounds % 7 == 0 { timed("choose") { view.accountChooseStep(id, fromAccount: rounds % 2 == 0) } }
            if rounds % 11 == 0, let work = workIDs.randomElement() { timed("fold") { view.accountToggleWork(work) } }
            if rounds % 13 == 0 {
                timed("text") { view.accountToggleText(account.entries[(rounds / 13) % account.entries.count].id) }
            }
            if rounds % 17 == 0 {
                timed("key") { _ = view.accountKey(keyval: UInt32(rounds % 34 == 0 ? GDK_KEY_Down : GDK_KEY_Up), state: 0) }
            }
            rounds += 1
            timed("loop") {
                while g_main_context_iteration(nil, 0) != 0 {}
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        report("brain account sweep: \(rounds) rounds " + spent.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value / 1_000_000)ms" }.joined(separator: " "))
        _ = brainPump(0.4)
        try expect(
            rounds > 50 && BrainLogWatch.count == complaints && view.phase == .open,
            "a pointer, the wheel and the keys swept over the account while its items are made and dropped, \(rounds) times, and the toolkit complained of nothing (\(BrainLogWatch.count - complaints): \(BrainLogWatch.last))")
        view.clearSelection()
        let entryCount = account.entries.count
        view.restate(view.row)
        try expect(account.entries.count == entryCount, "and a restated turn changes nothing in what it says")
    }

    private static func checkAccountLive(_ expect: (Bool, String) throws -> Void) throws {
        let (waitingRow, waitingBuilder) = try accountRow("accountwait")
        let waiting = try BrainBed(row: waitingRow, width: 1100, key: "st-account-wait", policy: { waitingBuilder.brainPolicy })
        _ = brainPump(10) { waiting.view.stage?.hasPicture == true }
        settleAccount(waiting.view)
        guard let wa = waiting.view.account else { throw SelfTestFailure("brain: no account while waiting") }
        try expect(
            wa.account.needsYou && wa.askWidget != nil && wa.askHeight > 40 && wa.entries.allSatisfy { !$0.isResult },
            "what the agent is waiting on you for is pinned above the story")
        let askRect = waiting.rect(of: wa.askWidget!)
        let storyRect = waiting.rect(of: wa.story)
        try expect(
            askRect.y < storyRect.y && askRect.y + askRect.h <= storyRect.y + 1,
            "above it and never inside it (\(Int(askRect.y)) over \(Int(storyRect.y)))")
        let askText = wa.account.askItem?.subject ?? ""
        try expect(
            !askText.isEmpty && wa.askSignature.contains(askText) && askText.contains("install-linuxapp"),
            "in the agent's own words and with the command it wants to run (\(askText))")
        var asked = false
        waiting.host.revealApproval = { asked = true }
        wa.driveScroll(80)
        _ = brainPump(0.3)
        let still = waiting.rect(of: wa.askWidget!)
        try expect(abs(still.y - askRect.y) <= 1, "and it stays where it is when the story scrolls (\(Int(askRect.y)) then \(Int(still.y)))")
        waiting.view.model.setBrowseFocus(.list)
        press(waiting.view, "a")
        try expect(
            asked && waiting.view.model.pinnedStep == wa.account.askItem?.stepID,
            "`a` goes to the ask and scrolls the transcript to the card that carries it (asked \(asked), cursor \(waiting.view.model.pinnedStep ?? "none"), ask \(wa.account.askItem?.stepID ?? "none"), phase \(waiting.view.phase), stage \(waiting.view.stage != nil), focus \(waiting.view.model.browseFocus), needsYou \(waiting.view.model.account().needsYou))")
        waiting.close()

        let (liveRow, liveBuilder) = try accountRow("accountlive")
        let live = try BrainBed(row: liveRow, width: 1100, key: "st-account-live", policy: { liveBuilder.brainPolicy })
        defer { live.close() }
        _ = brainPump(10) { live.view.stage?.hasPicture == true }
        settleAccount(live.view)
        guard let account = live.view.account else { throw SelfTestFailure("brain: no account while live") }
        try expect(
            live.view.model.stepList.isFollowing && account.cells.values.contains { $0.rows.isEmpty == false },
            "a running turn's newest work line is open and the account follows it")
        try expect(
            account.visibleText.contains("ffmpeg") && account.cells.values.contains { !$0.pages.isEmpty },
            "with the running step's card, output tail and all, under its row")
        try expect(
            account.maxScroll <= 0 || account.scroll >= account.maxScroll - 1,
            "and sits at its end")
        account.driveScroll(-40)
        _ = brainPump(0.3)
        try expect(
            !live.view.model.stepList.isFollowing && account.pillShown,
            "a scroll up by hand stops it following and offers the way back")
        live.view.accountJumpToLatest()
        _ = brainPump(3) { account.maxScroll <= 0 || abs(account.scroll - account.maxScroll) < 2 }
        try expect(
            live.view.model.stepList.isFollowing && !account.pillShown && (account.maxScroll <= 0 || abs(account.scroll - account.maxScroll) < 2),
            "which takes it back to the newest item (following \(live.view.model.stepList.isFollowing), pill \(account.pillShown), \(Int(account.scroll)) of \(Int(account.maxScroll)), target \(Int(account.target)))")
    }


    private static func checkAccountHuge(_ expect: (Bool, String) throws -> Void) throws {
        let (row, builder) = try accountRow("big2000")
        BrainLogWatch.install()
        let complaints = BrainLogWatch.count
        let bed = try BrainBed(row: row, width: 1440, key: "st-account-huge", policy: { builder.brainPolicy })
        defer { bed.close() }
        _ = brainPump(15) { bed.view.stage?.hasPicture == true }
        settleAccount(bed.view, 3)
        let view = bed.view
        guard let account = view.account else { throw SelfTestFailure("brain: no account") }
        let total = account.entries.count
        let resting = account.cells.values.reduce(0) { $0 + $1.widgetCount }
        try expect(
            total > 150 && account.cells.count < total / 4 && resting < 700,
            "a turn of two thousand steps is \(total) items and the account holds \(account.cells.count) of them, \(resting) widgets")
        account.resetSolveStats()
        var peakWidgets = 0
        var peakCells = 0
        var frames: [Double] = []
        var lastFrame = Date()
        for index in 0..<90 {
            account.driveScroll(index % 30 < 15 ? 160 : -90)
            while g_main_context_iteration(nil, 0) != 0 {}
            Thread.sleep(forTimeInterval: 0.004)
            let now = Date()
            frames.append(now.timeIntervalSince(lastFrame))
            lastFrame = now
            peakWidgets = max(peakWidgets, account.cells.values.reduce(0) { $0 + $1.widgetCount })
            peakCells = max(peakCells, account.cells.count)
        }
        settleAccount(view, 3)
        let solve = Double(account.solveNanoseconds) / Double(max(account.solves, 1)) / 1_000_000
        frames.sort()
        let p95 = frames[min(frames.count - 1, Int(Double(frames.count) * 0.95))]
        report(
            String(
                format: "brain account at %d items: %d cells and %d widgets at most, solve %.2f ms, frame p95 %.1f ms, scroll %.0f of %.0f",
                total, peakCells, peakWidgets, solve, p95 * 1000, account.scroll, account.total))
        try expect(
            peakCells <= 60 && peakWidgets <= 1100,
            "scrolling it never holds more than a screenful and its margins (\(peakCells) items, \(peakWidgets) widgets)")
        try expect(
            BrainLogWatch.count == complaints,
            "and no widget of it is ever laid out in less room than it asked for (\(BrainLogWatch.last))")
        try expect(solve < 6, "and laying the story out is a few milliseconds (\(String(format: "%.2f", solve)) ms)")
        try expect(account.scroll > 1000, "the wheel scrolls it a long way")
        let mid = account.entries[total / 2]
        if let step = mid.stepIDs.first {
            view.browse(.click(step, double: false))
            settleAccount(view, 3)
            try expect(
                account.cells[mid.id] != nil && view.model.pinnedStep == step,
                "and a step in the middle is found by the cursor and its item made")
        }
    }

    /// The detail card of a step that wrote a long file opens the whole of it, with line numbers
    /// and a copy button, in a reader that draws only what is in view.
    private static func checkAccountReader(_ expect: (Bool, String) throws -> Void) throws {
        let (row, builder) = try accountRow("write")
        let bed = try BrainBed(row: row, width: 1440, key: "st-reader", policy: { builder.brainPolicy })
        defer { bed.close() }
        _ = brainPump(10) { bed.view.stage?.hasPicture == true }
        settleAccount(bed.view)
        let view = bed.view
        guard let write = view.model.steps.first(where: { $0.call?.call.name == "Write" }) else {
            throw SelfTestFailure("brain: the write demo has no Write step")
        }
        view.pin(write.id)
        _ = brainPump(4) { view.readout?.page?.subject?.toggleOutput != nil }
        _ = brainPump(0.4)
        guard let readout = view.readout else { throw SelfTestFailure("brain: no readout beside the account") }
        try expect(
            readout.diffReader(of: write.id) == nil && readout.page?.subject?.toggleOutput != nil,
            "a written file's card shows its first lines and offers the whole of it")
        let before = readout.visibleText
        try expect(
            before.contains(NeuralReading.showAllLines(140)) && before.contains(NeuralReading.copyAllLabel),
            "with a button that says how many lines there are and one that copies them all")
        readout.toggleOutput()
        _ = brainPump(3) { readout.diffReader(of: write.id) != nil }
        _ = brainPump(0.4)
        guard let reader = readout.diffReader(of: write.id) else {
            throw SelfTestFailure("brain: pressing the button opened no reader")
        }
        try expect(
            reader.lineCount == 140 && reader.reading.contains("numbered=true"),
            "pressing it opens a reader of all 140 lines, numbered from one (\(reader.reading))")
        try expect(
            reader.visibleRange().count < 60 && readout.visibleText.contains(NeuralReading.showFewerLines),
            "that draws only the lines in view (\(reader.visibleRange().count) of 140) and says how to close it")
        let shown = Double(gtk_widget_get_height(reader.widget))
        let card = Double(gtk_widget_get_height(readout.page?.scroller ?? reader.widget))
        try expect(
            shown >= 200 && shown <= 640 && shown <= card,
            "and the reader fits the card it is in (\(Int(shown)) of \(Int(card)))")
        readout.toggleOutput()
        _ = brainPump(3) { readout.diffReader(of: write.id) == nil }
        try expect(
            readout.diffReader(of: write.id) == nil && readout.visibleText.contains(NeuralReading.showAllLines(140)),
            "pressing again puts the first lines back")
        let wholeFile = NeuralReading.pasteText(of: NeuralReadout.fullDiff(of: write))
        try expect(
            wholeFile.split(separator: "\n", omittingEmptySubsequences: false).count == 140
                && !wholeFile.hasPrefix("+"),
            "and Copy all puts the file itself on the pasteboard, a diff's marks only where it is an edit")
    }
}

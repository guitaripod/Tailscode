import AgentTestSupport
import AppKit
import CodingAgentKit
import TailscodeCore

/// The checks of the two things a chat's brain owes the person who reads it: a head that wears the
/// level the chat is on, and a step's written file that can be read whole. The first is checked
/// from the store and through a real pane's composer, the second through the account's own views
/// and keys: the link and its total, the reader of exactly the file's lines, what it draws and
/// what it costs, where it stands in its card, and what closing it gives back.
@MainActor
enum BrainReaderChecks {
    static func run(_ expect: BrainAccountChecks.Expect) throws -> Int {
        var count = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ label: String) throws {
            if condition { count += 1 } else { failures.append(label) }
        }
        try effortFollowsTheChat(check)
        try effortFollowsThePill(check)
        try wholeFileInTheDetail(check)
        try wholeFileInACard(check)
        try anEditIsReadWithoutNumbers(check)
        try expect(failures.isEmpty, "reader: " + failures.joined(separator: " | "))
        return count
    }

    private static func writing(_ prefix: String, origin: TimeInterval = 1_792_000_000) -> [ChatMessage] {
        NeuralDemo.writing(prefix: prefix, origin: origin)
    }

    private static func settle(_ row: BrainRowView) {
        row.superview?.layoutSubtreeIfNeeded()
        row.layoutSubtreeIfNeeded()
        guard let account = row.account else { return }
        account.refresh(immediate: true)
        account.layoutSubtreeIfNeeded()
        account.realize()
        account.layoutSubtreeIfNeeded()
        account.detail?.layoutSubtreeIfNeeded()
    }

    private static func spin(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func key(_ characters: String, code: UInt16, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    @discardableResult
    private static func press(_ characters: String, code: UInt16, on account: BrainAccountView) -> Bool {
        guard let window = account.window else { return false }
        account.focus()
        return account.handleKey(key(characters, code: code, in: window))
    }

    private static func paint(_ view: NSView) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
    }

    private static func face(_ store: BrainStore, _ index: Int) -> NeuralFace? {
        store.order.indices.contains(index) ? store.model(store.order[index])?.face : nil
    }

    /// A turn that recorded no effort draws the level the chat is on, the older turns as well as
    /// the newest, and a level the turn carried is never overwritten.
    private static func effortFollowsTheChat(_ check: (Bool, String) throws -> Void) throws {
        var messages = writing("a-") + writing("b-", origin: 1_792_003_600)
        let fixture = BrainFixture(messages: messages, width: 1200)
        defer { fixture.tearDown() }
        let store = fixture.store
        try check(store.order.count == 2, "two written turns are two brains (\(store.order.count))")
        guard store.order.count == 2 else { return }
        try check(
            face(store, 0)?.hollow == true && face(store, 1)?.hollow == true,
            "with no level in the chat a turn that recorded none is the server's choice, five hollow bars")
        let options = ["low", "medium", "high", "xhigh"]
        let changed = store.setContext(NeuralBrainContext(effortOptions: options, effort: "xhigh"))
        let expected = NeuralFace(model: nil, effort: "xhigh", options: options)
        try check(changed, "a chat's level reaching the store is news to the heads")
        try check(
            face(store, 1) == expected && face(store, 1)?.hollow == false,
            "the newest turn wears the chat's level, not hollow bars")
        try check(face(store, 0) == expected, "and so does every older turn")
        try check(
            store.setContext(NeuralBrainContext(effortOptions: options, effort: "xhigh")) == false,
            "the same level arriving again with every token changes nothing")
        _ = store.setContext(NeuralBrainContext(effortOptions: options, effort: "low"))
        try check(
            face(store, 0) == NeuralFace(model: nil, effort: "low", options: options)
                && face(store, 1) == NeuralFace(model: nil, effort: "low", options: options),
            "a pick in the dial moves every head with it")
        _ = store.setContext(NeuralBrainContext(effortOptions: options, effort: nil))
        try check(face(store, 0)?.hollow == true, "a chat on the server's choice draws hollow bars again")

        for index in messages.indices where messages[index].role == .assistant && messages[index].id.hasPrefix("b-") {
            messages[index].reasoningEffort = "medium"
        }
        fixture.replace(messages: messages)
        _ = store.setContext(NeuralBrainContext(effortOptions: options, effort: "xhigh"))
        try check(
            face(store, 1) == NeuralFace(model: nil, effort: "medium", options: options),
            "a level the turn recorded itself still wins over the chat's")
        try check(face(store, 0) == expected, "while the turn that recorded none follows the chat")
    }

    /// The same, through a pane: its composer's pill shows a level, and the heads of the
    /// conversation it holds wear that one.
    private static func effortFollowsThePill(_ check: (Bool, String) throws -> Void) throws {
        let options = ["low", "medium", "high", "xhigh"]
        let session = AgentSession(
            id: "reader-effort", agentType: .claudeCode, title: "Reader", createdAt: Date(),
            updatedAt: Date(), reasoningEffort: "xhigh")
        let entry = SessionEntry(
            profileID: "reader-profile", profileName: "reader", host: "reader",
            backendType: .claudeCode, session: session)
        let pane = TranscriptViewController()
        _ = pane.view
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = pane.view
        defer { window.contentView = nil }
        pane.composer.prepare(
            for: entry, backend: MockBackend(agentType: .claudeCode, reasoningEffortOptions: options))
        try check(
            pane.composer.shownEffort == "xhigh" && pane.composer.shownEffortOptions == options,
            "the composer's pill shows the session's level (\(String(describing: pane.composer.shownEffort)))")
        let state = ConversationState(
            messages: writing("p-") + writing("q-", origin: 1_792_003_600), status: .idle,
            connection: .live, hasLoadedTranscript: true)
        pane.show(state: state)
        pane.view.layoutSubtreeIfNeeded()
        let store = pane.brains
        guard store.isActive, store.order.count == 2 else {
            try check(!store.isActive, "a pane that holds two written turns has two brains (\(store.order.count))")
            return
        }
        let expected = NeuralFace(model: nil, effort: "xhigh", options: options)
        try check(
            store.order.allSatisfy { store.model($0)?.face == expected },
            "every head of the pane wears the level its pill shows, none of them hollow")
        try check(
            store.chatContext.effort == "xhigh" && store.liveContext.effort == "xhigh",
            "and the store holds that level for the turns that come next")
    }

    private static func pinnedWrite(
        _ fixture: BrainFixture, index: Int = 0
    ) -> (row: BrainRowView, account: BrainAccountView, step: NeuralStep)? {
        guard let row = fixture.open(index), let account = row.account else { return nil }
        settle(row)
        guard let write = row.model.steps.first(where: { $0.call?.call.name == "Write" }) else { return nil }
        return (row, account, write)
    }

    private static func visibleLink(_ page: AccountReadoutPage) -> String? {
        page.diffs.first?.link.title
    }

    /// The detail column beside the story: the first lines, the link that says how many there are,
    /// the reader of every one of them, the keys, the fit and the way back.
    private static func wholeFileInTheDetail(_ check: (Bool, String) throws -> Void) throws {
        let fixture = BrainFixture(messages: writing("r-"), width: 1420)
        defer { fixture.tearDown() }
        let builtBefore = AccountDiffReader.built
        guard let (row, account, write) = pinnedWrite(fixture) else {
            try check(false, "the written turn opens and has its Write")
            return
        }
        account.choose(write.id, fromAccount: false)
        settle(row)
        guard let detail = account.detail, let block = detail.diffs.first else {
            try check(false, "two columns have a detail that holds the write's diff")
            return
        }
        let words = detail.visibleText
        try check(
            words.contains(NeuralReading.showAllLines(140)) && words.contains(NeuralReading.copyAllLabel),
            "the card shows its first lines with a link that says all 140 and a Copy all")
        try check(
            !words.contains(NeuralReading.showFewerLines) && block.reader == nil,
            "and has opened no reader")
        try check(
            AccountDiffReader.built == builtBefore,
            "a step nobody opened builds nothing of the reader (\(AccountDiffReader.built - builtBefore) built)")
        try check(
            detail.openReader == nil && account.openReader == nil, "the account holds no reader before the link is pressed")

        let fullDiff = NeuralReadout.fullDiff(of: write)
        let pasted = NeuralReading.pasteText(of: fullDiff)
        try check(
            block.allText == pasted
                && pasted.split(separator: "\n", omittingEmptySubsequences: false).count == 140
                && !pasted.hasPrefix("+"),
            "Copy all puts the file itself on the pasteboard, all 140 lines and no marks")

        let scrolledFrom = detail.scroll?.contentView.bounds.minY ?? 0
        press(" ", code: 49, on: account)
        spin(0.25)
        settle(row)
        guard let reader = detail.openReader else {
            try check(false, "Space opens the reader of the open step's file")
            return
        }
        try check(
            AccountDiffReader.built == builtBefore + 1, "one press builds one reader (\(AccountDiffReader.built - builtBefore))")
        try check(
            reader.lineCount == 140 && reader.numbered,
            "it holds exactly 140 lines, numbered from one (\(reader.lineCount) numbered \(reader.numbered))")
        try check(
            detail.visibleText.contains(NeuralReading.showFewerLines)
                && !detail.visibleText.contains(NeuralReading.showAllLines(140)),
            "and the link now says how to close it")
        reader.layoutSubtreeIfNeeded()
        paint(reader)
        let drawn = reader.drawnRange
        try check(
            !drawn.isEmpty && drawn.count < 60 && drawn.lowerBound == 0,
            "it draws only the lines in view, from the first (\(drawn) of 140)")
        try check(
            reader.contentHeight > reader.frame.height * 2,
            "the file is much taller than what is drawn (\(Int(reader.contentHeight)) in \(Int(reader.frame.height)))")
        let shown = reader.frame.height
        let region = detail.scroll?.bounds.height ?? 0
        try check(
            shown >= 200 && shown <= 640 && shown <= region,
            "the reader fits the card it is in (\(Int(shown)) of \(Int(region)))")
        spin(0.2)
        if let scroll = detail.scroll {
            let top = block.convert(block.bounds, to: scroll.documentView!)
            let clip = scroll.contentView.bounds
            try check(
                top.minY >= clip.minY - 1 && top.maxY <= clip.maxY + 1,
                "the card is scrolled until the file and its buttons are in view (\(top) in \(clip), placed \(detail.placements), document \(detail.documentHeight))")
        }
        reader.showLine(100)
        paint(reader)
        let later = reader.drawnRange
        try check(
            later.contains(100) && later.count < 60 && later.lowerBound > 0,
            "scrolled to line 100 it draws that part and still only what is in view (\(later))")
        try check(
            reader.accessibilityLabel() == Localized.text("%lld lines", 140),
            "a screen reader is told it is 140 lines")

        account.refresh(immediate: true)
        settle(row)
        try check(
            detail.openReader != nil && block.expanded,
            "the reader stays open while the card is read again")

        press("o", code: 31, on: account)
        spin(0.25)
        settle(row)
        try check(
            detail.openReader == nil && detail.visibleText.contains(NeuralReading.showAllLines(140)),
            "o closes it and brings the first lines back")
        try check(
            abs((detail.scroll?.contentView.bounds.minY ?? 0) - scrolledFrom) < 1,
            "the card goes back to where it was")
        block.link.onTap?()
        settle(row)
        try check(detail.openReader != nil, "pressing the link opens it too")
        block.link.onTap?()
        settle(row)
        try check(detail.openReader == nil, "and closes it")
        try check(
            row.model.browseState.outputExpanded == false,
            "the browse state agrees that the output is put away")
    }

    /// With the account in one column the step under the cursor opens its card under its row, and
    /// the reader stands inside it at four fifths of what the story shows.
    private static func wholeFileInACard(_ check: (Bool, String) throws -> Void) throws {
        let fixture = BrainFixture(messages: writing("c-"), width: 1180)
        defer { fixture.tearDown() }
        guard let (row, account, write) = pinnedWrite(fixture) else {
            try check(false, "the written turn opens at 1180")
            return
        }
        account.choose(write.id, fromAccount: false)
        account.scrollTo(0, animated: false)
        account.realize()
        settle(row)
        try check(account.detail == nil, "one column has no detail column")
        let pages = account.cells.values.compactMap { ($0 as? AccountWorkCell)?.cursorPage }
        guard let card = pages.first, let block = card.diffs.first else {
            try check(false, "the step under the cursor opens a card with the file's diff (\(pages.count) cards)")
            return
        }
        try check(
            card.visibleText.contains(NeuralReading.showAllLines(140)), "the card offers the whole file")
        _ = press(" ", code: 49, on: account)
        spin(0.6)
        settle(row)
        guard let reader = card.openReader else {
            try check(false, "Space opens the reader inside the card")
            return
        }
        let wanted = max(300, min(640, (account.viewHeight * 0.8).rounded()))
        try check(
            reader.lineCount == 140 && reader.numbered
                && abs(reader.frame.height - min(wanted, reader.contentHeight + 2)) < 1.5,
            "it is the whole file at four fifths of the story's height (\(Int(reader.frame.height)) for \(Int(wanted)))")
        try check(
            account.openReader === reader, "the account finds the reader a card holds")
        let placed = block.convert(block.bounds, to: account.document)
        try check(
            placed.minY >= account.scrollY - 1 && placed.maxY <= account.scrollY + account.viewHeight + 1,
            "the story is scrolled so the file and its buttons are in view (\(placed) in \(account.scrollY)+\(account.viewHeight))")
        press("o", code: 31, on: account)
        spin(0.6)
        settle(row)
        try check(card.openReader == nil && card.visibleText.contains(NeuralReading.showAllLines(140)), "closing gives the first lines back")
    }

    /// An edit is read whole too, with the marks of what changed and no line numbers, because its
    /// lines are not the file's.
    private static func anEditIsReadWithoutNumbers(_ check: (Bool, String) throws -> Void) throws {
        var messages = writing("e-")
        let old = (1...30).map { "let before\($0) = \($0)" }.joined(separator: "\n")
        let new = (1...36).map { "let after\($0) = \($0 * 2)" }.joined(separator: "\n")
        for message in messages.indices {
            for part in messages[message].parts.indices {
                guard case .tool(var call) = messages[message].parts[part].kind, call.name == "Edit" else { continue }
                call.input = .object([
                    "file_path": .string("/home/marcus/Dev/rust/flaccy/linux/shared/src/lyrics/mod.rs"),
                    "old_string": .string(old), "new_string": .string(new),
                ])
                messages[message].parts[part].kind = .tool(call)
            }
        }
        let fixture = BrainFixture(messages: messages, width: 1420)
        defer { fixture.tearDown() }
        guard let row = fixture.open(0), let account = row.account else {
            try check(false, "the edited turn opens")
            return
        }
        settle(row)
        guard let edit = row.model.steps.first(where: { $0.call?.call.name == "Edit" }) else {
            try check(false, "the turn has its Edit")
            return
        }
        let builtBefore = AccountDiffReader.built
        account.choose(edit.id, fromAccount: false)
        settle(row)
        guard let detail = account.detail, let block = detail.diffs.first else {
            try check(false, "the edit's card holds a diff")
            return
        }
        let total = NeuralReadout.fullDiff(of: edit).count
        try check(
            block.link.title == NeuralReading.showAllLines(total) && total >= 66,
            "an edit that changed sixty-six lines says Show all \(total) lines (\(block.link.title))")
        block.toggle()
        spin(0.2)
        settle(row)
        guard let reader = detail.openReader else {
            try check(false, "the edit opens a reader")
            return
        }
        try check(
            reader.lineCount == total && !reader.numbered,
            "it holds all \(total) lines of the diff, without numbers (\(reader.lineCount), numbered \(reader.numbered))")
        try check(
            AccountDiffReader.built == builtBefore + 1, "and builds nothing until it is asked")
        reader.layoutSubtreeIfNeeded()
        paint(reader)
        try check(
            !reader.drawnRange.isEmpty && reader.drawnRange.count < total,
            "it draws the lines in view only (\(reader.drawnRange))")
        let pasted = block.allText ?? ""
        try check(
            pasted.hasPrefix("- let before1 = 1") && pasted.contains("\n+ let after1 = 2"),
            "Copy all keeps an edit's marks")
    }
}

import AppKit
import CodingAgentKit
import TailscodeCore

/// What `--selftest` holds the Agents window to with no server: the demo board draws every section,
/// a verb in flight is off and never sent twice, Stop asks first, the tower opens and closes
/// without leaving a watch behind, the longest title and command a person can make wrap whole and
/// leave nothing ambiguous, and a machine that stopped answering is dimmed with its buttons off.
/// Run in a child under a running application, as the world clock's audit is, because AppKit lays
/// views out on the real main thread there and a suspension resumes on it.
@MainActor
enum AgentsChecks {
    nonisolated static let spec = "agents-check"

    static func runAsChild() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                let notes = try await run()
                print("AGENTS_NOTES \(notes)")
                print("AGENTS_OK")
                exit(0)
            } catch {
                print("AGENTS_FAILED \(error)")
                exit(1)
            }
        }
        app.run()
        exit(1)
    }

    final class Child {
        private let process = Process()
        private let pipe = Pipe()
        private var startFailure: String?

        init() {
            guard let executable = Bundle.main.executablePath else {
                startFailure = "no executable path"
                return
            }
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--bench", AgentsChecks.spec]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                startFailure = "could not start the audit: \(error)"
            }
        }

        func verdict(timeout: TimeInterval = 120) -> (failure: String?, notes: String) {
            if let startFailure { return (startFailure, "") }
            let deadline = Date().addingTimeInterval(timeout)
            let pid = process.processIdentifier
            var exited = false
            while !exited, Date() < deadline {
                var status: Int32 = 0
                let reaped = waitpid(pid, &status, WNOHANG)
                exited = reaped == pid || reaped == -1
                if !exited { usleep(50_000) }
            }
            if !exited {
                kill(pid, SIGKILL)
                return ("the agents audit did not finish in \(Int(timeout)) s", "")
            }
            let lines = String(
                decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            ).split(separator: "\n")
            let notes = lines.last { $0.hasPrefix("AGENTS_NOTES ") }
                .map { String($0.dropFirst("AGENTS_NOTES ".count)) } ?? ""
            guard
                let verdict = lines.last(where: { $0 == "AGENTS_OK" || $0.hasPrefix("AGENTS_FAILED") })
            else { return ("the agents audit printed no verdict", notes) }
            return (
                verdict == "AGENTS_OK" ? nil : String(verdict.dropFirst("AGENTS_FAILED ".count)),
                notes
            )
        }
    }

    static func trace(_ line: String) {
        print("AGENTS_STEP \(line)")
        fflush(stdout)
    }

    static func run() async throws -> String {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("agents: \(label)") }
            checks += 1
        }
        func step(_ name: String) { trace(name) }
        step("demoBoardDraws")
        try await demoBoardDraws(expect)
        step("anEmptyBoardSaysWhatItIsFor")
        try await anEmptyBoardSaysWhatItIsFor(expect)
        step("aVerbInFlightIsOffAndSentOnce")
        try await aVerbInFlightIsOffAndSentOnce(expect)
        step("aFailureStaysInlineAndKeepsTheButtonsLive")
        try await aFailureStaysInlineAndKeepsTheButtonsLive(expect)
        step("aReplyThatNeedsTheChatOpensIt")
        try await aReplyThatNeedsTheChatOpensIt(expect)
        step("stopAsksFirst")
        try await stopAsksFirst(expect)
        step("aMultiLineCommandShowsEveryLine")
        try await aMultiLineCommandShowsEveryLine(expect)
        step("theLongestWordsWrapWhole")
        try await theLongestWordsWrapWhole(expect)
        step("anAwayMachineIsDimmedAndOff")
        try await anAwayMachineIsDimmedAndOff(expect)
        step("theTowerOpensAndClosesWithTheWindow")
        try await theTowerOpensAndClosesWithTheWindow(expect)
        step("theRealPathApproves")
        try await theRealPathApproves(expect)
        step("theHourDrawsLanesAndSelects")
        try await theHourDrawsLanesAndSelects(expect)
        step("theKeyboardAndTheMenuWork")
        try await theKeyboardAndTheMenuWork(expect)
        step("theObjectSitsUnderWhatItIsDoing")
        try await theObjectSitsUnderWhatItIsDoing(expect)
        step("aListedAgentSaysSo")
        try await aListedAgentSaysSo(expect)
        step("theShortcutOpensTheWindow")
        try await theShortcutOpensTheWindow(expect)
        return "\(checks) agents claims"
    }

    private static func demoBoardDraws(_ expect: (Bool, String) throws -> Void) async throws {
        let feed = DemoFeed()
        let controller = AgentsFixtures.controller(feed)
        controller.startWatching()
        await AgentsFixtures.settle(controller)
        let board = feed.board
        try expect(controller.board.items.count == 10, "the demo board is ten lines: the head, four headings, a card, three rows and a finish")
        try expect(AgentsFixtures.allCells(AgentsAskCardView.self, in: controller).count == board.needsYou.count, "a card per ask")
        try expect(AgentsFixtures.allCells(AgentsRowView.self, in: controller).count == board.working.count + board.background.count, "a row per agent")
        try expect(AgentsFixtures.allCells(AgentsFinishRowView.self, in: controller).count == board.finished.count, "a line per ending")
        let summary = AgentsFixtures.cell(AgentsSummaryView.self, in: controller)
        try expect(summary?.sentenceText == board.sentence, "the sentence is Core's, word for word")
        try expect(summary?.watchText == board.watchLine, "the watch line is Core's, word for word")
        try expect(summary?.machineCount == board.machines.count, "a chip for each machine when there is more than one")
        let card = AgentsFixtures.cell(AgentsAskCardView.self, in: controller)
        try expect(card?.block.commandText == board.needsYou.first?.ask.object, "the command is shown word for word")
        try expect(card?.leadText == board.needsYou.first?.ask.lead, "the ask leads with Core's words")
        let rows = AgentsFixtures.allCells(AgentsRowView.self, in: controller)
        try expect(rows.first?.showsStrip == true && rows.first?.childLines == 2, "a watched row has its pulse and its two agents hanging under it")
        try expect(rows.last?.showsStrip == false, "a background row draws no pulse")
        try expect(!(rows.first?.elapsedText ?? "").isEmpty, "a row says how long it has been going")
        let faults = AgentsFixtures.allCells(AgentsRowView.self, in: controller).flatMap {
            AgentsFixtures.problems(in: $0, label: "row")
        }
        try expect(faults.isEmpty, "the demo rows are whole: \(faults.prefix(3))")
        controller.stopWatching()
    }

    private static func anEmptyBoardSaysWhatItIsFor(_ expect: (Bool, String) throws -> Void) async throws {
        let feed = DemoFeed()
        let controller = AgentsFixtures.controller(feed)
        controller.startWatching()
        feed.replace(.empty)
        await AgentsFixtures.settle(controller)
        try expect(controller.board.items.count == 2, "an empty board is its head and one calm line")
        try expect(AgentsFixtures.cell(AgentsEmptyView.self, in: controller) != nil, "the calm line is drawn")
        try expect(
            AgentsFixtures.cell(AgentsSummaryView.self, in: controller)?.sentenceText == AgentBoard.empty.sentence,
            "the head says that nothing is running")
        controller.stopWatching()
    }

    private static func aVerbInFlightIsOffAndSentOnce(_ expect: (Bool, String) throws -> Void) async throws {
        let feed = DemoFeed()
        feed.replyDelay = .milliseconds(200)
        let controller = AgentsFixtures.controller(feed)
        controller.startWatching()
        await AgentsFixtures.settle(controller)
        guard let board = Optional(feed.board), let card = board.needsYou.first else {
            throw SelfTestFailure("agents: the demo board has a card")
        }
        var block = AgentsFixtures.cell(AgentsAskCardView.self, in: controller)?.block
        try expect(block?.buttons.allSatisfy(\.isEnabled) == true, "a fresh card can be answered")
        (block?.buttons.last as? NSButton)?.performClick(nil)
        controller.actions.decide(card.id, ask: card.ask, allow: true)
        block = AgentsFixtures.cell(AgentsAskCardView.self, in: controller)?.block
        try expect(block?.buttons.allSatisfy { !$0.isEnabled } == true, "Approve and Deny are off while the answer is out")
        try expect((block?.buttons.last as? NSButton)?.title == Localized.text("Approving…"), "and the button says what it is doing")
        try await Task.sleep(for: .milliseconds(450))
        try expect(feed.asked.filter { $0.hasPrefix("approve") }.count == 1, "a double press sends one answer")
        block = AgentsFixtures.cell(AgentsAskCardView.self, in: controller)?.block
        try expect((block?.buttons.last as? NSButton)?.title == Localized.text("Approved"), "a sent answer shows as done, and the card stays until the board takes it away")
        try expect(block?.buttons.allSatisfy { !$0.isEnabled } == true, "and cannot be sent again")
        controller.stopWatching()
    }

    private static func aFailureStaysInlineAndKeepsTheButtonsLive(_ expect: (Bool, String) throws -> Void) async throws {
        let feed = DemoFeed()
        feed.replyDelay = .milliseconds(50)
        feed.reply = .failed("the machine did not answer")
        let controller = AgentsFixtures.controller(feed)
        controller.startWatching()
        await AgentsFixtures.settle(controller)
        guard let card = feed.board.needsYou.first else { throw SelfTestFailure("agents: a card") }
        controller.actions.decide(card.id, ask: card.ask, allow: false)
        try await Task.sleep(for: .milliseconds(250))
        let block = AgentsFixtures.cell(AgentsAskCardView.self, in: controller)?.block
        try expect(block?.statusText.contains("the machine did not answer") == true, "a failure says why, on the card")
        try expect(block?.buttons.allSatisfy(\.isEnabled) == true, "and the buttons stay live")
        controller.stopWatching()
    }

    private static func aReplyThatNeedsTheChatOpensIt(_ expect: (Bool, String) throws -> Void) async throws {
        let feed = DemoFeed()
        feed.replyDelay = .milliseconds(30)
        feed.reply = .needsChat
        let controller = AgentsFixtures.controller(feed)
        var opened: [String] = []
        controller.onOpenChat = { opened.append($0) }
        controller.startWatching()
        await AgentsFixtures.settle(controller)
        guard let card = feed.board.needsYou.first else { throw SelfTestFailure("agents: a card") }
        controller.actions.decide(card.id, ask: card.ask, allow: true)
        try await Task.sleep(for: .milliseconds(200))
        try expect(opened == [card.id], "needsChat opens that session's chat and nothing else")
        controller.stopWatching()
    }

    private static func stopAsksFirst(_ expect: (Bool, String) throws -> Void) async throws {
        let feed = DemoFeed()
        feed.replyDelay = .milliseconds(30)
        let controller = AgentsFixtures.controller(feed)
        var asked: [String] = []
        var proceed: (() -> Void)?
        controller.confirmStopOverride = { title, go in
            asked.append(title)
            proceed = go
        }
        controller.startWatching()
        await AgentsFixtures.settle(controller)
        guard let row = feed.board.working.first else { throw SelfTestFailure("agents: a working row") }
        controller.select(key: row.id, from: .code)
        (controller.window as? AgentsWindow)?.onStop?()
        try expect(asked == [row.title], "Command-period asks first, naming the chat")
        try expect(!feed.asked.contains { $0.hasPrefix("stop") }, "and sends nothing until the answer is yes")
        try expect(AgentsWords.stopQuestion(row.title).contains(row.title), "the question names the chat")
        proceed?()
        try await Task.sleep(for: .milliseconds(200))
        try expect(feed.asked.contains("stop:" + row.id), "a yes stops it")
        try expect(controller.actions.stopPhase(for: row.id) == .sent(.stop), "and the peek says it was sent")
        controller.stopWatching()
    }

    private static func theLongestWordsWrapWhole(_ expect: (Bool, String) throws -> Void) async throws {
        let title = String(repeating: "A very long title that keeps going ", count: 6).prefix(200)
        let command = String(repeating: "swift build -c release --product TailscodeMac && ", count: 12).prefix(600)
        for width in [1180, 860] as [CGFloat] {
            let feed = DemoFeed()
            let controller = AgentsFixtures.controller(feed, width: width)
            controller.startWatching()
            feed.replace(AgentsFixtures.longBoard(title: String(title), command: String(command)))
            await AgentsFixtures.settle(controller)
            let cards = AgentsFixtures.allCells(AgentsAskCardView.self, in: controller)
            let shown = cards.first?.block.commandText ?? ""
            try expect(shown == feed.board.needsYou.first?.ask.object, "the card shows the whole ask, word for word, at \(Int(width))")
            try expect(shown.count >= 400, "the command is long enough to wrap (\(shown.count) characters)")
            let rowViews = (0..<controller.board.table.numberOfRows).compactMap {
                controller.board.table.rowView(atRow: $0, makeIfNecessary: true)
            }
            for rowView in rowViews {
                guard let cell = rowView.view(atColumn: 0) as? NSView else { continue }
                let faults = AgentsFixtures.problems(in: cell, label: "\(type(of: cell)) at \(Int(width))")
                try expect(faults.isEmpty, "a 200-character title and a 600-character command wrap without clipping or ambiguity: \(faults.prefix(2))")
                try expect(rowView.frame.height + 1 >= cell.fittingSize.height, "the row is as tall as its words at \(Int(width))")
            }
            controller.select(key: feed.board.needsYou[0].id, from: .code)
            await AgentsFixtures.settle(controller)
            controller.peek.view.layoutSubtreeIfNeeded()
            let peekFaults = AgentsFixtures.problems(in: controller.peek.view, label: "peek at \(Int(width))")
            try expect(peekFaults.isEmpty, "the peek of the same ask is whole: \(peekFaults.prefix(2))")
            try expect(controller.peek.texts.contains(String(title)), "the peek carries the whole title")
            controller.stopWatching()
        }
    }

    private static func anAwayMachineIsDimmedAndOff(_ expect: (Bool, String) throws -> Void) async throws {
        let feed = DemoFeed()
        let controller = AgentsFixtures.controller(feed)
        controller.context.lastHeard = { profile in profile == "p-away" ? Date().addingTimeInterval(-180) : nil }
        controller.startWatching()
        feed.replace(AgentsFixtures.awayBoard())
        await AgentsFixtures.settle(controller)
        let cards = AgentsFixtures.allCells(AgentsAskCardView.self, in: controller)
        try expect(cards.count == 3, "three machines ask")
        let byName = Dictionary(uniqueKeysWithValues: cards.compactMap { card in card.card.map { ($0.machine, card) } })
        let up = byName["machine up"]
        let unknown = byName["machine unknown"]
        let away = byName["machine away"]
        try expect(up?.block.buttons.allSatisfy(\.isEnabled) == true && up?.alphaValue == 1, "a machine that answers is live")
        try expect(unknown?.block.buttons.allSatisfy(\.isEnabled) == true && unknown?.block.statusText.isEmpty == true, "a machine nobody has asked yet is live and says nothing")
        try expect(away?.block.buttons.allSatisfy { !$0.isEnabled } == true, "a machine that stopped answering has its buttons off")
        try expect(away?.block.statusText.hasPrefix(Localized.text("Not answering")) == true && away?.block.statusText.contains("last seen") == true, "and says when it was last seen")
        let awayRow = AgentsFixtures.allCells(AgentsRowView.self, in: controller).first
        try expect(awayRow?.row?.isAway == true && awayRow?.noteText.isEmpty == false, "a row of an away machine says so")
        controller.context.lastHeard = { _ in nil }
        controller.board.refresh()
        controller.startWatching()
        feed.replace(AgentsFixtures.awayBoard())
        await AgentsFixtures.settle(controller)
        let again = AgentsFixtures.allCells(AgentsAskCardView.self, in: controller).first { $0.card?.machine == "machine away" }
        try expect(again?.block.statusText == Localized.text("Not answering"), "never heard from at all, it says only that it is not answering")
        controller.stopWatching()
    }
}

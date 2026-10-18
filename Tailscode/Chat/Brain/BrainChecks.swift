#if DEBUG
    import CodingAgentKit
    import TailscodeCore
    import UIKit

    /// What `TAILSCODE_NEURAL_CHECK=1` runs in the app: the claims the brain makes, asserted against
    /// the real classes in the real process, one line a claim in the log (`brain-check PASS|FAIL
    /// name detail`) and a total at the end. The claims that need no screen are asserted from the
    /// demo's own turns; the ones about the move, the clocks and the cost read the rows on screen.
    @MainActor
    enum BrainChecks {
        struct Result {
            let name: String
            let passed: Bool
            let detail: String
        }

        private static var results: [Result] = []

        private static func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
            let result = Result(name: name, passed: passed, detail: passed ? "" : detail())
            results.append(result)
            AppLogger.ui.info(
                "brain-check \(passed ? "PASS" : "FAIL") \(name) \(result.detail)")
        }

        static var isEnabled: Bool {
            ProcessInfo.processInfo.environment["TAILSCODE_NEURAL_CHECK"] != nil
        }

        private static func turns(_ messages: [ChatMessage], running: Bool = false) -> [NeuralTurn] {
            NeuralTurns.partition(messages: messages, running: running)
        }

        static func runModel() {
            results = []
            let demo = NeuralDemo.conversation()
            let all = turns(demo)
            let build = NeuralBrainModel(turn: all[0])
            let long = NeuralBrainModel(turn: all[1])

            let policy = NeuralOpenPolicy(turns: all)
            check("closed by default", policy.openTurnID == nil, "open=\(policy.openTurnID ?? "-")")
            var choices = policy.toggle(turnID: all[0].id)
            let opened = NeuralOpenPolicy(turnIDs: all.map(\.id) + ["new"], choices: choices)
            check("a new turn leaves the open one open", opened.openTurnID == all[0].id)
            choices = opened.toggle(turnID: all[1].id)
            check(
                "opening one closes the other",
                NeuralOpenPolicy(turnIDs: all.map(\.id), choices: choices).openTurnID == all[1].id)

            let card = build.brainCard(now: Date())
            let words = card.headline.pieces.map(\.text).joined(separator: " ")
            check(
                "a fixed error is not a failure in the card",
                { if case .doneAfterRetries = card.verdict { return true } else { return false } }()
                    && !words.lowercased().contains("failed")
                    && words.lowercased().contains("fixed"),
                words)
            check("a fixed error rings dashed, never solid", card.ringZones.isEmpty && !card.repairedZones.isEmpty)
            check("the card's edge is settled", card.edge == .settled)
            check(
                "the card's third line is the agent's first words",
                card.quote != nil || card.digest.isEmpty == false)

            runLiveAndSettle(all)
            runList(long)
            runIncremental()
            runKeys(long)
            runAccount(long, build: build)
            runMetrics(long)
            runMove(long)
            runWords(all)
            runEffort()
            runReader()
            let failed = results.filter { !$0.passed }.count
            AppLogger.ui.info("brain-check model done pass=\(results.count - failed) fail=\(failed)")
        }

        private static func runLiveAndSettle(_ all: [NeuralTurn]) {
            var running = all[1]
            running.outcome = .running
            if let last = running.steps.indices.last { running.steps[last].status = .running }
            var model = NeuralBrainModel(
                turn: running, context: NeuralBrainContext(activity: .usingTool(name: "Bash", kind: .shell)))
            model.update(turn: running, context: NeuralBrainContext(activity: .usingTool(name: "Bash", kind: .shell)))
            let live = model.liveCard
            check("a running turn has a live card", live != nil)
            if let live {
                let reading = live.reading(now: Date())
                check("the live card says Working", reading.word == NeuralReading.verdictWorking, reading.word)
                check("the live card breathes", live.isAnimated(reduceMotion: false) && model.needsLiveCardClock)
                check("reduced motion stops the live card's clock", !model.needsLiveCardClock(reduceMotion: true))
                check("the live card has a step in flight", live.flight != nil)
                let line = live.line(now: Date(), compact: true)
                check("compact live line drops the output", {
                    if case .none = line.trailing { return true }
                    return line.kind == .quote
                }() || { if case .silence = line.trailing { return true }; return false }())
            }
            let settled = NeuralBrainModel(turn: all[1])
            check("a settled turn has no live card", settled.liveCard == nil && !settled.needsLiveCardClock)
            let mid = NeuralCardSettle.at(0.2)
            check("settle is one 400 ms move", NeuralCardSettle.duration == 0.4 && !mid.isDone && NeuralCardSettle.at(0.4).isDone)
            check("a card that settled off screen is simply settled", NeuralCardSettle.settled.isDone)
            check("reduced motion settles at once", NeuralCardSettle.at(0.01, reduceMotion: true).isDone)
            var clock = NeuralCardSettleClock()
            clock.observe(running: true, now: 1)
            let moment = clock.observe(running: false, now: 5)
            check("the settle clock notices the end of a turn", moment && clock.isSettling(now: 5.2) && !clock.isSettling(now: 5.5))
            var waiting = all[1]
            waiting.outcome = .running
            if let index = waiting.steps.lastIndex(where: { NeuralReading.isTool($0) }) {
                waiting.steps[index].status = .waitingApproval
            }
            let ask = NeuralBrainModel(turn: waiting).liveCard
            check("a waiting turn says Waiting for you", ask?.reading(now: Date()).word == NeuralReading.verdictWaiting)
        }

        private static func contextFor(_ isLatest: Bool) -> NeuralBrainContext {
            NeuralBrainContext(providerID: "p", effortOptions: isLatest ? ["low", "high"] : ["low"])
        }

        private static func incrementalMatches(_ grown: BrainStore, _ fresh: BrainStore, count: Int) -> Bool {
            for number in 1...count {
                guard let id = fresh.turnID(atBrain: number), grown.turnID(atBrain: number) == id,
                    let left = grown.model(for: id), let right = fresh.model(for: id),
                    left.turn == right.turn
                else { return false }
            }
            return true
        }

        private static func runIncremental() {
            var messages: [ChatMessage] = []
            let grown = BrainStore()
            var identical = true
            var layoutsEqual = true
            for index in 0..<40 {
                let turn = NeuralDemo.largeTurn(steps: 24, prefix: "i\(index)-", origin: 1_792_000_000 + Double(index) * 4000)
                messages.append(contentsOf: turn)
                var tailCount = turn.count
                for growth in 0..<3 {
                    if growth > 0 {
                        let more = NeuralDemo.largeTurn(steps: 24 + growth * 6, prefix: "i\(index)-", origin: 1_792_000_000 + Double(index) * 4000)
                        messages.removeLast(tailCount)
                        messages.append(contentsOf: more)
                        tailCount = more.count
                    }
                    let layout = grown.prepare(messages: messages, running: true, awaiting: .none) { _, latest in contextFor(latest) }
                    let fresh = BrainStore()
                    let reference = fresh.prepare(messages: messages, running: true, awaiting: .none) { _, latest in contextFor(latest) }
                    identical = identical && incrementalMatches(grown, fresh, count: index + 1)
                    for number in 1...(index + 1) {
                        guard let id = fresh.turnID(atBrain: number) else { continue }
                        let left = layout.turn(startingAt: grown.anchorID(of: id) ?? "")?.row.stamp
                        let right = reference.turn(startingAt: fresh.anchorID(of: id) ?? "")?.row.stamp
                        if left != right { layoutsEqual = false }
                    }
                }
            }
            check("the incremental store reads the same turns as a fresh one", identical)
            check("the incremental layout carries the same rows as a fresh one", layoutsEqual)
        }

        private static func runList(_ model: NeuralBrainModel) {
            let large = NeuralBrainModel(turn: turns(NeuralDemo.largeTurn(steps: 174, prefix: "x-"))[0])
            let list = large.stepList
            let window = list.rows(atOffset: 0, height: 300, input: .touch)
            check("the list draws a window, not the turn", window.count <= 12 && list.total > 100, "\(window.count)/\(list.total)")
            let heights = window.map { $0.height(input: .touch) }
            check("rows are 32, and 48 for a note", heights.allSatisfy { $0 == 32 || $0 == 48 }, "\(Set(heights))")
            let sum = list.visibleRows.reduce(0.0) { $0 + $1.height(input: .touch) }
            check("content height is the sum of row heights", abs(list.contentHeight(input: .touch) - sum) < 0.01)
            let said = list.visibleRows.first { $0.isSaid }
            check("a note is two lines tall", said?.height(input: .touch) == 48 && said?.height(input: .pointer) == 40)
            let far = list.rows(atOffset: list.contentHeight(input: .touch) - 100, height: 300, input: .touch)
            check("a window at the end costs a window", far.count <= 12 && far.last?.id == list.visibleRows.last?.id)
        }

        private static func runKeys(_ start: NeuralBrainModel) {
            var model = start
            model.browse(.key(.down))
            check("down sets the cursor on the first step", model.pinnedStep == model.steps.first?.id)
            model.browse(.key(.character("s")))
            let said = model.steps.first { NeuralReading.isNote($0) }?.id
            check("s goes to the next thing it said", model.pinnedStep == said)
            model.browse(.key(.character("1")))
            check("1 solos SAID", model.stepList.filter.zones == [.say])
            model.browse(.key(.character("0")))
            check("0 clears the zones", model.stepList.filter.zones.isEmpty)
            model.browse(.key(.character("!")))
            check("! shows failed only", model.stepList.filter.failedOnly && model.stepList.visibleCount == model.stepList.failedCount)
            model.browse(.key(.escape))
            check("Esc clears the filter before the cursor", !model.stepList.filter.failedOnly && model.pinnedStep != nil)
            model.browse(.key(.escape))
            check("Esc then clears the cursor", model.pinnedStep == nil)
            let effects = model.browse(.key(.escape))
            check("Esc then collapses the brain", effects.contains(.collapseBrain))
            model.browse(.key(.character("/")))
            check("/ focuses the search", model.browseState.focus == .search && model.browseState.searchOpen)
            model.browse(.searchText("ffmpeg"))
            check("search filters the list", model.stepList.isFiltered && model.stepList.visibleCount < model.stepList.total)
            model.browse(.key(.escape))
            check("Esc clears the search first", model.stepList.filter.query.isEmpty)
            model.browse(.key(.character("c"), [.command]))
            check("a chord that is not the list's does nothing", model.pinnedStep == nil)
            let effectsAfterPage = model.browse(.key(.pageDown))
            check("PageDown walks eight", effectsAfterPage.contains { if case .scrollTo = $0 { return true } else { return false } })
            model.browse(.hover(model.steps[3].id))
            check("hover previews and leaves the cursor", model.previewedStep == model.steps[3].id && model.pinnedStep != model.steps[3].id)
        }

        private static func runAccount(_ model: NeuralBrainModel, build: NeuralBrainModel) {
            let account = model.account(answer: "Done. It is at out/demo.mp4.", prompt: "Make a product demonstration .mp4")
            check("the account has an Asked", account.asked?.text == "Make a product demonstration .mp4")
            check("the account's result names what came of it", account.result?.answer != nil)
            check("the account has a said item", account.items.contains { if case .said = $0 { return true } else { return false } })
            check("a fixed error is amber in the header", account.header.clause != nil && account.header.pillWord == NeuralReading.verdictDone)
            var ask = model
            var turn = ask.turn
            turn.outcome = .running
            if let index = turn.steps.lastIndex(where: { NeuralReading.isTool($0) }) { turn.steps[index].status = .waitingApproval }
            ask.update(turn: turn, context: .none)
            let waiting = ask.account()
            check("needs-you leads the account", waiting.needsYou && waiting.askItem != nil)
            ask.browse(.key(.character("a")))
            check("a goes to the ask", ask.drainAccountEffects().contains { if case .goToAsk = $0 { return true } else { return false } })
            if let said = model.steps.first(where: { NeuralReading.isNote($0) }) {
                var replying = model
                replying.browse(.reply(said.id))
                let outbox = replying.drainAccountEffects()
                var quote: String?
                if case .reply(let text)? = outbox.first { quote = text }
                check("reply quotes the words and sends nothing", quote?.hasPrefix("> ") == true && outbox.count == 1, quote ?? "-")
            }
        }

        private static func runMetrics(_ model: NeuralBrainModel) {
            let phone = NeuralStageMetrics.make(width: 374, density: .compact, input: .touch, zonesWithSteps: 6)
            check("a phone is an accordion", phone.arrangement == .accordion)
            check("a phone's touch rows are 32", phone.listRowHeight == 32 && Double(phone.rowsShown) * 32 <= NeuralStageMetrics.listMaxHeight(input: .touch))
            check("a phone's head is 280 at most", phone.stage.width <= 280)
            let single = NeuralStageMetrics.make(width: 1280, density: .compact, input: .touch, zonesWithSteps: 6)
            let split = NeuralStageMetrics.make(width: 1440, density: .compact, input: .touch, zonesWithSteps: 6)
            check("1280 is one column of account", single.arrangement == .split && single.accountLayout == .single)
            check("1440 splits the account in two", split.accountLayout == .split && split.detail != nil)
            check("a wide card keeps the zone strip", NeuralStageMetrics.cardLayout(width: 740) == .wide && NeuralStageMetrics.cardLayout(width: 374) == .narrow)
            check("a narrow card drops the strip", model.brainCard(now: Date()).fit(width: 374).contains(.zoneStrip) == false)
            check("the footer keeps Rows and Share on a phone", {
                let kinds = NeuralStageMetrics.footerParts(width: 374).map(\.kind)
                return kinds.contains(.rows) && kinds.contains(.share) && !kinds.contains(.close)
            }())
        }

        private static func runMove(_ model: NeuralBrainModel) {
            let metrics = NeuralStageMetrics.make(width: 374, density: .compact, input: .touch, zonesWithSteps: 6)
            let open = NeuralTransition.make(.open, metrics: metrics, nodeCount: model.nodeCount)
            let start = open.frame(at: 0)
            let end = open.frame(at: 1)
            check("the move starts on the card's picture", start.traveller == metrics.card.picture, "\(start.traveller)")
            check("the move ends on the stage", end.traveller == metrics.stage && end.rowHeight == metrics.rowHeight)
            let midway = open.frame(at: 0.5)
            let back = open.reversed(from: 0.5)
            check(
                "a reversal starts where the move was",
                abs(back.frame(at: 0).traveller.x - midway.traveller.x) < 0.01
                    && abs(back.frame(at: 0).rowHeight - midway.rowHeight) < 0.01)
            check("a reversal ends on the card", back.frame(at: 1).traveller == metrics.card.picture)
            check("open runs 320 ms and close 220", open.duration == 0.32 && NeuralTransition.make(.close, metrics: metrics, nodeCount: 3).duration == 0.22)
            let calm = NeuralTransition.make(.open, metrics: metrics, nodeCount: 20, reduceMotion: true)
            check("reduced motion is a 120 ms crossfade", calm.duration == 0.12 && calm.frame(at: 0.25).traveller == metrics.card.picture)
            let strained = NeuralTransition.make(.open, metrics: metrics, nodeCount: 20, level: .strained)
            check("a strained window is 160 ms with no sweep", strained.duration == 0.16 && strained.frame(at: 0.5).sweepAmount == 0)
            let live = NeuralTransition.make(.open, metrics: metrics, nodeCount: 20, live: true)
            check("a live open carries the swell", live.fromLive && live.frame(at: 0.5, clock: 0.95).travellerSwell < 1.0001)
        }

        private static func runWords(_ all: [NeuralTurn]) {
            let build = NeuralBrainModel(turn: all[0])
            let rows = build.stepList.visibleRows
            check("a fixed step is Fixed on retry, in amber", rows.contains { $0.verdict == .fixed && $0.markTone == .attention })
            check("no step of a fixed turn reads Failed", !rows.contains { $0.verdict == .failed })
            check("plain titles read as a sentence", rows.contains { $0.title.hasPrefix("Built") || $0.title.hasPrefix("Ran") })
            let result = build.account(answer: "ok", prompt: "p").result
            check("the result lists a check after a retry", result?.checks.contains { $0.verdict == .fixed } == true)
        }

        private static func writingTurn(prefix: String) -> NeuralTurn? {
            turns(NeuralDemo.writing(prefix: prefix)).first
        }

        /// A turn with an edit of forty lines inside one file, which is a diff with marks and no
        /// numbers.
        private static func editingMessages() -> [ChatMessage] {
            let before = (1...20).map { "let old\($0) = \($0)" }.joined(separator: "\n")
            let after = (1...22).map { "let new\($0) = \($0 * 2)" }.joined(separator: "\n")
            let call = ToolCall(
                id: "edit-call", name: "Edit", status: .completed,
                input: .object([
                    "file_path": .string("/tmp/edit.swift"), "old_string": .string(before),
                    "new_string": .string(after),
                ]), output: "The file has been updated.")
            let origin = Date(timeIntervalSince1970: 1_792_100_000)
            return [
                ChatMessage(
                    id: "e-u", role: .user, agentType: .claudeCode,
                    parts: [MessagePart(id: "t", kind: .text("Rename the constants."))],
                    createdAt: origin, completedAt: origin),
                ChatMessage(
                    id: "e-m1", role: .assistant, agentType: .claudeCode,
                    parts: [
                        MessagePart(id: "p0", kind: .reasoning("Renaming them in one edit.")),
                        MessagePart(id: "p1", kind: .tool(call)),
                        MessagePart(id: "p2", kind: .text("Done.")),
                    ],
                    createdAt: origin.addingTimeInterval(5), completedAt: origin.addingTimeInterval(6)),
            ]
        }

        private static func firstStep(of model: NeuralBrainModel, named name: String) -> NeuralStep? {
            model.steps.first { $0.call?.call.name == name }
        }

        private static func descendants(of view: UIView) -> [UIView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }

        private static func card(
            for stepID: String, in model: NeuralBrainModel, expanded: Bool, viewport: CGFloat = 600,
            copied: ((String) -> Void)? = nil
        ) -> BrainStepCard? {
            let value = NeuralReadout.make(model: model, subject: .step(stepID), now: Date())
            guard case .step(let step) = value.body else { return nil }
            let card = BrainStepCard()
            card.readerViewport = { viewport }
            card.onCopy = copied
            card.frame = CGRect(x: 0, y: 0, width: 360, height: 10)
            card.configure(
                step: step, model: model, style: .init(isPreview: false, isLive: false, bordered: true),
                outputExpanded: expanded)
            let height = card.fittedHeight(width: 360)
            card.frame = CGRect(x: 0, y: 0, width: 360, height: height)
            card.layoutIfNeeded()
            return card
        }

        private static func button(titled title: String, in view: UIView) -> BrainTextButton? {
            descendants(of: view).compactMap { $0 as? BrainTextButton }
                .first { $0.accessibilityLabel == title }
        }

        private static func reader(in view: UIView) -> BrainDiffReaderView? {
            descendants(of: view).compactMap { $0 as? BrainDiffReaderView }.first
        }

        /// The brain's header wears the level the chat is on for a turn whose own messages
        /// recorded none, for the latest turn and for the older ones, and a level a turn carried
        /// wins.
        private static func runEffort() {
            let options = ["low", "medium", "high", "xhigh"]
            let older = NeuralDemo.writing(prefix: "a-", origin: 1_792_000_000)
            let newer = NeuralDemo.writing(prefix: "b-", origin: 1_792_200_000)
            let messages = older + newer
            func faces(effort: String?) -> [NeuralFace] {
                let controller = ChatBrainController()
                _ = controller.layout(
                    reading: .init(messages: messages, running: false, awaiting: .none),
                    facts: StatusFacts(), call: nil, providerID: nil, effortOptions: options,
                    effort: effort)
                return (1...2).compactMap { number in
                    controller.store.turnID(atBrain: number)
                        .flatMap { controller.store.model(for: $0)?.face }
                }
            }
            guard ChatBrainController().isActive else {
                check("the brain is drawn here, so its header can be read", false)
                return
            }
            let named = faces(effort: "xhigh")
            let expected = NeuralFace(model: nil, providerID: nil, effort: "xhigh", options: options)
            check(
                "every turn wears the chat's level when it recorded none",
                named.count == 2 && named.allSatisfy { !$0.hollow && $0.effort == expected.effort },
                "\(named.map { "\($0.effort)/\($0.hollow)" })")
            let none = faces(effort: nil)
            check(
                "a chat with no level leaves the server deciding",
                none.count == 2 && none.allSatisfy { $0.hollow }, "\(none.map(\.hollow))")
            let high = faces(effort: "low")
            check(
                "another level draws another number of bars",
                high.count == 2 && high.allSatisfy { $0.effort < expected.effort && !$0.hollow },
                "\(high.map(\.effort))")
            let store = BrainStore()
            func latestFace(_ effort: String?) -> NeuralFace? {
                _ = store.prepare(messages: messages, running: false, awaiting: .none) { _, _ in
                    NeuralBrainContext(effortOptions: options, effort: effort)
                }
                return store.turnID(atBrain: 2).flatMap { store.model(for: $0)?.face }
            }
            let before = latestFace("low")
            let after = latestFace("xhigh")
            check(
                "a pick on the pill redraws the brains already held",
                before != nil && after != nil && before != after && after?.hollow == false)
            var own = turns(messages)[0]
            own.effort = "low"
            let kept = NeuralBrainModel(turn: own, context: NeuralBrainContext(effortOptions: options, effort: "xhigh")).face
            check("a level the turn carried wins", kept.effort == high.first?.effort && !kept.hollow)
        }

        /// The card of a step that wrote a long file says how long it is, opens the whole of it in
        /// a reader that draws only the lines in view, fits the window it is in, copies the whole
        /// of it, and builds nothing of this for a step nobody opened.
        private static func runReader() {
            guard let turn = writingTurn(prefix: "r-") else {
                check("the writing turn exists", false)
                return
            }
            var model = NeuralBrainModel(turn: turn)
            guard let write = firstStep(of: model, named: "Write") else {
                check("the writing turn has a Write", false)
                return
            }
            let whole = NeuralReadout.fullDiff(of: write)
            check("a Write reads as 140 lines, every one added", whole.count == 140 && NeuralReading.isWholeFile(whole))

            let builtBefore = BrainDiffReaderView.built
            var pasted: String?
            guard let closed = card(for: write.id, in: model, expanded: false, copied: { pasted = $0 })
            else {
                check("the closed card is made", false)
                return
            }
            check("a step nobody opened builds no reader", BrainDiffReaderView.built == builtBefore && reader(in: closed) == nil)
            let more = NeuralReading.showAllLines(140)
            check("the link says how many lines there are", button(titled: more, in: closed) != nil, more)
            check("the plain text of the count is gone", !descendants(of: closed).contains { ($0 as? UILabel)?.attributedText?.string.contains("125 more") == true })
            let copy = button(titled: NeuralReading.copyAllLabel, in: closed)
            check("the card offers Copy all", copy != nil)
            copy?.sendActions(for: .touchUpInside)
            check(
                "Copy all puts the whole file on the pasteboard",
                pasted == NeuralReading.pasteText(of: whole) && pasted?.split(separator: "\n", omittingEmptySubsequences: false).count == 140,
                "\(pasted?.count ?? -1)")
            check("the button says Copied for a moment", copy?.accessibilityLabel == Localized.text("Copied"))

            guard let open = card(for: write.id, in: model, expanded: true, viewport: 600),
                let readerView = reader(in: open)
            else {
                check("the open card has a reader", false)
                return
            }
            check("expanding opens a reader of exactly 140 lines", readerView.lines.count == 140)
            check("a file written whole is numbered", readerView.isNumbered)
            check("the reader says how many lines it holds", readerView.accessibilityLabel == Localized.text("%lld lines", 140))
            check("the link becomes Show fewer lines", button(titled: NeuralReading.showFewerLines, in: open) != nil)
            check("the reader fits the window with both buttons", readerView.frame.height + 82 <= 600 && readerView.frame.height >= 160, "\(readerView.frame.height)")
            let tall = card(for: write.id, in: model, expanded: true, viewport: 2000).flatMap { reader(in: $0) }
            check("the reader is never taller than 640", (tall?.frame.height ?? 0) <= 640, "\(tall?.frame.height ?? -1)")
            readerView.layoutIfNeeded()
            let canvas = UIGraphicsImageRenderer(size: readerView.bounds.size)
            _ = canvas.image { readerView.layer.render(in: $0.cgContext) }
            let window = Int(readerView.bounds.height / readerView.lineHeight) + 4
            check("the reader draws only the lines in view", readerView.visibleRange().count <= window && readerView.visibleRange().first == 0, "\(readerView.visibleRange())")
            check("a hundred and forty lines draw as many as thirty", readerView.drawnLines <= window && readerView.drawnLines > 0, "\(readerView.drawnLines)")
            readerView.contentOffset = CGPoint(x: 0, y: readerView.contentHeight)
            readerView.layoutIfNeeded()
            _ = canvas.image { readerView.layer.render(in: $0.cgContext) }
            check("scrolled to the end it draws the last line and still few", readerView.visibleRange().upperBound == 140 && readerView.drawnLines <= window, "\(readerView.visibleRange())")

            let shut = card(for: write.id, in: model, expanded: false)
            check("closing restores the first lines", shut.map { reader(in: $0) == nil && button(titled: more, in: $0) != nil } == true)

            let edit = NeuralBrainModel(turn: turns(editingMessages())[0])
            if let step = firstStep(of: edit, named: "Edit"), let editCard = card(for: step.id, in: edit, expanded: true),
                let editReader = reader(in: editCard)
            {
                let lines = NeuralReadout.fullDiff(of: step)
                check(
                    "an edit opens a reader with its marks and no numbers",
                    editReader.lines.count == lines.count && lines.count == 42 && !editReader.isNumbered && !NeuralReading.isWholeFile(lines),
                    "\(lines.count)")
                let text = NeuralReading.pasteText(of: lines)
                check("an edit is pasted with its marks", text.hasPrefix("- let old1") && text.contains("\n+ let new22"), String(text.prefix(40)))
            } else {
                check("an edit has a reader", false)
            }

            let id = write.id
            model.browse(.click(id, double: false))
            let opened = model.browse(.key(.space))
            check("Space opens the output of the step under the cursor", opened.contains(.expandOutputToggle) && model.browseState.outputExpanded)
            let shutAgain = model.browse(.key(.character("o")))
            check("o closes it again", shutAgain.contains(.expandOutputToggle) && !model.browseState.outputExpanded)
            model.browse(.key(.down))
            check("moving the cursor leaves the output closed", !model.browseState.outputExpanded)
        }

        /// With the writing turn on screen: a click on the Write and Space open the whole file in a
        /// reader the account has scrolled to, and `o` closes it and puts the account back.
        static func runReaderScreen(
            collection: UICollectionView, store: BrainStore, toggle: @escaping (String) -> Void
        ) async {
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            func walk(_ verb: String, _ value: String) {
                BrainWalk.run(
                    verb: verb, value: value, store: store, collection: collection, toggle: toggle,
                    rows: { _ in }, share: { _ in }, refresh: {})
            }
            func visibleReader() -> BrainDiffReaderView? {
                collection.visibleCells.lazy.compactMap { reader(in: $0) }.first
            }
            guard let id = store.latestTurnID, let model = store.model(for: id),
                let index = model.steps.firstIndex(where: { $0.call?.call.name == "Write" })
            else {
                check("the writing turn is on screen", false)
                return
            }
            if !store.isOpen(id) { toggle(id) }
            await wait(1.8)
            walk("click", String(index + 1))
            await wait(0.8)
            check("a card that is open and unread has no reader", visibleReader() == nil)
            walk("key", "space")
            await wait(1.5)
            guard let opened = visibleReader() else {
                check("Space opens the reader on screen", false)
                return
            }
            check("Space opens the reader on screen", opened.lines.count == 140 && opened.isNumbered)
            var scroller: UIView? = opened.superview
            while let view = scroller, !(view is UICollectionView) { scroller = view.superview }
            if let account = scroller as? UICollectionView {
                let top = opened.convert(opened.bounds, to: account).minY - account.contentOffset.y
                check("the account scrolled until the reader leads", top >= 0 && top <= 70, "\(top)")
                check(
                    "the reader and its buttons are in view together",
                    opened.convert(opened.bounds, to: account).maxY - account.contentOffset.y + 40 <= account.bounds.height,
                    "\(account.bounds.height)")
            } else {
                check("the reader sits in the account's list", false)
            }
            check("the reader draws a window of lines", opened.drawnLines > 0 && opened.drawnLines < 40, "\(opened.drawnLines)")
            walk("key", "o")
            await wait(1.5)
            check("o closes the reader", visibleReader() == nil)
            walk("key", "space")
            await wait(1.2)
            check("Space opens it again", visibleReader() != nil)
            walk("key", "down")
            await wait(1.2)
            check("moving the cursor closes it", visibleReader() == nil)
            let failed = results.filter { !$0.passed }.count
            AppLogger.ui.info("brain-check reader screen done pass=\(results.count - failed) fail=\(failed)")
        }

        /// Opens and closes the latest brain in the list on screen and reads what the move cost,
        /// what clocks exist while it is open and after it has closed.
        static func runScreen(
            collection: UICollectionView, store: BrainStore, toggle: @escaping (String) -> Void
        ) async {
            guard let id = store.latestTurnID else { return }
            func cell() -> NeuralBrainCell? {
                collection.visibleCells.compactMap { $0 as? NeuralBrainCell }
                    .first { $0.brainRow.turnID == id }
            }
            func wait(_ seconds: Double) async {
                try? await Task.sleep(for: .seconds(seconds))
            }
            await wait(0.5)
            guard let row = cell()?.brainRow else {
                check("the latest brain is on screen", false)
                return
            }
            check("a settled card owns no display link and no clock", !row.ownsDisplayLink && BrainLiveClock.shared.registered == 0)
            toggle(id)
            await wait(1.6)
            let openRow = cell()?.brainRow
            check("the open move landed", openRow?.phase == .open, "\(String(describing: openRow?.phase))")
            if let move = openRow?.lastMove {
                check("the open move drew about a frame a tick", move.frames >= 12, "\(move.frames)")
                check("at most one dropped frame in the open", move.maxGap <= 0.036, String(format: "%.1f ms", move.maxGap * 1000))
            } else {
                check("the open move was measured", false)
            }
            check("a settled open brain owns no display link", !(openRow?.ownsDisplayLink ?? true))
            check("a settled open brain's head runs no clock", openRow?.openView?.stage.head.isClockRunning == false)
            toggle(id)
            await wait(1.2)
            let closed = cell()?.brainRow
            check("the close move landed", closed?.phase == .closed, "\(String(describing: closed?.phase))")
            if let move = closed?.lastMove {
                check("at most one dropped frame in the close", move.maxGap <= 0.036, String(format: "%.1f ms", move.maxGap * 1000))
            }
            check("closing lets the open parts go", closed?.openView == nil)
            toggle(id)
            await wait(0.12)
            toggle(id)
            await wait(1.2)
            check("a press mid-move reverses and lands closed", cell()?.brainRow.phase == .closed, "\(String(describing: cell()?.brainRow.phase))")
            await wait(7)
            check(
                "the textures are let go after the pictures",
                (NeuralMetalContext.shared?.retainCount ?? 0) == 0, "\(NeuralMetalContext.shared?.retainCount ?? -1)")
            let total = results.filter { !$0.passed }.count
            AppLogger.ui.info("brain-check screen done pass=\(results.count - total) fail=\(total)")
        }
    }
#endif

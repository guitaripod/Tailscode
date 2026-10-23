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
            runLazy()
            runKeys(long)
            runAccount(long, build: build)
            runMetrics(long)
            runPhoneMetrics()
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
                    let layout = grown.prepare(messages: messages, running: true, awaiting: .none) { latest in contextFor(latest) }
                    let fresh = BrainStore()
                    let reference = fresh.prepare(messages: messages, running: true, awaiting: .none) { latest in contextFor(latest) }
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

        private static func runLazy() {
            let messages = (0..<40).flatMap {
                NeuralDemo.largeTurn(steps: 24, prefix: "z\($0)-", origin: 1_792_000_000 + Double($0) * 4000)
            }
            let store = BrainStore()
            let layout = store.prepare(messages: messages, running: false, awaiting: .none) { latest in contextFor(latest) }
            check("opening a chat makes the newest turn's model and no other", store.count == 40 && store.realisedCount == 1, "\(store.count) brains \(store.realisedCount) models")
            let ids = (1...40).compactMap { store.turnID(atBrain: $0) }
            let rows = ids.compactMap { id in layout.turn(startingAt: id)?.row }
            check("every brain is placed from its outline", ids.count == 40 && rows.count == 40 && ids.allSatisfy { store.anchorID(of: $0) != nil })
            let older = ids[10]
            let before = layout.turn(startingAt: older)?.row.stamp
            let middle = ids[20]
            let matched = store.stepMatching("swift build", in: middle)
            check("Find lands on a step of a turn nobody has looked at", matched != nil && store.realisedCount == 1, "\(String(describing: matched)) \(store.realisedCount)")
            let made = store.model(for: older)
            check("asking for a model makes that one", made != nil && store.realisedCount == 2, "\(store.realisedCount)")
            let again = store.prepare(messages: messages, running: false, awaiting: .none) { latest in contextFor(latest) }
            check("making a model leaves its row as it was", again.turn(startingAt: older)?.row.stamp == before)
            let eager = BrainStore()
            _ = eager.prepare(messages: messages, running: false, awaiting: .none) { latest in contextFor(latest) }
            for id in ids { _ = eager.model(for: id) }
            let settled = eager.prepare(messages: messages, running: false, awaiting: .none) { latest in contextFor(latest) }
            check(
                "a store that made every model has the rows of one that made none",
                ids.allSatisfy { settled.turn(startingAt: $0)?.row.stamp == again.turn(startingAt: $0)?.row.stamp })
            check(
                "the models made later are the models made at once",
                ids.allSatisfy { store.model(for: $0)?.turn == eager.model(for: $0)?.turn })
            var slices = 0
            while !store.indexSearch(budget: 0.000_01) { slices += 1 }
            check("Find's index is read in more than one slice", slices > 1, "\(slices)")
            check(
                "the index is the search text of every brain",
                ids.allSatisfy { store.indexedSearchText(for: $0) == BrainStore.searchText(of: eager.model(for: $0)?.turn ?? NeuralTurn(id: "")) })
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

        private static func runPhoneMetrics() {
            for width in [320.0, 375, 402, 430, 744] {
                let metrics = NeuralStageMetrics.make(
                    width: width - 16, density: .compact, input: .touch, phone: true)
                check("a \(Int(width)) pt phone opens compact", metrics.isPhone && metrics.rowHeight <= 400, "\(metrics.rowHeight)")
                check("a \(Int(width)) pt phone's head is 152 at most", metrics.stage.height <= 160, "\(metrics.stage.height)")
                check("a \(Int(width)) pt phone's card stays 84", metrics.cardHeight == 84)
            }
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
                _ = store.prepare(messages: messages, running: false, awaiting: .none) { _ in
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
            func accountHost() -> UIView {
                collection.visibleCells.compactMap { $0 as? NeuralBrainCell }
                    .compactMap { $0.brainRow.openView?.builtAccount }.first ?? collection
            }
            func visibleReader() -> BrainDiffReaderView? {
                reader(in: accountHost())
            }
            guard let id = store.latestTurnID, let model = store.model(for: id),
                let index = model.steps.firstIndex(where: { $0.call?.call.name == "Write" })
            else {
                check("the writing turn is on screen", false)
                return
            }
            if !store.isOpen(id) { toggle(id) }
            await wait(1.8)
            let phone = collection.visibleCells.compactMap { $0 as? NeuralBrainCell }
                .contains { $0.brainRow.openView?.metrics.isPhone == true }
            if phone {
                walk("sheet", "")
                await wait(1.2)
            }
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

        private struct Sample {
            let mean: Double
            let p95: Double
            let max: Double
        }

        private static func time(_ count: Int, _ body: () -> Void) -> Sample {
            var all: [Double] = []
            for _ in 0..<count {
                let start = CACurrentMediaTime()
                body()
                all.append((CACurrentMediaTime() - start) * 1000)
            }
            all.sort()
            return Sample(
                mean: all.reduce(0, +) / Double(max(all.count, 1)),
                p95: all[min(all.count - 1, Int(Double(all.count) * 0.95))], max: all.last ?? 0)
        }

        private static func report(_ name: String, _ sample: Sample, _ extra: String = "") {
            AppLogger.ui.info(
                "brain-perf \(name) mean=\(String(format: "%.3f", sample.mean))ms p95=\(String(format: "%.3f", sample.p95))ms max=\(String(format: "%.3f", sample.max))ms \(extra)")
        }

        /// The longest the main thread went between two frames while it ran, and how many gaps
        /// were longer than 25 ms: what a person feels as a hitch.
        @MainActor
        private final class GapMeter: NSObject {
            private var link: CADisplayLink?
            private var last: CFTimeInterval = 0
            private(set) var longest = 0.0
            private(set) var hitches = 0
            private(set) var frames = 0

            func start() {
                last = 0
                longest = 0
                hitches = 0
                frames = 0
                link?.invalidate()
                let made = CADisplayLink(target: self, selector: #selector(step(_:)))
                made.add(to: .main, forMode: .common)
                link = made
            }

            @objc private func step(_ display: CADisplayLink) {
                let now = display.timestamp
                if last > 0 {
                    let gap = (now - last) * 1000
                    longest = max(longest, gap)
                    if gap > 25 { hitches += 1 }
                    frames += 1
                }
                last = now
            }

            func stop() {
                link?.invalidate()
                link = nil
            }
        }

        static var isPerf: Bool {
            ProcessInfo.processInfo.environment["TAILSCODE_NEURAL_PERF"] != nil
        }

        /// What the main thread pays for a running turn's Megatron: a conversation state arriving
        /// (a token), the one-second clock, and what stays alive once the chat has left the window.
        /// Needs `TAILSCODE_NEURAL_STATE=shell` and a long turn (`TAILSCODE_NEURAL_LARGE=174`).
        static func runPerf(
            collection: UICollectionView, store: BrainStore, toggle: @escaping (String) -> Void
        ) async {
            guard let id = store.latestTurnID else { return }
            func cell() -> NeuralBrainCell? {
                collection.visibleCells.compactMap { $0 as? NeuralBrainCell }
                    .first { $0.brainRow.turnID == id }
            }
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            let streamed = (0..<40).flatMap {
                NeuralDemo.largeTurn(steps: 24, prefix: "p\($0)-", origin: 1_792_000_000 + Double($0) * 4000)
            }
            let probe = BrainStore()
            let neutral: (Bool) -> NeuralBrainContext = { _ in NeuralBrainContext() }
            report("prepare cold 40 turns", time(1) {
                _ = probe.prepare(messages: streamed, running: true, awaiting: .none, context: neutral)
            })
            for turns in [40, 300, 1500] {
                let conversation = ChatRebuildBench.conversation(turns: turns, growing: "done")
                let cold = BrainStore()
                report("open cold \(turns) turns", time(1) {
                    _ = cold.prepare(messages: conversation, running: false, awaiting: .none, context: neutral)
                })
                report("open cold \(turns) turns, newest model", time(1) {
                    _ = cold.model(for: cold.latestTurnID ?? "")
                })
                report("open cold \(turns) turns, one older model", time(1) {
                    _ = cold.model(for: cold.turnID(atBrain: max(1, turns / 2)) ?? "")
                })
                var streamed = conversation
                var words = 0
                report("open cold \(turns) turns, then a token", time(200) {
                    words += 1
                    let last = streamed.count - 1
                    streamed[last].parts[streamed[last].parts.count - 1].kind = .text(String(repeating: "word ", count: words))
                    _ = cold.prepare(messages: streamed, running: true, awaiting: .none, context: neutral)
                })
            }
            for turns in [40, 300] {
                let conversation = (0..<turns).flatMap {
                    NeuralDemo.largeTurn(steps: 24, prefix: "h\($0)-", origin: 1_792_000_000 + Double($0) * 4000)
                }
                let cold = BrainStore()
                report("open cold \(turns) heavy turns", time(1) {
                    _ = cold.prepare(messages: conversation, running: false, awaiting: .none, context: neutral)
                })
            }
            var growing = streamed
            var counter = 0
            report("prepare per token 40 turns", time(300) {
                counter += 1
                if let message = growing.indices.last(where: { index in
                    growing[index].parts.contains { if case .text = $0.kind { return true } else { return false } }
                }), let part = growing[message].parts.indices.last(where: { if case .text = growing[message].parts[$0].kind { return true } else { return false } }),
                    case .text(let words) = growing[message].parts[part].kind
                {
                    growing[message].parts[part].kind = .text(words + "x")
                }
                _ = probe.prepare(messages: growing, running: true, awaiting: .none, context: neutral)
            })
            var partitioned: [NeuralTurn] = []
            report("partition 40 turns", time(1) {
                partitioned = NeuralTurns.partition(messages: streamed, running: true)
            })
            report("models of 40 turns", time(1) {
                for turn in partitioned { _ = NeuralBrainModel(turn: turn, context: NeuralBrainContext()) }
            })
            report("search text of 40 turns", time(1) {
                for turn in partitioned { _ = BrainStore.searchText(of: turn) }
            })
            let heavy: [ChatMessage] = streamed.map { message in
                var copy = message
                for index in copy.parts.indices {
                    if case .tool(var call) = copy.parts[index].kind {
                        call.output = String(repeating: "a line of tool output that a build prints\n", count: 500)
                        copy.parts[index].kind = .tool(call)
                    }
                }
                return copy
            }
            let heavyProbe = BrainStore()
            report("prepare cold 40 turns 20 KB outputs", time(1) {
                _ = heavyProbe.prepare(messages: heavy, running: true, awaiting: .none, context: neutral)
            })
            var heavyGrowing = heavy
            report("prepare per token 40 turns 20 KB outputs", time(200) {
                if let message = heavyGrowing.indices.last(where: { index in
                    heavyGrowing[index].parts.contains { if case .text = $0.kind { return true } else { return false } }
                }), let part = heavyGrowing[message].parts.indices.last(where: { if case .text = heavyGrowing[message].parts[$0].kind { return true } else { return false } }),
                    case .text(let words) = heavyGrowing[message].parts[part].kind
                {
                    heavyGrowing[message].parts[part].kind = .text(words + "x")
                }
                _ = heavyProbe.prepare(messages: heavyGrowing, running: true, awaiting: .none, context: neutral)
            })
            await wait(1.5)
            guard let closed = cell() else {
                AppLogger.ui.info("brain-perf the latest brain is not on screen")
                return
            }
            report("closed-live token", time(300) { closed.refreshLive(); closed.layoutIfNeeded() })
            let settled = collection.visibleCells.compactMap { $0 as? NeuralBrainCell }.first { $0.brainRow.turnID != id }
            if let settled {
                report("settled-card token", time(300) { settled.refreshLive(); settled.layoutIfNeeded() })
            } else {
                AppLogger.ui.info("brain-perf no settled card on screen")
            }
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
            attributes.size = CGSize(width: collection.bounds.width, height: 100)
            report("closed-live self-size", time(300) { _ = closed.preferredLayoutAttributesFitting(attributes) })
            if let settled {
                report("settled-card self-size", time(300) { _ = settled.preferredLayoutAttributesFitting(attributes) })
            }
            let meter = GapMeter()
            meter.start()
            let tap = time(1) { toggle(id); collection.layoutIfNeeded() }
            await wait(2)
            meter.stop()
            report("open tap", tap, "frames=\(meter.frames) longestGap=\(String(format: "%.1f", meter.longest))ms hitches=\(meter.hitches)")
            guard let open = cell(), open.brainRow.openView != nil else {
                AppLogger.ui.info("brain-perf the brain did not open")
                return
            }
            report("open-live token", time(300) { open.refreshLive(); open.layoutIfNeeded() })
            report("open-live second", time(100) { open.brainRow.openView?.tick(); open.layoutIfNeeded() })
            let before = BrainLiveClock.shared.ticks
            let held = BrainLiveClock.shared.registered
            let headRunning = open.brainRow.openView?.stage.head.isClockRunning ?? false
            let context = NeuralMetalContext.shared?.retainCount ?? -1
            let parent = collection.superview
            collection.removeFromSuperview()
            await wait(3.5)
            AppLogger.ui.info(
                "brain-perf away registered=\(BrainLiveClock.shared.registered)/\(held) ticks=\(BrainLiveClock.shared.ticks - before) running=\(BrainLiveClock.shared.isRunning) headClock=\(headRunning)->\(open.brainRow.openView?.stage.head.isClockRunning ?? false) displayLink=\(open.brainRow.ownsDisplayLink) metalHolds=\(context)->\(NeuralMetalContext.shared?.retainCount ?? -1)")
            if let parent { parent.addSubview(collection) }
            await wait(1)
            AppLogger.ui.info(
                "brain-perf back registered=\(BrainLiveClock.shared.registered) running=\(BrainLiveClock.shared.isRunning)")
            toggle(id)
            await wait(1.2)
            let second = time(1) { toggle(id); collection.layoutIfNeeded() }
            await wait(1.5)
            report("reopen tap", second)
            AppLogger.ui.info("brain-perf done")
        }

        private static func verticalScrollers(in view: UIView) -> [UIScrollView] {
            var found: [UIScrollView] = []
            func walk(_ node: UIView) {
                if let scroll = node as? UIScrollView, scroll.isScrollEnabled, !node.isHidden,
                    scroll.contentSize.height > scroll.bounds.height + 1,
                    scroll.bounds.height > 0
                {
                    found.append(scroll)
                }
                for child in node.subviews { walk(child) }
            }
            walk(view)
            return found
        }

        /// A phone's open Megatron on screen: short and fixed, nothing in it scrolls, a long list
        /// says how many more and a short one opens in place, the cursor row stays on the stage,
        /// and the account opens in a sheet and not in the page.
        static func runPhoneScreen(
            collection: UICollectionView, store: BrainStore, toggle: @escaping (String) -> Void
        ) async {
            guard let id = store.latestTurnID else { return }
            func cell() -> NeuralBrainCell? {
                collection.visibleCells.compactMap { $0 as? NeuralBrainCell }
                    .first { $0.brainRow.turnID == id }
            }
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            guard let width = cell()?.brainRow.bounds.width, width > 0, width < 500 else {
                AppLogger.ui.info("brain-check phone screen skipped: the row is not a phone's")
                return
            }
            if !store.isOpen(id) { toggle(id) }
            await wait(1.8)
            guard let row = cell()?.brainRow, let open = row.openView, let model = store.model(for: id) else {
                check("the phone's brain opened", false)
                return
            }
            let viewport = collection.bounds.height
            let phone = NeuralStageMetrics.make(width: Double(width), density: ChatDensitySetting.current, input: .touch, phone: true)
            check("the open row is the compact height", abs(Double(row.bounds.height) - phone.rowHeight) < 1.5, "\(row.bounds.height) vs \(phone.rowHeight)")
            check("the open row is at most 400 and a half of a viewport", row.bounds.height <= 400 && row.bounds.height <= viewport * 0.6, "\(row.bounds.height) of \(viewport)")
            check("nothing in the open Megatron scrolls vertically", verticalScrollers(in: open).isEmpty, "\(verticalScrollers(in: open).map { "\(type(of: $0))" })")
            check("the account is not built, let alone in the page", open.builtAccount == nil)
            let total = model.stepList.visibleCount
            if total > NeuralStageMetrics.phoneRowSlots {
                check("a long list ends in how many more", open.compactList.linkTitles.contains(NeuralReading.moreSteps(total - (open.compactList.itemCount - 1))), "\(open.compactList.linkTitles)")
                check("the list draws its slots and no more", open.compactList.itemCount == NeuralStageMetrics.phoneRowSlots, "\(open.compactList.itemCount)")
            }
            let target = model.steps[min(13, model.steps.count - 1)].id
            let number = model.steps.firstIndex { $0.id == target }.map { $0 + 1 } ?? 1
            open.walk(verb: "click", value: String(number))
            await wait(0.6)
            check("the step on the cursor is on the stage", open.compactList.visibleRowIDs.contains(target), "\(open.compactList.visibleRowIDs) vs \(target)")
            open.walk(verb: "key", value: "esc")
            await wait(0.3)
            let before = row.bounds.height
            open.walk(verb: "search", value: "ff")
            await wait(0.4)
            let narrowed = store.model(for: id)?.stepList.visibleCount ?? 0
            if narrowed > NeuralStageMetrics.phoneRowSlots, NeuralStageMetrics.phoneExpandsInPlace(visibleCount: narrowed) {
                open.walk(verb: "more", value: "")
                await wait(0.6)
                let grown = cell()?.brainRow.bounds.height ?? 0
                let expected = Double(NeuralStageMetrics.phoneExpandedSlots(visibleCount: narrowed) - NeuralStageMetrics.phoneRowSlots) * 32
                check("a short list opens in place by its own rows", abs(Double(grown - before) - expected) < 2, "\(grown - before) vs \(expected)")
                check("an opened list still holds no scroller", verticalScrollers(in: open).isEmpty)
                open.walk(verb: "less", value: "")
                await wait(0.6)
                check("showing fewer gives the height back", abs((cell()?.brainRow.bounds.height ?? 0) - before) < 2)
            } else {
                check("the filter left a list that opens in place", false, "\(narrowed)")
            }
            open.walk(verb: "key", value: "esc")
            await wait(0.3)
            open.walk(verb: "sheet", value: "")
            await wait(1.2)
            check("the account opens in a sheet", open.builtAccount?.superview != nil && open.builtAccount?.window != nil)
            check("the row did not grow for the sheet", abs((cell()?.brainRow.bounds.height ?? 0) - before) < 2)
            open.walk(verb: "dismiss", value: "")
            await wait(0.6)
            check("the sheet lets the account go", open.builtAccount?.superview == nil)
            check("a settled stage holds no swipe recogniser", !open.stage.holdsSwipe)
            check(
                "a swipe may not start within a thumb of either screen edge",
                !BrainStageView.swipeMayStart(atX: 12, windowWidth: 402)
                    && !BrainStageView.swipeMayStart(atX: 390, windowWidth: 402)
                    && BrainStageView.swipeMayStart(atX: 120, windowWidth: 402))
            open.walk(verb: "dive", value: "shell")
            await wait(0.9)
            check("a dive holds the swipe that leaves it", open.stage.holdsSwipe)
            open.walk(verb: "key", value: "esc")
            await wait(0.9)
            check("leaving the dive lets the swipe go", !open.stage.holdsSwipe)
            let failed = results.filter { !$0.passed }.count
            AppLogger.ui.info("brain-check phone screen done pass=\(results.count - failed) fail=\(failed)")
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
            await runPhoneScreen(collection: collection, store: store, toggle: toggle)
            let total = results.filter { !$0.passed }.count
            AppLogger.ui.info("brain-check screen done pass=\(results.count - total) fail=\(total)")
        }
    }
#endif

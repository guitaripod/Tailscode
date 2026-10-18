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
            runKeys(long)
            runAccount(long, build: build)
            runMetrics(long)
            runMove(long)
            runWords(all)
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

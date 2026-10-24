import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// `tailscode --selftest` drives the whole chain with no window: tailnet reading, profile and
/// secret stores, every configured server's health and session list, then the newest session's
/// stream until a transcript lands.
///
/// This is how the Linux client is validated in a build loop — and on a headless box it is the
/// only way, since there is no display to render into and no Secret Service to answer.
public enum SelfTest {
    public static var isRequested: Bool { Arguments.contains("--selftest") }

    /// The pass over the servers keeps one loaded conversation aside as the two-observer subject:
    /// a conversation with words in it makes the stronger subject, and an empty one only stands in
    /// when every server's newest chat is empty.
    public static func run() async -> Never {
        let only = ProcessInfo.processInfo.environment["TAILSCODE_SELFTEST_ONLY"]
        startWatchdog(seconds: only == nil ? 175 : 600)
        if let only { runOnly(only) }
        var failures = 0

        let tailnet = TailnetStatusLinux.read()
        report("tailnet: \(tailnet.address ?? "no address") · \(tailnet.peers.count) peers")

        do {
            try await checkStores()
            report("stores: ok")
        } catch {
            report("stores: \(error)")
            failures += 1
        }

        do {
            let checks = try checkVim()
            report("vim: \(checks) commands behave")
        } catch {
            report("vim: \(error)")
            failures += 1
        }

        do {
            let checks = try checkMarkup()
            report("markup: \(checks) shapes render")
        } catch {
            report("markup: \(error)")
            failures += 1
        }

        do {
            let checks = try checkListHang()
            report("list hang: \(checks) claims hold — measured once per font, again only when the font changes")
        } catch {
            report("list hang: \(error)")
            failures += 1
        }

        do {
            let checks = try checkTable()
            report("table: \(checks) widths measure the height they draw")
            let arrival = try checkTableArrival()
            report("table arrival: \(arrival) a draft holds its rows and the wash lands")
            let fits = try checkTableFitsItsCard()
            report("table fit: \(fits) a realized table draws every row inside its card")
            let sealing = try checkTableSealingOnBridgeShape()
            report("table sealing: \(sealing) a bridge message with no isStreaming stamp still drafts")
        } catch {
            report("table: \(error)")
            failures += 1
        }

        do {
            let checks = try checkSyntax()
            report("syntax: \(checks) claims hold — code colours and never becomes markup")
        } catch {
            report("syntax: \(error)")
            failures += 1
        }

        do {
            let checks = try checkCascade()
            report("cascade: \(checks) prefixes reveal cleanly")
        } catch {
            report("cascade: \(error)")
            failures += 1
        }

        do {
            let checks = try checkInterruption()
            report("interruption: \(checks) marker shapes")
        } catch {
            report("interruption: \(error)")
            failures += 1
        }

        do {
            let checks = try checkTranscriptNotes()
            report("transcript notes: \(checks) claims hold: words, face and never an answer")
        } catch {
            report("transcript notes: \(error)")
            failures += 1
        }

        do {
            let checks = try checkModelSeamAndCarry()
            report("model seam and carry: \(checks) claims hold: one seam, one carried line, the typed words only")
        } catch {
            report("model seam and carry: \(error)")
            failures += 1
        }

        do {
            let checks = try checkPartyCards()
            report("party: \(checks) claims hold: six cards, the one in use, a name kept and given back, a swap, a level step, no card on another")
        } catch {
            report("party: \(error)")
            failures += 1
        }

        do {
            let checks = try checkAgentsBoard()
            report("agents: \(checks) claims hold: four sections, Approve once and dead in flight, Stop asked first, long text wrapped, Core's hour, one window, no watch left")
        } catch {
            report("agents: \(error)")
            failures += 1
        }

        do {
            let checks = try checkProviderRetryCard()
            report("provider retry: \(checks) claims hold: words, remedy and a clock that wakes once")
        } catch {
            report("provider retry: \(error)")
            failures += 1
        }

        do {
            let checks = try checkRevertBanner()
            report("revert banner: \(checks) claims hold: words, the more line, restoring")
        } catch {
            report("revert banner: \(error)")
            failures += 1
        }

        do {
            let checks = try checkCompactChat()
            report(
                "compact chat: \(checks) claims hold: gaps, rail settling, plate placement, hover timing, the picture gallery, the rail in every stage, density")
        } catch {
            report("compact chat: \(error)")
            failures += 1
        }

        do {
            let checks = try checkApplyPath()
            report("apply path: \(checks) claims hold: builder reachable mid-build, doubled-row watch incremental")
        } catch {
            report("apply path: \(error)")
            failures += 1
        }

        do {
            let checks = try checkBrain()
            report(
                "brain: \(checks) claims hold: rows, Lines, fallbacks, stage layout, hover, pin, replay, dive, clocks, hidden panes, the share poster, the collapsed line's fit, the scroll anchor, release")
        } catch {
            report("brain: \(error)")
            failures += 1
        }

        do {
            let checks = try checkReplaceChildren()
            report("reorder: \(checks) claims hold: a kept row survives being moved, a dropped one is freed")
        } catch {
            report("reorder: \(error)")
            failures += 1
        }

        do {
            let checks = try checkWorkflowCard()
            report("workflow card: \(checks) run shapes read correctly")
        } catch {
            report("workflow card: \(error)")
            failures += 1
        }

        let runFailures = WorkflowRunCheck.run()
        if runFailures.isEmpty {
            report("workflow run: every ending is read, holds still, and the tempo is thirty")
        } else {
            report("workflow run: \(runFailures.joined(separator: " · "))")
            failures += 1
        }

        do {
            let checks = try checkSubagentCard()
            report("subagent card: \(checks) claims hold — the line reads the errand, not the week")
        } catch {
            report("subagent card: \(error)")
            failures += 1
        }

        do {
            let checks = try checkStatusBand()
            report("status band: \(checks) states say the right thing")
        } catch {
            report("status band: \(error)")
            failures += 1
        }

        do {
            let checks = try checkBandHoldsStill()
            report("status band holds still: \(checks) claims hold — a fact keeps its place")
        } catch {
            report("status band holds still: \(error)")
            failures += 1
        }

        do {
            let checks = try checkChatChrome()
            report("chat chrome: \(checks) claims hold — one chip, one stop, a failed card, calm ink")
        } catch {
            report("chat chrome: \(error)")
            failures += 1
        }

        do {
            let checks = try checkGit()
            report("git: \(checks) claims hold — the tree reads, the patch colours, the classes exist")
        } catch {
            report("git: \(error)")
            failures += 1
        }

        do {
            let checks = try checkSpend()
            report("spend: \(checks) numbers hold, and the panel can be built")
        } catch {
            report("spend: \(error)")
            failures += 1
        }

        do {
            let checks = try checkAnalyticsShare()
            report("analytics share: \(checks) claims hold — words, card and PNG")
        } catch {
            report("analytics share: \(error)")
            failures += 1
        }

        do {
            let checks = try checkNotificationPlate()
            report("notification plate: \(checks) claims hold — face and picture are real PNGs")
        } catch {
            report("notification plate: \(error)")
            failures += 1
        }

        do {
            let checks = try checkFreeLedger()
            report("analytics ledger: \(checks) claims hold — free models counted, gaps named")
        } catch {
            report("analytics ledger: \(error)")
            failures += 1
        }

        do {
            try checkActivityMotion()
            report("activity: \(ActivityKind.everyState.count) states move as they mean")
        } catch {
            report("activity: \(error)")
            failures += 1
        }

        do {
            let checks = try checkCascadeBudget()
            report("cascade budget: \(checks) claims hold — calm writes on every frame the display draws")
        } catch {
            report("cascade budget: \(error)")
            failures += 1
        }

        do {
            let checks = try checkRevealGeometry()
            report("reveal geometry: \(checks) claims hold — a frame paints the wave and lays nothing out")
        } catch {
            report("reveal geometry: \(error)")
            failures += 1
        }

        do {
            let checks = try checkPreviewPane()
            report("preview: \(checks) claims hold — every face drawn, no clock left behind")
        } catch {
            report("preview: \(error)")
            failures += 1
        }

        do {
            let checks = try checkRepeatingMotion()
            report("repeating motion: \(checks) claims hold — every never-ending lap asks again")
        } catch {
            report("repeating motion: \(error)")
            failures += 1
        }

        do {
            let checks = try checkCompletion()
            report("completion: \(checks) queries rank and gate")
        } catch {
            report("completion: \(error)")
            failures += 1
        }

        do {
            let checks = try checkShortcuts()
            report("shortcuts: \(checks) keys resolve, rebind and stay conflict-free")
        } catch {
            report("shortcuts: \(error)")
            failures += 1
        }

        do {
            let checks = try checkPaneDrop()
            report("pane drop: \(checks) drags land where they are aimed")
        } catch {
            report("pane drop: \(error)")
            failures += 1
        }

        do {
            let checks = try checkPaneVerbs()
            report("pane verbs: \(checks) chords, divider keys and strip drags reach the tree")
        } catch {
            report("pane verbs: \(error)")
            failures += 1
        }

        do {
            let checks = try checkTileCanvas()
            report("tile canvas: \(checks) claims hold — rects, layers, hiding, no re-parent, dividers, disposal")
        } catch {
            report("tile canvas: \(error)")
            failures += 1
        }

        do {
            let checks = try checkTileHost()
            report("tile host: \(checks) claims hold — placement, densities, overflow, dividers, pins, snapshot")
        } catch {
            report("tile host: \(error)")
            failures += 1
        }

        do {
            let checks = try checkLegacyTiling()
            report("legacy tiling: \(checks) claims hold — the nested host still boots")
        } catch {
            report("legacy tiling: \(error)")
            failures += 1
        }

        do {
            let checks = try checkStudioSheet()
            report("studio sheet: \(checks) claims hold — one frame, one window, one keyboard")
        } catch {
            report("studio sheet: \(error)")
            failures += 1
        }

        do {
            let checks = try checkMediaViewer()
            report("media viewer: \(checks) claims hold — one stack, the top sheet closes, the keyboard goes back")
        } catch {
            report("media viewer: \(error)")
            failures += 1
        }

        do {
            let checks = try checkVideoSlot()
            report("video slot: \(checks) answers, player \(SelfTest.playerState)")
        } catch {
            report("video slot: \(error)")
            failures += 1
        }

        do {
            let checks = try checkBrowserSlot()
            report("browser slot: \(checks) answers, engine \(SelfTest.engineState)")
        } catch {
            report("browser slot: \(error)")
            failures += 1
        }

        do {
            let checks = try checkModelDial()
            report("model dial: \(checks) answers drawn")
        } catch {
            report("model dial: \(error)")
            failures += 1
        }

        do {
            let checks = try checkParity()
            report("parity: \(checks) capabilities answered")
        } catch {
            report("parity: \(error)")
            failures += 1
        }

        do {
            let checks = try checkPointerFeedback()
            report("pointer feedback: \(checks) claims hold — the message under the pointer, its verbs, a chat row's verbs")
        } catch {
            report("pointer feedback: \(error)")
            failures += 1
        }

        do {
            let checks = try checkFlight()
            report("flight recorder: \(checks) claims hold — the ring round-trips and keeps counts only")
        } catch {
            report("flight recorder: \(error)")
            failures += 1
        }

        do {
            let checks = try checkResourceGuard()
            report("resource guard: \(checks) cgroup names decided")
        } catch {
            report("resource guard: \(error)")
            failures += 1
        }

        do {
            let checks = try await checkSelfDiagnosis()
            report("self-diagnosis: \(checks) claims hold — a pinned thread is sampled and the polls wait for a window")
        } catch {
            report("self-diagnosis: \(error)")
            failures += 1
        }

        do {
            let checks = try checkRestorePlan()
            report("safe restore: \(checks) launches decided and woken in order")
        } catch {
            report("safe restore: \(error)")
            failures += 1
        }

        do {
            let checks = try checkDeepSeekBalance()
            report("deepseek balance: \(checks) claims hold — money, never a bar")
        } catch {
            report("deepseek balance: \(error)")
            failures += 1
        }

        do {
            let checks = try checkUsageGlance()
            report("usage glance: \(checks) states say only what each needs to")
        } catch {
            report("usage glance: \(error)")
            failures += 1
        }

        let chooserFailures = PaneChooserCheck.run()
        if chooserFailures.isEmpty {
            report("pane chooser: servers, chats and keys behave")
        } else {
            report("pane chooser: \(chooserFailures.joined(separator: " · "))")
            failures += 1
        }

        let boardFailures = WatchChooserCheck.run()
        if boardFailures.isEmpty {
            report("watch board: sections compact, sources report, keys leave the box alone")
        } else {
            report("watch board: \(boardFailures.joined(separator: " · "))")
            failures += 1
        }

        let imageFailures = ImageGenDoorCheck.run()
        if imageFailures.isEmpty {
            report("image door: the machine, the lane it grows and the words it may say all hold")
        } else {
            report("image door: \(imageFailures.joined(separator: " · "))")
            failures += 1
        }

        let studioFailures = StudioLayoutCheck.run() + studioWidgetChecks()
        if studioFailures.isEmpty {
            report("studio: the room, the shelf's merge and walk, the chips, the pill and the passes all hold")
        } else {
            report("studio: \(studioFailures.joined(separator: " · "))")
            failures += 1
        }

        let forgeFailures = ForgeBoardCheck.run()
        if forgeFailures.isEmpty {
            report("video forge: the graph, the frames, the job's walk and the board all hold")
        } else {
            report("video forge: \(forgeFailures.joined(separator: " · "))")
            failures += 1
        }

        let accountFailures = WatchAccountsCheck.run()
        if accountFailures.isEmpty {
            report("watch accounts: rows state a fact first, and the flow shows one code")
        } else {
            report("watch accounts: \(accountFailures.joined(separator: " · "))")
            failures += 1
        }

        do {
            let checks = try checkWatchAccounts()
            report("watch sign-in: \(checks) states, tokens kept where secrets go")
        } catch {
            report("watch sign-in: \(error)")
            failures += 1
        }

        do {
            let checks = try checkWatchDirectory()
            report("watch directory: \(checks) shapes read into rows")
        } catch {
            report("watch directory: \(error)")
            failures += 1
        }

        let modelFailures = ModelChooserCheck.run()
        if modelFailures.isEmpty {
            report("model chooser: providers fold, ranking holds, keys behave")
        } else {
            report("model chooser: \(modelFailures.joined(separator: " · "))")
            failures += 1
        }

        let newChatFailures = NewChatChooserCheck.run()
        if newChatFailures.isEmpty {
            report("new chat: folders rank, servers cycle, both modes behave")
        } else {
            report("new chat: \(newChatFailures.joined(separator: " · "))")
            failures += 1
        }

        let folderFailures = FolderBrowserCheck.run()
        if folderFailures.isEmpty {
            report("folder browser: paths walk, filters narrow, servers cycle")
        } else {
            report("folder browser: \(folderFailures.joined(separator: " · "))")
            failures += 1
        }

        let selectionFailures = ChatSelectionCheck.run()
        if selectionFailures.isEmpty {
            report("chat selection: marks key on the server, prune, and say what they did")
        } else {
            report("chat selection: \(selectionFailures.joined(separator: " · "))")
            failures += 1
        }

        do {
            try checkSettingsFile()
            report("settings file: survives a reinstall")
        } catch {
            report("settings file: \(error)")
            failures += 1
        }

        do {
            let checks = try checkBeta()
            report("beta: \(checks) claims hold — the mark, its sheen, its card, its report and its seen state")
        } catch {
            report("beta: \(error)")
            failures += 1
        }

        do {
            let checks = try checkChatSwitch()
            report("chat switch: \(checks) claims hold — messages are drawn once for every pane, a long chat shows as soon as it covers the page, and a blank state never wipes it")
        } catch {
            report("chat switch: \(error)")
            failures += 1
        }

        do {
            let checks = try checkBrainSwap()
            report("readout swap: \(checks) claims hold — a subject that arrives during the cross-fade waits for it, leaves the fading page whole and is never stale")
        } catch {
            report("readout swap: \(error)")
            failures += 1
        }

        do {
            let checks = try checkShutdown()
            report("shutdown: \(checks) claims hold — nothing posted runs once the process is quitting, a held widget reads nil when it is gone and a closing window gives its backfill back")
        } catch {
            report("shutdown: \(error)")
            failures += 1
        }

        do {
            let checks = try checkRange()
            report("range: \(checks) claims hold — the sheet's rows, the wall chip, the pace bar's tick and the sheet itself")
        } catch {
            report("range: \(error)")
            failures += 1
        }

        do {
            let checks = try checkClock()
            report("clock: \(checks) claims hold — the chip, the glance, the sheet, its alarms and the palette it draws with")
        } catch {
            report("clock: \(error)")
            failures += 1
        }

        do {
            let checks = try checkSidebar()
            report("sidebar: \(checks) claims hold — a burst of draws is two, the last request is drawn, a row with no parent is left alone")
        } catch {
            report("sidebar: \(error)")
            failures += 1
        }

        do {
            let checks = try checkFirstRun()
            report("first run: \(checks) claims hold — the desktop entry, the link arguments and every state the window draws")
        } catch {
            report("first run: \(error)")
            failures += 1
        }

        do {
            let checks = try await checkVoiceAudio()
            report("voice audio: \(checks) claims hold — devices, levels, and a stop that is safe twice")
        } catch {
            report("voice audio: \(error)")
            failures += 1
        }

        do {
            let checks = try checkCall()
            report("call: \(checks) claims hold — the control, the strip, every face, and the call's whole life over fake audio")
        } catch {
            report("call: \(error)")
            failures += 1
        }

        do {
            let checks = try checkSetup()
            report("setup: \(checks) claims hold — every checklist state, motion that means something, a job followed to its end, the server section, and the call's press")
        } catch {
            report("setup: \(error)")
            failures += 1
        }

        let radarFailures = checkRadar()
        if radarFailures.isEmpty {
            report("tailnet radar: the dial laps, lights and settles")
        } else {
            report("tailnet radar: \(radarFailures.joined(separator: " · "))")
            failures += 1
        }

        do {
            let checks = try checkPalettes()
            report("themes: \(checks) themes read in both appearances")
        } catch {
            report("themes: \(error)")
            failures += 1
        }

        do {
            try checkImageCache()
            report("image cache: pictures round-trip and stay keyed to their file")
        } catch {
            report("image cache: \(error)")
            failures += 1
        }

        await ServerDirectory.shared.reload()
        let profiles = await ServerDirectory.shared.profiles()
        guard !profiles.isEmpty else {
            report("no servers configured — set TAILSCODE_HOST to seed one")
            exit(1)
        }

        var warmed: (backend: any CodingAgentBackend, session: AgentSession)?
        var warmedIsEmpty = true
        for profile in profiles {
            guard let backend = await ServerDirectory.shared.backend(for: profile) else {
                report("\(profile.name): no backend")
                failures += 1
                continue
            }
            do {
                let health = try await backend.health()
                let sessions = try await backend.listSessions()
                report("\(profile.name): \(health.version ?? "unknown") · \(sessions.count) sessions")
                guard let newest = Self.observable(in: sessions) else { continue }
                let state = try await firstState(of: newest, on: backend)
                report("  \(newest.title.prefix(50)): \(state.messages.count) messages")
                guard state.hasLoadedTranscript else {
                    report("  transcript never loaded")
                    failures += 1
                    continue
                }
                if warmed == nil || (warmedIsEmpty && !state.messages.isEmpty) {
                    warmed = (backend, newest)
                    warmedIsEmpty = state.messages.isEmpty
                }
            } catch {
                report("\(profile.name): \(error)")
                failures += 1
            }
        }

        let (entries, unreachable) = await ServerDirectory.shared.entries()
        report("list: \(entries.count) entries, \(unreachable.count) unreachable")

        #if !HAS_VTE
            let shellOutput = TerminalPane.shell("echo tailscode-shell-ok", in: nil)
            if shellOutput.contains("tailscode-shell-ok") {
                report("shell: ok (one command at a time; install vte4 for a full terminal)")
            } else {
                report("shell: no output")
                failures += 1
            }
        #else
            report("shell: vte4 terminal")
        #endif

        if let warmed {
            do {
                let count = try await checkTwoObservers(
                    backend: warmed.backend, session: warmed.session)
                report("two observers: agree on \(count) messages")
            } catch {
                report("two observers: \(error)")
                failures += 1
            }
        } else {
            report("two observers: no loaded session to observe")
            failures += 1
        }

        if ProcessInfo.processInfo.environment["TAILSCODE_SELFTEST_SEND"] == "1" {
            do {
                try await checkRoundTrip(profiles)
                report("send: ok")
            } catch {
                report("send: \(error)")
                failures += 1
            }
        }

        report(failures == 0 ? "SELFTEST_OK" : "SELFTEST_FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension SelfTest {
    /// The Studio's widgets, on the harness display: a shelf keeps the tiles that did not change and
    /// only turns when the room says so, a tray of chips breaks its lines on their own widths and
    /// folds into one control, and a stage keeps its progress line hidden until there is a count.
    static func studioWidgetChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let shelf = StudioShelfView()
        let first = (0..<5).map { StudioTile(id: "t\($0)", words: "w\($0)") }
        shelf.update(tiles: first, selection: "t1")
        expect(shelf.tileIDs == ["t0", "t1", "t2", "t3", "t4"], "the shelf holds its tiles in the order it was given")
        shelf.update(tiles: [StudioTile(id: "job", inFlight: true)] + first.dropLast(), selection: "t1")
        expect(shelf.tileIDs == ["job", "t0", "t1", "t2", "t3"], "a job leads, and a tile that left is gone")
        expect(shelf.summary.hasPrefix("rail tiles=5"), "the shelf starts as a rail")
        shelf.place(rail: false)
        expect(shelf.summary.hasPrefix("strip tiles=5"), "and turns into a strip without losing a tile")

        let shell = StudioStageShell()
        shell.setProgress(nil)
        expect(shell.progressSummary == "hidden", "no count, no progress line")
        shell.setProgress([1, 0.25])
        expect(shell.progressSummary == "line=1.00/0.25", "two passes are two segments")
        shell.setVerbs([StudioVerb(id: "save", glyph: "d", title: "Save", hint: "", perform: {})], visible: false)
        expect(shell.verbSummary.hasPrefix("reserved"), "the verbs hold their room while nothing is to be done")
        shell.setVerbs([StudioVerb(id: "save", glyph: "d", title: "Save", hint: "", perform: {})], visible: true)
        expect(shell.verbSummary.hasPrefix("shown"), "and show once there is a picture")

        let foot = Gtk.label("", css: "studio-foot", selectable: false)
        let tray = StudioChipTray(trailing: foot)
        let chips = (0..<6).map { _ in StudioChip.button {} }
        for (index, chip) in chips.enumerated() {
            chip.apply(StudioChipReading(id: .engine, label: "Label \(index)", value: "Value"))
        }
        tray.fill(chips)
        tray.layout(available: 10_000)
        let wide = gtk_widget_get_first_child(tray.lines).map { _ in 1 } ?? 0
        tray.layout(available: 200)
        var rows = 0
        var child = gtk_widget_get_first_child(tray.lines)
        while let current = child {
            rows += 1
            child = gtk_widget_get_next_sibling(current)
        }
        expect(wide == 1 && rows > 1, "a narrow dock wraps its chips onto more lines instead of clipping")
        tray.fold(true)
        expect(tray.isFolded, "a short pane folds them into Settings")
        return failures
    }
}

/// A thread that installs the stack sampler on itself and burns CPU until told to stop, so the
/// self-test has a busy thread to sample that is not the one doing the asking.
final class SpinningThread: @unchecked Sendable {
    private let lock = NSLock()
    private var installed = false
    private var stopping = false
    private var sink = 0.0

    func start() {
        let thread = Thread { [self] in
            _ = tailscode_stack_sampler_install()
            lock.lock()
            installed = true
            lock.unlock()
            while !isStopping { sink += Self.work(20_000) }
        }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    @inline(never)
    private static func work(_ count: Int) -> Double {
        var total = 0.0
        for index in 0..<count { total += Double(index).squareRoot() }
        return total
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    func waitUntilInstalled() -> Bool {
        for _ in 0..<200 {
            lock.lock()
            let ready = installed
            lock.unlock()
            if ready { return true }
            usleep(5_000)
        }
        return false
    }

    func stop() {
        lock.lock()
        stopping = true
        lock.unlock()
    }
}

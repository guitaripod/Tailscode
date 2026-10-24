import AgentTestSupport
import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// `TailscodeMac --selftest` drives the whole chain with no window: the markdown renderer, the
/// slash completion, the shared shortcut registry, the composer's vim mode and the local stores
/// first — pure logic a headless box checks perfectly well — then every configured server's
/// health, its session list, and the newest session's stream until a transcript lands.
///
/// A Mac reached over ssh has no window server, so a screenshot cannot prove the app works from a
/// build loop. This can. It is driven by the main run loop and not by `dispatchMain()`, which parks
/// the main thread: a main-actor task resumed after an await would then make AppKit windows and
/// Auto Layout on a worker thread, and Auto Layout aborts the process for it.
@MainActor
enum SelfTest {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest")
    }

    static func run() async -> Never {
        startWatchdog()
        var failures = 0
        let tileChild = TileChecks.Child()
        let chatChild = ChatChecks.Child()
        let clockChild = MeridianChecks.Child()
        let openChild = BrainOpenChecks.Child()
        let agentsChild = AgentsChecks.Child()

        do {
            let checks = try checkMarkup()
            report("markup: \(checks) shapes render")
        } catch {
            report("markup: \(error)")
            failures += 1
        }

        do {
            let checks = try checkCode()
            report("code: \(checks) claims hold — roles colour, lines never fold")
        } catch {
            report("code: \(error)")
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
            let checks = try checkDialPill()
            report("dial pill: \(checks) levels hold the pill's width")
        } catch {
            report("dial pill: \(error)")
            failures += 1
        }

        do {
            let checks = try checkSessionSync()
            report(
                "session sync: \(checks) claims hold — a level another desk picked reaches an open pane and is what a send from here carries")
        } catch {
            report("session sync: \(error)")
            failures += 1
        }

        do {
            let checks = try checkModelDial()
            report("model dial: \(checks) pairs, previews and keys draw as the state says")
        } catch {
            report("model dial: \(error)")
            failures += 1
        }

        do {
            let checks = try checkTheme()
            report("theme: \(checks) palettes reach AppKit and keep their meanings")
        } catch {
            report("theme: \(error)")
            failures += 1
        }

        do {
            let checks = try MeridianChecks.run()
            let audit = clockChild.verdict()
            if let failure = audit.failure { throw SelfTestFailure("label audit: \(failure)") }
            report(
                "world clock: \(checks) claims hold — the chip, the glance, Meridian's lanes, line and alarms; "
                    + "\(audit.notes), 0 cut short at zoom 1.0, 1.5 and 2.0, at 1392x796 and 752x520")
        } catch {
            report("world clock: \(error)")
            failures += 1
        }

        do {
            let checks = try RangeChecks.run()
            report("range: \(checks) claims hold — every tank a row, a bar as tall as a plain one, words only as news")
        } catch {
            report("range: \(error)")
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
            let checks = try checkTranscriptRows()
            report("transcript rows: \(checks) claims hold — a step keeps its own key")
        } catch {
            report("transcript rows: \(error)")
            failures += 1
        }

        do {
            let checks = try checkTranscriptPage()
            report("transcript page: \(checks) claims hold — a row's place is read from the top")
        } catch {
            report("transcript page: \(error)")
            failures += 1
        }

        let chat = chatChild.verdict()
        if chat.failures.isEmpty {
            report(
                "compact chat: \(chat.notes) claims hold — gaps by relationship, the rail's stages and "
                    + "its plate, the picture gallery, seams, timing")
        } else {
            report("compact chat: \(chat.failures.joined(separator: " · "))")
            failures += 1
        }

        do {
            let checks = try checkTranscriptColumn()
            report("transcript column: \(checks) claims hold — rows stand alone and stack as a stack would")
        } catch {
            report("transcript column: \(error)")
            failures += 1
        }

        do {
            let checks = try checkPointerFeedback()
            report("pointer: \(checks) claims hold — what can be pressed answers before the press")
        } catch {
            report("pointer: \(error)")
            failures += 1
        }

        do {
            let checks = try checkSubagentRow()
            report("subagent row: \(checks) claims hold — the clock stops with the call")
        } catch {
            report("subagent row: \(error)")
            failures += 1
        }

        let runFailures = WorkflowRunCheck.run()
        if runFailures.isEmpty {
            report("workflow run: every ending settles the run, stops its clock and holds still")
        } else {
            report("workflow run: \(runFailures.joined(separator: " · "))")
            failures += 1
        }

        do {
            let checks = try checkWorkflowCard()
            report(
                "workflow card: \(checks) claims hold — the mark is the run's, no phase is claimed"
            )
        } catch {
            report("workflow card: \(error)")
            failures += 1
        }

        do {
            let checks = try checkActivityTempo()
            report("activity tempo: \(checks) claims hold — nothing moves at a rate of its own")
        } catch {
            report("activity tempo: \(error)")
            failures += 1
        }

        do {
            let checks = try await ShareChecks.run()
            report("analytics share: \(checks) claims hold — every fixture on every format at 2x, the sheet's chips, capacity, memory and picture")
        } catch {
            report("analytics share: \(error)")
            failures += 1
        }

        do {
            let checks = try checkLocalWorkLayout()
            report(
                "analytics local work: \(checks) claims hold — the section leads a local-led page and carries its tiles"
            )
        } catch {
            report("analytics local work: \(error)")
            failures += 1
        }

        do {
            let checks = try checkRepeatingMotion()
            report(
                "repeating motion: \(checks) claims hold — every never-ending lap asks again")
        } catch {
            report("repeating motion: \(error)")
            failures += 1
        }

        let cutOffFailures = InterruptedTurnCheck.run()
        if cutOffFailures.isEmpty {
            report("cut-off turn: the words, the cost, the press and the refusal all hold")
        } else {
            report("cut-off turn: \(cutOffFailures.joined(separator: " · "))")
            failures += 1
        }

        do {
            let checks = try checkInterruptedCard()
            report("cut-off card: \(checks) claims hold — nothing on it is this client's wording")
        } catch {
            report("cut-off card: \(error)")
            failures += 1
        }

        do {
            let checks = try checkTranscriptNote()
            report("transcript note: \(checks) claims hold: a quiet line, never a card")
        } catch {
            report("transcript note: \(error)")
            failures += 1
        }

        do {
            let checks = try checkProviderRetryCard()
            report("provider retry card: \(checks) claims hold: the reason, the countdown, the remedy")
        } catch {
            report("provider retry card: \(error)")
            failures += 1
        }

        do {
            let checks = try checkRevertBanner()
            report("revert banner: \(checks) claims hold: the files, the paging line, the restore press")
        } catch {
            report("revert banner: \(error)")
            failures += 1
        }

        do {
            let checks = try checkShortcuts()
            report("shortcuts: \(checks) keys resolve, rebind and stay conflict-free")
        } catch {
            report("shortcuts: \(error)")
            failures += 1
        }

        #if !TAILSCODE_MAS
            do {
                let checks = try checkVideoSlot()
                report(
                    "video slot: \(checks) answers, resolver \(VideoResolver.tool() ?? "missing")")
            } catch {
                report("video slot: \(error)")
                failures += 1
            }

            do {
                let checks = try checkWatchBoard()
                report("watch board: \(checks) rows, badges and pictures draw")
            } catch {
                report("watch board: \(error)")
                failures += 1
            }

            do {
                let checks = try checkWatchAccounts()
                report("watch accounts: \(checks) rows and sign-in steps render")
            } catch {
                report("watch accounts: \(error)")
                failures += 1
            }
        #endif

        let imageFailures = ImageGenDoorCheck.run()
        if imageFailures.isEmpty {
            report("image door: the machine, the lane it grows and the words it may say all hold")
        } else {
            report("image door: \(imageFailures.joined(separator: " · "))")
            failures += 1
        }

        let previewFailures = PreviewCheck.run()
        if previewFailures.isEmpty {
            report(
                "preview: every face the pane can wear draws from its state — the checklist, the picture "
                    + "decoded from real JPEG bytes, the banner, the strip's badge — and a parked or "
                    + "shut-down pane owns no clock and no stream")
        } else {
            report("preview: \(previewFailures.joined(separator: " · "))")
            failures += 1
        }

        let studioFailures = StudioCheck.run()
        if studioFailures.isEmpty {
            report(
                "studio: both lanes' shelves, stage states, verbs, chips, the clip's start frame and passes, "
                    + "what redraws on a change, the folds, the keys, the lane switch and the sheet — its frame, motion, "
                    + "keys, focus and menu — all hold")
        } else {
            report("studio: \(studioFailures.joined(separator: " · "))")
            failures += 1
        }

        let viewerFailures = MediaViewerCheck.run()
        if viewerFailures.isEmpty {
            report(
                "viewer: the pager, the zoom and the keys, the stack of sheets — depth, top-only dismissal, the stacked "
                    + "frame, focus — and a gallery's retargeting, a clip's controls and a sheet in motion that lays nothing out all hold")
        } else {
            report("viewer: \(viewerFailures.joined(separator: " · "))")
            failures += 1
        }

        let forgeFailures = ForgeBoardCheck.run()
        if forgeFailures.isEmpty {
            report("video forge: the graph, the frames, the job's walk and the board all hold")
        } else {
            report("video forge: \(forgeFailures.joined(separator: " · "))")
            failures += 1
        }

        do {
            let checks = try checkForgeSurface()
            report("forge surface: \(checks) claims hold across \(ForgeDemo.states.count) states")
        } catch {
            report("forge surface: \(error)")
            failures += 1
        }

        do {
            let checks = try checkBrowserSlot()
            report("browser slot: \(checks) answers, engine WKWebView")
        } catch {
            report("browser slot: \(error)")
            failures += 1
        }

        do {
            let checks = try checkGit()
            report("git: \(checks) claims hold — the tree reads, the patch colours")
        } catch {
            report("git: \(error)")
            failures += 1
        }

        do {
            let checks = try checkUpdates()
            report("updates: \(checks) claims hold — nothing unchecked reads as current")
        } catch {
            report("updates: \(error)")
            failures += 1
        }

        do {
            let checks = try FirstRunChecks.run()
            report("first run: \(checks) claims hold — every state draws, Return connects, Escape is Later")
        } catch {
            report("first run: \(error)")
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
            let checks = try checkVim()
            report("vim: \(checks) commands behave")
        } catch {
            report("vim: \(error)")
            failures += 1
        }

        let chooserFailures = PaneChooserCheck.run()
        if chooserFailures.isEmpty {
            report("pane chooser: servers, chats and keys behave")
        } else {
            report("pane chooser: \(chooserFailures.joined(separator: " · "))")
            failures += 1
        }

        let newChatFailures = NewChatChooserCheck.run()
        if newChatFailures.isEmpty {
            report("new chat: folders rank, modes swap, keys behave")
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
            report("chat selection: two servers stay two chats, copy counts once")
        } else {
            report("chat selection: \(selectionFailures.joined(separator: " · "))")
            failures += 1
        }

        let modelFailures = ModelChooserCheck.run()
        if modelFailures.isEmpty {
            report("model chooser: providers fold, ranking holds, keys behave")
        } else {
            report("model chooser: \(modelFailures.joined(separator: " · "))")
            failures += 1
        }

        #if !TAILSCODE_MAS
            let watchFailures = WatchChooserCheck.run()
            if watchFailures.isEmpty {
                report("watch directory: sections compact, keys stay off the letters")
            } else {
                report("watch directory: \(watchFailures.joined(separator: " · "))")
                failures += 1
            }

            let accountFailures = WatchAccountsCheck.run()
            if accountFailures.isEmpty {
                report("watch accounts: each site states itself, the device flow keeps its shape")
            } else {
                report("watch accounts: \(accountFailures.joined(separator: " · "))")
                failures += 1
            }
        #endif

        do {
            let checks = try checkPaneHitTest()
            report("pane hit test: \(checks) presses land where they look")
        } catch {
            report("pane hit test: \(error)")
            failures += 1
        }

        do {
            let checks = try checkPaneVerbs()
            report("pane verbs: \(checks) chords, menu items, divider keys and strip drags reach the tree")
        } catch {
            report("pane verbs: \(error)")
            failures += 1
        }

        do {
            let checks = try checkFlight()
            report("flight: \(checks) claims hold — the ring keeps every second and survives a reopen")
        } catch {
            report("flight: \(error)")
            failures += 1
        }

        do {
            let checks = try checkRestorePlan()
            report("restore plan: \(checks) claims hold — an unclean launch parks, a second floors")
        } catch {
            report("restore plan: \(error)")
            failures += 1
        }

        do {
            let checks = try checkLoopMeter()
            report("loop meter: \(checks) claims hold — a 200 ms spin reads as one")
        } catch {
            report("loop meter: \(error)")
            failures += 1
        }

        do {
            let checks = try await checkWatchdog()
            report("watchdog: \(checks) claims hold — a blocked main thread is caught from outside")
        } catch {
            report("watchdog: \(error)")
            failures += 1
        }

        do {
            let checks = try checkMemoryPressureMapping()
            report("memory pressure: \(checks) claims hold — the kernel's words reach the governor")
        } catch {
            report("memory pressure: \(error)")
            failures += 1
        }

        do {
            let checks = try checkShedEffects()
            report("shed effects: \(checks) claims hold — loaded stops the reveal, strained everything")
        } catch {
            report("shed effects: \(error)")
            failures += 1
        }

        do {
            try checkStores()
            report("stores: ok")
        } catch {
            report("stores: \(error)")
            failures += 1
        }

        do {
            try checkImageStore()
            report("image store: pictures round-trip and stay keyed to their file")
        } catch {
            report("image store: \(error)")
            failures += 1
        }

        do {
            try checkTypeAreas()
            report("type areas: each area sizes only its own lines")
        } catch {
            report("type areas: \(error)")
            failures += 1
        }

        do {
            try checkToastWidth()
            report("toasts: a sentence is given the width it takes")
        } catch {
            report("toasts: \(error)")
            failures += 1
        }

        #if !TAILSCODE_MAS
            let shellOutput = TerminalPane.shell("echo tailscode-shell-ok", in: nil)
            if shellOutput.contains("tailscode-shell-ok") {
                report("shell: ok (one command at a time in a login shell)")
            } else {
                report("shell: no output")
                failures += 1
            }
        #endif

        let profiles = ServerDirectory.shared.profiles
        guard !profiles.isEmpty else {
            report("no servers configured — set TAILSCODE_HOST to seed one")
            exit(1)
        }

        for profile in profiles {
            guard let backend = ServerDirectory.shared.backend(for: profile) else {
                report("\(profile.name): no backend")
                failures += 1
                continue
            }
            do {
                let health = try await backend.health()
                let sessions = try await backend.listSessions()
                report(
                    "\(profile.name): \(health.version ?? "unknown") · \(sessions.count) sessions")
                guard let newest = sessions.first else { continue }
                let state = try await firstState(of: newest, on: backend)
                report(
                    "  \(newest.title): \(state.messages.count) messages · \(state.connection)")
            } catch {
                report("\(profile.name): \(error)")
                failures += 1
            }
        }
        do {
            let count = try await checkTwoObservers(profiles)
            report("two observers: agree on \(count) messages")
        } catch {
            report("two observers: \(error)")
            failures += 1
        }

        let tiles = tileChild.verdict()
        if tiles.failures.isEmpty {
            report(
                "tiles: a frame applies the newest state, one conversation per chat, parked panes "
                    + "own nothing, closed panes are freed, a split needs room, the canvas places every pane where Core says and never re-parents one (\(tiles.notes))")
        } else {
            report("tiles: \(tiles.failures.joined(separator: " · "))")
            failures += 1
        }

        let opening = openChild.verdict()
        if opening.failures.isEmpty {
            report(
                "megatron open: the longest turn of the main thread stays under \(Int(BrainOpenChecks.ceiling)) ms (median) while one opens or closes"
                    + (opening.note.isEmpty ? "" : " (\(opening.note))"))
        } else {
            report("megatron open: \(opening.failures.joined(separator: " · "))")
            failures += 1
        }

        let agents = agentsChild.verdict()
        if let failure = agents.failure {
            report("agents: \(failure)")
            failures += 1
        } else {
            report(
                "agents: \(agents.notes) — the board, its peek and its hour draw, a verb in flight is off, Stop asks first, the tower leaves no watch")
        }

        report(failures == 0 ? "SELFTEST_OK" : "SELFTEST_FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func settled(_ conversation: AgentConversation) async throws -> [String] {
        let deadline = Date().addingTimeInterval(20)
        for await state in await conversation.states() {
            if state.hasLoadedTranscript { return state.messages.map(\.id) }
            if Date() > deadline { break }
        }
        throw SelfTestFailure("observer never loaded a transcript")
    }

    /// The first snapshot that has actually loaded a transcript, or whatever arrived within the
    /// deadline — a stream that never delivers is the failure this is looking for.
    private static func firstState(
        of session: AgentSession, on backend: any CodingAgentBackend
    ) async throws -> ConversationState {
        let conversation = AgentConversation(backend: backend, sessionID: session.id)
        var latest = ConversationState()
        let deadline = Date().addingTimeInterval(15)
        for await state in await conversation.states() {
            latest = state
            if state.hasLoadedTranscript || Date() > deadline { break }
        }
        return latest
    }

    /// A self-test that hangs is worse than one that fails: it stalls the build loop on a machine
    /// nobody is looking at.
    private static func startWatchdog() {
        Task.detached {
            try? await Task.sleep(for: .seconds(90))
            FileHandle.standardOutput.write(Data("SELFTEST_TIMEOUT\n".utf8))
            exit(2)
        }
    }

    private static func report(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

/// The watchdog's reports, kept from its own queue.
final class SelfTestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [(StallWatch.Event, MainThreadState?)] = []

    func add(_ event: StallWatch.Event, _ state: MainThreadState?) {
        lock.lock()
        held.append((event, state))
        lock.unlock()
    }

    func clear() {
        lock.lock()
        held = []
        lock.unlock()
    }

    var events: [(StallWatch.Event, MainThreadState?)] {
        lock.lock()
        defer { lock.unlock() }
        return held
    }
}

/// A count bumped from whatever thread a callback lands on.
final class SelfTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

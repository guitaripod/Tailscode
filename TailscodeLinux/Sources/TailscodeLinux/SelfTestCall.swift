import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

private final class CallMemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(for key: String) throws -> String? { lock.withLock { values[key] } }
    func setValue(_ value: String, for key: String) throws { lock.withLock { values[key] = value } }
    func removeValue(for key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

private final class CallReadyGateway: VoiceHealthFetching, @unchecked Sendable {
    func get(_ url: URL, bearer: String?, timeout: TimeInterval) async throws -> VoiceHTTPAnswer {
        let body = VoiceHealth(
            gateway: "0.1.0", protocolVersion: VoiceWire.version, engine: .ready, model: "voice", detail: nil)
        return VoiceHTTPAnswer(status: 200, body: (try? JSONEncoder().encode(body)) ?? Data())
    }
}

private final class CallFakeCapture: VoiceAudioCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private(set) var starts = 0
    private(set) var stops = 0
    var level: Double { 0 }
    var running: Bool { lock.withLock { continuation != nil } }

    func start() async throws -> AsyncStream<Data> {
        let (stream, made) = AsyncStream<Data>.makeStream()
        lock.withLock {
            starts += 1
            continuation = made
        }
        return stream
    }

    func stop() async {
        lock.withLock {
            stops += 1
            continuation?.finish()
            continuation = nil
        }
    }
}

private final class CallFakePlayback: VoiceAudioPlayback, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var plays: [Data] = []
    private(set) var starts = 0
    private(set) var stops = 0
    private var open = false
    var level: Double { 0 }
    var running: Bool { lock.withLock { open } }

    func start() async throws { lock.withLock { starts += 1; open = true } }
    func play(_ pcm: Data) async { lock.withLock { plays.append(pcm) } }
    func flush() async {}
    func stop() async { lock.withLock { stops += 1; open = false } }

    func played(_ pcm: Data) -> Int { lock.withLock { plays.filter { $0 == pcm }.count } }
}

private final class CallQuietTransport: VoiceTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var output: AsyncThrowingStream<VoiceFrame, Error>.Continuation?
    private var sentTexts: [String] = []

    var texts: [String] { lock.withLock { sentTexts } }

    func connect(url: URL, bearer: String?) async throws {}
    func sendBinary(_ data: Data) async throws {}

    func sendText(_ text: String) async throws {
        lock.withLock { sentTexts.append(text) }
        guard text.contains("\"hello\"") else { return }
        emit(.ready(.init(gateway: "selftest", model: "none")))
        emit(.phase(.listening, at: 0))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.emit(.dispatch(id: "d1", text: "Can you run the tests and tell me what fails?"))
        }
    }

    private func emit(_ message: VoiceServerMessage) {
        guard let text = try? VoiceCodec.encode(message) else { return }
        _ = lock.withLock { output }?.yield(.text(text))
    }

    func receive() -> AsyncThrowingStream<VoiceFrame, Error> {
        let (stream, made) = AsyncThrowingStream<VoiceFrame, Error>.makeStream()
        lock.withLock { output = made }
        return stream
    }

    func close() async {
        lock.withLock {
            output?.finish()
            output = nil
        }
    }
}

private final class CallAudioRig: @unchecked Sendable {
    let lock = NSLock()
    var pairs: [(CallFakeCapture, CallFakePlayback)] = []
    var transports: [CallQuietTransport] = []
    var refuseAudio = false
}

final class CallStubHost: CallPaneHost, @unchecked Sendable {
    var entry: SessionEntry?
    var state: ConversationState?
    var sent: [String] = []
    var notices: [String] = []
    var announced: [String] = []
    var stops = 0

    init(chat: String, host: String = "gateway.selftest.invalid") {
        entry = SessionEntry(
            profileID: "selftest", profileName: "selftest", host: host, backendType: .claudeCode,
            session: AgentSession(
                id: chat, agentType: .claudeCode, title: "Call test \(chat)", directory: nil,
                createdAt: Date(), updatedAt: Date()))
    }

    var callEntry: SessionEntry? { entry }
    var callState: ConversationState? { state }
    var callWindow: UnsafeMutablePointer<GtkWidget>? { nil }
    func callSend(_ words: String) -> Bool { sent.append(words); return true }
    func callStopTurn() { stops += 1 }
    func callNotice(_ words: String) { notices.append(words) }
    func callAnnounce(_ words: String) { announced.append(words) }
    func callChipChanged() {}
}

extension SelfTest {
    /// One check on its own, for the loop that is working on it: `TAILSCODE_SELFTEST_ONLY=call`.
    static func runOnly(_ name: String) -> Never {
        do {
            switch name {
            case "party": report("party: \(try checkPartyCards()) claims hold")
            case "quickask": report("quick ask party: \(try checkQuickAskParty()) claims hold")
            case "keyboard": report("keyboard: \(try checkKeyboardRebind()) claims hold")
            case "carry": report("model seam and carry: \(try checkModelSeamAndCarry()) claims hold")
            case "call": report("call: \(try checkCall()) claims hold")
            case "beta": report("beta: \(try checkBeta()) claims hold")
            case "sidebar": report("sidebar: \(try checkSidebar()) claims hold")
            case "agents":
                report("agents: \(try checkAgentsBoard()) claims hold")
                report("agents watch: \(try checkAgentsWatch()) claims hold")
            case "clock": report("clock: \(try checkClock()) claims hold")
            case "shutdown": report("shutdown: \(try checkShutdown()) claims hold")
            case "share": report("analytics share: \(try checkAnalyticsShare()) claims hold")
            case "brain": report("brain: \(try checkBrain()) claims hold")
            case "chatswitch": report("chat switch: \(try checkChatSwitch()) claims hold")
            case "readoutswap": report("readout swap: \(try checkBrainSwap()) claims hold")
            case "setup": report("setup: \(try checkSetup()) claims hold")
            case "diagnosis": report("self-diagnosis: \(try runBlocking { try await checkSelfDiagnosis() }) claims hold")
            case "guard": report("resource guard: \(try checkResourceGuard()) claims hold")
            case "audio": report("voice audio: \(try runBlocking { try await checkVoiceAudio() }) claims hold")
            default: report("no check named \(name)"); exit(2)
            }
            report("SELFTEST_OK")
            exit(0)
        } catch {
            report("\(error)")
            report("SELFTEST_FAILED")
            exit(1)
        }
    }

    private static func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = BlockingBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
            done.signal()
        }
        while done.wait(timeout: .now() + 0.01) == .timedOut {
            while g_main_context_iteration(nil, 0) != 0 {}
        }
        return try box.result!.get()
    }

    /// What a call promises on this desk without a gateway: the control shows, dims and hides for
    /// every state a gateway can say, the strip draws every face and says its word, holds a settled
    /// face still, runs a clock and captions, mutes and hangs up, lingers when it ends and then
    /// leaves; and a real `VoiceCallDesk` over fake audio proves what the call does with the pane —
    /// the dictated words arrive through the pane's send path, the agent's account is fed on every
    /// state, both sounds play, another call replaces this one, and capture and playback are
    /// stopped after every way a call can end.
    static func checkCall() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("call: \(label)") }
            checks += 1
        }
        func pump(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                while g_main_context_iteration(nil, 0) != 0 {}
                if done() { return true }
                usleep(4000)
            }
            return done()
        }
        let animations = tailscode_animations_enabled() != 0
        defer {
            tailscode_set_animations_enabled(animations ? 1 : 0)
            VoiceCallRunner.forcedReach = nil
            VoiceCallRunner.forcedEndpoint = nil
        }

        try checkCallEntry(expect, pump)
        try checkCallStrip(expect, pump)
        try checkCallDesk(expect, pump)
        return checks
    }

    private static func checkCallEntry(
        _ expect: (Bool, String) throws -> Void, _ pump: (Double, () -> Bool) -> Bool
    ) throws {
        let reaches: [(VoiceReach, shown: Bool, enabled: Bool)] = [
            (.unknown, false, true), (.checking, false, false), (.noGateway, false, true),
            (.ready(gateway: "0.1.0"), true, true), (.loading, true, false), (.busy, true, false),
            (.tooOld(protocol: 0), true, false), (.tooOld(protocol: 99), true, false),
            (.needsSetup, true, true), (.engineDown(detail: "CUDA out of memory"), true, true),
            (.wantsPassword, true, true),
            (.unreachable("it did not answer in time"), true, true),
        ]
        for (reach, shown, enabled) in reaches {
            try expect(PaneCall.shows(reach: reach, active: false) == shown, "\(reach): the control is \(shown ? "shown" : "hidden")")
            try expect(
                VoiceCallEntryPoint.isEnabled(reach: reach, active: false) == enabled || !shown,
                "\(reach): the control is \(enabled ? "live" : "dimmed")")
            if shown, !enabled {
                try expect(
                    VoiceCallEntryPoint.tooltip(reach: reach) == reach.line,
                    "\(reach): a dimmed control says why in the reach's own words")
            }
            try expect(
                PaneCall.shows(reach: reach, active: true) && VoiceCallEntryPoint.isEnabled(reach: reach, active: true),
                "\(reach): a call in progress can always be hung up")
        }

        let host = CallStubHost(chat: "entry")
        VoiceCallRunner.forcedEndpoint = VoiceEndpoint(host: "voice-entry.invalid")
        let call = PaneCall(host: host)
        for (reach, shown, enabled) in reaches {
            VoiceCallRunner.forcedReach = reach
            call.refresh()
            try expect(call.chipVisible == shown, "the widget: \(reach) \(shown ? "shows" : "hides") the control")
            guard shown else { continue }
            try expect(call.chipEnabled == enabled, "the widget: \(reach) is \(enabled ? "live" : "dimmed")")
            try expect(
                call.chipTooltip == VoiceCallEntryPoint.tooltip(reach: reach, active: false),
                "the widget: \(reach) wears the entry point's tooltip")
            try expect(call.chipWordText == VoiceCallEntryPoint.label(active: false), "the widget: the word is Core's")
        }
        host.entry = nil
        call.chatChanged()
        try expect(!call.chipVisible, "a pane with no chat shows no control")
        call.shutdown()
        VoiceCallRunner.forcedReach = nil
        VoiceCallRunner.forcedEndpoint = nil
    }

    private static func checkCallStrip(
        _ expect: (Bool, String) throws -> Void, _ pump: (Double, () -> Bool) -> Bool
    ) throws {
        let clocks = CallClock.text(0) == "0:00" && CallClock.text(65) == "1:05" && CallClock.text(3725) == "1:02:05"
        try expect(clocks && CallClock.text(-4) == "0:00", "the timer reads m:ss and h:mm:ss")

        let tally = CallTally()
        let strip = CallStripView(
            reportLines: { ["Gateway: studio:4102"] }, mute: { tally.mutes.append($0) },
            hangUp: { tally.hangUps += 1 })
        let window = gtk_window_new()!
        gtk_window_set_default_size(ptr(window), 520, 300)
        gtk_window_set_child(ptr(window), strip.widget)
        gtk_window_present(ptr(window))
        let started = Date().addingTimeInterval(-65)
        strip.apply(VoiceCallSnapshot(face: .hearing, lines: [], startedAt: started), level: { 0 })
        _ = pump(BetaSheen.duration + 0.4) { false }
        strip.dismiss()
        let baseline = Int(tailscode_live_ticks())

        for face in VoiceCallFace.everyFace {
            let snapshot = VoiceCallSnapshot(
                face: face, lines: [], startedAt: started,
                degraded: face == .degraded(.engineError) ? VoiceCallDegradation(reason: .engineError, recovering: false) : nil,
                end: face == .ended ? .hungUp : nil,
                endLine: face == .ended ? VoiceCallReading.end(.hungUp, client: .linux) : nil)
            strip.apply(snapshot, level: { 0.5 })
            _ = pump(0.05) { false }
            try expect(strip.report.contains("word=\"\(snapshot.word)\""), "\(face): the strip says the face's word")
            try expect(strip.isShown, "\(face): the strip is up")
            try expect(strip.hasMute == face.isOpen && strip.hasHangUp == face.isOpen, "\(face): mute and hang up are there while the call is open")
            try expect(
                strip.faceMark.isMoving == face.motion.isAnimated, "\(face): the clock runs exactly when the face moves")
            if !face.motion.isAnimated {
                try expect(strip.faceMark.glyphText == face.glyph, "\(face): a settled face wears its own glyph")
            }
        }
        strip.dismiss()
        try expect(!strip.isShown && Int(tailscode_live_ticks()) <= baseline, "taking the strip down leaves no clock running")

        strip.apply(
            VoiceCallSnapshot(face: .degraded(.runaway), lines: [], startedAt: started,
                degraded: VoiceCallDegradation(reason: .runaway, recovering: true)),
            level: { 0 })
        try expect(
            Int(tailscode_live_ticks()) <= baseline, "a degraded face holds perfectly still and runs no clock")
        strip.dismiss()

        let lines = [VoiceCallLine(id: "u1", kind: .you, text: "can you run the tests", final: false)]
        strip.apply(VoiceCallSnapshot(face: .hearing, lines: lines, startedAt: started), level: { 0 })
        try expect(
            strip.report.contains("you=\"can you run the tests\"") && !strip.report.contains("voice="),
            "what you said is on the strip and the strip has no line for a voice")
        try expect(strip.report.contains("clock=\"1:0"), "the timer counts from the call's start")
        strip.setAgent(kind: .usingTool(name: "Bash", kind: .shell), text: "Working. Running a command.")
        try expect(strip.report.contains("agent=\"Working. Running a command.\""), "the agent's line is on the strip")
        let long = String(repeating: "a very long caption that must wrap and then be cut ", count: 12)
        strip.apply(
            VoiceCallSnapshot(face: .hearing, lines: [VoiceCallLine(id: "u2", kind: .you, text: long, final: false)], startedAt: started),
            level: { 0.7 })
        try expect(gtk_widget_get_height(strip.widget) < 220 || !pump(0.2) { false }, "a long caption is held to two lines and never grows the strip without end")

        strip.apply(VoiceCallSnapshot(face: .listening, lines: [], startedAt: started, muted: false), level: { 0 })
        strip.pressMute()
        _ = pump(0.1) { false }
        try expect(tally.mutes == [true], "pressing mute asks the call to mute")
        strip.apply(VoiceCallSnapshot(face: .listening, lines: [], startedAt: started, muted: true), level: { 0 })
        try expect(strip.muteWord == VoiceCallReading.unmute, "muted, the control offers to unmute")
        strip.pressMute()
        _ = pump(0.1) { false }
        try expect(tally.mutes == [true, false], "and pressing it again asks to unmute")
        strip.pressHangUp()
        _ = pump(0.1) { false }
        try expect(tally.hangUps == 1, "pressing hang up asks the call to end")
        strip.apply(VoiceCallSnapshot(face: .listening, lines: [], startedAt: started, muted: false), level: { 0 })
        try expect(strip.muteWord == VoiceCallReading.mute, "unmuted, it offers to mute")

        tailscode_set_animations_enabled(0)
        strip.apply(VoiceCallSnapshot(face: .working, lines: [], startedAt: started), level: { 0 })
        try expect(
            !strip.faceMark.isMoving && strip.faceMark.glyphText == VoiceCallFace.working.glyph,
            "reduced motion drops the movement and keeps the glyph")
        strip.apply(VoiceCallSnapshot(face: .connecting, lines: [], startedAt: nil), level: { 0 })
        try expect(!strip.faceMark.isMoving, "reduced motion stops the connecting sweep")
        tailscode_set_animations_enabled(1)

        CallStripView.lingers = 300
        defer { CallStripView.lingers = 6000 }
        strip.apply(
            VoiceCallSnapshot(
                face: .ended, lines: lines, startedAt: started, end: .replaced,
                endLine: VoiceCallReading.end(.replaced, client: .linux)),
            level: { 0 })
        try expect(
            strip.report.contains("end=\"\(VoiceCallReading.end(.replaced, client: .linux))\""),
            "a replaced call reads why on its strip")
        try expect(!strip.hasMute && !strip.hasHangUp, "an ended call offers neither mute nor hang up")
        try expect(strip.isShown, "an ended strip stays for a moment")
        try expect(pump(2) { !strip.isShown }, "and leaves by itself")
        strip.tearDown()
        gtk_window_destroy(ptr(window))
        _ = pump(0.1) { false }
    }

    private static func checkCallDesk(
        _ expect: (Bool, String) throws -> Void, _ pump: (Double, () -> Bool) -> Bool
    ) throws {
        let rig = CallAudioRig()
        let desk = VoiceCallDesk(
            secrets: CallMemorySecrets(), probe: VoiceReachProbe(fetcher: CallReadyGateway()),
            makeTransport: {
                let made = CallQuietTransport()
                rig.lock.withLock { rig.transports.append(made) }
                return made
            })
        let runner = VoiceCallRunner(
            desk: desk,
            audio: {
                if rig.lock.withLock({ rig.refuseAudio }) { throw VoiceAudioError.unavailable("no sound card") }
                let pair = (CallFakeCapture(), CallFakePlayback())
                rig.lock.withLock { rig.pairs.append(pair) }
                return (pair.0, pair.1)
            })
        func latest() -> (CallFakeCapture, CallFakePlayback)? { rig.lock.withLock { rig.pairs.last } }
        func allStopped() -> Bool { rig.lock.withLock { rig.pairs.allSatisfy { !$0.0.running && !$0.1.running } } }

        let hostA = CallStubHost(chat: "chat-a")
        let callA = PaneCall(host: hostA, runner: runner)
        callA.chatChanged()
        try expect(pump(6) { callA.chipVisible && callA.chipEnabled }, "a gateway that is ready shows a live control (watched, not asked once)")

        callA.pressEntry()
        try expect(pump(6) { runner.isActive(chat: "selftest/chat-a") && callA.strip.isShown }, "pressing the control starts a call and docks the strip (notices=\(hostA.notices) active=\(String(describing: runner.active?.chat)) \(callA.reading))")
        try expect(callA.isOwner && callA.chipWordText == VoiceCallEntryPoint.label(active: true), "the control becomes hang up")
        try expect(pump(3) { latest()?.0.running == true && latest()?.1.running == true }, "capture and playback are started with the call")
        try expect(pump(4) { callA.strip.report.contains("face=listening") || callA.strip.report.contains("face=working") }, "the call goes live")

        var state = ConversationState()
        state.status = .running
        state.messages = [
            ChatMessage(id: "m1", role: .user, agentType: .claudeCode, createdAt: Date())
        ]
        hostA.state = state
        callA.stateChanged(state)
        let account = SpokenDigest.snapshot(from: state).digest
        try expect(pump(2) { callA.strip.report.contains("agent=\"\(account)\"") }, "every state the pane receives is turned into the agent's account on the strip (\(callA.strip.report))")

        var idle = ConversationState()
        idle.status = .idle
        hostA.state = idle
        callA.stateChanged(idle)
        let finished = VoiceChime.finished()
        try expect(
            pump(3) { latest()?.1.played(finished) ?? 0 >= 1 }, "the agent finishing while the person is quiet plays the finished sound through the call's speaker")

        var asking = ConversationState()
        asking.status = .running
        asking.pendingPermissions = [PermissionRequest(id: "p1", sessionID: "chat-a", title: "run it", toolName: "Bash")]
        hostA.state = asking
        callA.stateChanged(asking)
        let attention = VoiceChime.attention()
        try expect(pump(3) { latest()?.1.played(attention) ?? 0 == 1 }, "a question or approval that begins to wait plays the attention sound")
        callA.stateChanged(asking)
        _ = pump(0.3) { false }
        try expect(latest()?.1.played(attention) == 1, "and only once for the same one")

        try expect(
            pump(5) { !hostA.sent.isEmpty },
            "what the voice dispatched arrives through the pane's own send path")
        try expect(
            pump(3) { rig.lock.withLock { rig.transports.first?.texts.contains { $0.contains("\"sent\"") } ?? false } },
            "and the gateway is told it was sent")
        try expect(hostA.sent.first == "Can you run the tests and tell me what fails?", "as the words the person said")

        let hostB = CallStubHost(chat: "chat-b")
        let callB = PaneCall(host: hostB, runner: runner)
        callB.chatChanged()
        _ = pump(1) { callB.chipVisible }
        callB.pressEntry()
        try expect(pump(6) { runner.isActive(chat: "selftest/chat-b") }, "a second call starts")
        try expect(
            pump(3) { callA.strip.report.contains(VoiceCallReading.end(.replaced, client: .linux)) },
            "the first pane's strip reads that another call replaced it")
        try expect(pump(3) { !callA.chipWordText.isEmpty && callA.chipWordText == VoiceCallEntryPoint.label(active: false) }, "and its control is a call again")
        try expect(pump(3) { rig.lock.withLock { rig.pairs.count == 2 && !rig.pairs[0].0.running && !rig.pairs[0].1.running } }, "the replaced call's capture and playback are stopped")

        hostB.entry = hostA.entry
        callB.chatChanged()
        try expect(pump(4) { runner.active == nil }, "a pane that moves to another chat hangs its call up")
        try expect(pump(3, allStopped), "capture and playback are stopped after the chat switch")

        callA.pressEntry()
        try expect(pump(6) { runner.isActive(chat: "selftest/chat-a") }, "a call starts again")
        callA.pressEntry()
        try expect(pump(4) { runner.active == nil }, "pressing the control during a call hangs up")
        try expect(pump(3, allStopped), "capture and playback are stopped after a hang up")
        try expect(
            callA.strip.report.contains("word=\"\(VoiceCallFace.ended.word)\""), "the strip reads that the call ended")

        callB.pressEntry()
        try expect(pump(6) { runner.active != nil }, "another call starts")
        callB.shutdown()
        try expect(pump(4) { runner.active == nil }, "closing the pane hangs its call up")
        try expect(pump(3, allStopped), "capture and playback are stopped after the pane closes")

        rig.lock.withLock { rig.refuseAudio = true }
        let hostC = CallStubHost(chat: "chat-c")
        let callC = PaneCall(host: hostC, runner: runner)
        callC.chatChanged()
        _ = pump(2) { callC.chipVisible }
        callC.pressEntry()
        try expect(pump(4) { !hostC.notices.isEmpty }, "an audio stack that cannot start is said in words and starts no call")
        try expect(runner.active == nil && allStopped(), "and leaves nothing running")
        callC.shutdown()
        callA.shutdown()
        _ = pump(0.3) { false }
    }
}

private final class BlockingBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

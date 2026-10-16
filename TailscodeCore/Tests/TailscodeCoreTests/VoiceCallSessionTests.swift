import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Voice call session")
struct VoiceCallSessionTests {
    private func audio(_ byte: UInt8 = 1, count: Int = 3_840) -> Data { Data(repeating: byte, count: count) }

    @Test("It says hello first, to the call address, with the bearer and an ASCII title")
    func hello() async throws {
        let rig = VoiceRig(title: "Fix the parser, café")
        await rig.session.start()
        #expect(rig.transport.connectedURL?.absoluteString == "ws://box.tailnet.ts.net:4102/call")
        #expect(rig.transport.connectedBearer == "secret")
        guard case .hello(let hello)? = rig.transport.clientMessages.first else {
            Issue.record("the first frame was not hello")
            return
        }
        #expect(hello.v == VoiceWire.version)
        #expect(hello.client == .linux)
        #expect(hello.app == "1.70")
        #expect(hello.title == "Fix the parser, cafe")
        #expect(rig.capture.running)
        #expect(rig.playback.isStarted)
    }

    @Test("Ready opens the line, stamps the start once and pushes what the agent is doing")
    func ready() async {
        let rig = VoiceRig()
        await rig.session.update(agent: VoiceAgentSnapshot(busy: true, digest: "Working. Reading files.", turn: 4))
        await rig.session.start()
        #expect(await rig.snapshot().face == .connecting)
        rig.transport.emit(.ready(.init(gateway: "0.1", model: "voice")))
        #expect(await eventually { rig.transport.agentFrames.count == 1 })
        #expect(rig.transport.agentFrames.first == VoiceClientMessage.AgentState(busy: true, digest: "Working. Reading files.", turn: 4))
        #expect(await rig.snapshot().startedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test("Without a word from the agent the first frame says it is idle")
    func readyWithoutAgent() async {
        let rig = VoiceRig()
        await rig.opened()
        #expect(rig.transport.agentFrames == [VoiceAgentSnapshot.idle.wire])
    }

    @Test("Microphone chunks go out as binary frames, long ones cut and a half sample dropped")
    func capture() async {
        let rig = VoiceRig()
        await rig.opened()
        rig.capture.push(audio(7))
        rig.capture.push(audio(9, count: 20_001))
        #expect(await eventually { rig.transport.binaries.count == 3 })
        #expect(rig.transport.binaries[0] == audio(7))
        #expect(rig.transport.binaries[1].count == VoiceWire.maxChunkBytes)
        #expect(rig.transport.binaries[2].count == 20_000 - VoiceWire.maxChunkBytes)
        #expect(rig.transport.binaries.allSatisfy { $0.count % 2 == 0 })
    }

    @Test("Muted, the line carries silence of the same length rather than a gap")
    func muted() async {
        let rig = VoiceRig()
        await rig.opened()
        await rig.session.setMuted(true)
        rig.capture.push(audio(5))
        #expect(await eventually { rig.transport.binaries.count == 1 })
        #expect(rig.transport.binaries[0] == Data(count: 3_840))
        #expect(await rig.snapshot().muted)
    }

    @Test("The voice is played, and the moment the person speaks it is flushed and the tail dropped")
    func bargeIn() async {
        let rig = VoiceRig()
        await rig.opened()
        rig.transport.emit(.phase(.speaking, at: 2))
        rig.transport.emit(audio: audio(1))
        #expect(await eventually { rig.playback.played.count == 1 })
        let flushes = rig.playback.flushes
        rig.transport.emit(.phase(.hearing, at: 3))
        #expect(await eventually { rig.playback.flushes == flushes + 1 })
        rig.transport.emit(audio: audio(2))
        rig.transport.emit(.phase(.listening, at: 4))
        rig.transport.emit(audio: audio(3))
        #expect(await eventually { rig.playback.played.count == 2 })
        #expect(rig.playback.played.map { $0.first } == [1, 3])
    }

    @Test("A dispatch goes through the app's send path and is answered sent")
    func dispatchSent() async {
        let rig = VoiceRig()
        await rig.opened()
        rig.transport.emit(.dispatch(id: "d1", text: "run the tests"))
        #expect(await eventually { rig.transport.clientMessages.contains(.sent(id: "d1")) })
        #expect(rig.prompts.sent == ["run the tests"])
    }

    @Test("A dispatch the app could not send is answered refused, with the same id")
    func dispatchRefused() async {
        let rig = VoiceRig()
        rig.prompts.accept(false)
        await rig.opened()
        rig.transport.emit(.dispatch(id: "d2", text: "run the tests"))
        #expect(
            await eventually {
                rig.transport.clientMessages.contains(.refused(id: "d2", reason: VoiceCallSession.refusal))
            })
        #expect(!rig.transport.clientMessages.contains(.sent(id: "d2")))
    }

    @Test("Dispatches are sent one after another, in the order they came")
    func dispatchOrder() async {
        let rig = VoiceRig()
        await rig.opened()
        rig.transport.emit(.dispatch(id: "a", text: "first"))
        rig.transport.emit(.dispatch(id: "b", text: "second"))
        #expect(await eventually { rig.prompts.sent.count == 2 })
        #expect(rig.prompts.sent == ["first", "second"])
        #expect(await eventually { rig.transport.clientMessages.contains(.sent(id: "b")) })
    }

    @Test("Stop stops the agent's turn")
    func stop() async {
        let rig = VoiceRig()
        await rig.opened()
        rig.transport.emit(.stop)
        #expect(await eventually { rig.prompts.stops == 1 })
    }

    @Test("What was heard is kept as lines, a partial updated in place, and only the last six are held")
    func lines() async {
        let rig = VoiceRig()
        await rig.opened()
        rig.transport.emit(.user(id: "u1", text: "run the", final: false))
        rig.transport.emit(.user(id: "u1", text: "run the tests", final: false))
        #expect(await eventually { await rig.snapshot().lines.last?.text == "run the tests" })
        #expect(await rig.snapshot().lines.count == 1)
        rig.transport.emit(.user(id: "u1", text: "run the tests please", final: true))
        rig.transport.emit(.say(text: "Okay,", final: false))
        rig.transport.emit(.say(text: "Okay, running them", final: false))
        rig.transport.emit(.say(text: "Okay, running them now.", final: true))
        #expect(await eventually { await rig.snapshot().lines.last?.text == "Okay, running them now." })
        let two = await rig.snapshot().lines
        #expect(two.map(\.kind) == [.you, .voice])
        #expect(two.map(\.text) == ["run the tests please", "Okay, running them now."])
        #expect(two.allSatisfy { $0.final })
        for index in 0..<9 {
            rig.transport.emit(.say(text: "line \(index)", final: true))
        }
        #expect(await eventually { await rig.snapshot().lines.last?.text == "line 8" })
        let capped = await rig.snapshot().lines
        #expect(capped.count == VoiceCallSnapshot.lineLimit)
        #expect(capped.first?.text == "line 3")
    }

    @Test("A degraded voice stops playing and says why until it recovers")
    func degradedCycle() async {
        let rig = VoiceRig()
        await rig.opened()
        rig.transport.emit(.phase(.speaking, at: 2))
        rig.transport.emit(.degraded(.runaway, recovering: true))
        rig.transport.emit(.phase(.degraded, at: 3))
        #expect(await eventually { await rig.snapshot().face == .degraded(.runaway) })
        let degraded = await rig.snapshot().degraded
        #expect(degraded == VoiceCallDegradation(reason: .runaway, recovering: true))
        #expect(rig.playback.flushes >= 1)
        rig.transport.emit(audio: audio(1))
        rig.transport.emit(.phase(.listening, at: 4))
        #expect(await eventually { await rig.snapshot().face == .listening })
        #expect(await rig.snapshot().degraded == nil)
        rig.transport.emit(audio: audio(2))
        #expect(await eventually { rig.playback.played.count == 1 })
        #expect(rig.playback.played.first?.first == 2)
    }

    @Test("A flood of agent updates is one frame after the debounce, and a repeat is none")
    func debounce() async {
        let rig = VoiceRig()
        await rig.opened()
        rig.transport.clearLog()
        for turn in 1...50 {
            await rig.session.update(agent: VoiceAgentSnapshot(busy: true, digest: "Working. Step \(turn).", turn: turn))
        }
        await rig.clock.advance(by: 0.2)
        #expect(rig.transport.agentFrames.isEmpty)
        await rig.clock.advance(by: 0.06)
        #expect(rig.transport.agentFrames == [VoiceClientMessage.AgentState(busy: true, digest: "Working. Step 50.", turn: 50)])
        await rig.session.update(agent: VoiceAgentSnapshot(busy: true, digest: "Working. Step 50.", turn: 51))
        await rig.clock.advance(by: 0.3)
        #expect(rig.transport.agentFrames.count == 1)
    }

    @Test("The agent frame is repeated every five seconds even when nothing changed")
    func heartbeat() async {
        let rig = VoiceRig()
        await rig.opened()
        rig.transport.clearLog()
        await rig.clock.advance(by: 4.9)
        #expect(rig.transport.agentFrames.isEmpty)
        await rig.clock.advance(by: 0.2)
        #expect(rig.transport.agentFrames.count == 1)
        await rig.clock.advance(by: 5)
        #expect(rig.transport.agentFrames.count == 2)
        #expect(Set(rig.transport.agentFrames.map(\.digest)) == [SpokenDigest.idle])
    }

    @Test("The agent finishing while the person is quiet is one chime; while the voice speaks it is none")
    func chime() async {
        let rig = VoiceRig()
        await rig.opened()
        await rig.session.update(agent: VoiceAgentSnapshot(busy: true, digest: "Working. Thinking.", turn: 1))
        #expect(await rig.snapshot().face == .working)
        await rig.session.update(agent: VoiceAgentSnapshot(busy: false, digest: "Done. Fixed.", turn: 2))
        #expect(await rig.snapshot().finishedChimes == 1)
        #expect(await rig.snapshot().face == .listening)
        rig.transport.emit(.phase(.speaking, at: 5))
        #expect(await eventually { await rig.snapshot().face == .speaking })
        await rig.session.update(agent: VoiceAgentSnapshot(busy: true, digest: "Working. Thinking.", turn: 3))
        await rig.session.update(agent: VoiceAgentSnapshot(busy: false, digest: "Done. Again.", turn: 4))
        #expect(await rig.snapshot().finishedChimes == 1)
    }

    @Test("A lost line is redialled after 1 second, says so meanwhile, and the call carries on")
    func reconnect() async {
        let rig = VoiceRig()
        await rig.opened()
        rig.transport.emit(.user(id: "u1", text: "hello there", final: true))
        #expect(await eventually { await rig.snapshot().lines.count == 1 })
        rig.transport.drop()
        #expect(await eventually { await rig.snapshot().reconnecting })
        #expect(await rig.snapshot().face == .connecting)
        #expect(await rig.snapshot().word == VoiceCallReading.reconnecting)
        #expect(rig.capture.running)
        await rig.clock.advance(by: 0.9)
        #expect(rig.transport.connects == 1)
        await rig.clock.advance(by: 0.2)
        #expect(rig.transport.connects == 2)
        rig.transport.emit(.ready(.init(gateway: "0.1", model: "voice")))
        rig.transport.emit(.phase(.listening, at: 9))
        #expect(await eventually { await rig.snapshot().face == .listening })
        let back = await rig.snapshot()
        #expect(!back.reconnecting)
        #expect(back.lines.count == 1)
        #expect(back.startedAt == Date(timeIntervalSince1970: 1_000))
        let hellos = rig.transport.clientMessages.filter { if case .hello = $0 { return true } else { return false } }
        #expect(hellos.count == 2)
    }

    @Test("Three redials at 1, 2 and 4 seconds and then the call is over, lost, with nothing left running")
    func lost() async {
        let rig = VoiceRig()
        await rig.opened()
        rig.transport.failNextConnects(3)
        rig.transport.drop()
        #expect(await eventually { await rig.snapshot().reconnecting })
        await rig.clock.advance(by: 1)
        #expect(rig.transport.connects == 2)
        await rig.clock.advance(by: 1.9)
        #expect(rig.transport.connects == 2)
        await rig.clock.advance(by: 0.1)
        #expect(rig.transport.connects == 3)
        await rig.clock.advance(by: 3.9)
        #expect(rig.transport.connects == 3)
        await rig.clock.advance(by: 0.1)
        #expect(rig.transport.connects == 4)
        #expect(await eventually { await rig.snapshot().end == .lost })
        let ended = await rig.snapshot()
        #expect(ended.face == .ended)
        #expect(ended.endLine == VoiceCallReading.end(.lost, client: .linux))
        #expect(!rig.capture.running)
        #expect(!rig.playback.isStarted)
        #expect(await eventually { rig.recorder.isFinished })
    }

    @Test("A reconnect that connects and drops again before ready still counts against the three")
    func flapping() async {
        let rig = VoiceRig()
        await rig.opened()
        rig.transport.drop()
        for (index, wait) in [1.0, 2.0, 4.0].enumerated() {
            #expect(await eventually { await rig.snapshot().reconnecting })
            await rig.clock.advance(by: wait)
            #expect(rig.transport.connects == index + 2)
            rig.transport.drop()
        }
        #expect(await eventually { await rig.snapshot().end == .lost })
    }

    @Test("A busy refusal while redialling is the old call not yet released, so it is tried again")
    func busyWhileRedialling() async {
        let rig = VoiceRig()
        await rig.opened()
        rig.transport.drop()
        #expect(await eventually { await rig.snapshot().reconnecting })
        await rig.clock.advance(by: 1)
        rig.transport.emit(.error(code: "busy", message: "A call is already in progress."))
        #expect(await eventually { rig.clock.sleepers > 0 })
        #expect(await rig.snapshot().end == nil)
        await rig.clock.advance(by: 2)
        #expect(rig.transport.connects == 3)
    }

    @Test("An error frame ends the call with the gateway's reason and stops the audio")
    func errorFrame() async {
        let rig = VoiceRig()
        await rig.opened()
        rig.transport.emit(.error(code: "engineDown", message: "The voice engine is not reachable."))
        #expect(await eventually { await rig.snapshot().end != nil })
        let ended = await rig.snapshot()
        #expect(ended.end == .gateway(code: "engineDown", message: "The voice engine is not reachable."))
        #expect(ended.endLine == VoiceCallReading.degraded(.engineDown))
        #expect(ended.face == .ended)
        #expect(!rig.capture.running)
        #expect(rig.playback.stops >= 1)
        #expect(rig.transport.closes >= 1)
    }

    @Test("Hanging up says bye, stops the microphone and the speaker, closes the line and ends the stream")
    func hangUp() async {
        let rig = VoiceRig()
        await rig.opened()
        await rig.session.hangUp()
        #expect(rig.transport.clientMessages.contains(.bye))
        #expect(!rig.capture.running)
        #expect(rig.capture.stopCount == 1)
        #expect(rig.playback.stops == 1)
        #expect(rig.transport.closes >= 1)
        #expect(await rig.snapshot().end == .hungUp)
        #expect(await eventually { rig.recorder.isFinished })
        #expect(rig.recorder.faces.last == .ended)
        await rig.session.hangUp()
        #expect(rig.capture.stopCount == 1)
    }

    @Test("Hanging up in the middle of a sentence leaves nothing playing and ignores the rest of it")
    func hangUpMidSpeech() async {
        let rig = VoiceRig()
        await rig.opened()
        rig.transport.emit(.phase(.speaking, at: 2))
        rig.transport.emit(audio: audio(1))
        #expect(await eventually { rig.playback.played.count == 1 })
        await rig.session.hangUp()
        rig.transport.emit(audio: audio(2))
        rig.capture.push(audio(3))
        await rig.clock.settle()
        #expect(rig.playback.played.count == 1)
        #expect(rig.playback.stops == 1)
        #expect(!rig.capture.running)
        #expect(rig.transport.binaries.isEmpty)
        #expect(await rig.snapshot().face == .ended)
    }

    @Test("A microphone the person refused ends the call before any line is dialled")
    func microphoneDenied() async {
        let rig = VoiceRig()
        rig.capture.failStart(with: .microphoneDenied)
        await rig.session.start()
        let ended = await rig.snapshot()
        #expect(ended.end == .microphoneDenied)
        #expect(ended.endLine == VoiceCallReading.microphoneDenied(client: .linux))
        #expect(rig.transport.connects == 0)
        #expect(!rig.capture.running)
        #expect(!rig.playback.isStarted)
    }

    @Test("A gateway that cannot be reached ends the call at once, with nothing left running")
    func couldNotConnect() async {
        let rig = VoiceRig()
        rig.transport.failNextConnects(1)
        await rig.session.start()
        guard case .couldNotConnect? = await rig.snapshot().end else {
            Issue.record("the call did not end as unreachable")
            return
        }
        #expect(!rig.capture.running)
        #expect(!rig.playback.isStarted)
        #expect(rig.transport.connects == 1)
    }

    @Test("Starting twice is one call")
    func startsOnce() async {
        let rig = VoiceRig()
        await rig.session.start()
        await rig.session.start()
        #expect(rig.transport.connects == 1)
    }

    @Test("An unknown frame from a newer gateway is ignored")
    func unknownFrames() async {
        let rig = VoiceRig()
        await rig.opened()
        rig.transport.emit(.unknown("telemetry"))
        rig.transport.emit(.recycled)
        await rig.clock.settle()
        #expect(await rig.snapshot().face == .listening)
        #expect(await rig.snapshot().end == nil)
    }
}

private final class GatedCapture: VoiceAudioCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var waiting = false
    private var released = false
    private var active = false

    var level: Double { 0 }
    var entered: Bool { lock.withLock { waiting } }
    var running: Bool { lock.withLock { active } }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { gate = nil }
            return gate
        }
        continuation?.resume()
    }

    func start() async throws -> AsyncStream<Data> {
        lock.withLock { waiting = true }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                gate = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        lock.withLock { active = true }
        return AsyncStream<Data>.makeStream().stream
    }

    func stop() async { lock.withLock { active = false } }
}

@Suite("Voice call session start")
struct VoiceCallSessionStartTests {
    @Test("Hanging up while the microphone is still opening leaves nothing running once it has opened")
    func hangUpDuringStart() async {
        let capture = GatedCapture()
        let playback = FakePlayback()
        let transport = FakeTransport()
        let session = VoiceCallSession(
            endpoint: VoiceEndpoint(host: "box.tailnet.ts.net"), client: .linux, appVersion: "1", title: nil,
            transport: transport, capture: capture, playback: playback, send: { _ in true }, stopTurn: {},
            clock: ManualVoiceClock())
        let starting = Task { await session.start() }
        #expect(await eventually { capture.entered })
        await session.hangUp()
        capture.release()
        await starting.value
        #expect(!capture.running)
        #expect(!playback.isStarted)
        #expect(transport.connects == 0)
        #expect(await session.current().end == .hungUp)
    }
}

private final class GatedStopCapture: VoiceAudioCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var waiting = false
    private var open = false
    private var active = false
    private var stopped = false

    var level: Double { 0 }
    var stopEntered: Bool { lock.withLock { waiting } }
    var running: Bool { lock.withLock { active } }
    var didStop: Bool { lock.withLock { stopped } }

    func openGate() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            open = true
            defer { gate = nil }
            return gate
        }
        continuation?.resume()
    }

    func start() async throws -> AsyncStream<Data> {
        lock.withLock { active = true }
        return AsyncStream<Data>.makeStream().stream
    }

    func stop() async {
        lock.withLock { waiting = true }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let passThrough = lock.withLock { () -> Bool in
                if open { return true }
                gate = continuation
                return false
            }
            if passThrough { continuation.resume() }
        }
        lock.withLock {
            active = false
            stopped = true
        }
    }
}

@Suite("Voice call session teardown")
struct VoiceCallSessionTeardownTests {
    private struct Rig {
        let session: VoiceCallSession
        let capture = GatedStopCapture()
        let playback = FakePlayback()
        let transport = FakeTransport()
        let recorder = Recorder()
        let watcher: Task<Void, Never>

        init() {
            session = VoiceCallSession(
                endpoint: VoiceEndpoint(host: "box.tailnet.ts.net"), client: .linux, appVersion: "1", title: nil,
                transport: transport, capture: capture, playback: playback, send: { _ in true }, stopTurn: {},
                clock: ManualVoiceClock())
            watcher = recorder.watch(session.snapshots)
        }

        func opened() async {
            await session.start()
            transport.emit(.ready(.init(gateway: "0.1", model: "voice")))
            transport.emit(.phase(.listening, at: 1))
            _ = await eventually { await session.current().face == .listening }
        }

        func assertHeldOpen() async {
            #expect(await eventually { capture.stopEntered })
            let held = await session.current()
            #expect(held.end == nil)
            #expect(held.endLine == nil)
            #expect(held.face != .ended)
            #expect(recorder.snapshots.allSatisfy { $0.end == nil && $0.face != .ended })
            #expect(!recorder.isFinished)
        }

        func assertDoneOnceVisible() async {
            #expect(await eventually { await session.current().end != nil })
            #expect(capture.didStop)
            #expect(!capture.running)
            #expect(playback.stops >= 1)
            #expect(transport.closes >= 1)
            #expect(await eventually { recorder.isFinished })
            #expect(recorder.snapshots.last?.face == .ended)
        }
    }

    @Test("An error frame does not show the call as over until capture, playback and the line are stopped")
    func errorFrame() async {
        let rig = Rig()
        await rig.opened()
        rig.transport.emit(.error(code: "silent", message: "gone"))
        await rig.assertHeldOpen()
        rig.capture.openGate()
        await rig.assertDoneOnceVisible()
        #expect(await rig.session.current().end == .gateway(code: "silent", message: "gone"))
    }

    @Test("A hang up does not show the call as over until capture, playback and the line are stopped")
    func hangUp() async {
        let rig = Rig()
        await rig.opened()
        let hanging = Task { await rig.session.hangUp() }
        await rig.assertHeldOpen()
        await rig.session.hangUp()
        rig.capture.openGate()
        await hanging.value
        await rig.assertDoneOnceVisible()
        #expect(await rig.session.current().end == .hungUp)
    }
}

@Suite("Voice call engine")
struct VoiceCallEngineTests {
    @Test("While the gateway loads its model the connecting face says so, with how far it has got")
    func loadingIsSaid() async {
        let rig = VoiceRig()
        await rig.session.start()
        #expect(await rig.snapshot().word == "Connecting")
        rig.transport.emit(.engine(.loading, progress: nil))
        #expect(await eventually { await rig.snapshot().engine == .loading })
        var snapshot = await rig.snapshot()
        #expect(snapshot.face == .connecting)
        #expect(snapshot.isStartingEngine)
        #expect(snapshot.word == "Starting the voice model")
        #expect(snapshot.spoken == "Starting the voice model. This can take a few minutes.")
        rig.transport.emit(.engine(.loading, progress: 0.31))
        #expect(await eventually { await rig.snapshot().engineProgress == 0.31 })
        snapshot = await rig.snapshot()
        #expect(snapshot.word == "Starting the voice model, 31%")
        #expect(snapshot.face == .connecting)
        #expect(snapshot.face.icon.motion.isAnimated)
    }

    @Test("A stopped engine that is about to be started reads the same, and progress is clamped")
    func stoppedAndClamped() async {
        let rig = VoiceRig()
        await rig.session.start()
        rig.transport.emit(.engine(.stopped, progress: 4))
        #expect(await eventually { await rig.snapshot().engine == .stopped })
        let snapshot = await rig.snapshot()
        #expect(snapshot.isStartingEngine)
        #expect(snapshot.engineProgress == 1)
    }

    @Test("When the line opens the wait is over: the face is the call's and the model is ready")
    func readyEndsTheWait() async {
        let rig = VoiceRig()
        await rig.session.start()
        rig.transport.emit(.engine(.loading, progress: 0.9))
        #expect(await eventually { await rig.snapshot().engine == .loading })
        rig.transport.emit(.ready(.init(gateway: "0.1", model: "voice")))
        rig.transport.emit(.phase(.listening, at: 1))
        #expect(await eventually { await rig.snapshot().face == .listening })
        let snapshot = await rig.snapshot()
        #expect(snapshot.engine == .ready)
        #expect(snapshot.engineProgress == nil)
        #expect(!snapshot.isStartingEngine)
        #expect(snapshot.word == "Listening")
    }

    @Test("A state that is not a wait leaves the face's own word alone, and a redial is still a redial")
    func otherStates() async {
        let rig = VoiceRig()
        await rig.session.start()
        rig.transport.emit(.engine(.busy, progress: nil))
        #expect(await eventually { await rig.snapshot().engine == .busy })
        #expect(await rig.snapshot().word == "Connecting")
        var snapshot = VoiceCallSnapshot(face: .connecting, reconnecting: true, engine: .loading)
        #expect(snapshot.word == "Reconnecting the call…")
        snapshot = VoiceCallSnapshot(face: .listening, engine: .loading)
        #expect(snapshot.word == "Listening")
    }
}

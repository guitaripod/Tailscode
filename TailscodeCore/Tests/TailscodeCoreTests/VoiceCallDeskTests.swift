import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

extension Result where Failure == VoiceCallStartError {
    fileprivate var problem: VoiceCallStartError? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

private final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(for key: String) throws -> String? { lock.withLock { values[key] } }
    func setValue(_ value: String, for key: String) throws { lock.withLock { values[key] = value } }
    func removeValue(for key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

private final class Gateway: VoiceHealthFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var answer: VoiceHTTPAnswer
    private var requiredBearer: String?
    private var bearerLog: [String?] = []
    private var held: CheckedContinuation<Void, Never>?
    private var holdNext = false

    init(_ engine: VoiceEngineState = .ready, requiring bearer: String? = nil) {
        answer = Gateway.health(engine)
        requiredBearer = bearer
    }

    static func health(_ engine: VoiceEngineState) -> VoiceHTTPAnswer {
        let body = VoiceHealth(gateway: "0.1.0", protocolVersion: VoiceWire.version, engine: engine, model: "voice", detail: nil)
        return VoiceHTTPAnswer(status: 200, body: (try? JSONEncoder().encode(body)) ?? Data())
    }

    var requests: Int { lock.withLock { bearerLog.count } }
    var bearers: [String?] { lock.withLock { bearerLog } }

    func say(_ engine: VoiceEngineState) { lock.withLock { answer = Gateway.health(engine) } }

    func holdNextRequest() { lock.withLock { holdNext = true } }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { held = nil }
            return held
        }
        continuation?.resume()
    }

    func get(_ url: URL, bearer: String?, timeout: TimeInterval) async throws -> VoiceHTTPAnswer {
        let shouldHold = lock.withLock { () -> Bool in
            bearerLog.append(bearer)
            defer { holdNext = false }
            return holdNext
        }
        if shouldHold {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { held = continuation }
            }
        }
        return lock.withLock {
            if let requiredBearer, bearer != requiredBearer { return VoiceHTTPAnswer(status: 401, body: Data()) }
            return answer
        }
    }
}

private final class Collected<Item: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [Item] = []

    var items: [Item] { lock.withLock { held } }

    func collect<Stream: AsyncSequence & Sendable>(_ stream: Stream) -> Task<Void, Never> where Stream.Element == Item {
        Task {
            do {
                for try await item in stream { lock.withLock { held.append(item) } }
            } catch {
            }
        }
    }
}

private final class Wires: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeTransport] = []

    var all: [FakeTransport] { lock.withLock { made } }

    func make() -> any VoiceTransport {
        let transport = FakeTransport()
        lock.withLock { made.append(transport) }
        return transport
    }
}

private final class Devices: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [FakeCapture] = []
    private var playbacks: [FakePlayback] = []
    private var failure: VoiceAudioError?

    var made: Int { lock.withLock { captures.count } }
    var capture: [FakeCapture] { lock.withLock { captures } }
    var playback: [FakePlayback] { lock.withLock { playbacks } }

    func fail(with error: VoiceAudioError) { lock.withLock { failure = error } }

    func make() throws -> (VoiceAudioCapture, VoiceAudioPlayback) {
        if let error = lock.withLock({ failure }) { throw error }
        let pair = (FakeCapture(), FakePlayback())
        lock.withLock {
            captures.append(pair.0)
            playbacks.append(pair.1)
        }
        return pair
    }
}

private struct DeskRig {
    let desk: VoiceCallDesk
    let gateway: Gateway
    let wires = Wires()
    let devices = Devices()
    let clock = ManualVoiceClock()
    let secrets = MemorySecrets()
    let prompts = Prompts()
    let endpoint = VoiceEndpoint(host: "box.tailnet.ts.net")

    init(_ engine: VoiceEngineState = .ready, requiring bearer: String? = nil) {
        let gateway = Gateway(engine, requiring: bearer)
        let wires = self.wires
        self.gateway = gateway
        desk = VoiceCallDesk(
            secrets: secrets, probe: VoiceReachProbe(fetcher: gateway), clock: clock, makeTransport: { wires.make() })
    }

    @discardableResult
    func start(chat: String, endpoint: VoiceEndpoint? = nil) async -> Result<Void, VoiceCallStartError> {
        let devices = self.devices
        let prompts = self.prompts
        return await desk.start(
            chat: chat, title: "Chat \(chat)", endpoint: endpoint ?? self.endpoint, client: .linux, app: "1.70",
            audio: { try devices.make() }, send: { prompts.send($0) }, stopTurn: { prompts.stop() })
    }

    func open(chat: String) async -> ActiveCall? {
        _ = await start(chat: chat)
        let call = await desk.active
        guard let wire = wires.all.last else { return call }
        wire.emit(.ready(.init(gateway: "0.1.0", model: "voice")))
        wire.emit(.phase(.listening, at: 1))
        _ = await eventually { await call?.session.current().face == .listening }
        return call
    }
}

@Suite("Voice call desk")
struct VoiceCallDeskTests {
    @Test("A call starts for a chat, dials the gateway with the stored password and says hello")
    func starts() async throws {
        let rig = DeskRig(requiring: "hunter2")
        #expect((await rig.start(chat: "a")).problem == .wantsPassword)
        #expect(rig.devices.made == 0)
        await rig.desk.remember(password: "hunter2", for: rig.endpoint)
        #expect(await rig.desk.reach(for: rig.endpoint) == .ready(gateway: "0.1.0"))
        #expect(try rig.secrets.value(for: rig.endpoint.secretKey) == "hunter2")
        let result = await rig.start(chat: "a")
        #expect(result.problem == nil)
        #expect(await rig.desk.isActive(chat: "a"))
        #expect(!(await rig.desk.isActive(chat: "b")))
        let wire = try #require(rig.wires.all.first)
        #expect(wire.connectedURL?.absoluteString == "ws://box.tailnet.ts.net:4102/call")
        #expect(wire.connectedBearer == "hunter2")
        guard case .hello(let hello)? = wire.clientMessages.first else {
            Issue.record("the first frame was not hello")
            return
        }
        #expect(hello.app == "1.70")
        #expect(hello.title == "Chat a")
        #expect(rig.devices.capture.first?.running == true)
    }

    @Test("A second start ends the first with the reason, for the surface it was on, and owns the line")
    func secondStartEndsFirst() async throws {
        let rig = DeskRig()
        let first = try #require(await rig.open(chat: "a"))
        let ending = Task { () -> [VoiceCallSnapshot] in
            var seen: [VoiceCallSnapshot] = []
            for await snapshot in first.snapshots { seen.append(snapshot) }
            return seen
        }
        let result = await rig.start(chat: "b")
        #expect(result.problem == nil)
        #expect(await rig.desk.active?.chat == "b")
        #expect(!(await rig.desk.isActive(chat: "a")))
        let seen = await ending.value
        #expect(seen.last?.end == .replaced)
        #expect(seen.last?.endLine == VoiceCallReading.end(.replaced, client: .linux))
        #expect(rig.devices.capture[0].running == false)
        #expect(rig.devices.playback[0].isStarted == false)
        #expect(rig.devices.capture[1].running == true)
        #expect(rig.wires.all.count == 2)
        #expect(rig.wires.all[0].clientMessages.contains { if case .bye = $0 { return true } else { return false } })
        #expect(await first.snapshots.first { _ in true }?.end == .replaced)
    }

    @Test("Hanging up ends the call, frees the microphone and leaves the reason for the report")
    func hangsUp() async throws {
        let rig = DeskRig()
        let call = try #require(await rig.open(chat: "a"))
        await rig.desk.hangUp()
        #expect(await rig.desk.active == nil)
        #expect(!(await rig.desk.isActive(chat: "a")))
        #expect(await call.session.current().end == .hungUp)
        #expect(rig.devices.capture[0].running == false)
        #expect(rig.devices.playback[0].stops >= 1)
        let lines = await rig.desk.reportLines(for: rig.endpoint)
        #expect(lines.contains("Last call: hung up"))
        #expect(lines.contains("Gateway state: ready"))
        await rig.desk.hangUp()
        #expect(await rig.desk.active == nil)
    }

    @Test("The agent's account reaches the call only for the chat the call belongs to")
    func feedsOnlyTheActiveChat() async throws {
        let rig = DeskRig()
        _ = try #require(await rig.open(chat: "a"))
        let wire = try #require(rig.wires.all.first)
        wire.clearLog()
        await rig.desk.feed(agent: VoiceAgentSnapshot(busy: true, digest: "Working. Other chat.", turn: 2), chat: "b")
        await rig.clock.advance(by: 0.5)
        #expect(wire.agentFrames.isEmpty)
        await rig.desk.feed(agent: VoiceAgentSnapshot(busy: true, digest: "Working. Reading files.", turn: 3), chat: "a")
        await rig.clock.advance(by: 0.5)
        #expect(wire.agentFrames == [VoiceClientMessage.AgentState(busy: true, digest: "Working. Reading files.", turn: 3)])
    }

    @Test("A gateway that is not ready refuses with its own reason and nothing is opened")
    func refused() async {
        let rig = DeskRig(.loading)
        let result = await rig.start(chat: "a")
        #expect(result.problem == .notReady(.loading))
        if case .failure(let failure) = result { #expect(failure.line == VoiceReach.loading.line) }
        #expect(rig.devices.made == 0)
        #expect(rig.wires.all.isEmpty)
        #expect(await rig.desk.active == nil)
        rig.gateway.say(.busy)
        #expect((await rig.start(chat: "a")).problem == .notReady(.busy))
        rig.gateway.say(.ready)
        #expect((await rig.start(chat: "a")).problem == nil)
    }

    @Test("A start that is refused does not end the call that is running")
    func refusalKeepsTheRunningCall() async throws {
        let rig = DeskRig()
        _ = try #require(await rig.open(chat: "a"))
        rig.gateway.say(.loading)
        await rig.clock.advance(by: VoiceCallDesk.refreshInterval + 1)
        #expect((await rig.start(chat: "b")).problem == .notReady(.loading))
        #expect(await rig.desk.isActive(chat: "a"))
        #expect(rig.devices.capture[0].running)
    }

    @Test("The gateway reading busy because of this device's own call does not refuse the next one, which waits for the release")
    func replacingOnABusyGateway() async throws {
        let rig = DeskRig()
        _ = try #require(await rig.open(chat: "a"))
        rig.gateway.say(.busy)
        let starting = Task { await rig.start(chat: "b") }
        #expect(await eventually { rig.wires.all.count == 2 && rig.clock.sleepers >= 1 })
        #expect(rig.wires.all[1].connects == 0)
        #expect(!rig.devices.capture[0].running)
        await rig.clock.advance(by: VoiceCallDesk.releasePoll * 2)
        #expect(rig.wires.all[1].connects == 0)
        rig.gateway.say(.ready)
        await rig.clock.advance(by: VoiceCallDesk.releasePoll * 2)
        #expect((await starting.value).problem == nil)
        #expect(rig.wires.all[1].connects == 1)
        #expect(await rig.desk.active?.chat == "b")
    }

    @Test("Starting right after a hang up waits for the gateway to let go instead of refusing it as busy")
    func startingAfterHangUp() async throws {
        let rig = DeskRig()
        _ = try #require(await rig.open(chat: "a"))
        rig.gateway.say(.busy)
        await rig.desk.hangUp()
        let starting = Task { await rig.start(chat: "b") }
        #expect(await eventually { rig.clock.sleepers >= 1 })
        rig.gateway.say(.ready)
        await rig.clock.advance(by: VoiceCallDesk.releasePoll * 2)
        #expect((await starting.value).problem == nil)
        #expect(await rig.desk.isActive(chat: "b"))
    }

    @Test("A gateway that never lets go is dialled anyway after the grace, and says so itself")
    func neverReleased() async throws {
        let rig = DeskRig()
        _ = try #require(await rig.open(chat: "a"))
        rig.gateway.say(.busy)
        await rig.desk.hangUp()
        let starting = Task { await rig.start(chat: "b") }
        #expect(await eventually { rig.clock.sleepers >= 1 })
        for _ in 0..<20 { await rig.clock.advance(by: VoiceCallDesk.releasePoll) }
        #expect((await starting.value).problem == nil)
        #expect(rig.wires.all[1].connects == 1)
    }

    @Test("A missing microphone is a refusal in the platform's own words, and the old call stays")
    func audioRefusal() async throws {
        let rig = DeskRig()
        _ = try #require(await rig.open(chat: "a"))
        rig.devices.fail(with: .microphoneDenied)
        let result = await rig.start(chat: "b")
        #expect(result.problem == .audio(VoiceCallReading.microphoneDenied(client: .linux)))
        #expect(await rig.desk.isActive(chat: "a"))
    }

    @Test("A demo host plays the scripted call with no gateway, password or audio stack")
    func demo() async throws {
        let rig = DeskRig(.down)
        let demo = VoiceEndpoint(host: "studio.tailnet-demo.ts.net")
        #expect(demo.isDemo)
        #expect(await rig.desk.reach(for: demo).canStart)
        let result = await rig.desk.start(
            chat: "d", title: "Demo", endpoint: demo, client: .ios, app: "1",
            audio: { throw VoiceAudioError.microphoneDenied }, send: { rig.prompts.send($0) }, stopTurn: {})
        #expect(result.problem == nil)
        #expect(rig.gateway.requests == 0)
        #expect(rig.wires.all.isEmpty)
        let call = try #require(await rig.desk.active)
        #expect(await rig.desk.isActive(chat: "d"))
        for _ in 0..<60 { await rig.clock.advance(by: 0.1) }
        let faces = await call.session.current()
        #expect(faces.face != .connecting)
        #expect(faces.startedAt != nil)
        await rig.desk.hangUp()
        #expect(await call.session.current().end == .hungUp)
        #expect(rig.prompts.sent.count <= 1)
    }

    @Test("A start that a newer start overtook while the gateway was being asked gives way")
    func superseded() async throws {
        let rig = DeskRig()
        rig.gateway.holdNextRequest()
        let desk = rig.desk
        let slow = Task { await rig.start(chat: "slow") }
        #expect(await eventually { rig.gateway.requests == 1 })
        #expect((await rig.start(chat: "fast")).problem == nil)
        rig.gateway.release()
        #expect((await slow.value).problem == .superseded)
        #expect(await desk.active?.chat == "fast")
        #expect(rig.devices.made == 1)
    }

    @Test("The reach is cached with the probe's answer, a fresh one is reused and refresh asks again")
    func reachCache() async {
        let rig = DeskRig()
        #expect(await rig.desk.reach(for: rig.endpoint) == .unknown)
        #expect(await rig.desk.refresh(rig.endpoint) == .ready(gateway: "0.1.0"))
        #expect(rig.gateway.requests == 1)
        _ = await rig.start(chat: "a")
        #expect(rig.gateway.requests == 1)
        await rig.clock.advance(by: VoiceCallDesk.refreshInterval + 1)
        _ = await rig.start(chat: "b")
        #expect(rig.gateway.requests == 2)
        rig.gateway.say(.loading)
        #expect(await rig.desk.refresh(rig.endpoint) == .loading)
        #expect(await rig.desk.reach(for: rig.endpoint) == .loading)
        #expect(await rig.desk.reportLines(for: rig.endpoint).contains("Gateway state: model loading"))
    }

    @Test("Changes of reach are announced once each, in order, to everyone who listens")
    func reachChanges() async {
        let rig = DeskRig()
        let first = Collected<VoiceReach>()
        let second = Collected<VoiceReach>()
        let watchers = [
            first.collect(rig.desk.reachChanges().map(\.reach)),
            second.collect(rig.desk.reachChanges().map(\.reach)),
        ]
        await rig.desk.refresh(rig.endpoint)
        await rig.desk.refresh(rig.endpoint)
        rig.gateway.say(.busy)
        await rig.desk.refresh(rig.endpoint)
        let expected: [VoiceReach] = [.checking, .ready(gateway: "0.1.0"), .busy]
        #expect(await eventually { first.items == expected && second.items == expected })
        watchers.forEach { $0.cancel() }
    }

    @Test("A surface that asks for the reach has it kept fresh every twenty seconds until the last one lets go")
    func watching() async {
        let rig = DeskRig()
        await rig.desk.watchReach(of: rig.endpoint)
        await rig.desk.watchReach(of: rig.endpoint)
        #expect(await eventually { rig.gateway.requests == 1 })
        await rig.clock.advance(by: 19)
        #expect(rig.gateway.requests == 1)
        await rig.clock.advance(by: 1.5)
        #expect(rig.gateway.requests == 2)
        rig.gateway.say(.loading)
        await rig.clock.advance(by: VoiceCallDesk.refreshInterval)
        #expect(rig.gateway.requests == 3)
        #expect(await rig.desk.reach(for: rig.endpoint) == .loading)
        await rig.desk.unwatchReach(of: rig.endpoint)
        await rig.clock.advance(by: VoiceCallDesk.refreshInterval)
        #expect(rig.gateway.requests == 4)
        await rig.desk.unwatchReach(of: rig.endpoint)
        await rig.clock.advance(by: VoiceCallDesk.refreshInterval * 3)
        #expect(rig.gateway.requests == 4)
        #expect(rig.clock.sleepers == 0)
    }

    @Test("A password that is forgotten takes the reach back to unknown")
    func forgetting() async {
        let rig = DeskRig(requiring: "pw")
        #expect(await rig.desk.refresh(rig.endpoint) == .wantsPassword)
        #expect(await rig.desk.remember(password: "pw", for: rig.endpoint) == .ready(gateway: "0.1.0"))
        #expect(rig.gateway.bearers.last == "pw")
        await rig.desk.forgetPassword(for: rig.endpoint)
        #expect(await rig.desk.password(for: rig.endpoint) == nil)
        #expect(await rig.desk.reach(for: rig.endpoint) == .unknown)
    }

    @Test("The active call is announced when it starts, when another replaces it and when it ends")
    func activeChanges() async throws {
        let rig = DeskRig()
        let seen = Collected<String?>()
        let watcher = seen.collect(rig.desk.activeChanges().map { $0?.chat })
        _ = try #require(await rig.open(chat: "a"))
        _ = await rig.start(chat: "b")
        await rig.desk.hangUp()
        #expect(await eventually { seen.items == [nil, "a", "b", nil] })
        watcher.cancel()
    }
}

@Suite("Voice endpoint override")
struct VoiceEndpointOverrideTests {
    private let profile = URL(string: "http://box.tailnet.ts.net:4096")!

    @Test("A ws or http address in the environment replaces the profile's gateway, port and all")
    func overrides() throws {
        let key = VoiceEndpoint.overrideKey
        let ws = try #require(VoiceEndpoint(profileURL: profile, environment: [key: "ws://127.0.0.1:5123/call"]))
        #expect(ws == VoiceEndpoint(host: "127.0.0.1", port: 5123))
        #expect(ws.callURL.absoluteString == "ws://127.0.0.1:5123/call")
        let http = try #require(VoiceEndpoint(profileURL: profile, environment: [key: " http://localhost:6000 "]))
        #expect(http.healthURL.absoluteString == "http://localhost:6000/health")
        let bare = try #require(VoiceEndpoint(profileURL: profile, environment: [key: "http://192.168.1.4"]))
        #expect(bare.port == VoiceWire.port)
    }

    @Test("Anything else is ignored, a demo host is never redirected and a profile with no host still yields the override")
    func ignores() throws {
        let key = VoiceEndpoint.overrideKey
        for bad in ["", "box.example", "ftp://box.example:1", "https://box.example", "ws://", "not a url"] {
            #expect(VoiceEndpoint(profileURL: profile, environment: [key: bad]) == VoiceEndpoint(host: "box.tailnet.ts.net"))
        }
        let demo = try #require(URL(string: "http://studio.tailnet-demo.ts.net:4096"))
        #expect(VoiceEndpoint(profileURL: demo, environment: [key: "ws://127.0.0.1:5123"])?.host == "studio.tailnet-demo.ts.net")
        #expect(VoiceEndpoint(profileURL: URL(fileURLWithPath: "/tmp/x"), environment: [key: "ws://127.0.0.1:5123"])?.port == 5123)
        #expect(VoiceEndpoint(profileURL: URL(fileURLWithPath: "/tmp/x"), environment: [:]) == nil)
    }
}

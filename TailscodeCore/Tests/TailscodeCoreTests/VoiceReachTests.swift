import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private struct ScriptedFetcher: VoiceHealthFetching {
    let behave: @Sendable (URL, String?) async throws -> VoiceHTTPAnswer

    func get(_ url: URL, bearer: String?, timeout: TimeInterval) async throws -> VoiceHTTPAnswer {
        try await behave(url, bearer)
    }
}

private final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(for key: String) throws -> String? { lock.withLock { values[key] } }
    func setValue(_ value: String, for key: String) throws { lock.withLock { values[key] = value } }
    func removeValue(for key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

@Suite("Voice endpoint and reach")
struct VoiceReachTests {
    private func health(_ engine: VoiceEngineState, protocolVersion: Int = VoiceWire.version, detail: String? = nil) -> VoiceHTTPAnswer {
        let body = VoiceHealth(gateway: "0.3.1", protocolVersion: protocolVersion, engine: engine, model: "voice", detail: detail)
        return VoiceHTTPAnswer(status: 200, body: (try? JSONEncoder().encode(body)) ?? Data())
    }

    private func probe(_ behave: @escaping @Sendable (URL, String?) async throws -> VoiceHTTPAnswer, timeout: TimeInterval = 2) -> VoiceReachProbe {
        VoiceReachProbe(fetcher: ScriptedFetcher(behave: behave), timeout: timeout)
    }

    private let endpoint = VoiceEndpoint(host: "box.tailnet.ts.net")

    @Test("The endpoint is derived from a profile's base URL the way the delegate daemon's host is")
    func endpointDerivation() throws {
        let profile = try #require(URL(string: "http://box.tailnet.ts.net:4098"))
        let endpoint = try #require(VoiceEndpoint(profileURL: profile))
        #expect(endpoint.host == DelegateAccess.host(of: profile))
        #expect(endpoint.callURL.absoluteString == "ws://box.tailnet.ts.net:4102/call")
        #expect(endpoint.healthURL.absoluteString == "http://box.tailnet.ts.net:4102/health")
        #expect(endpoint.address == "box.tailnet.ts.net:4102")
        let numericURL = try #require(URL(string: "http://100.64.0.7:4096/x"))
        let numeric = try #require(VoiceEndpoint(profileURL: numericURL))
        #expect(numeric.callURL.absoluteString == "ws://100.64.0.7:4102/call")
        #expect(VoiceEndpoint(profileURL: URL(fileURLWithPath: "/tmp/x")) == nil)
    }

    @Test("The gateway's password has a key of its own, per machine, apart from the delegate's")
    func secrets() {
        let secrets = MemorySecrets()
        #expect(endpoint.secretKey == "voice.box.tailnet.ts.net")
        #expect(endpoint.secretKey != DelegateAccess(host: endpoint.host).secretKey)
        #expect(endpoint.password(in: secrets) == nil)
        endpoint.remember(password: "hunter2", in: secrets)
        #expect(endpoint.password(in: secrets) == "hunter2")
        #expect(VoiceEndpoint(host: endpoint.host).password(in: secrets) == "hunter2")
        #expect(VoiceEndpoint(host: "other").password(in: secrets) == nil)
        endpoint.forgetPassword(in: secrets)
        #expect(endpoint.password(in: secrets) == nil)
    }

    @Test("A healthy gateway is ready, and the probe asks the health address with the bearer")
    func ready() async {
        let asked = Asked()
        let reach = await probe { url, bearer in
            asked.record(url, bearer)
            return self.health(.ready)
        }.read(endpoint, bearer: "pw")
        #expect(reach == .ready(gateway: "0.3.1"))
        #expect(asked.url?.absoluteString == "http://box.tailnet.ts.net:4102/health")
        #expect(asked.bearer == "pw")
    }

    @Test("Each engine state, a protocol that does not match and a password wanted are all told apart")
    func states() async {
        let cases: [(VoiceHTTPAnswer, VoiceReach)] = [
            (health(.loading), .loading),
            (health(.busy), .busy),
            (health(.down, detail: "No GPU — café"), .engineDown(detail: "No GPU cafe")),
            (health(.down), .engineDown(detail: nil)),
            (health(.ready, protocolVersion: 0), .tooOld(protocol: 0)),
            (health(.ready, protocolVersion: 7), .tooOld(protocol: 7)),
            (VoiceHTTPAnswer(status: 401, body: Data()), .wantsPassword),
            (VoiceHTTPAnswer(status: 403, body: Data()), .wantsPassword),
            (VoiceHTTPAnswer(status: 404, body: Data()), .noGateway),
            (VoiceHTTPAnswer(status: 200, body: Data("<html>".utf8)), .noGateway),
            (VoiceHTTPAnswer(status: 502, body: Data()), .unreachable(VoiceCallReading.httpStatus(502))),
        ]
        for (answer, expected) in cases {
            let reach = await probe { _, _ in answer }.read(endpoint)
            #expect(reach == expected)
        }
    }

    @Test("A refused connection is no gateway; an unreachable machine and a timeout are unreachable")
    func failures() async {
        let refused = await probe { _, _ in throw URLError(.cannotConnectToHost) }.read(endpoint)
        #expect(refused == .noGateway)
        let nameless = await probe { _, _ in throw URLError(.cannotFindHost) }.read(endpoint)
        #expect(nameless == .unreachable(VoiceCallReading.machineUnreachable))
        let slow = await probe { _, _ in throw URLError(.timedOut) }.read(endpoint)
        #expect(slow == .unreachable(VoiceCallReading.timedOut))
    }

    @Test("A gateway that never answers is given up on at the deadline")
    func deadline() async {
        let began = Date()
        let reach = await probe({ _, _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return VoiceHTTPAnswer(status: 200, body: Data())
        }, timeout: 0.05).read(endpoint)
        #expect(reach == .unreachable(VoiceCallReading.timedOut))
        #expect(Date().timeIntervalSince(began) < 20)
        #expect(VoiceReachProbe.timeout == 2)
    }

    @Test("A demo host is ready with no network at all")
    func demo() async {
        let reach = await probe { _, _ in throw URLError(.notConnectedToInternet) }
            .read(VoiceEndpoint(host: "studio.tailnet-demo.ts.net"))
        #expect(reach == .ready(gateway: VoiceDemo.gatewayVersion))
        #expect(VoiceDemo.isDemoHost("homelab.tailnet-demo.ts.net"))
        #expect(!VoiceDemo.isDemoHost("box.tailnet.ts.net"))
    }

    @Test("A real socket that nothing listens on throws at connect instead of pretending")
    func realTransportRefuses() async {
        let transport = URLSessionVoiceTransport()
        var thrown = false
        do {
            try await transport.connect(url: URL(string: "ws://127.0.0.1:1/call")!, bearer: nil)
        } catch {
            thrown = true
        }
        #expect(thrown)
        var sendFailed = false
        do { try await transport.sendText("x") } catch { sendFailed = true }
        #expect(sendFailed)
        await transport.close()
    }

    @Test("Chunks are cut to what the gateway accepts")
    func chunks() {
        #expect(VoiceChunks.split(Data(), limit: 100).isEmpty)
        #expect(VoiceChunks.split(Data([1]), limit: 100).isEmpty)
        #expect(VoiceChunks.split(Data(count: 10), limit: 100).map(\.count) == [10])
        #expect(VoiceChunks.split(Data(count: 11), limit: 100).map(\.count) == [10])
        #expect(VoiceChunks.split(Data(count: 250), limit: 100).map(\.count) == [100, 100, 50])
        #expect(VoiceChunks.split(Data(count: 250), limit: 101).map(\.count) == [100, 100, 50])
    }
}

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var lastURL: URL?
    private var lastBearer: String?

    var url: URL? { lock.withLock { lastURL } }
    var bearer: String? { lock.withLock { lastBearer } }

    func record(_ url: URL, _ bearer: String?) {
        lock.withLock {
            lastURL = url
            lastBearer = bearer
        }
    }
}

@Suite("Voice call report")
struct VoiceCallReportTests {
    @Test("The report names the gateway, its version and how the last call ended")
    func lines() {
        let endpoint = VoiceEndpoint(host: "box.tailnet.ts.net")
        let report = VoiceCallReport.lines(endpoint: endpoint, reach: .ready(gateway: "0.3.1"), end: .lost)
        #expect(report.contains("Gateway: box.tailnet.ts.net:4102"))
        #expect(report.contains("Gateway version: 0.3.1"))
        #expect(report.contains("Last call: connection lost"))
        let down = VoiceCallReport.lines(endpoint: endpoint, reach: .engineDown(detail: "no GPU"))
        #expect(down.contains("Gateway state: model down (no GPU)"))
        #expect(!down.contains { $0.hasPrefix("Last call") || $0.hasPrefix("Gateway version") })
        let composed = BetaReport.compose(feature: .voiceCall, app: "1.70", system: "Linux", lines: report)
        #expect(composed.contains("Feature: voiceCall"))
    }
}

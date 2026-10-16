import Foundation
import Testing

@testable import TailscodeCore

/// The doctor against `scripts/mock-comfyui.py` over a real socket: the same HTTP the clients
/// speak, in each state the mock can be put in. Skipped where there is no python3 with Pillow.
@Suite("Media doctor against the mock", .enabled(if: MockComfy.available))
struct MediaMockTests {
    private func examine(_ environment: [String: String], wait: TimeInterval = 0) async throws -> MediaVerdict {
        try await MockComfy.run(environment) { endpoint in
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            let report = await MediaDoctor(transport: .live).examine(endpoint)
            return MediaVerdict(endpoint: endpoint, report: report)
        }
    }

    @Test("The mock as it starts is a machine with everything, and the doctor says ready")
    func everything() async throws {
        let found = try await examine([:])
        #expect(found.report.ready, "\(found.report.checks.map { "\($0.id)=\($0.state)" })")
        #expect(found.check("media.comfy")?.facts["version"] == "0.41.2")
        #expect(found.check("media.gpu")?.facts["totalMB"] == "98304")
        #expect(found.check("media.video.models")?.facts["models"] == "/opt/ComfyUI/models")
        #expect(found.readyEngines == [.quality, .turbo, .fast])
    }

    @Test("Without the video files the video lane names them and the pictures still work")
    func noVideo() async throws {
        let found = try await examine(["MOCK_NO_VIDEO": "1"])
        #expect(found.check("media.video.models")?.facts["missing"] == "videoModel,videoEncoder,videoVAE,audioVAE,videoUpscaler")
        #expect(found.video?.sentence.hasPrefix("Missing for video, 71.1 GB in all") == true)
        #expect(found.report.ready)
        #expect(found.readyEngines.count == 3)
    }

    @Test("Hidden files, a small card, an old version and missing nodes each show up")
    func shortfalls() async throws {
        let found = try await examine([
            "MOCK_MISSING": "qwen3vl_4b_bf16.safetensors", "MOCK_VRAM_GB": "24",
            "MOCK_VERSION": "0.36.0", "MOCK_NODES_MISSING": "QwenImage21Cache,ReferenceMultiLatent",
        ])
        #expect(found.check("media.gpu")?.state == .unavailable)
        #expect(found.check("media.image.nodes")?.facts["missing"] == "QwenImage21Cache", "Klein is not installed, so its nodes are not asked after")
        #expect(found.check("media.image.nodes")?.facts["version"] == "0.36.0")
        #expect(found.image(.quality) != nil && found.image(.fast) != nil)
        #expect(found.check("media.image.model.kleinEncoder")?.state == .todo)
    }

    @Test("A ComfyUI that predates /models is read through its loaders")
    func legacy() async throws {
        let found = try await examine(["MOCK_LEGACY": "1", "MOCK_MISSING": "flux2-vae.safetensors"])
        #expect(found.check("media.video.models")?.state == .ok)
        #expect(found.check("media.image.model.kleinVAE")?.state == .todo)
    }

    @Test("A file listed inside a subfolder is misplaced")
    func subfolder() async throws {
        let found = try await examine(["MOCK_SUBFOLDER": "ltx-2.5-video-vae-bf16.safetensors"])
        #expect(found.check("media.video.model.videoVAE")?.facts["misplaced"] == "1")
    }

    @Test("A server that answers as something else is not ComfyUI")
    func notComfy() async throws {
        #expect(try await examine(["MOCK_NOT_COMFY": "1"]).comfy == .notComfy)
    }

    @Test("A proxy that accepts while the process loads is starting, then ready")
    func slowStart() async throws {
        try await MockComfy.run(["MOCK_START_DELAY": "3"]) { endpoint in
            let early = MediaVerdict(
                endpoint: endpoint, report: await MediaDoctor(transport: .live).examine(endpoint))
            #expect(early.comfy == .starting)
            #expect(early.recheck == 5)
            try await Task.sleep(nanoseconds: 3_200_000_000)
            let late = MediaVerdict(
                endpoint: endpoint, report: await MediaDoctor(transport: .live).examine(endpoint))
            #expect(late.isAnswering)
        }
    }

    @Test("Nothing listening on the port is a refusal, with the one command that starts it")
    func nothingThere() async {
        let report = await MediaDoctor(transport: .live).examine(ForgeEndpoint(host: "127.0.0.1", port: 1))
        let found = MediaVerdict(endpoint: ForgeEndpoint(host: "127.0.0.1", port: 1), report: report)
        #expect(found.comfy == .refused || found.comfy == .loopbackOnly)
        #expect(found.check("media.comfy")?.fix?.command == ForgeSetup.startCommand)
    }
}

enum MockComfy {
    static let script: String = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("scripts/mock-comfyui.py").path
    }()

    static let available: Bool = {
        guard FileManager.default.fileExists(atPath: script) else { return false }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        check.arguments = ["python3", "-c", "import PIL"]
        check.standardError = FileHandle.nullDevice
        check.standardOutput = FileHandle.nullDevice
        guard (try? check.run()) != nil else { return false }
        check.waitUntilExit()
        return check.terminationStatus == 0
    }()

    @discardableResult
    static func run<T: Sendable>(
        _ environment: [String: String], _ body: @Sendable (ForgeEndpoint) async throws -> T
    ) async throws -> T {
        let port = Int.random(in: 30_000...60_000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script]
        var env = ProcessInfo.processInfo.environment
        env["MOCK_PORT"] = "\(port)"
        env["MOCK_DOCTOR_ONLY"] = "1"
        env["MOCK_OUTPUT"] = NSTemporaryDirectory() + "mock-comfy-\(port)"
        for (key, value) in environment { env[key] = value }
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            process.terminate()
            kill(process.processIdentifier, SIGKILL)
        }
        let endpoint = ForgeEndpoint(host: "127.0.0.1", port: port)
        for _ in 0..<50 {
            if await endpoint.reach(timeout: .seconds(1)) == .listening { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return try await body(endpoint)
    }
}

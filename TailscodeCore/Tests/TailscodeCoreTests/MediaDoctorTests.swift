import CodingAgentKit
import CodingAgentKitApple
import Foundation
import Testing

@testable import TailscodeCore

/// A ComfyUI that says what it is told to, answering the way the real one does: `/system_stats`
/// with a device, `/models/<folder>` with the files in it, `/object_info` with a key per node
/// class, and `/v1/models` on the ports a language-model server lives on.
final class FakeComfy: @unchecked Sendable {
    var reach: PortReachability.Verdict = .listening
    var loopback = false
    var stats: Result<MediaAnswer, MediaTransportError>?
    var folders: [String: [String]]? = FakeComfy.everything
    var combo = false
    var listable = true
    var classes: Set<String>? = FakeComfy.everyClass
    var helper: [String] = []
    var vramGB = 96.0
    var device = "cuda"
    var version = "0.41.2"
    var argv = ["/srv/ComfyUI/main.py", "--listen"]
    private let lock = NSLock()
    private var log: [String] = []

    static let everything: [String: [String]] = {
        var folders: [String: [String]] = [:]
        for file in MediaRequirements.allFiles { folders[file.folder, default: []].append(file.name) }
        return folders
    }()

    static let everyClass: Set<String> = Set(
        (MediaRequirements.video.nodes + MediaRequirements.imageNodes).map(\.classType))

    private func record(_ path: String) {
        lock.withLock { log.append(path) }
    }

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    static func json(_ object: Any) -> MediaAnswer {
        MediaAnswer(status: 200, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    func dropping(_ names: [String]) -> Self {
        for (folder, list) in folders ?? [:] { folders?[folder] = list.filter { !names.contains($0) } }
        return self
    }

    func without(_ roles: MediaRole...) -> Self {
        dropping(roles.map { MediaRequirements.file($0).name })
    }

    private var statsAnswer: MediaAnswer {
        let total = vramGB * 1_073_741_824
        return Self.json([
            "system": ["comfyui_version": version, "argv": argv],
            "devices": [
                [
                    "name": "Test card", "type": device, "vram_total": total,
                    "vram_free": total - 1_073_741_824,
                ]
            ],
        ])
    }

    private func objectInfo() -> [String: Any] {
        var info: [String: Any] = [:]
        for name in classes ?? [] { info[name] = ["input": ["required": [String: Any]()]] }
        for (node, field, folder) in [
            ("UNETLoader", "unet_name", "diffusion_models"), ("CLIPLoader", "clip_name", "text_encoders"),
            ("VAELoader", "vae_name", "vae"), ("LatentUpscaleModelLoader", "model_name", "latent_upscale_models"),
        ] where info[node] != nil {
            let names = folders?[folder] ?? []
            let spec: [Any] = combo ? ["COMBO", ["options": names]] : [names]
            info[node] = ["input": ["required": [field: spec]]]
        }
        return info
    }

    func transport() -> MediaTransport {
        MediaTransport(
            get: { [self] url, _ in
                record(url.path)
                if url.path == "/v1/models" {
                    guard !helper.isEmpty, url.port == 8081 else { throw MediaTransportError.refused }
                    return Self.json(["data": helper.map { ["id": $0] }])
                }
                switch url.path {
                case "/system_stats":
                    guard let stats else { return statsAnswer }
                    return try stats.get()
                case "/object_info":
                    guard classes != nil else { return MediaAnswer(status: 500, body: Data()) }
                    return Self.json(objectInfo())
                default:
                    if !listable { return MediaAnswer(status: 404, body: Data()) }
                    if url.path.hasPrefix("/object_info/") {
                        let node = String(url.path.dropFirst("/object_info/".count))
                        return Self.json(objectInfo().filter { $0.key == node })
                    }
                    if url.path.hasPrefix("/models/") {
                        let folder = String(url.path.dropFirst("/models/".count))
                        guard !combo, let list = folders?[folder] else {
                            return MediaAnswer(status: 404, body: Data())
                        }
                        return Self.json(list)
                    }
                    return MediaAnswer(status: 404, body: Data())
                }
            },
            reach: { [self] _ in reach },
            reachLoopback: { [self] _ in loopback })
    }
}

@Suite("Media doctor")
struct MediaDoctorTests {
    private let arch = ForgeEndpoint(host: "arch")

    private func examine(
        _ fake: FakeComfy, thisMachine: Bool = false, helper: ImageGenHelper? = nil
    ) async -> MediaVerdict {
        let report = await MediaDoctor(
            transport: fake.transport(), thisMachine: thisMachine, helper: helper
        ).examine(arch)
        return MediaVerdict(endpoint: arch, report: report)
    }

    @Test("A machine with everything is ready and says so on every row")
    func everythingThere() async {
        let found = await examine(FakeComfy())
        #expect(found.report.capability == "media")
        #expect(found.report.ready && found.report.available)
        #expect(found.report.checks.map(\.id) == [
            "media.comfy", "media.gpu", "media.video.nodes", "media.video.models",
            "media.image.nodes", "media.image.models", "media.enhancer",
        ])
        #expect(found.report.checks.allSatisfy { $0.state == .ok })
        #expect(found.check("media.comfy")?.facts["version"] == "0.41.2")
        #expect(found.video == nil)
        #expect(ImageGenEngine.allCases.allSatisfy { found.image($0) == nil })
        #expect(found.readyEngines == [.quality, .turbo, .fast])
        #expect(found.check("media.image.models")?.facts["engines"] == "quality,turbo,fast")
    }

    @Test("The models folder is read off how ComfyUI was started, and the fix goes there")
    func modelsFolder() async {
        let fake = FakeComfy().without(.videoModel)
        let found = await examine(fake)
        #expect(found.check("media.video.models")?.facts["models"] == "/srv/ComfyUI/models")
        #expect(found.check("media.video.model.videoModel")?.fix?.command?.hasSuffix("--local-dir /srv/ComfyUI/models") == true)
        fake.argv = ["main.py"]
        let relative = await examine(fake)
        #expect(relative.check("media.video.models")?.facts["models"] == MediaCommands.defaultModels)
        fake.argv = ["/x/main.py", "--base-directory", "/data/comfy"]
        let based = await examine(fake)
        #expect(based.check("media.video.models")?.facts["models"] == "/data/comfy/models")
    }

    @Test("A missing video model is named by its role and size, with the one command that fetches it")
    func missingVideoModel() async {
        let found = await examine(FakeComfy().without(.videoModel))
        let models = found.check("media.video.models")
        #expect(models?.state == .todo)
        #expect(models?.facts["missing"] == "videoModel")
        #expect(models?.facts["bytes"] == "42018190584")
        let row = found.check("media.video.model.videoModel")
        #expect(row?.state == .todo)
        #expect(row?.fix?.id == "media.fetch.videoModel")
        #expect(row?.fix?.kind == .command)
        #expect(
            row?.fix?.command
                == "hf download Lightricks/LTX-2.5 --revision 49b093a39c19169a8a81721dcc541e07e945232f diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors --local-dir /srv/ComfyUI/models"
        )
        #expect(row?.fix?.bytes == 42_018_190_584)
        #expect(row?.facts["gated"] == "1")
        #expect(
            found.video?.sentence
                == "The video model is missing: 42 GB, ltx-2.5-22b-distilled-transformer-bf16.safetensors")
        #expect(found.report.ready, "pictures still work, so something can render")
        #expect(found.image(.quality) == nil)
    }

    @Test("Several missing video files are one sentence with a total, and one command per repository")
    func missingManyVideoFiles() async {
        let found = await examine(FakeComfy().without(.videoModel, .videoEncoder, .audioVAE))
        let models = found.check("media.video.models")
        #expect(models?.facts["missing"] == "videoModel,videoEncoder,audioVAE")
        #expect(
            found.video?.sentence
                == "Missing for video, 68.6 GB in all: The video model (42 GB); The video text encoder (26.3 GB) and 1 more"
        )
        let all = models?.fix?.command ?? ""
        #expect(all.hasPrefix("hf download Lightricks/LTX-2.5 --revision "))
        #expect(all.components(separatedBy: " ").filter { $0.hasSuffix(".safetensors") }.count == 3)
        #expect(all.contains(" && ") == false, "one repository is one command")
        #expect(models?.fix?.id == "media.fetch.video")
    }

    @Test("A file inside a subfolder is not where the graph looks, and is said to be misplaced without a fix")
    func misplaced() async {
        let fake = FakeComfy()
        let listed = fake.folders?["diffusion_models"] ?? []
        fake.folders?["diffusion_models"] = listed.map {
            $0 == MediaRequirements.videoModel.name ? "ltx/" + $0 : $0
        }
        let found = await examine(fake)
        let row = found.check("media.video.model.videoModel")
        #expect(row?.facts["misplaced"] == "1")
        #expect(row?.fix == nil)
        #expect(found.check("media.video.models")?.facts["misplaced"] == "videoModel")
        #expect(
            MediaReading.line(for: row!, in: found).detail
                == "ltx-2.5-22b-distilled-transformer-bf16.safetensors is in a subfolder; ComfyUI needs it directly in diffusion_models")
    }

    @Test("A ComfyUI too old for the nodes says which and what version has them, and offers the update")
    func missingNodes() async {
        let fake = FakeComfy()
        fake.version = "0.36.0"
        fake.classes = FakeComfy.everyClass.subtracting(["QwenImage21Cache", "TextEncodeQwenImage21"])
        let found = await examine(fake)
        let nodes = found.check("media.image.nodes")
        #expect(nodes?.state == .todo)
        #expect(nodes?.facts["missing"] == "QwenImage21Cache,TextEncodeQwenImage21")
        #expect(nodes?.facts["needVersion"] == "0.37.0")
        #expect(nodes?.fix?.command == MediaCommands.update(into: "/srv/ComfyUI"))
        #expect(found.image(.quality)?.sentence == "ComfyUI 0.36.0 lacks QwenImage21Cache, TextEncodeQwenImage21; 0.37.0 or newer has what this needs")
        #expect(found.image(.fast) == nil, "Klein does not use them")
        #expect(found.check("media.video.nodes")?.state == .ok)
    }

    @Test("Klein's nodes need 0.41, and an old ComfyUI is told so")
    func kleinNodes() async {
        let fake = FakeComfy()
        fake.classes = FakeComfy.everyClass.subtracting(["ReferenceMultiLatent"])
        let found = await examine(fake)
        #expect(found.image(.fast) != nil)
        #expect(found.image(.quality) == nil)
        #expect(found.check("media.image.nodes")?.facts["needVersion"] == "0.41.0")
        #expect(found.check("media.image.nodes")?.facts["engines"] == "fast")
    }

    @Test("A small card is unavailable for video with the need stated, and no card at all makes the capability unavailable")
    func gpu() async {
        let fake = FakeComfy()
        fake.vramGB = 24
        let small = await examine(fake)
        let card = small.check("media.gpu")
        #expect(card?.state == .unavailable)
        #expect(card?.facts["totalMB"] == "24576")
        #expect(card?.facts["needMB"] == "73728")
        #expect(MediaReading.line(for: card!, in: small).detail.hasPrefix("The video model needs about 72 GB of video memory; this card, Test card, has 24 GB"))
        #expect(small.report.available)
        #expect(small.report.ready, "a card below the measured peak is advice, and does not stop a render being tried")
        fake.device = "cpu"
        let none = await examine(fake)
        #expect(!none.report.available && !none.report.ready)
        #expect(none.video?.checkID == "media.gpu")
    }

    @Test("Nothing installed lists every file and is not ready")
    func nothingInstalled() async {
        let fake = FakeComfy()
        fake.folders = ["diffusion_models": [], "text_encoders": [], "vae": [], "latent_upscale_models": []]
        let found = await examine(fake)
        #expect(!found.report.ready)
        #expect(found.check("media.image.models")?.state == .todo)
        #expect(found.check("media.image.models")?.fix?.id == "media.fetch.image")
        #expect(found.check("media.image.models")?.fix?.command?.contains("Comfy-Org/Qwen-Image-2.1") == true)
        #expect(found.check("media.image.models")?.facts["optional"] == nil)
        #expect(found.check("media.video.models")?.facts["bytes"] == "71114917404")
        let rows = found.report.checks.filter { $0.id.hasPrefix("media.video.model.") || $0.id.hasPrefix("media.image.model.") }
        #expect(rows.count == 5 + 7)
        #expect(rows.allSatisfy { $0.fix != nil })
        #expect(found.readyEngines.isEmpty)
    }

    @Test("A picture engine that is only partly there stays out, and the rest are optional rows")
    func partialEngine() async {
        let found = await examine(FakeComfy().without(.kleinEncoder, .qwenTurboModel))
        #expect(found.check("media.image.models")?.state == .ok)
        #expect(found.check("media.image.models")?.facts["engines"] == "quality")
        #expect(found.check("media.image.models")?.facts["optional"] == nil)
        #expect(found.check("media.image.model.kleinEncoder")?.facts["optional"] == "1")
        #expect(found.readyEngines == [.quality])
        #expect(found.image(.turbo)?.sentence == "The Qwen Turbo picture model is missing: 14.2 GB, qwen_image_2.1_turbo_bf16.safetensors")
        let health = found.health()
        #expect(health.reachable)
        #expect(Set(health.missingModels) == [ImageGenModelFile.turboDiffusion.path, ImageGenModelFile.kleinText.path])
    }

    @Test("The fallback reads the loaders' own choices when /models is not there, in both shapes")
    func fallback() async {
        let fake = FakeComfy().without(.qwenVAE)
        fake.combo = true
        let found = await examine(fake)
        #expect(found.check("media.video.models")?.state == .ok)
        #expect(found.check("media.image.model.qwenVAE")?.state == .todo)
    }

    @Test("A machine that cannot be listed is blocked, not missing everything")
    func unlistable() async {
        let fake = FakeComfy()
        fake.listable = false
        let found = await examine(fake)
        #expect(found.check("media.video.models")?.state == .blocked)
        #expect(found.check("media.video.models")?.facts["bytes"] == "71114917404")
        #expect(found.video == nil)
        #expect(!found.report.ready)
        fake.listable = true
        fake.classes = nil
        let nodes = await examine(fake)
        #expect(nodes.check("media.video.nodes")?.facts["phase"] == "unreadable")
    }

    @Test("Each way ComfyUI can be out of reach is its own phase with its own words")
    func unreachable() async {
        let fake = FakeComfy()
        fake.reach = .refused
        let refused = await examine(fake)
        #expect(refused.comfy == .refused)
        #expect(refused.check("media.comfy")?.fix?.command == ForgeSetup.startCommand)
        #expect(refused.check("media.comfy")?.fix?.id == "media.start")
        #expect(refused.check("media.gpu")?.state == .blocked)
        #expect(refused.check("media.video.models")?.state == .blocked)
        #expect(!refused.report.ready)
        #expect(
            MediaReading.line(for: refused.check("media.comfy")!, in: refused).detail
                == "Nothing is listening on 8188 on arch. If ComfyUI is running there, start it listening on its Tailscale address so other machines can reach it.")

        fake.loopback = true
        let notLocal = await examine(fake)
        #expect(notLocal.comfy == .refused, "a remote machine's loopback says nothing")
        let local = await examine(fake, thisMachine: true)
        #expect(local.comfy == .loopbackOnly)
        #expect(
            MediaReading.line(for: local.check("media.comfy")!, in: local).detail
                == "ComfyUI is running on arch but only accepts connections from that machine: start it again listening on its Tailscale address")

        fake.reach = .timedOut
        let silent = await examine(fake)
        #expect(silent.comfy == .timedOut)
        #expect(silent.check("media.comfy")?.fix == nil)
        fake.reach = .nameNotResolved
        #expect(await examine(fake).comfy == .unresolved)

        let other = FakeComfy()
        other.stats = .success(MediaAnswer(status: 200, body: Data("<html>".utf8)))
        let page = await examine(other)
        #expect(page.comfy == .notComfy)
        #expect(
            MediaReading.line(for: page.check("media.comfy")!, in: page).detail
                == "Something answers on arch:8188 but it is not ComfyUI")
    }

    @Test("A socket that accepts while ComfyUI loads is starting, never failed, and asked again in seconds")
    func starting() async {
        let fake = FakeComfy()
        fake.stats = .success(MediaAnswer(status: 503, body: Data()))
        let busy = await examine(fake)
        #expect(busy.comfy == .starting)
        #expect(busy.check("media.comfy")?.state == .working)
        #expect(busy.recheck == 5)
        #expect(busy.video == nil, "unknown is not a reason to refuse a render")
        #expect(
            MediaReading.line(for: busy.check("media.comfy")!, in: busy).detail
                == "ComfyUI is starting on arch; it will be ready in a minute")
        fake.stats = .failure(.timedOut)
        #expect(await examine(fake).comfy == .starting)
        fake.stats = .failure(.refused)
        #expect(await examine(fake).comfy == .refused)
    }

    @Test("The prompt helper never blocks: absent is ok with a fact, present names the model")
    func enhancer() async {
        let none = await examine(FakeComfy())
        #expect(none.check("media.enhancer")?.state == .ok)
        #expect(none.check("media.enhancer")?.facts["absent"] == "1")
        #expect(MediaReading.line(for: none.check("media.enhancer")!, in: none).detail.hasPrefix("None found"))
        let fake = FakeComfy()
        fake.helper = ["qwen3-27b"]
        let found = await examine(fake)
        #expect(found.check("media.enhancer")?.facts["model"] == "qwen3-27b")
        #expect(found.check("media.enhancer")?.facts["address"] == "arch:8081")
        let down = FakeComfy()
        down.reach = .refused
        down.helper = ["x"]
        #expect(await examine(down).check("media.enhancer")?.state == .ok)
    }

    @Test("One look is one set of requests, however many ask, and the cache holds for a short while")
    func readiness() async {
        let fake = FakeComfy()
        let clock = Clock(Date(timeIntervalSince1970: 1000))
        let hub = MediaReadiness(
            doctor: { _ in MediaDoctor(transport: fake.transport()) }, now: { clock.now })
        async let video = hub.verdict(for: arch)
        async let image = hub.verdict(for: arch)
        let (one, two) = await (video, image)
        #expect(one == two, "the two surfaces share one answer")
        let first = fake.requests.filter { $0 == "/system_stats" }.count
        #expect(first == 1)
        _ = await hub.verdict(for: arch)
        #expect(fake.requests.filter { $0 == "/system_stats" }.count == 1)
        clock.now = clock.now.addingTimeInterval(MediaReadiness.lifetime + 1)
        _ = await hub.verdict(for: arch)
        #expect(fake.requests.filter { $0 == "/system_stats" }.count == 2)
        _ = await hub.verdict(for: arch, force: true)
        #expect(fake.requests.filter { $0 == "/system_stats" }.count == 3)
        await hub.forget(arch)
        #expect(await hub.cached(for: arch) == nil)
        fake.stats = .success(MediaAnswer(status: 503, body: Data()))
        _ = await hub.verdict(for: arch, force: true)
        clock.now = clock.now.addingTimeInterval(MediaReadiness.startingLifetime + 1)
        #expect(await hub.cached(for: arch) == nil, "a ComfyUI that is starting is not held for long")
    }

    @Test("The picture side's health is the same report in its own shape")
    func imageHealth() async {
        let found = await examine(FakeComfy().without(.kleinModel))
        let health = found.health(running: 2)
        #expect(health.reachable && health.version == "0.41.2" && health.running == 2)
        #expect(health.missingModels == [ImageGenModelFile.kleinDiffusion.path])
        let sighting = ImageGenSighting(endpoint: ImageGenEndpoint(host: "arch"), health: health)
        #expect(sighting.available(.quality) && !sighting.available(.fast))
        let down = FakeComfy()
        down.reach = .timedOut
        let silent = await examine(down).health()
        #expect(!silent.reachable && silent.missingModels.isEmpty)
        let unlisted = FakeComfy()
        unlisted.listable = false
        #expect(Set(await examine(unlisted).health().missingModels) == Set(ImageGenModelFile.all.map(\.path)))
    }

    @Test("The video board says why in the doctor's words, and the render button opens the setup instead")
    func board() async {
        var board = ForgeBoard(endpoint: arch)
        board.point(at: arch)
        board.describe("a cat on a roof")
        #expect(board.begin() == .render(board.recipe))
        board.assessed(await examine(FakeComfy().without(.videoModel)))
        #expect(board.blocker?.checkID == "media.video.models")
        #expect(board.begin() == .checklist)
        #expect(board.renderCall == "See what is missing")
        let renderer = board.sections.first { $0.id == ForgeBoard.rendererID }?.rows.first
        #expect(renderer?.detail == "The video model is missing: 42 GB, ltx-2.5-22b-distilled-transformer-bf16.safetensors")
        #expect(renderer?.badge == "not ready")
        board.assessed(await examine(FakeComfy()))
        #expect(board.blocker == nil)
        #expect(board.begin() == .render(board.recipe))
        let fake = FakeComfy()
        fake.reach = .refused
        board.assessed(await examine(fake))
        #expect(board.begin() == .checklist, "a port nothing listens on cannot render, so the checklist opens")
        #expect(board.renderCall == "See what is missing")
        #expect(board.sections.first { $0.id == ForgeBoard.rendererID }?.rows.first?.badge == "down")
        fake.reach = .timedOut
        board.assessed(await examine(fake))
        #expect(board.begin() == .render(board.recipe), "a machine that is only silent may be asleep, and the render wakes it")
        board.assessed(MediaVerdict(endpoint: ForgeEndpoint(host: "elsewhere"), report: SetupReport(capability: "media", ready: true, checks: [])))
        #expect(board.readiness?.endpoint == arch, "an answer about another machine is dropped")
        board.point(at: ForgeEndpoint(host: "elsewhere"))
        #expect(board.readiness == nil)
    }

    @Test("The setup surface shows what the machine can make, and files a ComfyUI that lacks files")
    func setup() async {
        var setup = ForgeSetup(current: arch, known: [])
        setup.assessed(await examine(FakeComfy().without(.audioVAE)))
        #expect(setup.status.stage == .listening)
        #expect(setup.status.tone == .attention)
        #expect(setup.commit?.endpoint == arch)
        let fake = FakeComfy()
        fake.reach = .refused
        setup.assessed(await examine(fake))
        #expect(setup.status.stage == .failed)
        #expect(setup.status.diagnosis?.fix == .copyCommand(ForgeSetup.startCommand))
        #expect(setup.status.title == "Nothing is listening on 8188 on arch")
        #expect(setup.secondary != nil)
        fake.loopback = true
        setup.assessed(await examine(fake, thisMachine: true))
        #expect(setup.status.title == "ComfyUI is running on arch but only accepts connections from that machine")
        #expect(setup.status.diagnosis?.fix == .copyCommand(ForgeSetup.startCommand))
        fake.stats = .success(MediaAnswer(status: 503, body: Data()))
        fake.reach = .listening
        setup.assessed(await examine(fake))
        #expect(setup.status.stage == .listening)
        #expect(setup.status.title == "arch is starting")
        setup.type("studio")
        #expect(setup.media == nil)
    }

    @Test("The first guess is the server's own host, a server's filed renderer wins, and a demo suggests nothing")
    func endpointPlan() throws {
        let server = ConnectionProfile(
            id: "p1", name: "Studio", backend: .claudeCode, baseURL: try #require(URL(string: "http://studio.tail1.ts.net:4098")))
        let demo = ConnectionProfile(
            id: DemoWorld.profilePrefix + "x", name: "Demo", backend: .claudeCode, baseURL: try #require(URL(string: "http://demo:1")))
        let derived = MediaEndpointPlan.choose(profiles: [demo, server], filed: { _ in nil })
        #expect(derived?.endpoint == ForgeEndpoint(host: "studio.tail1.ts.net"))
        #expect(derived?.origin == .derived)
        #expect(derived?.renderer.name == nil, "the server's name is not the renderer's")
        let kept = MediaEndpointPlan.choose(profiles: [server], filed: { _ in ForgeEndpoint(host: "gpu", port: 9000) })
        #expect(kept?.endpoint == ForgeEndpoint(host: "gpu", port: 9000))
        #expect(kept?.origin == .perProfile)
        #expect(MediaEndpointPlan.choose(profiles: [demo], filed: { _ in nil }) == nil)
        let second = ConnectionProfile(
            id: "p2", name: "Laptop", backend: .claudeCode, baseURL: try #require(URL(string: "http://laptop:4098")))
        #expect(MediaEndpointPlan.choose(profiles: [server, second], preferring: "p2", filed: { _ in nil })?.profileName == "Laptop")
    }
}

final class Clock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) { self.now = now }
}

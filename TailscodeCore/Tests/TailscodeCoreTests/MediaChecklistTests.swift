import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Media checklist")
struct MediaChecklistTests {
    private let arch = ForgeEndpoint(host: "arch")
    private let english = Locale(identifier: "en_US")

    private func report(_ fake: FakeComfy, thisMachine: Bool = false) async -> SetupReport {
        await MediaDoctor(transport: fake.transport(), thisMachine: thisMachine).examine(arch)
    }

    private func checklist(_ fake: FakeComfy, focus: SetupFocus? = nil) async -> SetupChecklist {
        let found = await report(fake)
        let snapshot = SetupSnapshot(target: .media(arch), phase: .loaded, report: found)
        return SetupChecklist(snapshot: snapshot, locale: english, focus: focus)
    }

    private func bare() -> FakeComfy { FakeComfy().dropping(MediaRequirements.allFiles.map(\.name)) }

    @Test("Video first: the video files are rows in order, pictures fold into one optional row, the button copies the next file")
    func videoFocus() async throws {
        let list = await checklist(bare(), focus: .video)
        #expect(list.status == .needs(5))
        #expect(list.headline == "Video needs 5 things")
        #expect(
            list.rows.map(\.id) == [
                "media.comfy", "media.gpu", "media.video.nodes", "media.video.model.videoModel",
                "media.video.model.videoEncoder", "media.video.model.videoVAE", "media.video.model.audioVAE",
                "media.video.model.videoUpscaler", "media.image.models",
            ])
        let first = try #require(list.rows.first { $0.id == "media.video.model.videoModel" })
        #expect(list.primary == .copy(command: first.fix!.command!, label: "Copy command"))
        #expect(first.fix?.command?.hasPrefix("hf download Lightricks/LTX-2.5 --revision") == true)
        let folded = try #require(list.rows.first { $0.id == "media.image.models" })
        #expect(folded.optional && !folded.isBlocking)
        #expect(folded.line?.hasPrefix("Optional · ") == true)
    }

    @Test("Pictures first: the nearest engine's files lead and are required, the other engines wait as optional rows")
    func picturesFocus() async throws {
        let list = await checklist(bare(), focus: .pictures)
        #expect(list.status == .needs(3))
        #expect(list.headline == "Pictures need 3 things")
        let ids = list.rows.map(\.id)
        #expect(Array(ids.prefix(7)) == [
            "media.comfy", "media.gpu", "media.image.nodes", "media.image.model.qwenModel",
            "media.image.model.qwenEncoder", "media.image.model.qwenVAE", "media.image.model.qwenTurboModel",
        ])
        #expect(ids.last == "media.video.models")
        let required = list.rows.filter(\.isBlocking).map(\.id)
        #expect(required == ["media.image.model.qwenModel", "media.image.model.qwenEncoder", "media.image.model.qwenVAE"])
        guard case .copy(let command, _) = try #require(list.primary) else {
            Issue.record("the button copies a command")
            return
        }
        #expect(command.contains("qwen_image_2.1_int8_convrot.safetensors"))
    }

    @Test("The research licence is said once, on the first Qwen row, and the gate once per gated repository")
    func licensing() async throws {
        let list = await checklist(bare(), focus: .pictures)
        let qwen = list.rows.filter { $0.line?.contains("For personal and research use only") == true }
        #expect(qwen.map(\.id) == ["media.image.model.qwenModel"])
        let klein = list.rows.filter { $0.fix?.reason?.contains("gated on Hugging Face") == true }
        #expect(klein.map(\.id).filter { $0.contains("klein") } == ["media.image.model.kleinModel"])
        let reason = try #require(klein.first { $0.id == "media.image.model.kleinModel" }?.fix?.reason)
        #expect(reason.contains("FLUX Klein"))
        #expect(reason.contains("huggingface.co/black-forest-labs/flux-3-image-klein-comfy"))
        #expect(reason.contains("hf auth login"))
        let video = await checklist(bare(), focus: .video)
        let gated = video.rows.filter { $0.fix?.reason?.contains("gated on Hugging Face") == true }
        #expect(gated.map(\.id).filter { $0.hasPrefix("media.video.model.") } == ["media.video.model.videoModel"])
        #expect(gated.first?.fix?.reason?.contains("LTX-2.5") == true)
        let second = try #require(video.rows.first { $0.id == "media.video.model.videoEncoder" })
        #expect(second.fix?.reason == "An interrupted download resumes when the command is run again.")
        let ungated = try #require(list.rows.first { $0.id == "media.image.model.qwenEncoder" })
        #expect(ungated.fix?.reason == "An interrupted download resumes when the command is run again.")
    }

    @Test("A ready lane says so in its own words and offers the next place to go")
    func readyWords() async {
        let video = await checklist(FakeComfy(), focus: .video)
        #expect(video.status == .ready && video.headline == "Video is ready")
        #expect(video.primary == .finish(label: "Render"))
        let pictures = await checklist(FakeComfy(), focus: .pictures)
        #expect(pictures.headline == "Pictures are ready")
        #expect(pictures.primary == .finish(label: "Open the studio"))
        let either = await checklist(FakeComfy())
        #expect(either.headline == "Images and video are ready")
        #expect(either.primary == .finish(label: "Done"))
    }

    @Test("An optional lane never holds readiness: video ready with no pictures is ready, and pictures ask for themselves")
    func optionalLane() async {
        let noPictures = FakeComfy().dropping(MediaRequirements.imageFiles.map(\.name))
        let fromVideo = await checklist(noPictures, focus: .video)
        #expect(fromVideo.status == .ready)
        let unfocused = await checklist(noPictures)
        #expect(unfocused.status == .ready && unfocused.headline == "Video is ready")
        let fromPictures = await checklist(noPictures, focus: .pictures)
        #expect(fromPictures.status == .needs(3))
        let noVideo = FakeComfy().dropping(MediaRequirements.video.files.map(\.name))
        #expect(await checklist(noVideo).headline == "Pictures are ready")
        #expect(await checklist(noVideo, focus: .video).status == .needs(5))
    }

    @Test("An engine already there is enough: the other engines are optional rows that never block")
    func installedEngine() async throws {
        let onlyKlein = FakeComfy().without(.qwenModel, .qwenTurboModel, .qwenEncoder, .qwenVAE)
        let list = await checklist(onlyKlein, focus: .pictures)
        #expect(list.status == .ready)
        let extra = list.rows.filter { $0.id.hasPrefix("media.image.model.") }
        #expect(!extra.isEmpty && extra.allSatisfy { $0.optional && !$0.isBlocking })
        #expect(extra.allSatisfy { $0.line?.hasPrefix("Optional · ") == true })
    }

    @Test("ComfyUI out of reach is one row, the safe start command, and a headline that says so")
    func comfyDown() async throws {
        let fake = FakeComfy()
        fake.reach = .refused
        let list = await checklist(fake, focus: .video)
        #expect(list.rows.map(\.id) == ["media.comfy"])
        #expect(list.headline == "ComfyUI is not answering")
        #expect(list.primary == .copy(command: ForgeSetup.startCommand, label: "Copy command"))
        let reason = try #require(list.rows.first?.fix?.reason)
        #expect(reason.contains("Tailscale address"))
        let starting = FakeComfy()
        starting.stats = .success(MediaAnswer(status: 503, body: Data()))
        let waking = await checklist(starting)
        #expect(waking.status == .working && waking.headline == "ComfyUI is starting")
        #expect(waking.primary == nil)
    }

    @Test("A machine with no graphics card can never do it and says so once")
    func noCard() async {
        let fake = FakeComfy()
        fake.device = "cpu"
        let list = await checklist(fake)
        #expect(list.status == .unavailable)
        #expect(list.headline == "Not possible on this machine: ComfyUI found no graphics card to paint with")
    }

    @Test("A small card is a note on the video lane, not a block")
    func smallCard() async throws {
        let fake = FakeComfy()
        fake.vramGB = 24
        let video = await checklist(fake, focus: .video)
        let card = try #require(video.rows.first { $0.id == "media.gpu" })
        #expect(card.state == .unavailable && !card.isBlocking)
        #expect(video.status == .ready)
        let pictures = await checklist(fake, focus: .pictures)
        #expect(pictures.rows.contains { $0.id == "media.gpu" } == false)
    }

    @Test("The checklist names the machine it checks and offers to change it")
    func place() async {
        let list = await checklist(FakeComfy())
        #expect(list.place == SetupPlace(line: "ComfyUI at arch:8188", changeLabel: "Change"))
        #expect(list.target.forgeEndpoint == arch)
    }

    @Test("The start command binds loopback and the tailnet address only, and starts nothing without one")
    func startCommand() throws {
        #expect(!ForgeSetup.startCommand.contains("0.0.0.0"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("start-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func stub(_ name: String, _ body: String) throws {
            let url = directory.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try stub("python", "echo \"python $*\"")
        let head = ["/usr/bin/head", "/bin/head"].first { FileManager.default.isExecutableFile(atPath: $0) }
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("head").path, withDestinationPath: head ?? "/usr/bin/head")
        func run() throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", ForgeSetup.startCommand]
            process.environment = ["PATH": directory.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try stub("tailscale", "echo 100.101.102.103")
        #expect(try run() == "python main.py --listen 127.0.0.1,100.101.102.103 --port 8188")
        try stub("tailscale", "echo 100.101.102.103; echo fd7a::1")
        #expect(try run() == "python main.py --listen 127.0.0.1,100.101.102.103 --port 8188")
        try stub("tailscale", "exit 1")
        #expect(try run() == "Tailscale gave no address, so ComfyUI was not started")
        try stub("tailscale", "true")
        #expect(try run() == "Tailscale gave no address, so ComfyUI was not started")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("tailscale"))
        #expect(try run().hasSuffix("Tailscale gave no address, so ComfyUI was not started"))
        #expect(try !run().contains("python main.py"))
    }

    @Test("Targets for a server: the renderer filed for it, else its own host on ComfyUI's port, never for a demo")
    func targets() {
        let url = URL(string: "http://arch.tailnet.ts.net:4096")!
        let derived = SetupTargets.targets(forProfileURL: url, profileID: "p1", filed: { _ in nil })
        let media = derived.first { $0.capability == SetupCapability.media }
        #expect(media?.forgeEndpoint == ForgeEndpoint(host: "arch.tailnet.ts.net"))
        let chosen = ForgeEndpoint(host: "studio", port: 9000)
        let filed = SetupTargets.targets(forProfileURL: url, profileID: "p1", filed: { _ in chosen })
        #expect(filed.first { $0.capability == SetupCapability.media }?.forgeEndpoint == chosen)
        #expect(SetupTargets.targets(forProfileURL: url, profileID: nil, filed: { _ in chosen }).first { $0.capability == SetupCapability.media }?.forgeEndpoint == ForgeEndpoint(host: "arch.tailnet.ts.net"))
        let demo = URL(string: "http://\(DelegateDemo.hosts.sorted().first ?? "demo.invalid"):4096")!
        #expect(SetupTargets.targets(forProfileURL: demo).contains { $0.capability == SetupCapability.media } == false)
    }

    @Test("The source answers from the doctor, reuses a fresh look, and calls an unused silent machine absent")
    func source() async {
        let fake = FakeComfy()
        let held = MediaReadiness(doctor: { _ in MediaDoctor(transport: fake.transport()) })
        let target = SetupTarget.media(arch)
        let source = MediaSetupSource(readiness: held, used: { _ in false })
        guard case .report(let report) = await source.report(for: target) else {
            Issue.record("an answering ComfyUI is a report")
            return
        }
        #expect(report.capability == "media" && report.ready)
        let looked = fake.requests.filter { $0 == "/system_stats" }.count
        _ = await source.report(for: target)
        #expect(fake.requests.filter { $0 == "/system_stats" }.count == looked, "a look younger than the freshness is reused")

        let silent = FakeComfy()
        silent.reach = .refused
        let quiet = MediaReadiness(doctor: { _ in MediaDoctor(transport: silent.transport()) })
        guard case .absent = await MediaSetupSource(readiness: quiet, used: { _ in false }).report(for: target) else {
            Issue.record("a machine that never answered and was never used is absent")
            return
        }
        await quiet.forget()
        guard case .report = await MediaSetupSource(readiness: quiet, used: { _ in true }).report(for: target) else {
            Issue.record("a renderer the person has used is shown as it is")
            return
        }
        let asleep = FakeComfy()
        asleep.reach = .timedOut
        let off = MediaReadiness(doctor: { _ in MediaDoctor(transport: asleep.transport()) })
        guard case .unreachable = await MediaSetupSource(readiness: off, used: { _ in false }).report(for: target) else {
            Issue.record("a machine that does not answer at all is not drawn")
            return
        }
    }

    @Test("The server screen's row says Ready, or Needs setup, or offers the quiet invitation")
    func capabilityRow() async throws {
        let target = SetupTarget.media(arch)
        let ready = await report(FakeComfy())
        let row = try #require(SetupCapabilityRow.row(for: SetupSnapshot(target: target, phase: .loaded, report: ready), locale: english))
        #expect(row.title == "Images and video" && row.chip == "Ready" && row.line == "Images and video are ready")
        #expect(!row.quiet)
        let missing = await report(bare())
        let needs = try #require(SetupCapabilityRow.row(for: SetupSnapshot(target: target, phase: .loaded, report: missing), locale: english))
        #expect(needs.chip == "Needs setup")
        let absent = try #require(SetupCapabilityRow.row(for: SetupSnapshot(target: target, phase: .absent, report: missing), locale: english))
        #expect(absent.quiet && absent.title == "Add image and video generation")
        #expect(absent.opens == .checklist(target))
        #expect(SetupTargets.listed.contains(SetupCapability.media))
    }
}

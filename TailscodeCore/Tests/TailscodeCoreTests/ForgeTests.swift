import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// The renderer is on another machine and a render costs minutes, so everything that can be wrong
/// about one has to be wrong here instead: a graph the server would refuse, a frame this app
/// misreads as silence, a bar driven off the sampler's step counter, a seed that does not come
/// back. These pin the shapes verified against the live ComfyUI on 2026-08-22.
@Suite("Video forge")
struct ForgeTests {
    private let recipe = ForgeRecipe(
        prompt: "a cat asleep on a warm roof", negative: "blurry", width: 1280, height: 704,
        seconds: 5, fps: 24, seed: 7)

    @Test("The shared forge check passes")
    func sharedCheck() {
        let issues = ForgeBoardCheck.run()
        #expect(issues.isEmpty, "ForgeBoardCheck: \(issues)")
    }

    @Test("The graph is the twenty-eight nodes the box actually ran")
    func graphShape() {
        let graph = ForgeGraph(recipe: recipe)
        #expect(graph.nodes.count == 28)
        #expect(Set(graph.keys).count == 28)
        #expect(graph.payload.count == 28)
        #expect(
            Set(graph.keys) == [
                "unet", "clip", "vae_v", "vae_a", "upscaler", "pos", "neg", "cond", "lat_v",
                "lat_a", "av1", "noise1", "sampler", "sig1", "guider1", "pass1", "split1", "up",
                "av2", "noise2", "sig2", "guider2", "pass2", "split2", "pixels", "audio", "video",
                "save",
            ])
        #expect(graph.problems.isEmpty)
    }

    @Test("A clip is seconds times frames per second plus the keyframe, never one frame short")
    func lengthInvariant() {
        for seconds in ForgeRecipe.secondsRange {
            for fps in ForgeRecipe.fpsOptions {
                let made = ForgeRecipe(prompt: "x", seconds: seconds, fps: fps)
                #expect(made.length == seconds * fps + 1)
                let graph = ForgeGraph(recipe: made)
                #expect(graph.node("lat_v")?.inputs["length"] == .whole(made.length))
                #expect(graph.node("lat_a")?.inputs["frames_number"] == .whole(made.length))
                #expect(graph.problems.isEmpty)
            }
        }
    }

    @Test("The expensive pass runs on a quarter of the pixels")
    func halfSizeFirstPass() {
        for size in ForgeSize.options {
            let made = ForgeRecipe(prompt: "x", width: size.width, height: size.height)
            let graph = ForgeGraph(recipe: made)
            #expect(graph.node("lat_v")?.inputs["width"] == .whole(size.width / 2))
            #expect(graph.node("lat_v")?.inputs["height"] == .whole(size.height / 2))
            #expect(made.width % ForgeRecipe.block == 0)
            #expect(made.height % ForgeRecipe.block == 0)
        }
    }

    @Test("Every link names a node that exists and an output that node actually has")
    func linksResolve() throws {
        let graph = ForgeGraph(recipe: recipe)
        for node in graph.nodes {
            for link in node.links {
                let target = try #require(
                    graph.node(link.key), "\(node.key).\(link.field) points at \(link.key)")
                let outputs = try #require(ForgeClass.outputs[target.classType])
                #expect(link.slot >= 0 && link.slot < outputs)
            }
        }
        #expect(graph.node("cond")?.inputs["negative"] == .link("neg", 0))
        #expect(graph.node("guider1")?.inputs["negative"] == .link("cond", 1))
        #expect(graph.node("av2")?.inputs["audio_latent"] == .link("split1", 1))
        #expect(graph.node("audio")?.inputs["samples"] == .link("split2", 1))
    }

    @Test("A graph whose links have been cut says which ones rather than letting the server say it")
    func danglingLinksAreNamed() {
        let good = ForgeNode(key: "a", classType: "UNETLoader", inputs: ["unet_name": .text("m")])
        let bad = ForgeNode(
            key: "b", classType: "CLIPTextEncode",
            inputs: ["text": .text("x"), "clip": .link("nowhere", 0)])
        let slot = ForgeNode(
            key: "c", classType: "CLIPTextEncode",
            inputs: ["text": .text("x"), "clip": .link("a", 4)])
        let graph = ForgeGraph(recipe: recipe, nodes: [good, bad, slot])
        #expect(graph.problems.contains { $0.contains("nowhere") }, "a link to a node nobody built")
        #expect(graph.problems.contains { $0.contains("c") && $0.contains("4") }, "a slot the node does not have")
        #expect(!graph.problems.isEmpty)
        #expect(ForgeGraph(recipe: recipe).problems.isEmpty)
    }

    @Test("The graph is postable exactly as it stands")
    func payloadIsWireReady() throws {
        let graph = ForgeGraph(recipe: recipe)
        #expect(JSONSerialization.isValidJSONObject(graph.payload))
        let data = try JSONSerialization.data(withJSONObject: graph.payload)
        let read = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let save = try #require(read["save"] as? [String: Any])
        #expect(save["class_type"] as? String == "SaveVideo")
        let inputs = try #require(save["inputs"] as? [String: Any])
        #expect(inputs["filename_prefix"] as? String == ForgeGraph.prefix)
        #expect(inputs["video"] as? [Any] != nil)
        let unet = try #require(read["unet"] as? [String: Any])
        let unetInputs = try #require(unet["inputs"] as? [String: Any])
        #expect(unetInputs["unet_name"] as? String == ForgeModel.fileName)
    }

    @Test("The one model is driven exactly as the box measured it")
    func theOneDrive() {
        let graph = ForgeGraph(recipe: recipe)
        #expect(graph.node("unet")?.inputs["unet_name"] == .text(ForgeModel.fileName))
        #expect(graph.node("sig1")?.classType == "ManualSigmas")
        #expect(graph.node("sig1")?.inputs["sigmas"] == .text(ForgeModel.stageOneSigmas))
        #expect(graph.node("sig2")?.inputs["sigmas"] == .text(ForgeModel.stageTwoSigmas))
        #expect(graph.node("guider1")?.inputs["video_cfg"] == .decimal(1.0))
        #expect(graph.node("guider2")?.inputs["audio_cfg"] == .decimal(1.0))
        #expect(graph.node("sampler")?.inputs["sampler_name"] == .text("euler_ancestral"))
        #expect(graph.node("neg")?.inputs["text"] == .text("blurry"))
        #expect(!ForgeField.allCases.contains { $0.label == Localized.text("Model") })
        let stale = Data(#"{"prompt":"a cat","width":1280,"height":704,"seconds":5,"fps":24,"seed":7,"model":"dev"}"#.utf8)
        let read = try? JSONDecoder().decode(ForgeRecipe.self, from: stale)
        #expect(read?.prompt == "a cat", "a recipe that named the model there used to be still reads")
    }

    @Test("Every frame the socket sends reads as the event it is")
    func everyFrameParses() {
        let frames: [(String, ForgeEvent)] = [
            (
                #"{"type":"status","data":{"status":{"exec_info":{"queue_remaining":0}},"sid":"x"}}"#,
                .status(queued: 0)
            ),
            (
                #"{"type":"execution_start","data":{"prompt_id":"pid","timestamp":1787393464769}}"#,
                .started("pid")
            ),
            (
                #"{"type":"execution_cached","data":{"nodes":[],"prompt_id":"pid","timestamp":1}}"#,
                .cached("pid", nodes: [])
            ),
            (
                #"{"type":"executing","data":{"node":"pass1","display_node":"pass1","prompt_id":"pid"}}"#,
                .executing("pid", node: "pass1")
            ),
            (
                #"{"type":"executed","data":{"node":"save","display_node":"save","output":null,"prompt_id":"pid"}}"#,
                .executed("pid", node: "save")
            ),
            (
                #"{"type":"progress","data":{"value":1,"max":8,"prompt_id":"pid","node":"pass1"}}"#,
                .sampling("pid", node: "pass1", step: 1, steps: 8)
            ),
            (
                #"{"type":"execution_success","data":{"prompt_id":"pid","timestamp":2}}"#,
                .succeeded("pid")
            ),
            (#"{"type":"executing","data":{"node":null,"prompt_id":"pid"}}"#, .finished("pid")),
            (#"{"type":"execution_interrupted","data":{"prompt_id":"pid"}}"#, .interrupted("pid")),
            (#"{"type":"b_preview","data":{}}"#, .ignored),
        ]
        for (text, expected) in frames {
            #expect(ForgeEvent.read(text) == expected, "\(text)")
        }
    }

    @Test("A finished render announces itself with an executing frame that names no node")
    func nullNodeIsTheTerminalSentinel() {
        let done = ForgeEvent.read(#"{"type":"executing","data":{"node":null,"prompt_id":"pid"}}"#)
        #expect(done == .finished("pid"))
        #expect(done.isTerminal)
        #expect(done.promptID == "pid")
        let ordinary = ForgeEvent.read(
            #"{"type":"executing","data":{"node":"pixels","prompt_id":"pid"}}"#)
        #expect(!ordinary.isTerminal)
    }

    @Test("The bar is finished nodes over all nodes, not the sampler's own counter")
    func fractionComesFromTheCensus() {
        let frame = #"""
            {"type":"progress_state","data":{"prompt_id":"pid","nodes":{
            "a":{"state":"finished","display_node_id":"a"},
            "b":{"state":"finished","display_node_id":"b"},
            "c":{"state":"finished","display_node_id":"c"},
            "d":{"state":"running","display_node_id":"d"}}}}
            """#
        guard case .progressed(let id, let census) = ForgeEvent.read(frame) else {
            Issue.record("a progress_state frame is a census")
            return
        }
        #expect(id == "pid")
        #expect(census.finished == 3)
        #expect(census.total == 4)
        #expect(census.fraction == 0.75)
        #expect(census.running == "d")

        var job = ForgeJob(recipe: recipe)
        job.submitting()
        job.accepted(promptID: "pid")
        job.saw(.sampling("pid", node: "pass1", step: 8, steps: 8))
        #expect(job.fraction == 0, "the sampler reaching its own maximum is not the render finishing")
        job.saw(.progressed("pid", census: census))
        #expect(job.fraction == 0.75)
        job.saw(.sampling("pid", node: "pass2", step: 1, steps: 4))
        #expect(job.fraction == 0.75, "the second pass restarting the counter does not empty the bar")
    }

    @Test("A job walks from a draft to a file, and every stop on the way has its own words")
    func jobWalk() {
        var job = ForgeJob(recipe: recipe)
        #expect(job.phase == .drafting)
        #expect(job.title == "a cat asleep on a warm roof")
        job.submitting()
        #expect(job.phase == .submitting)
        #expect(job.subtitle == Localized.text("Waking the renderer…"))
        job.accepted(promptID: "pid", queued: 1)
        #expect(job.phase == .queued(1))
        job.saw(.started("pid"))
        #expect(job.phase == .running(0))
        #expect(job.subtitle == Localized.text("Rendering · %@%%", "0"))
        job.saw(.progressed("pid", census: ForgeCensus(finished: 14, total: 28, running: "pass2")))
        #expect(job.percent == 50)
        #expect(job.stageName == Localized.text("Second pass"))
        job.saw(.finished("pid"))
        #expect(job.isCollecting)
        let asset = ForgeAsset(filename: "forge_00007.mp4", subfolder: "video")
        job.delivered(asset)
        #expect(job.phase == .done(asset))
        #expect(job.isFinished)
        #expect(job.detail == recipe.summary)
    }

    @Test("A render that stops for any reason stops in a way the reader can act on")
    func terminalPhases() {
        var failed = ForgeJob(recipe: recipe)
        failed.submitting()
        failed.accepted(promptID: "pid")
        failed.saw(
            .failed("pid", reason: Localized.text("%@ failed: %@", "UNETLoader", "no such file")))
        #expect(failed.phase == .failed(Localized.text("%@ failed: %@", "UNETLoader", "no such file")))
        #expect(failed.subtitle.contains("no such file"))
        #expect(!failed.isBusy)

        var stopped = ForgeJob(recipe: recipe)
        stopped.submitting()
        stopped.accepted(promptID: "pid")
        stopped.cancelled()
        #expect(stopped.phase == .cancelled)
        #expect(stopped.subtitle == Localized.text("Stopped"))

        var revised = ForgeJob(recipe: recipe)
        revised.submitting()
        revised.revise(recipe.with(prompt: "something else"))
        #expect(revised.phase == .drafting, "editing what is being rendered starts a new draft")
    }

    @Test("Frames belonging to somebody else's render are not this render")
    func otherJobsAreIgnored() {
        var job = ForgeJob(recipe: recipe)
        job.submitting()
        job.accepted(promptID: "mine")
        job.saw(.progressed("theirs", census: ForgeCensus(finished: 27, total: 28, running: "save")))
        #expect(job.phase == .queued(0), "somebody else's progress does not start this render")
        #expect(job.census == nil)
        job.saw(.failed("theirs", reason: "their problem"))
        #expect(job.isBusy, "and somebody else's failure does not stop it")
    }

    @Test("Every way a render can fail says something a person could act on")
    func failureSentences() {
        #expect(
            ForgeFailure.unreachable("arch").description == Localized.text("%@ did not answer", "arch"))
        #expect(ForgeFailure.rejected("arch", "width must be divisible by 32").description
            == "width must be divisible by 32")
        #expect(ForgeFailure.refused("arch", "no").description == "no")
        #expect(
            ForgeFailure.disconnected("arch").description
                == Localized.text("Lost contact with %@ while it was rendering", "arch"))
        #expect(
            ForgeFailure.noOutput("arch").description
                == Localized.text("%@ finished but saved no video", "arch"))
        #expect(ForgeFailure.renderFailed("arch", "out of memory").description == "out of memory")
        #expect(!ForgeFailure.unconfigured.description.isEmpty)
        for failure: ForgeFailure in [
            .unreachable("arch"), .rejected("arch", "x"), .refused("arch", "x"),
            .disconnected("arch"), .noOutput("arch"), .renderFailed("arch", "x"),
        ] {
            #expect(failure.host == "arch")
        }
        struct Stranger: Error {}
        #expect(
            ForgeClient.reason(Stranger(), host: "arch")
                == ForgeFailure.unreachable("arch").description)
        #expect(
            ForgeClient.reason(ForgeFailure.noOutput("arch"), host: "arch")
                == ForgeFailure.noOutput("arch").description)
    }

    @Test("What the server refuses to run is read back as the field somebody can change")
    func rejectionReadsAsAdvice() {
        let body: [String: Any] = [
            "node_errors": [
                "lat_v": [
                    "errors": [["message": "width must be a multiple of 32", "details": ""]]
                ]
            ]
        ]
        #expect(ForgeFetch.complaint(in: body) == Localized.text("%@: %@", "lat_v", "width must be a multiple of 32"))
        #expect(ForgeFetch.complaint(in: ["error": ["type": "prompt_outputs_failed_validation"]])
            == "prompt_outputs_failed_validation")
        #expect(ForgeFetch.complaint(in: ["prompt_id": "pid", "node_errors": [String: Any]()]) == nil)
    }

    @Test("The file the server wrote is found wherever it files it")
    func assetIsReadOutOfHistory() throws {
        let outputs: [String: Any] = [
            "save": [
                "images": [
                    ["filename": "forge_00001.mp4", "subfolder": "video", "type": "output"]
                ],
                "animated": [true],
            ]
        ]
        let asset = try #require(ForgeAsset.read(outputs: outputs))
        #expect(asset.filename == "forge_00001.mp4")
        #expect(asset.subfolder == "video")
        #expect(asset.type == "output")
        #expect(asset.isVideo)
        #expect(ForgeAsset.read(outputs: ["save": ["images": [Any]()]]) == nil)
        let endpoint = ForgeEndpoint(host: "arch")
        #expect(
            asset.url(on: endpoint)?.absoluteString
                == "http://arch:8188/view?filename=forge_00001.mp4&subfolder=video&type=output")
    }

    @Test("An address is read the same way the agent connection reads one")
    func endpointReading() {
        #expect(ForgeEndpoint.read("arch") == .endpoint(ForgeEndpoint(host: "arch")))
        #expect(ForgeEndpoint.read("100.64.0.3") == .endpoint(ForgeEndpoint(host: "100.64.0.3")))
        #expect(ForgeEndpoint.read("http://arch:9000") == .endpoint(ForgeEndpoint(host: "arch", port: 9000)))
        #expect(ForgeEndpoint.read("arch:8188/") == .endpoint(ForgeEndpoint(host: "arch")))
        #expect(ForgeEndpoint.read("0.0.0.0:8188") == .bindAll)
        #expect(ForgeEndpoint.read("   ") == .empty)
        #expect(ForgeEndpoint.read("ftp://arch") == .unsupportedScheme("ftp"))
        #expect(ForgeEndpoint.complaint(.invalid) != nil)
        #expect(ForgeEndpoint.complaint(.unsupportedScheme("ftp")) != nil)
        #expect(ForgeEndpoint.complaint(.empty) == nil)
        let endpoint = ForgeEndpoint(host: "arch")
        #expect(endpoint.url("/prompt")?.absoluteString == "http://arch:8188/prompt")
        #expect(
            endpoint.socketURL(clientID: "cid")?.absoluteString == "ws://arch:8188/ws?clientId=cid")
        #expect(!ForgeEndpoint.sentence(for: .refused, host: "arch").isEmpty)
        #expect(
            ForgeEndpoint.sentence(for: .nameNotResolved, host: "arch")
                != ForgeEndpoint.sentence(for: .timedOut, host: "arch"))
    }

    @Test("The board's sections are the same four everywhere, in the same order")
    func boardSections() {
        var board = ForgeBoard(endpoint: ForgeEndpoint(host: "arch"))
        board.describe("a cat")
        board.filled(history: [
            ForgeEntry(id: "j", recipe: recipe, asset: ForgeAsset(filename: "a.mp4"))
        ])
        #expect(
            board.sections.map(\.id) == [
                ForgeBoard.rendererID, ForgeBoard.renderID, ForgeBoard.settingsID,
                ForgeBoard.historyID,
            ])
        #expect(board.rows.allSatisfy { $0.id.hasPrefix($0.sectionID) })
        #expect(Set(board.rows.map(\.id)).count == board.rows.count)
    }

    @Test("Every setting the board offers can be walked and lands on something renderable")
    func settingsWalk() {
        var board = ForgeBoard(endpoint: ForgeEndpoint(host: "arch"))
        board.describe("a cat")
        for field in ForgeField.allCases where field.isCyclable {
            guard let index = board.rows.firstIndex(where: { $0.kind == .field(field) }) else {
                Issue.record("\(field) is a row")
                continue
            }
            board.focus(index)
            #expect(board.activate() == .choose(field))
            let options = board.choices(of: field)
            #expect(!options.isEmpty, "\(field) has a menu")
            for choice in options {
                board.pick(field, id: choice.id)
                #expect(ForgeGraph(recipe: board.recipe).problems.isEmpty)
            }
        }
        #expect(board.value(of: .seconds) == Localized.text("%@s", "\(board.recipe.seconds)"))
        #expect(board.value(of: .fps) == Localized.text("%@ fps", "\(board.recipe.fps)"))
    }

    @Test("A clip that opens on a picture carries the verified image-to-video nodes on both passes")
    func firstFrameGraph() {
        let kept = ForgeGraph(recipe: recipe.with(frame: .kept("hill.png [output]")))
        #expect(kept.problems.isEmpty)
        #expect(kept.startsFromFrame)
        #expect(kept.nodes.count == 32)
        #expect(kept.node("still")?.inputs["image"] == .text("hill.png [output]"))
        #expect(kept.node("prep")?.inputs["img_compression"] == .whole(ForgeGraph.frameCompression))
        #expect(kept.node("start1")?.inputs["latent"] == .link("lat_v", 0))
        #expect(kept.node("start1")?.inputs["strength"] == .decimal(ForgeGraph.firstPassHold))
        #expect(kept.node("start2")?.inputs["latent"] == .link("up", 0))
        #expect(kept.node("start2")?.inputs["strength"] == .decimal(ForgeGraph.secondPassHold))
        #expect(kept.node("av1")?.inputs["video_latent"] == .link("start1", 0))
        #expect(kept.node("av2")?.inputs["video_latent"] == .link("start2", 0))
        #expect(kept.node("pos")?.inputs["text"] == .text(ForgeRecipe.openingLine + " " + recipe.prompt))
        #expect(JSONSerialization.isValidJSONObject(kept.payload))

        let plain = ForgeGraph(recipe: recipe)
        #expect(!plain.startsFromFrame)
        #expect(plain.node("av1")?.inputs["video_latent"] == .link("lat_v", 0))
        #expect(plain.node("pos")?.inputs["text"] == .text(recipe.prompt))
    }

    @Test("A file on this device is named by the upload, and a graph without one refuses to post")
    func uploadedFrame() {
        let unplaced = ForgeGraph(recipe: recipe.with(frame: .file("/tmp/hill.png")))
        #expect(!unplaced.startsFromFrame)
        #expect(unplaced.problems.contains(Localized.text("the start picture was never put on the machine")))
        let placed = ForgeGraph(recipe: recipe.with(frame: .file("/tmp/hill.png")), uploadedFrame: "hill.png")
        #expect(placed.problems.isEmpty)
        #expect(placed.node("still")?.inputs["image"] == .text("hill.png"))
        #expect(ForgeFrame.file("/tmp/hill.png").needsUpload)
        #expect(!ForgeFrame.kept("hill.png [output]").needsUpload)
        #expect(ForgeFrame.file("/tmp/hill.png").label == "hill.png")
        #expect(ForgeFrame.kept("video/hill.png [output]").label == "hill.png")
    }

    @Test("A clip continues another by opening it on the machine and taking its last frame")
    func continuedGraph() {
        let clip = ForgeAsset(filename: "forge_00014_.mp4", subfolder: "video", type: "output")
        let graph = ForgeGraph(recipe: recipe.with(frame: .clipEnd(clip)))
        #expect(graph.problems.isEmpty)
        #expect(graph.nodes.count == 34)
        #expect(graph.node("reel")?.inputs["file"] == .text("video/forge_00014_.mp4 [output]"))
        #expect(graph.node("frames")?.inputs["video"] == .link("reel", 0))
        #expect(graph.node("last")?.inputs["batch_index"] == .whole(ForgeGraph.lastFrameIndex))
        #expect(graph.node("last")?.inputs["length"] == .whole(1))
        #expect(graph.node("prep")?.inputs["image"] == .link("last", 0))
        #expect(ForgeFrame.clipEnd(clip).isClipEnd)
        #expect(ForgeFrame.clipEnd(clip).label == "forge_00014_.mp4")
    }

    @Test("The save node's file is the clip, not the clip a continuation opened")
    func savedFileWins() {
        let outputs: [String: Any] = [
            "reel": ["images": [["filename": "forge_00014_.mp4", "subfolder": "video", "type": "input"]], "animated": [true]],
            "save": ["images": [["filename": "forge_00015_.mp4", "subfolder": "video", "type": "output"]], "animated": [true]],
        ]
        #expect(ForgeAsset.read(outputs: outputs) == ForgeAsset(filename: "forge_00015_.mp4", subfolder: "video", type: "output"))
        let unnamed: [String: Any] = [
            "9": ["images": [["filename": "x.mp4", "subfolder": "video", "type": "input"]]],
            "7": ["images": [["filename": "y.mp4", "subfolder": "video", "type": "output"]]],
        ]
        #expect(ForgeAsset.read(outputs: unnamed)?.filename == "y.mp4")
        #expect(ForgeAsset(filename: "a.mp4", subfolder: "video", type: "output").annotatedName == "video/a.mp4 [output]")
        #expect(ForgeAsset(filename: "a.mp4").annotatedName == "a.mp4 [output]")
    }

    @Test("The sound is the closing sentence of the prompt, and a recipe without one still reads")
    func soundAndDecoding() throws {
        let heard = recipe.with(sound: "wind in the grass")
        #expect(heard.renderedPrompt == recipe.prompt + " wind in the grass")
        #expect(ForgeGraph(recipe: heard).node("pos")?.inputs["text"] == .text(heard.renderedPrompt))
        #expect(heard.summary == recipe.summary)
        #expect(heard.with(frame: .kept("a.png [output]")).summary.hasSuffix(Localized.text("from %@", "a.png")))
        let old = Data(#"{"prompt":"a cat","negative":"","width":1280,"height":704,"seconds":5,"fps":24,"seed":7,"model":"distilled"}"#.utf8)
        let decoded = try JSONDecoder().decode(ForgeRecipe.self, from: old)
        #expect(decoded.sound.isEmpty)
        #expect(decoded.frame == nil)
        #expect(decoded.prompt == "a cat")
        let round = try JSONDecoder().decode(ForgeRecipe.self, from: JSONEncoder().encode(heard.with(frame: .clipEnd(ForgeAsset(filename: "c.mp4")))))
        #expect(round == heard.with(frame: .clipEnd(ForgeAsset(filename: "c.mp4"))))
    }

    @Test("The bar is finished over the whole graph, because the server's census names only nodes it has touched")
    func censusAgainstGraph() {
        var job = ForgeJob(recipe: recipe)
        job.submitting()
        job.accepted(promptID: "p", nodes: 28)
        job.saw(.started("p"))
        job.saw(.progressed("p", census: ForgeCensus(finished: 5, total: 5, running: nil)))
        #expect(job.fraction.map { abs($0 - 5.0 / 28.0) < 0.001 } == true)
        #expect(!job.isCollecting)
        job.saw(.progressed("p", census: ForgeCensus(finished: 27, total: 28, running: "save")))
        #expect(job.fraction.map { abs($0 - 27.0 / 28.0) < 0.001 } == true)
        job.saw(.finished("p"))
        #expect(job.isCollecting)
    }

    @Test("A sketch rides the job while it runs and is let go when it ends")
    func sketches() {
        let frame = ImageGenPreviewFrame(encoding: .jpeg, bytes: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        var job = ForgeJob(recipe: recipe)
        job.saw(.sketched(frame))
        #expect(job.sketch == nil)
        job.submitting()
        job.accepted(promptID: "p")
        job.saw(.started("p"))
        job.saw(.sketched(frame))
        #expect(job.sketch == frame)
        #expect(ForgeEvent.sketched(frame).promptID == nil)
        #expect(!ForgeEvent.sketched(frame).isTerminal)
        job.saw(.sampling("p", node: "pass2", step: 2, steps: 3))
        job.saw(.progressed("p", census: ForgeCensus(finished: 20, total: 28, running: "pass2")))
        #expect(ForgeWords.sketchCaption(job) == Localized.text("Sketch · %@ · step %@ of %@", Localized.text("Second pass"), "2", "3"))
        job.delivered(ForgeAsset(filename: "a.mp4"))
        #expect(job.sketch == nil)
        var stopped = ForgeJob(recipe: recipe)
        stopped.submitting()
        stopped.accepted(promptID: "p")
        stopped.saw(.sketched(frame))
        stopped.saw(.interrupted("p"))
        #expect(stopped.sketch == nil)
    }

    @Test("The clock learns seconds per megapixel-frame and says about, or nothing")
    func clock() {
        var clock = ForgeClock()
        #expect(clock.estimate(recipe) == nil)
        #expect(!clock.knows(recipe))
        clock.learn(recipe, seconds: 100)
        #expect(clock.knows(recipe))
        #expect(clock.estimate(recipe).map { abs($0 - 100) < 0.001 } == true)
        let shorter = recipe.with(seconds: 1)
        let ratio = Double(shorter.length) / Double(recipe.length)
        #expect(clock.estimate(shorter).map { abs($0 - 100 * ratio) < 0.01 } == true)
        clock.learn(recipe, seconds: 200)
        #expect(clock.estimate(recipe).map { abs($0 - 150) < 0.001 } == true)
        clock.learn(recipe, seconds: 0)
        #expect(clock.estimate(recipe).map { abs($0 - 150) < 0.001 } == true)
        #expect(ForgeClock.words(4) == Localized.text("%@ s", "4"))
        #expect(ForgeClock.words(0.2) == Localized.text("%@ s", "1"))
        #expect(ForgeClock.words(90) == Localized.text("%@ min %@ s", "1", "30"))
        #expect(ForgeClock.words(120) == Localized.text("%@ min", "2"))
        #expect(ForgeClock.words(700) == Localized.text("%@ min", "11"))
        let round = try? JSONDecoder().decode(ForgeClock.self, from: JSONEncoder().encode(clock))
        #expect(round == clock)
    }

    @Test("A job wears its estimate before and during the render, and never once it has outrun it")
    func estimateWords() {
        var job = ForgeJob(recipe: recipe, expected: 60)
        #expect(job.subtitle == Localized.text("Ready to render") + " · " + Localized.text("about %@", Localized.text("%@ min", "1")))
        job.submitting()
        job.accepted(promptID: "p")
        job.saw(.started("p"))
        job.saw(.progressed("p", census: ForgeCensus(finished: 7, total: 28, running: "pass1")))
        #expect(job.remaining(now: Date().addingTimeInterval(10)) == Localized.text("about %@ left", Localized.text("%@ s", "50")))
        #expect(job.subtitle.hasSuffix(Localized.text("about %@ left", Localized.text("%@ min", "1"))))
        #expect(job.remaining(now: Date().addingTimeInterval(3600)) == nil)
        let plain = ForgeJob(recipe: recipe)
        #expect(plain.subtitle == Localized.text("Ready to render"))
        #expect(plain.remaining() == nil)
        var board = ForgeBoard(endpoint: ForgeEndpoint(host: "arch"))
        board.describe("a cat")
        #expect(board.expectation == nil)
        var clock = ForgeClock()
        clock.learn(board.recipe, seconds: 45)
        board.learned(clock)
        #expect(board.expectation == Localized.text("about %@", Localized.text("%@ s", "45")))
        #expect(board.job.subtitle.hasSuffix(Localized.text("about %@", Localized.text("%@ s", "45"))))
        var done = ForgeJob(recipe: board.recipe)
        done.submitting(at: Date(timeIntervalSince1970: 0))
        done.accepted(promptID: "p", at: Date(timeIntervalSince1970: 0))
        done.delivered(ForgeAsset(filename: "a.mp4"), at: Date(timeIntervalSince1970: 30))
        #expect(done.worked == 30)
        #expect(board.learn(from: done) != nil)
        #expect(board.clock.estimate(board.recipe).map { abs($0 - 37.5) < 0.001 } == true)
    }

    @Test("The board follows a size only where nobody chose one, and a start picture sets it")
    func sizeFollowing() {
        var board = ForgeBoard(endpoint: ForgeEndpoint(host: "arch"))
        board.describe("a cat")
        #expect(!board.sizeChosen)
        board.follow(size: .portrait)
        #expect(board.recipe.size == .portrait)
        board.pick(.size, id: ForgeSize.landscape.id)
        #expect(board.sizeChosen)
        board.follow(size: .square)
        #expect(board.recipe.size == .landscape)
        board.start(from: .kept("tall.png [output]"), pictureWidth: 600, pictureHeight: 1000)
        #expect(board.recipe.size == .landscape)
        #expect(board.recipe.frame == .kept("tall.png [output]"))
        var fresh = ForgeBoard(endpoint: ForgeEndpoint(host: "arch"))
        fresh.describe("a cat")
        fresh.start(from: .kept("tall.png [output]"), pictureWidth: 600, pictureHeight: 1000)
        #expect(fresh.recipe.size == .portrait)
        fresh.start(from: .file("/tmp/wide.png"), pictureWidth: 1920, pictureHeight: 1080)
        #expect(fresh.recipe.size == .landscape)
        fresh.start(from: nil)
        #expect(fresh.recipe.frame == nil)
        #expect(ForgeSize.nearest(width: 1000, height: 1000) == .square)
        #expect(ForgeSize.nearest(width: 0, height: 0) == .landscape)
        #expect(ForgeSize.following(.wide) == .landscape)
        #expect(ForgeSize.following(.tall) == .portrait)
        #expect(ForgeSize.following(.square) == .square)
        let entry = ForgeEntry(id: "j", recipe: recipe.with(size: .portrait).with(seed: 7), asset: ForgeAsset(filename: "a.mp4", subfolder: "video"))
        board.extend(entry)
        #expect(board.recipe.frame == .clipEnd(ForgeAsset(filename: "a.mp4", subfolder: "video")))
        #expect(board.recipe.size == .portrait)
        #expect(board.recipe.seed != 7)
        #expect(board.recipe.prompt == recipe.prompt)
        #expect(!board.sizeChosen)
        let lost = ForgeEntry(id: "k", recipe: recipe, asset: nil, failure: "gone")
        var before = board
        board.extend(lost)
        #expect(board.recipe == before.recipe)
        before.hear("rain")
        #expect(before.recipe.sound == "rain")
        #expect(before.value(of: .sound) == "rain")
        #expect(board.value(of: .sound) == ForgeWords.soundUnset)
        #expect(board.rows.contains { $0.kind == .field(.sound) })
        #expect(board.rows.contains { $0.kind == .field(.frame) })
        #expect(ForgeField.sound.isTyped && !ForgeField.frame.isTyped && !ForgeField.frame.isCyclable)
        #expect(ForgeStudio.chips == [.size, .seconds, .fps, .seed])
    }

    @Test("The video brief asks for a caption and tells the helper what the words do not say")
    func videoBrief() {
        let plain = ForgeRewriteContext(recipe: recipe, sizeChosen: false)
        let ask = plain.ask("a red kite")
        #expect(ask.system == ForgeBrief.system)
        #expect(ask.instruction == nil)
        #expect(ask.user.contains("The request: a red kite"))
        #expect(ask.user.contains("runs 5 seconds at 24 frames"))
        #expect(!ask.user.contains("already chosen"))
        #expect(!ask.user.contains("opens on a picture"))
        #expect(ask.user.contains("rewritten_prompt"))
        #expect(ForgeBrief.system.contains("wh_ratio"))

        let chosen = ForgeRewriteContext(recipe: recipe.with(size: .portrait), sizeChosen: true)
        #expect(chosen.ask("x").user.contains("already chosen: 9:16"))
        #expect(ForgeBrief.ratioWord(for: .square) == "1:1")
        #expect(ForgeBrief.ratioWord(for: .landscape) == "16:9")

        let framed = ForgeRewriteContext(recipe: recipe.with(frame: .kept("a.png [output]")), sizeChosen: false)
        #expect(framed.ask("x").user.contains("opens on a picture"))
        let continued = ForgeRewriteContext(recipe: recipe.with(frame: .clipEnd(ForgeAsset(filename: "a.mp4"))), sizeChosen: false)
        #expect(continued.ask("x").user.contains("continues an earlier one"))

        let heard = ForgeRewriteContext(recipe: recipe.with(sound: "rain"), sizeChosen: false)
        #expect(heard.ask("x").user.contains("\"rain\""))
        #expect(heard.ask("x").user.contains("Do not repeat it"))
        let avoided = ForgeRewriteContext(recipe: recipe, sizeChosen: false)
        #expect(avoided.ask("x").user.contains("Keep out of the clip, and do not mention: blurry"))

        let revision = ForgeRewriteContext(recipe: recipe, sizeChosen: false, instruction: "slower", previous: "A wide shot…")
        #expect(revision.isRevision)
        #expect(revision.ask("x").instruction == "slower")
        #expect(revision.ask("x").user.contains("Instruction: slower"))
        #expect(revision.ask("x").user.contains("Previous caption: A wide shot…"))
        #expect(!ForgeRewriteContext(recipe: recipe, sizeChosen: false, instruction: " ", previous: "p").isRevision)

        let read = ImageGenBrief.readExpansion(#"{"rewritten_prompt": "A wide shot holds.", "wh_ratio": "9:16"}"#)
        #expect(read?.prompt == "A wide shot holds.")
        #expect(read?.aspect.map(ForgeSize.following) == .portrait)
    }
}

/// A probe's calls, counted from inside a concurrent scan. The sweep's probe is `@Sendable`, so a
/// local array cannot be written from it.
private final class AskedHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String] = []

    func add(_ host: String) {
        lock.lock()
        hosts.append(host)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }
}

/// Setting the renderer up is the half that decides whether video generation is a feature or a
/// rumour: an address typed blind into a one-field prompt is how it was, and every rule that makes
/// it feel like adding a server — the sweep, the check, the sentence a failure gets, the memory —
/// lives here rather than in three clients.
@Suite("Forge setup")
struct ForgeSetupTests {
    private let arch = ForgeEndpoint(host: "arch")

    private var tailnet: [TailscaleDevice] {
        [
            TailscaleDevice(
                name: "arch.tail1234.ts.net", hostname: "arch",
                addresses: ["100.64.0.3", "fd7a::3"], os: "linux"),
            TailscaleDevice(
                name: "phone.tail1234.ts.net", hostname: "phone", addresses: ["100.64.0.4"],
                os: "iOS"),
            TailscaleDevice(
                name: "mac.tail1234.ts.net", hostname: "macbook", addresses: ["100.64.0.5"],
                os: "macOS"),
        ]
    }

    @Test("The shared setup check passes")
    func sharedCheck() {
        let issues = ForgeSetupCheck.run()
        #expect(issues.isEmpty, "ForgeSetupCheck: \(issues)")
    }

    @Test("A typed address walks from nothing to a machine that answered, and files nothing early")
    func theWalk() {
        var setup = ForgeSetup(tailnet: .up(address: "100.64.0.9"))
        #expect(setup.status.stage == .blank)
        #expect(setup.commit == nil)
        setup.type("ftp://arch")
        #expect(setup.status.stage == .unreadable)
        #expect(setup.status.detail == ForgeEndpoint.complaint(.unsupportedScheme("ftp")))
        setup.type("arch:8188")
        #expect(setup.status.stage == .ready)
        #expect(setup.hint == nil, "a port somebody typed is not read back to them")
        #expect(setup.primary.action == .check(arch))
        setup.checking()
        #expect(setup.status.stage == .checking)
        #expect(!setup.primary.isEnabled)
        setup.reached(.listening)
        #expect(setup.status.stage == .listening)
        #expect(setup.commit == ForgeRenderer(endpoint: arch))
        #expect(setup.primary.action == .save(ForgeRenderer(endpoint: arch)))
        setup.type("other")
        #expect(setup.status.stage == .ready, "changing the address un-answers it")
        #expect(setup.commit == nil)
    }

    @Test("Every way the check can fail says the one thing that is wrong and the one press that fixes it")
    func everyFailureExplainsItself() {
        var setup = ForgeSetup(tailnet: .up(address: "100.64.0.9"))
        setup.type("arch")

        setup.reached(.timedOut)
        #expect(setup.status.diagnosis?.fix == .retry)
        #expect(setup.status.title == Localized.text("No answer from %@", "arch:8188"))
        #expect(setup.secondary != nil, "a sleeping renderer may still be the right machine")
        #expect(setup.secondaryNote != nil)

        setup.reached(.refused)
        #expect(setup.status.diagnosis?.fix == .copyCommand(ForgeSetup.startCommand))
        #expect(setup.status.diagnosis?.actionTitle == ForgeSetup.startCommandTitle)
        #expect(setup.status.title == Localized.text("Nothing is rendering on %@", "arch"))
        #expect(setup.secondary != nil)

        setup.reached(.nameNotResolved)
        #expect(setup.status.diagnosis?.fix == .retry)
        #expect(setup.status.title == Localized.text("Can't resolve that name"))
        #expect(setup.secondary == nil, "an address that can never work is never filed")

        var offline = ForgeSetup(tailnet: .daemonDown)
        offline.type("arch")
        offline.reached(.timedOut)
        #expect(offline.status.diagnosis == ConnectDiagnosis.offTailnet(deviceName: offline.deviceName))
        #expect(!offline.discovery.isEnabled)

        #expect(ConnectDiagnosis.forge(verdict: .listening, endpoint: arch, tailnet: nil) == nil)
    }

    @Test("The renderer's failures reuse the server flow's own sentences wherever they are the same fact")
    func sentencesAreNotForked() {
        let address = HostAddress.read("arch:8188", defaultPort: 8188)
        guard case .address(let parsed) = address else {
            Issue.record("arch:8188 is an address")
            return
        }
        let server = ConnectDiagnosis.make(
            outcome: .unreachable("x"), address: parsed, tailnetAddress: nil, alternatePort: nil,
            sentPassword: false, reachability: .timedOut)
        let forge = ConnectDiagnosis.forge(
            verdict: .timedOut, endpoint: arch, tailnet: .loggedOut)
        #expect(server == forge, "off the tailnet is one fact with one wording")

        let serverName = ConnectDiagnosis.make(
            outcome: .unreachable("x"), address: parsed, tailnetAddress: "100.64.0.9",
            alternatePort: nil, sentPassword: false, reachability: .nameNotResolved)
        let forgeName = ConnectDiagnosis.forge(
            verdict: .nameNotResolved, endpoint: arch, tailnet: .up(address: "100.64.0.9"))
        #expect(serverName == forgeName, "and so is a name that will not resolve")
    }

    @Test("The tailnet is swept for a machine answering on the forge port, not for an agent")
    func sweepFindsTheRenderer() async {
        let targets = ForgeSweep.targets(tailnet)
        #expect(targets.map(\.machine) == ["arch", "macbook"], "a phone is never asked")
        #expect(targets[0].hosts == ["arch.tail1234.ts.net", "100.64.0.3"])
        #expect(targets.allSatisfy { $0.hosts.count <= 2 }, "one address per family is enough")

        let probe: ForgeSweep.Probe = { host, port in
            guard port == ForgeSweep.port else { return .refused }
            if host.hasSuffix("ts.net") { return .nameNotResolved }
            return host == "100.64.0.3" ? .listening : .timedOut
        }
        let found = await ForgeSweep.run(targets: targets, probe: probe)
        #expect(found.count == 1)
        #expect(found[0].machine == "arch")
        #expect(found[0].host == "100.64.0.3", "the name did not resolve, so its number answered")
        #expect(found[0].endpoint == ForgeEndpoint(host: "100.64.0.3"))
        #expect(found[0].renderer.name == "arch")

        let named: ForgeSweep.Probe = { host, _ in host.hasSuffix("ts.net") ? .listening : .refused }
        let byName = await ForgeSweep.run(targets: targets, probe: named)
        #expect(byName.map(\.host) == ["arch.tail1234.ts.net", "mac.tail1234.ts.net"],
            "a resolving name is preferred, because it is what is worth remembering")

        let asked = AskedHosts()
        let counting: ForgeSweep.Probe = { host, _ in
            asked.add(host)
            return .timedOut
        }
        _ = await ForgeSweep.run(targets: [targets[0]], probe: counting)
        #expect(asked.all == ["arch.tail1234.ts.net"], "a machine that said nothing is not asked twice")

        #expect(await ForgeSweep.run(targets: [], probe: probe).isEmpty)
        #expect(ForgeSweep.targets([]).isEmpty)
    }

    @Test("The scan is a dial, and it never leaves a machine on it that did not answer")
    func theDial() {
        let targets = ForgeSweep.targets(tailnet)
        var reading = ForgeSweepReading()
        #expect(reading.stage == .rest)
        #expect(reading.actionTitle == Localized.text("Scan my tailnet"))
        reading.began(targets, at: 0)
        #expect(reading.blips.count == 2)
        #expect(reading.blips.allSatisfy { $0.tone == .pending })
        #expect(reading.isScanning)
        reading.advanced(checked: 2, total: 2)
        #expect(reading.detail == Localized.text("Asked %@ of %@.", "2", "2"))
        let found = ForgeCandidate(machine: "arch", host: "100.64.0.3", port: ForgeSweep.port)
        reading.found(found, at: 0.2)
        reading.found(found, at: 0.3)
        #expect(reading.found.count == 1, "the same machine twice is one machine")
        #expect(reading.blips.first { $0.key == "arch" }?.tone == .ready)
        reading.finished()
        #expect(reading.blips.map(\.key) == ["arch"])
        #expect(reading.title == Localized.text("%@ found", "1"))
        #expect(reading.tone == .live)

        var nothing = ForgeSweepReading()
        nothing.began(targets, at: 0)
        nothing.finished()
        #expect(nothing.blips.isEmpty)
        #expect(nothing.title == Localized.text("No renderer answered"))
        #expect(nothing.tone == .attention)

        let blocked = ForgeSweepReading(blocked: .loggedOut)
        #expect(blocked.title == TailscaleReading.loggedOut.title)
        #expect(blocked.detail == TailscaleReading.loggedOut.detail)
        #expect(blocked.actionTitle == TailscaleReading.loggedOut.actionTitle)
        #expect(!blocked.isScanning)

        let stable = RadarBlip(key: "arch", tone: .ready, bornAt: 0)
        #expect(stable.angle == TailnetRadar.angle(for: "arch"), "the constellation is the tailnet's own")
    }

    @Test("A machine a scan found is adopted already checked")
    func adoptingSkipsTheSecondAsk() {
        let candidate = ForgeCandidate(
            machine: "arch", host: "100.64.0.3", port: ForgeSweep.port, os: "linux")
        var setup = ForgeSetup()
        setup.adopt(candidate)
        #expect(setup.status.stage == .listening)
        #expect(setup.commit == ForgeRenderer(endpoint: candidate.endpoint, name: "arch"))
        #expect(candidate.detail.contains(Localized.text("answering")))
        #expect(candidate.id == "100.64.0.3:8188")
    }

    @Test("The control that opens the forge says one thing everywhere and wears a mark only when there is one")
    func theEntryControl() {
        #expect(ForgeEntryPoint.title == ForgeBoard().heading, "the button and the surface share a name")
        #expect(ForgeEntryPoint.menuTitle.hasSuffix("…"))
        #expect(!ForgeEntryPoint.symbol.isEmpty && !ForgeEntryPoint.glyph.isEmpty)
        #expect(ForgeEntryPoint.glyph.count == 1, "a text client has one column to spend")
        #expect(ForgeEntryPoint.tooltip(configured: false) != ForgeEntryPoint.tooltip(configured: true))
        #expect(ForgeEntryPoint.activity(rendering: true)?.icon.motion == .working)
        #expect(ForgeEntryPoint.activity(rendering: false) == nil)
        #expect(ForgeEntryPoint.accessibilityLabel(rendering: false) == ForgeEntryPoint.title)
        #expect(ForgeEntryPoint.accessibilityLabel(rendering: true) != ForgeEntryPoint.title)
    }

    @Test("The forge opens over the work and closing it never stops the render")
    func theModal() {
        #expect(ForgeSurface.title == ForgeEntryPoint.title)
        #expect(ForgeSurface.subtitle == ForgeBoard().notice)
        #expect(!ForgeSurface.dismissTitle.isEmpty)
        #expect(ForgeSurface.dismissNote(rendering: false) == nil)
        let note = ForgeSurface.dismissNote(rendering: true)
        #expect(note != nil)
        #expect(ForgeSurface.preferredWidth > ForgeSurface.minimumWidth)
        #expect(ForgeSurface.preferredHeight > ForgeSurface.minimumHeight)
        #expect(ForgeSurface.preferredWidth > ForgeSurface.preferredHeight)
        #expect(!ForgeStudio.chips.contains(.prompt))
    }

    @Test("The renderer row is the setup, not a text field")
    func theRendererRowOpensTheSetup() {
        var board = ForgeBoard()
        #expect(board.renderCall == ForgeSetup.title)
        #expect(board.sections[0].detail == Localized.text("Find it on your tailnet, or type its address"))
        guard let index = board.rows.firstIndex(where: { $0.kind == .field(.endpoint) }) else {
            Issue.record("the renderer is a row")
            return
        }
        board.focus(index)
        #expect(board.activate() == .configure)
        #expect(ForgeField.allCases.filter(\.opensSetup) == [.endpoint])
        #expect(!ForgeField.endpoint.isCyclable)
    }
}

/// Nested under `DeviceStores` on purpose: every device-local store shares one `UserDefaults`, and
/// corelibs' is not safe to write from two threads at once, so a suite that writes one has to be
/// serialized against every other suite that does.
extension DeviceStores {
    @Suite("Forge store")
    struct ForgeStoreTests {
        private func fresh() {
            UserDefaults.standard.removeObject(forKey: ForgeStore.endpointKey)
            UserDefaults.standard.removeObject(forKey: ForgeStore.recipeKey)
            UserDefaults.standard.removeObject(forKey: ForgeStore.historyKey)
        }

        @Test("The machine that renders survives the app being gone")
        func endpointRoundTrip() {
            fresh()
            #expect(ForgeStore.endpoint() == nil)
            ForgeStore.remember(ForgeEndpoint(host: "arch", port: 9000))
            #expect(ForgeStore.endpoint() == ForgeEndpoint(host: "arch", port: 9000))
            ForgeStore.remember(nil)
            #expect(ForgeStore.endpoint() == nil)
            fresh()
        }

        @Test("The settings come back but the words do not")
        func recipeRoundTrip() {
            fresh()
            #expect(ForgeStore.recipe().prompt.isEmpty)
            let recipe = ForgeRecipe(
                prompt: "a cat", negative: "blurry", sound: "rain", frame: .kept("a.png [output]"),
                width: 704, height: 1280, seconds: 8, fps: 30, seed: 12345)
            ForgeStore.remember(recipe)
            let read = ForgeStore.recipe()
            #expect(read.prompt.isEmpty, "a new box asks for something new")
            #expect(read.sound.isEmpty, "and is not still hearing yesterday's rain")
            #expect(read.frame == nil, "nor opening on yesterday's picture")
            #expect(read.negative == "blurry")
            #expect(read.size == ForgeSize.portrait)
            #expect(read.seconds == 8)
            #expect(read.fps == 30)
            #expect(read.seed == 12345)
            #expect(read.length == 8 * 30 + 1)
            fresh()
        }

        @Test("A clip that was made is still listed, newest first, and only once")
        func historyRoundTrip() {
            fresh()
            #expect(ForgeStore.history().isEmpty)
            let recipe = ForgeRecipe(prompt: "a cat", seed: 3)
            let first = ForgeEntry(
                id: "one", recipe: recipe, asset: ForgeAsset(filename: "one.mp4", subfolder: "video"),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_000))
            let second = ForgeEntry(
                id: "two", recipe: recipe, asset: nil, failure: "out of memory",
                finishedAt: Date(timeIntervalSince1970: 1_700_000_100))
            ForgeStore.record(first)
            ForgeStore.record(second)
            #expect(ForgeStore.history().map(\.id) == ["two", "one"])
            ForgeStore.record(first)
            #expect(ForgeStore.history().map(\.id) == ["one", "two"], "a repeat is moved, not doubled")
            let read = ForgeStore.history()[0]
            #expect(read.recipe.seed == 3)
            #expect(read.asset?.filename == "one.mp4")
            #expect(read.isPlayable)
            #expect(ForgeStore.history()[1].failure == "out of memory")
            ForgeStore.remove("one")
            #expect(ForgeStore.history().map(\.id) == ["two"])
            ForgeStore.forget()
            #expect(ForgeStore.history().isEmpty)
            fresh()
        }

        @Test("Every machine this device has rendered on is offered back, most recent first")
        func renderersRoundTrip() {
            UserDefaults.standard.removeObject(forKey: ForgeStore.renderersKey)
            UserDefaults.standard.removeObject(forKey: ForgeStore.endpointKey)
            #expect(ForgeStore.renderers().isEmpty)
            ForgeStore.remember(ForgeRenderer(endpoint: ForgeEndpoint(host: "arch"), name: "arch"))
            ForgeStore.remember(ForgeRenderer(endpoint: ForgeEndpoint(host: "studio"), name: "studio"))
            #expect(ForgeStore.renderers().map(\.id) == ["studio:8188", "arch:8188"])
            #expect(ForgeStore.endpoint() == ForgeEndpoint(host: "studio"))
            ForgeStore.remember(ForgeRenderer(endpoint: ForgeEndpoint(host: "arch")))
            #expect(ForgeStore.renderers().map(\.id) == ["arch:8188", "studio:8188"], "a machine used again moves rather than doubles")
            #expect(ForgeStore.renderers()[0].name == "arch", "and a name once learned is not thrown away")
            ForgeStore.remember(ForgeEndpoint(host: "box"))
            #expect(ForgeStore.renderers().map(\.id).first == "box:8188", "an address typed blind is filed too")
            #expect(ForgeStore.renderers()[0].name == nil)
            ForgeStore.forgetRenderer("box:8188")
            #expect(ForgeStore.renderers().map(\.id) == ["arch:8188", "studio:8188"])
            #expect(ForgeStore.endpoint() == nil, "forgetting the machine in use stops sending work to it")
            UserDefaults.standard.removeObject(forKey: ForgeStore.renderersKey)
            UserDefaults.standard.removeObject(forKey: ForgeStore.endpointKey)
        }

        @Test("Only a job that actually stopped becomes history")
        func onlyFinishedJobsAreFiled() {
            fresh()
            var job = ForgeJob(recipe: ForgeRecipe(prompt: "a cat"))
            #expect(ForgeStore.record(job) == nil)
            job.submitting()
            job.accepted(promptID: "pid")
            #expect(ForgeStore.record(job) == nil, "a render in flight is not a receipt")
            job.delivered(ForgeAsset(filename: "a.mp4", subfolder: "video"))
            let entry = ForgeStore.record(job)
            #expect(entry?.id == "pid")
            #expect(ForgeStore.history().count == 1)
            fresh()
        }
    }
}

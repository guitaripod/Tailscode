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
    let recipe = ForgeRecipe(
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
}

import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

extension ForgeTests {
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

    @Test("Where a job stands is read from the machine's history and queue, not from the socket")
    func standingIsReadFromTheMachine() {
        let host = "arch"
        let done: [String: Any] = [
            "status": ["status_str": "success", "completed": true],
            "outputs": ["save": ["images": [["filename": "a.mp4", "subfolder": "video", "type": "output"]]]],
        ]
        #expect(
            ForgeStanding.ending(of: done, host: host)
                == .finished(ForgeAsset(filename: "a.mp4", subfolder: "video")))
        let broke: [String: Any] = [
            "status": [
                "status_str": "error",
                "messages": [["execution_error", ["exception_message": "out of memory"]]],
            ]
        ]
        #expect(ForgeStanding.ending(of: broke, host: host) == .failed("out of memory"))
        let stopped: [String: Any] = [
            "status": [
                "status_str": "error",
                "messages": [["execution_start", [:]], ["execution_interrupted", ["node_id": "7"]]],
            ]
        ]
        #expect(
            ForgeStanding.ending(of: stopped, host: host) == .stopped,
            "a clip somebody stopped is not a clip that broke")
        let empty: [String: Any] = ["status": ["status_str": "success"], "outputs": [:]]
        #expect(
            ForgeStanding.ending(of: empty, host: host) == .failed(ForgeFailure.noOutput(host).description))

        let queue: [String: Any] = [
            "queue_running": [[10, "running-id", [:], [:], ["save"]]],
            "queue_pending": [[13, "third", [:], [:], []], [11, "first", [:], [:], []], [12, "second", [:], [:], []]],
        ]
        #expect(ForgeStanding.place(of: "running-id", in: queue) == .running)
        #expect(
            ForgeStanding.place(of: "first", in: queue) == .waiting(ahead: 1),
            "the running job is in front of it")
        #expect(
            ForgeStanding.place(of: "third", in: queue) == .waiting(ahead: 3),
            "the pending list is a heap on the server and is put in order before anyone is counted")
        #expect(ForgeStanding.place(of: "nobody", in: queue) == .unknown)
        #expect(ForgeStanding.place(of: "x", in: [:]) == .unknown)
    }

    @Test("A render has a name before the machine has been asked, and a recovered one is not timed")
    func recoveredJobs() {
        var job = ForgeJob(recipe: recipe)
        job.submitting()
        job.announce("minted")
        #expect(job.handle == "minted", "a Stop during the post names the job it means")
        #expect(job.promptID == nil, "but nothing is filed under a name the machine has not confirmed")
        #expect(ForgeEntry(job: job) == nil)
        job.accepted(promptID: "theirs", nodes: 28)
        #expect(job.handle == "theirs", "a machine that kept its own id is believed")
        job.draft()
        #expect(job.handle == nil)

        var lost = ForgeJob(recipe: recipe)
        lost.submitting(at: Date().addingTimeInterval(-3 * 3600))
        lost.accepted(promptID: "pid", nodes: 28)
        lost.recovered()
        #expect(lost.subtitle != ForgeJob(recipe: recipe).subtitle)
        lost.delivered(ForgeAsset(filename: "a.mp4", subfolder: "video"))
        #expect(lost.worked == nil, "the hours the app was closed are not hours of rendering")
        var clock = ForgeClock()
        var board = ForgeBoard(recipe: recipe)
        board.learned(clock)
        #expect(board.learn(from: lost) == nil)
        clock = ForgeClock()
        #expect(clock.estimate(recipe) == nil)
    }

    @Test("A clip is saved under the words that made it, not the machine's counter")
    func savedClipsAreNamedByTheirWords() {
        let asset = ForgeAsset(filename: "forge_00007_.mp4", subfolder: "video")
        let named = ForgeEntry(
            id: "a", recipe: ForgeRecipe(prompt: "A cat asleep, on a warm roof!\nSecond line", seed: 7), asset: asset)
        #expect(named.fileName == "a-cat-asleep-on-a-warm-roof-second-line-7.mp4")
        let blank = ForgeEntry(id: "b", recipe: ForgeRecipe(prompt: "  ?!  ", seed: 3), asset: asset)
        #expect(blank.fileName == "clip-3.mp4")
        let long = ForgeEntry(
            id: "c", recipe: ForgeRecipe(prompt: String(repeating: "wandering ", count: 30), seed: 1),
            asset: ForgeAsset(filename: "x.WEBM"))
        #expect(long.fileName.hasSuffix("-1.webm"))
        #expect(long.fileName.count <= 48 + "-1.webm".count)
        #expect(!long.fileName.contains("--"))
        let lantern = ForgeEntry(
            id: "d", recipe: ForgeRecipe(prompt: "a paper lantern drifting down a quiet river at dusk", seed: 9), asset: asset)
        #expect(lantern.fileName == "a-paper-lantern-drifting-down-a-quiet-river-at-9.mp4", "a name stops at a whole word")
    }

    @Test("A clip can only be continued on the machine that holds it")
    func continuingNeedsTheSameMachine() {
        let arch = ForgeEndpoint(host: "arch")
        let studio = ForgeEndpoint(host: "studio")
        let asset = ForgeAsset(filename: "forge_00007_.mp4", subfolder: "video")
        let here = ForgeEntry(
            id: "a", recipe: ForgeRecipe(prompt: "a cat asleep", seed: 3), asset: asset, endpoint: arch)
        let there = ForgeEntry(
            id: "b", recipe: ForgeRecipe(prompt: "a dog awake", seed: 4), asset: asset, endpoint: studio)
        var board = ForgeBoard(endpoint: arch, history: [here, there])
        #expect(board.canContinue(here))
        #expect(!board.canContinue(there))
        board.extend(there)
        #expect(board.recipe.frame == nil, "the same name on another machine is not this clip")
        #expect(board.continuing == nil)
        board.extend(here)
        #expect(board.recipe.frame == .clipEnd(asset))
        #expect(board.continuing?.id == "a", "the stage can name the clip the next one opens on")
        #expect(board.recipe.seed != 3, "and the seed is fresh")
        board.start(from: nil)
        #expect(board.continuing == nil)
        let failed = ForgeEntry(id: "c", recipe: ForgeRecipe(prompt: "x"), asset: nil, failure: "no")
        #expect(!board.canContinue(failed))
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

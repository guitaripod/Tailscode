import Foundation

/// The forge's rules, checked headlessly rather than in one client — the graph the box actually
/// ran, every frame the socket actually sends, the job's walk from a prompt to a file, and the
/// board that draws all of it. Both desktops run this from their own `--selftest`, so a ComfyUI
/// upgrade that renames a field or a refactor that loses the length invariant fails here rather
/// than as an empty progress bar on three platforms.
public enum ForgeBoardCheck {
    public static func run() -> [String] {
        var failures = ForgeSetupCheck.run()
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        struct Stranger: Error {}

        let recipe = ForgeRecipe(
            prompt: "a cat asleep on a warm roof", negative: "blurry", width: 1280, height: 704,
            seconds: 5, fps: 24, seed: 7)
        expect(recipe.length == 121, "five seconds at twenty-four frames is a hundred and twenty-one")
        expect(recipe.length == recipe.seconds * recipe.fps + 1, "the frame count is seconds times rate plus the keyframe")
        expect(
            recipe.stageOneWidth == 640 && recipe.stageOneHeight == 352,
            "the first pass samples at half the asked-for size")
        expect(ForgeRecipe(width: 1281, height: 703).width % ForgeRecipe.block == 0, "a frame size is rounded onto the latent grid")
        expect(ForgeRecipe(width: 1281, height: 703).height % ForgeRecipe.block == 0, "in both directions")
        expect(ForgeRecipe(seconds: 900).seconds == ForgeRecipe.secondsRange.upperBound, "a length nobody can render is clamped")
        expect(ForgeRecipe(fps: 7).fps == 24, "a frame rate the model does not know falls back")
        expect(!ForgeRecipe().isRenderable, "nothing is rendered from an empty prompt")
        expect(recipe.isRenderable, "and something is rendered from a described one")

        let graph = ForgeGraph(recipe: recipe)
        expect(graph.problems.isEmpty, "the verified graph has nothing wrong with it")
        expect(graph.nodes.count == 28, "the graph is the twenty-eight nodes the box ran")
        expect(graph.node("lat_v")?.inputs["length"] == .whole(121), "the latent carries the frame count")
        expect(graph.node("lat_v")?.inputs["width"] == .whole(640), "and the halved width")
        expect(graph.node("lat_a")?.inputs["frames_number"] == .whole(121), "the audio latent is the same length")
        expect(graph.node("noise1")?.inputs["noise_seed"] == .whole(7), "the seed drives the first pass")
        expect(
            graph.node("noise2")?.inputs["noise_seed"] == .whole(ForgeGraph.refinementSeed),
            "and the refinement pass is fixed, so a seed means one picture")
        expect(
            graph.node("unet")?.inputs["unet_name"] == .text(ForgeModel.fileName),
            "the chosen model is the one loaded")
        expect(
            graph.node("sig1")?.inputs["sigmas"] == .text(ForgeModel.stageOneSigmas),
            "and it brings its own schedule")
        expect(graph.node("save")?.inputs["filename_prefix"] == .text(ForgeGraph.prefix), "everything lands in one folder")
        expect(graph.node("split1")?.classType == "LTXVSeparateAVLatent", "the passes are split back into video and audio")
        expect(graph.node("av2")?.inputs["audio_latent"] == .link("split1", 1), "and the second slot is the audio")
        for node in graph.nodes {
            for link in node.links where graph.node(link.key) == nil {
                failures.append("\(node.key) takes \(link.field) from a node that is not there")
            }
        }
        expect(JSONSerialization.isValidJSONObject(graph.payload), "the graph is postable as it stands")
        expect(graph.payload.count == graph.nodes.count, "and every node reaches the wire")

        let broken = ForgeGraph(recipe: ForgeRecipe(prompt: "x", width: 1280, height: 704))
        expect(broken.problems.isEmpty, "a plain recipe is renderable")

        expect(
            ForgeEvent.read(#"{"type":"status","data":{"status":{"exec_info":{"queue_remaining":2}},"sid":"s"}}"#)
                == .status(queued: 2), "a status frame carries the queue")
        expect(
            ForgeEvent.read(#"{"type":"execution_start","data":{"prompt_id":"p","timestamp":1}}"#)
                == .started("p"), "a start names the job")
        expect(
            ForgeEvent.read(#"{"type":"execution_cached","data":{"nodes":["unet"],"prompt_id":"p"}}"#)
                == .cached("p", nodes: ["unet"]), "a cached frame lists what it skipped")
        expect(
            ForgeEvent.read(#"{"type":"executing","data":{"node":"pass1","display_node":"pass1","prompt_id":"p"}}"#)
                == .executing("p", node: "pass1"), "an executing frame names the node")
        expect(
            ForgeEvent.read(#"{"type":"executed","data":{"node":"save","display_node":"save","output":null,"prompt_id":"p"}}"#)
                == .executed("p", node: "save"), "an executed frame does too")
        expect(
            ForgeEvent.read(#"{"type":"progress","data":{"value":3,"max":8,"prompt_id":"p","node":"pass1"}}"#)
                == .sampling("p", node: "pass1", step: 3, steps: 8),
            "a progress frame is the sampler's step and never the whole render")
        expect(
            ForgeEvent.read(#"{"type":"execution_success","data":{"prompt_id":"p","timestamp":2}}"#)
                == .succeeded("p"), "a success frame is terminal")
        expect(
            ForgeEvent.read(#"{"type":"executing","data":{"node":null,"prompt_id":"p"}}"#)
                == .finished("p"),
            "an executing frame with no node is how a finished render announces itself")
        expect(ForgeEvent.read(#"{"type":"weather","data":{}}"#) == .ignored, "a frame nobody knows is dropped, not fatal")
        expect(ForgeEvent.read("not json at all") == .ignored, "and so is anything that is not a frame")
        expect(ForgeEvent.finished("p").isTerminal, "the null-node frame ends the listening")
        expect(!ForgeEvent.executing("p", node: "pass1").isTerminal, "an ordinary one does not")
        expect(ForgeEvent.status(queued: 0).promptID == nil, "a status frame is about no job in particular")

        let stateFrame = #"""
            {"type":"progress_state","data":{"prompt_id":"p","nodes":{
            "unet":{"value":1.0,"max":1.0,"state":"finished","node_id":"unet","display_node_id":"unet"},
            "clip":{"value":1.0,"max":1.0,"state":"finished","node_id":"clip","display_node_id":"clip"},
            "pass1":{"value":0.4,"max":1.0,"state":"running","node_id":"pass1","display_node_id":"pass1"},
            "save":{"value":0.0,"max":1.0,"state":"pending","node_id":"save","display_node_id":"save"}}}}
            """#
        guard case .progressed(let statePrompt, let census) = ForgeEvent.read(stateFrame) else {
            failures.append("a progress_state frame is a census")
            return failures
        }
        expect(statePrompt == "p", "the census names its job")
        expect(census.total == 4 && census.finished == 2, "the census counts every node, finished and not")
        expect(census.fraction == 0.5, "and the honest fraction is finished over total")
        expect(census.running == "pass1", "it also says what is working")
        expect(ForgeCensus(finished: 0, total: 0, running: nil).fraction == 0, "a census of nothing is not a division by zero")

        let failure = ForgeEvent.read(
            #"{"type":"execution_error","data":{"prompt_id":"p","node_type":"UNETLoader","exception_message":"no such file"}}"#)
        expect(failure == .failed("p", reason: Localized.text("%@ failed: %@", "UNETLoader", "no such file")),
            "an error frame carries the server's own words")
        expect(
            ForgeEvent.read(#"{"type":"execution_error","data":{"prompt_id":"p"}}"#)
                == .failed("p", reason: Localized.text("The render failed and said nothing about why")),
            "and says so plainly when it carries none")

        var job = ForgeJob(recipe: recipe)
        expect(job.phase == .drafting, "a job starts as a draft")
        expect(job.subtitle == Localized.text("Ready to render"), "a described draft says it is ready")
        expect(ForgeJob().subtitle == Localized.text("Describe the video"), "an empty one asks for words")
        job.submitting()
        expect(job.subtitle == Localized.text("Waking the renderer…"), "the twelve-second wake is explained while it happens")
        job.accepted(promptID: "p", queued: 2)
        expect(job.phase == .queued(2), "an accepted job knows how many are ahead")
        expect(job.subtitle == Localized.text("%@ ahead in the queue", "2"), "and says so")
        job.saw(.status(queued: 3))
        expect(job.phase == .queued(2), "the queue frame counts this job too")
        job.saw(.started("p"))
        expect(job.fraction == 0, "a started job is running at nothing")
        job.saw(.progressed("p", census: ForgeCensus(finished: 7, total: 28, running: "pass1")))
        expect(job.fraction == 0.25, "the bar is the node census")
        expect(job.stageName == Localized.text("First pass"), "and the node is said as a phrase")
        job.saw(.sampling("p", node: "pass1", step: 3, steps: 8))
        expect(job.fraction == 0.25, "a sampler step does not move the overall bar")
        expect(job.detail.contains(Localized.text("step %@ of %@", "3", "8")), "it is said in words instead")
        job.saw(.progressed("p", census: ForgeCensus(finished: 3, total: 28, running: "pass2")))
        expect(job.fraction == 0.25, "a census that counts fewer nodes does not walk the bar backwards")
        job.saw(.failed("other", reason: "somebody else's render"))
        expect(job.isBusy, "a frame about another job is not this job")
        job.saw(.finished("p"))
        expect(job.isCollecting, "the last frame leaves the job full but not finished")
        expect(job.subtitle == Localized.text("Saving the file…"), "which is a state with its own words")
        let asset = ForgeAsset(filename: "forge_00001.mp4", subfolder: "video", type: "output")
        job.delivered(asset)
        expect(job.asset == asset, "the file is the outcome")
        expect(job.badge == Localized.text("ready"), "and the row says so in a word")
        expect(job.isFinished && !job.isBusy, "a delivered job is over")

        var stopped = ForgeJob(recipe: recipe)
        stopped.submitting()
        stopped.accepted(promptID: "p")
        stopped.saw(.interrupted("p"))
        expect(stopped.phase == .cancelled, "an interrupt stops the job")
        expect(stopped.subtitle == Localized.text("Stopped"), "and says only that")

        var burnt = ForgeJob(recipe: recipe)
        burnt.submitting()
        burnt.accepted(promptID: "p")
        burnt.saw(.failed("p", reason: "out of memory"))
        expect(burnt.phase == .failed("out of memory"), "a failure is terminal")
        expect(burnt.subtitle == "out of memory", "and the reason is the line the reader gets")
        expect(burnt.badge == Localized.text("failed"), "with a word in the corner")

        guard case .endpoint(let arch) = ForgeEndpoint.read("arch") else {
            failures.append("a bare machine name is an endpoint")
            return failures
        }
        expect(arch.port == ForgeEndpoint.defaultPort, "and the port it answers on is supplied")
        expect(ForgeEndpoint.read("http://arch:9000") == .endpoint(ForgeEndpoint(host: "arch", port: 9000)), "a typed port is kept")
        expect(ForgeEndpoint.read("0.0.0.0:8188") == .bindAll, "the address a server binds to is not one to reach")
        expect(ForgeEndpoint.read("") == .empty, "nothing typed is not an error")
        expect(ForgeEndpoint.complaint(.bindAll) != nil, "and every refusal has a sentence")
        expect(ForgeEndpoint.complaint(.endpoint(arch)) == nil, "while a good address has none")
        expect(
            arch.socketURL(clientID: "abc")?.absoluteString == "ws://arch:8188/ws?clientId=abc",
            "the socket carries the same client id the submission will")
        expect(
            asset.url(on: arch)?.absoluteString
                == "http://arch:8188/view?filename=forge_00001.mp4&subfolder=video&type=output",
            "and a finished clip is fetched by the three fields the server gave back")
        expect(asset.isVideo, "an mp4 is a video")

        expect(ForgeFailure.unreachable("arch").description == Localized.text("%@ did not answer", "arch"), "an unreachable box names itself")
        expect(ForgeFailure.rejected("arch", "no such model").description == "no such model", "a refusal is the server's own words")
        expect(ForgeFailure.noOutput("arch").description == Localized.text("%@ finished but saved no video", "arch"), "a render that saved nothing says so")
        expect(
            ForgeFailure.missingFile("arch").description
                == Localized.text("%@ no longer has that clip", "arch"),
            "a kept clip whose file was cleaned up is gone rather than unreachable")
        expect(ForgeFailure.unconfigured.host.isEmpty, "a forge with no machine names none")
        expect(
            ForgeClient.reason(Stranger(), host: "arch") == ForgeFailure.unreachable("arch").description,
            "a foreign error never reaches a screen as itself")

        var board = ForgeBoard()
        expect(
            board.sections.map(\.id) == [ForgeBoard.rendererID, ForgeBoard.renderID, ForgeBoard.settingsID],
            "a fresh board is the renderer, the render and the settings")
        expect(board.begin() == .configure, "with nothing to render on, the board asks for a machine")
        expect(board.renderCall == ForgeSetup.title, "and says that is what the button does")
        expect(
            board.sections.first?.detail == Localized.text("Find it on your tailnet, or type its address"),
            "a forge with no renderer names both ways to get one rather than sitting blank")
        if let index = board.rows.firstIndex(where: { $0.kind == .field(.endpoint) }) {
            board.focus(index)
            expect(
                board.activate() == .configure,
                "and pressing the renderer row opens the setup rather than a text field")
        } else {
            failures.append("the renderer is a row")
        }
        expect(ForgeField.endpoint.opensSetup, "which is the one field that is a surface")
        expect(
            ForgeField.allCases.filter(\.opensSetup) == [.endpoint],
            "and the only one")
        board.point(at: arch)
        expect(board.begin() == .edit(.prompt), "with a machine but no words, it asks for words")
        board.describe("a cat asleep on a warm roof")
        expect(board.canRender, "with both, it can render")
        let asked = board.begin()
        expect(asked == .render(board.recipe), "and pressing it renders exactly what is on the board")
        expect(board.renderCall == Localized.text("Render"), "which is what the button says")
        board.reached(.timedOut)
        expect(
            board.rows.first?.detail == ForgeEndpoint.sentence(for: .timedOut, host: "arch"),
            "a machine that did not answer says so on its own row")
        board.reached(.listening)
        expect(board.rows.first?.badge == Localized.text("up"), "and one that did wears a word")
        expect(board.sections.first?.detail.isEmpty == true, "a renderer that exists needs no invitation")
        for section in board.sections {
            let spoken = ForgeBoard.headerDetail(of: section)
            switch section.id {
            case ForgeBoard.renderID, ForgeBoard.settingsID:
                expect(spoken == nil, "a heading never repeats what the button or the rows under it already say (\(section.id))")
            default:
                expect(spoken == (section.detail.isEmpty ? nil : section.detail), "and every other heading speaks its own detail (\(section.id))")
            }
        }

        if let index = board.rows.firstIndex(where: { $0.kind == .field(.size) }) {
            board.focus(index)
            expect(board.activate() == .choose(.size), "a setting opens its list rather than walking it")
            let sizes = board.choices(of: .size)
            expect(sizes.count == ForgeSize.options.count, "every offered size is in the menu")
            expect(sizes.contains(where: \.selected), "and the current one is marked")
            let next = sizes.first(where: { !$0.selected })?.id ?? sizes[0].id
            board.pick(.size, id: next)
            expect(board.recipe.size.id == next, "picking a row is what moves the setting")
            expect(board.recipe.width % ForgeRecipe.block == 0, "onto a size the model can take")
        } else {
            failures.append("the frame size is a row")
        }
        if let index = board.rows.firstIndex(where: { $0.kind == .field(.prompt) }) {
            board.focus(index)
            expect(board.activate() == .edit(.prompt), "words are the client's field to open")
        } else {
            failures.append("the prompt is a row")
        }
        let seedBefore = board.recipe.seed
        _ = board.handle(.reroll)
        expect(board.recipe.seed != seedBefore, "a re-roll never hands back the seed that was there")

        var running = ForgeJob(recipe: board.recipe)
        running.submitting()
        running.accepted(promptID: "p")
        running.saw(.progressed("p", census: ForgeCensus(finished: 14, total: 28, running: "pass2")))
        board.saw(running)
        expect(!board.canRender, "a board with a render in flight starts no second one")
        expect(board.rows.first(where: { $0.kind == .field(.size) })?.isActivatable == false,
            "and the settings the render already consumed are out of reach")
        expect(board.rows.first(where: { $0.kind == .job })?.fraction == 0.5, "the render row carries the bar")
        expect(board.begin() == .cancel, "pressing the render row stops it")
        expect(board.handle(.cancel).action == .cancel, "and so does the chord")
        expect(board.renderCall == Localized.text("Stop"), "which is what the button says")
        running.delivered(asset)
        board.saw(running)
        expect(board.begin() == .play(asset), "a finished render plays")
        expect(board.renderCall == Localized.text("Play"), "and says so")
        expect(board.handle(.cancel).handled == false, "there is nothing left to stop")

        board.filled(history: [])
        expect(
            board.rows.contains { $0.kind == .note && $0.title == Localized.text("Nothing rendered yet") },
            "an empty history says it is empty rather than vanishing")
        if let note = board.rows.firstIndex(where: { $0.kind == .note }) {
            board.focus(note)
            expect(board.cursor != note, "and the cursor does not stop on it")
        }

        let clips = (0..<7).map { index in
            ForgeEntry(
                id: "job\(index)", recipe: recipe.with(seed: index),
                asset: ForgeAsset(filename: "clip\(index).mp4", subfolder: "video"),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        }
        board.filled(history: clips)
        let kept = board.sections.first { $0.id == ForgeBoard.historyID }
        expect(kept?.rows.count == ForgeBoard.compactLimit + 1, "a long history is compacted")
        expect(kept?.hidden == 3, "and says how many it is holding")
        expect(kept?.rows.last?.kind == .expander(ForgeBoard.historyID), "behind one row")
        if let index = board.rows.firstIndex(where: { $0.kind == .expander(ForgeBoard.historyID) }) {
            board.focus(index)
            expect(board.activate() == nil, "expanding is a step")
            expect(
                board.sections.first { $0.id == ForgeBoard.historyID }?.rows.count == 8,
                "and the rest come out")
            expect(board.back(), "escape closes what was opened")
            expect(
                board.sections.first { $0.id == ForgeBoard.historyID }?.hidden == 3,
                "and the history is compact again")
        } else {
            failures.append("the expander is a row")
        }
        if let index = board.rows.firstIndex(where: { $0.entry?.id == "job2" }) {
            board.focus(index)
            expect(board.activate() == .play(ForgeAsset(filename: "clip2.mp4", subfolder: "video")),
                "a kept clip plays")
        } else {
            failures.append("a kept clip is a row")
        }
        board.reuse(clips[3])
        expect(board.recipe.seed == 3, "and its settings come back to the draft")

        var burntBoard = ForgeBoard(endpoint: arch)
        burntBoard.describe("a cat")
        burntBoard.saw(burnt)
        expect(
            burntBoard.rows.contains { $0.kind == .job && $0.detail == "out of memory" },
            "a render that failed says why on the board rather than going quiet")

        let clip = ForgeEntry(id: "j", recipe: recipe, asset: nil, failure: "out of memory")
        expect(clip.badge == Localized.text("failed"), "a clip that never arrived says so")
        expect(clip.detail == "out of memory", "and keeps the reason")
        expect(!clip.isPlayable, "and cannot be played")
        expect(ForgeEntry(job: ForgeJob(recipe: recipe)) == nil, "a draft is not history")

        let commands: [(UInt32, UInt32, ForgeCommand?)] = [
            (Keymap.up, 0, .up),
            (Keymap.down, 0, .down),
            (Keymap.enter, 0, .activate),
            (Keymap.tab, 0, .expand),
            (Keymap.escape, 0, .back),
            (UInt32(UnicodeScalar("g").value), Keymap.control, .render),
            (UInt32(UnicodeScalar("c").value), Keymap.control, .cancel),
            (UInt32(UnicodeScalar("r").value), Keymap.control, .reroll),
            (UInt32(UnicodeScalar("g").value), 0, nil),
            (UInt32(UnicodeScalar("5").value), 0, nil),
            (UInt32(UnicodeScalar("a").value), 0, nil),
        ]
        for (keyval, state, expected) in commands {
            guard let chord = KeyChord.canonical(keyval: keyval, state: state) else {
                failures.append("chord \(keyval) does not canonicalize")
                continue
            }
            expect(ForgeBoard.command(for: chord) == expected, "key \(keyval)/\(state)")
        }
        return failures
    }
}

import Foundation
import TailscodeCore

/// The Studio's pure logic, checked headlessly from `--selftest`: how the machine's folder and the
/// session become one shelf, what the stage says in each state of the slot, which verbs a stage
/// offers, what the chips show, when the shell folds a piece of itself and which key is which. None
/// of it needs a window or a machine — those are looked at with `--open studio:<state>`.
@MainActor
enum StudioCheck {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }
        shelf(expect)
        stage(expect)
        verbs(expect)
        chips(expect)
        folding(expect)
        keys(expect)
        clipShelf(expect)
        videoStage(expect)
        videoVerbs(expect)
        videoChips(expect)
        startFrom(expect)
        progressLine(expect)
        videoChanges(expect)
        laneSwitch(expect)
        return failures
    }

    private static func picture(
        _ name: String, remote: String? = nil, words: String = "words"
    ) -> ImageGenPicture {
        ImageGenPicture(
            path: "/nonexistent/\(name).png", prompt: words, engine: .quality, mode: .generate,
            aspect: .landscape, seconds: 40, seed: 1, remoteName: remote)
    }

    private static func shelf(_ expect: (Bool, String) -> Void) {
        let machine = ["c.png", "b.png", "a.png"].map { ImageGenLibraryItem(filename: $0) }
        let made = picture("fresh", remote: "d.png", words: "just made")
        let known = picture("known", remote: "b.png", words: "made here")
        let job = StudioShelfMerge.Job(words: "painting", startedAt: nil)
        let merged = StudioShelfMerge.merge(job: job, session: [made, known], machine: machine)
        expect(
            merged.map(\.id) == [StudioShelfMerge.jobID, "d.png", "c.png", "b.png", "a.png"],
            "the job leads, then what the listing has not caught up with, then the machine's own order")
        expect(merged.first?.isJob == true, "and the job's tile says it is one")
        expect(
            Set(merged.map(\.id)).count == merged.count,
            "a picture made here and its copy in the machine's folder are one tile")
        expect(
            merged.first { $0.id == "b.png" }?.words == "made here",
            "and the tile wears the words this Mac remembers for it")
        expect(
            StudioShelfMerge.merge(job: nil, session: [], machine: []).isEmpty,
            "an empty machine and an empty session are an empty shelf")
        let unnamed = picture("local")
        let again = StudioShelfMerge.merge(job: nil, session: [unnamed, unnamed], machine: machine)
        expect(
            again.map(\.id) == [unnamed.path, "c.png", "b.png", "a.png"],
            "a session picture the machine never named leads once, however often it is held")
        expect(
            StudioShelfMerge.neighbour(of: "c.png", step: 1, in: merged) == "b.png",
            "the right arrow walks to the next picture")
        expect(
            StudioShelfMerge.neighbour(of: "d.png", step: -1, in: merged) == "d.png",
            "and stops at the newest end rather than stepping onto the job")
        expect(
            StudioShelfMerge.neighbour(of: "a.png", step: 1, in: merged) == "a.png",
            "or lapping the oldest")
        expect(
            StudioShelfMerge.neighbour(of: nil, step: 1, in: merged) == "d.png",
            "nothing selected walks in from the newest end")
    }

    private static func stage(_ expect: (Bool, String) -> Void) {
        let endpoint = ImageGenEndpoint(host: "arch")
        func read(
            _ slot: ImageGenSlot, _ progress: ImageGenProgress? = nil, picture: Bool = false
        ) -> StudioStageState {
            StudioStageState.read(
                slot: slot, progress: progress, hasPicture: picture, hasWords: false,
                remedy: .retry)
        }
        var slot = ImageGenSlot(endpoint: endpoint)
        expect(read(slot) == .empty, "a slot nobody has touched is empty")
        expect(read(slot, picture: true) == .done, "one holding a picture is done")
        slot.hold(ImageGenReference(path: "/tmp/ref.png"))
        expect(read(slot) == .drafting, "a start-from picture makes it a draft")
        slot.releaseAllReferences()
        slot.begin(prompt: "a lighthouse")
        expect(read(slot).isWorking, "a render out is working before the machine has said a word")
        expect(
            read(slot, ImageGenProgress(stage: .queued(ahead: 2))) == .waiting("Behind 2 other renders"),
            "queued behind others is a sentence of Core's, not the client's")
        expect(
            read(slot, ImageGenProgress(stage: .loading)) == .waiting("Loading the model"),
            "loading the model is a wait")
        expect(
            read(slot, ImageGenProgress(stage: .painting, step: 12, steps: 28))
                == .painting(step: 12, steps: 28),
            "painting carries the sampler's own count")
        expect(
            read(slot, ImageGenProgress(stage: .decoding)) == .finishing("Decoding the picture"),
            "decoding is the sketch dimming, not a new picture")
        expect(
            !read(slot, ImageGenProgress(stage: .painting, step: 1, steps: 28)).showsPicture,
            "and nothing offers a picture's verbs while one is being painted")
        slot.fail(prompt: "a lighthouse", reason: ImageGenWords.stoppedNotice)
        expect(read(slot) == .stopped, "a stop is its own state, not a failure")
        slot.fail(prompt: "a lighthouse", reason: "ComfyUI is not answering")
        expect(
            read(slot) == .failed("ComfyUI is not answering", .retry),
            "a failure carries Core's reason and the one remedy")

        let asleep = ImageGenSighting(host: endpoint.displayHost, reachable: false)
        expect(
            StudioRemedy.choose(sighting: asleep, engine: .quality) == .wake,
            "a machine that did not answer is asked again")
        let half = ImageGenSighting(
            host: endpoint.displayHost, reachable: true,
            missingModels: [ImageGenModelFile.qwenDiffusion.path])
        expect(
            StudioRemedy.choose(sighting: half, engine: .quality) == .useEngine(.turbo)
                || StudioRemedy.choose(sighting: half, engine: .quality) == .useEngine(.fast),
            "a machine missing one engine's files offers the other")
        expect(
            StudioRemedy.choose(sighting: nil, engine: .quality) == .retry,
            "a machine nobody has looked at is simply tried again")
    }

    private static func verbs(_ expect: (Bool, String) -> Void) {
        expect(
            StudioVerbs.offered(state: .empty, kept: false, hasWords: false).isEmpty,
            "an empty stage offers no verbs")
        expect(
            StudioVerbs.offered(state: .painting(step: 1, steps: 28), kept: false, hasWords: true).isEmpty,
            "nor does one that is painting, which holds the capsule's room instead")
        expect(
            StudioVerbs.offered(state: .done, kept: false, hasWords: true)
                == [.save, .share, .copy, .open, .again, .reference, .discard],
            "a picture made here offers every verb in the order a hand reaches for them")
        expect(
            StudioVerbs.offered(state: .done, kept: true, hasWords: false)
                == [.save, .share, .copy, .open, .reference],
            "a kept picture with no words is neither rolled again nor discarded")
        expect(
            StudioVerbs.faces(state: .done, kept: false, hasWords: true).map(\.id)
                == ["save", "share", "copy", "open", "again", "reference", "animate", "discard"],
            "Animate this sits beside the verb that starts the next render from the picture")
        expect(
            StudioVerbs.faces(state: .empty, kept: false, hasWords: true).isEmpty,
            "and a stage with no picture hands nothing off")
        expect(
            StudioStageVerb(.reference).title == ImageGenAction.reference.phoneTitle
                && StudioStageVerb(.discard).isDestructive,
            "a verb keeps Core's word and its one destructive mark through the capsule's face")
    }

    private static func chips(_ expect: (Bool, String) -> Void) {
        var slot = ImageGenSlot(endpoint: ImageGenEndpoint(host: "arch"))
        slot.setEngine(.quality)
        let full = StudioChips.read(slot: slot, engineBlocked: false)
        expect(
            full.map(\.kind) == [
                .field(.engine), .field(.aspect), .field(.size), .field(.detail), .cutout, .avoid, .seed,
                .reference,
            ],
            "the quality engine offers every decision, in Core's order, then the switches")
        expect(
            full.first { $0.kind == .field(.aspect) }?.value == slot.aspect.short,
            "a chip says Core's value for it")
        slot.setEngine(.fast)
        let fast = StudioChips.read(slot: slot, engineBlocked: false)
        expect(
            !fast.contains { $0.kind == .field(.detail) } && !fast.contains { $0.kind == .cutout }
                && !fast.contains { $0.kind == .avoid },
            "the fast engine offers no detail, no cutout and no avoid list")
        slot.hold(ImageGenReference(path: "/tmp/ref.png"))
        let edit = StudioChips.read(slot: slot, engineBlocked: false)
        expect(
            !edit.contains { $0.kind == .field(.aspect) } && !edit.contains { $0.kind == .field(.size) },
            "while a picture is held the size follows it and the shape and size chips stand down")
        expect(
            edit.first { $0.kind == .reference }?.isOn == true,
            "and the reference chip says one is held")
        expect(
            StudioChips.read(slot: slot, engineBlocked: true).first?.isWarning == true,
            "the engine chip wears the warning when the machine lacks its files")
        expect(
            full.allSatisfy { $0.spoken.hasPrefix($0.label) },
            "every chip is read aloud as its decision and then its value")
    }

    private static func folding(_ expect: (Bool, String) -> Void) {
        expect(StudioFolding.foldsShelf(width: 959), "under 960 points the shelf is a strip")
        expect(!StudioFolding.foldsShelf(width: 960), "at 960 it is a rail")
        expect(StudioFolding.foldsChips(height: 759), "under 760 points the chips fold into Settings")
        expect(!StudioFolding.foldsChips(height: 760), "at 760 they do not")
    }

    private static func keys(_ expect: (Bool, String) -> Void) {
        func key(_ code: UInt16, _ character: String = "", command: Bool = false, shift: Bool = false, editing: Bool = false) -> StudioKey? {
            StudioKeys.match(
                keyCode: code, character: character, command: command, shift: shift, other: false,
                editing: editing)
        }
        expect(key(36, command: true) == .generate, "⌘↩ generates")
        expect(key(76, command: true) == .generate, "and so does the keypad's")
        expect(key(36) == nil, "↩ alone is a new line in the words")
        expect(key(53) == .stop, "⎋ stops")
        expect(key(14, "e", command: true) == .enhance, "⌘E enhances")
        expect(key(14, "e", command: true, shift: true) == .editThis, "⌘⇧E edits this")
        expect(key(15, "r", command: true, shift: true) == .again, "⌘⇧R rolls again")
        expect(key(18, "1", command: true) == .imageLane, "⌘1 is the image lane")
        expect(key(19, "2", command: true) == .videoLane, "⌘2 is the video lane")
        expect(key(1, "s", command: true) == .save, "⌘S saves")
        expect(key(123) == .previousTile && key(124) == .nextTile, "the arrows walk the shelf")
        expect(
            key(123, editing: true) == nil && key(124, editing: true) == nil,
            "but not while words are being edited")
        expect(key(49) == .open, "Space opens the picture full size")
        expect(key(49, editing: true) == nil, "and is a space in the words")
        expect(
            StudioKeys.match(
                keyCode: 36, character: "", command: true, shift: false, other: true, editing: false)
                == nil,
            "a chord with option or control in it is never the Studio's")
        let chords = StudioKey.allCases.filter { $0.chord.command }
        expect(
            Set(chords.map { "\($0.chord.key)\($0.chord.shift)" }).count == chords.count,
            "no two Studio chords are the same")
    }

    private static func recipe(words: String = "a cat asleep on a warm tiled roof") -> ForgeRecipe {
        ForgeRecipe(
            prompt: words, negative: "", width: 1280, height: 704, seconds: 5, fps: 24, seed: 7)
    }

    private static func entry(
        _ id: String, at seconds: Double, asset: String? = nil, failure: String? = nil
    ) -> ForgeEntry {
        ForgeEntry(
            id: id, recipe: recipe(), asset: asset.map { ForgeAsset(filename: $0) }, failure: failure,
            finishedAt: Date(timeIntervalSince1970: seconds))
    }

    private static func clipShelf(_ expect: (Bool, String) -> Void) {
        let older = entry("a", at: 1000, asset: "a.mp4")
        let newer = entry("b", at: 2000, asset: "b.mp4")
        let lost = entry("c", at: 3000, failure: "no output")
        let job = StudioClipShelf.Job(words: "painting", startedAt: nil)
        let merged = StudioClipShelf.merge(job: job, history: [older, newer, lost], missing: ["a"])
        expect(
            merged.map(\.id) == [StudioShelfMerge.jobID, "c", "b", "a"],
            "the render in flight leads the clips, then newest first whatever order the store gave")
        expect(merged.first?.isJob == true, "and its tile says it is the job")
        expect(
            merged.first { $0.id == "c" }?.isMissing == true
                && merged.first { $0.id == "a" }?.isMissing == true
                && merged.first { $0.id == "b" }?.isMissing == false,
            "a render that made nothing and a clip the renderer lost are marked, never dropped")
        expect(
            merged.first { $0.id == "b" }?.badge == "0:05" && merged.first { $0.id == "c" }?.badge == nil,
            "a clip wears its length and a receipt with no clip wears none")
        expect(merged.allSatisfy { $0.kind == .clip }, "every tile on this shelf is a clip")
        expect(
            StudioClipShelf.merge(job: nil, history: [older, older], missing: []).map(\.id) == ["a"],
            "a receipt filed twice is one tile")
        expect(
            StudioClipShelf.merge(job: nil, history: [], missing: []).isEmpty,
            "no receipts and no render is an empty shelf")
        expect(
            StudioShelfMerge.neighbour(of: "b", step: 1, in: merged) == "a"
                && StudioShelfMerge.neighbour(of: "c", step: -1, in: merged) == "c",
            "the arrows walk the clips and stop at the newest rather than stepping onto the job")
        expect(
            StudioClipTime.badge(seconds: 5) == "0:05" && StudioClipTime.badge(seconds: 75) == "1:15"
                && StudioClipTime.badge(seconds: 600) == "10:00" && StudioClipTime.badge(seconds: -3) == "0:00",
            "a clip's length is minutes and two-digit seconds")
        expect(
            StudioClipName.fileName(for: entry("n", at: 1, asset: "forge_00007.mp4"))
                == "a-cat-asleep-on-a-warm.mp4"
                && StudioClipName.fileName(for: entry("m", at: 1)) == "a-cat-asleep-on-a-warm.mp4",
            "a saved clip is named by its first six words and keeps the machine's extension")
    }

    private static func job(_ steps: (inout ForgeJob) -> Void) -> ForgeJob {
        var job = ForgeJob(recipe: recipe())
        steps(&job)
        return job
    }

    private static func videoStage(_ expect: (Bool, String) -> Void) {
        func read(
            _ job: ForgeJob, clip: StudioClipSource? = nil, start: Bool = false, words: Bool = false
        ) -> StudioVideoState {
            StudioVideoState.read(
                job: job, clip: clip, hasStart: start, hasWords: words, remedy: .retry)
        }
        let fresh = ForgeJob(recipe: recipe())
        expect(read(fresh) == .empty, "a forge nobody has touched is empty")
        expect(read(fresh, words: true) == .drafting, "words make a draft")
        expect(read(fresh, start: true) == .drafting, "and so does a first frame")
        expect(read(fresh, clip: .playable) == .done, "a clip chosen from the shelf is a finished one")
        expect(
            read(fresh, clip: .unavailable("gone")) == .failed("gone", .reuse),
            "a clip that cannot be played says why, in the failure tone, with the settings to take back")
        let waking = job { $0.submitting() }
        expect(
            read(waking) == .waiting(waking.subtitle) && waking.subtitle == Localized.text("Waking the renderer…"),
            "waking the machine is a sentence of Core's")
        let queued = job {
            $0.submitting()
            $0.accepted(promptID: "p", queued: 2)
        }
        expect(read(queued) == .waiting(queued.subtitle), "a queue is a wait")
        let loading = job {
            $0.submitting()
            $0.accepted(promptID: "p")
            $0.saw(.started("p"))
        }
        expect(
            read(loading) == .working(loading.stageName ?? loading.subtitle),
            "a run with no sampler step is the machine working out what it was asked")
        let sampling = job {
            $0.submitting()
            $0.accepted(promptID: "p")
            $0.saw(.started("p"))
            $0.saw(.sampling("p", node: "pass1", step: 2, steps: 8))
        }
        expect(read(sampling) == .painting(sampling.detail), "a sampler step is painting, said by the job")
        expect(
            read(sampling, clip: .playable) == .painting(sampling.detail),
            "and a render out outranks the clip that was on stage")
        let saving = job {
            $0.submitting()
            $0.accepted(promptID: "p")
            $0.saw(.started("p"))
            $0.saw(.finished("p"))
        }
        expect(read(saving) == .finishing(saving.subtitle), "a render that has said everything is saving")
        let failed = job {
            $0.submitting()
            $0.failed("out of memory")
        }
        expect(
            StudioVideoState.read(
                job: failed, clip: nil, hasStart: false, hasWords: true, remedy: .wake)
                == .failed("out of memory", .wake),
            "a failure carries Core's reason and the one remedy")
        let stopped = job {
            $0.submitting()
            $0.cancelled()
        }
        expect(read(stopped) == .stopped, "a stop is its own state, not a failure")
        expect(
            read(sampling).isWorking && !read(sampling).showsClip && StudioVideoState.done.showsClip
                && !StudioVideoState.drafting.isWorking,
            "only a finished clip offers a clip's verbs, and only a render out is working")
    }

    private static func videoVerbs(_ expect: (Bool, String) -> Void) {
        let all = StudioVideoVerbs.offered(state: .done, hasWords: true, playing: false, isHistory: true)
        expect(
            all.map(\.id) == ["play", "save", "share", "copy", "open", "again", "continue", "discard"],
            "a finished clip offers every verb in the order a hand reaches for them")
        expect(
            StudioVideoVerbs.offered(state: .done, hasWords: false, playing: false, isHistory: false).map(\.id)
                == ["play", "save", "share", "copy", "open", "continue"],
            "a clip with no words is not rolled again, and one not on the shelf is not discarded")
        expect(
            StudioVideoVerbs.offered(state: .done, hasWords: true, playing: true, isHistory: true).first?.title
                == Localized.text("Pause"),
            "the first verb is the other half of the one the clip is doing")
        expect(
            StudioVideoVerbs.offered(state: .painting("step"), hasWords: true, playing: false, isHistory: true).isEmpty
                && StudioVideoVerbs.offered(state: .empty, hasWords: true, playing: false, isHistory: false).isEmpty,
            "nothing is offered while a clip is being made or before there is one")
        expect(
            all.contains { $0.id == StudioVideoVerbs.primaryID },
            "and Continue it, the verb the accent is spent on, is among them")
        expect(
            StudioMenuWords.title(.open, lane: .video) == Localized.text("Play or Pause")
                && StudioMenuWords.title(.editThis, lane: .video) == ForgeWords.extendTitle
                && StudioMenuWords.title(.open, lane: .image) == ImageGenAction.open.title,
            "the same keys are the lane's own verbs: Space plays a clip and opens a picture")
    }

    private static func videoChips(_ expect: (Bool, String) -> Void) {
        var board = ForgeBoard(recipe: recipe(), endpoint: ForgeEndpoint(host: "arch"))
        let chips = StudioVideoChips.read(board: board)
        expect(
            chips.map(\.kind) == [.forge(.size), .forge(.seconds), .forge(.fps), .sound, .avoid, .forge(.seed)],
            "the clip's decisions are Core's, in its order: size, length, smoothness, sound, avoid, seed")
        expect(
            chips.first?.value == board.value(of: .size) && chips.allSatisfy(\.isLabelled),
            "a pill says the board's own value and wears its decision's word")
        expect(
            chips.allSatisfy { $0.spoken.hasPrefix($0.label) },
            "and is read aloud as the decision and then its value")
        expect(
            chips.first { $0.kind == .sound }?.value == Localized.text("Auto"),
            "a sound nobody wrote is the machine's to decide")
        board.hear("rain on a tin roof")
        board.avoid("blurry")
        let written = StudioVideoChips.read(board: board)
        expect(
            written.first { $0.kind == .sound }?.isOn == true && written.first { $0.kind == .avoid }?.isOn == true,
            "words in either box light its pill")
        expect(
            StudioVideoChips.estimate(board: board) == ForgeBoard.notice,
            "until a clip has been timed the line says only where the work happens")
        var clock = ForgeClock()
        clock.learn(board.recipe, seconds: 75)
        board.learned(clock)
        let estimate = StudioVideoChips.estimate(board: board)
        expect(
            estimate.contains("1280×704") && estimate.contains("5 s") && estimate.hasPrefix(Localized.text("about %@", "1 min 15 s")),
            "once timed it prices the clip in the machine's own measure at the shape asked for")
        expect(
            StudioVideoChips.read(board: board).first { $0.kind == .forge(.seconds) }?.value
                == board.value(of: .seconds),
            "a length is Core's reading of it")
    }

    private static func startFrom(_ expect: (Bool, String) -> Void) {
        var board = ForgeBoard(recipe: recipe(), endpoint: ForgeEndpoint(host: "arch"))
        board.start(from: .file("/tmp/tall.png"), pictureWidth: 700, pictureHeight: 1300)
        expect(
            board.recipe.size == ForgeSize.nearest(width: 700, height: 1300) && board.recipe.size == .portrait,
            "once a picture is the first frame the clip's size follows its shape")
        expect(board.recipe.frame == .file("/tmp/tall.png"), "and the board holds the frame")
        var chosen = ForgeBoard(recipe: recipe(), endpoint: ForgeEndpoint(host: "arch"))
        chosen.pick(.size, id: ForgeSize.square.id)
        chosen.start(from: .file("/tmp/tall.png"), pictureWidth: 700, pictureHeight: 1300)
        expect(
            chosen.recipe.size == .square,
            "unless somebody chose a size by hand, which a photograph does not overrule")
        let clip = ForgeEntry(
            id: "x", recipe: recipe().with(size: .portrait), asset: ForgeAsset(filename: "x.mp4", subfolder: "video"))
        var next = ForgeBoard(recipe: recipe(), endpoint: ForgeEndpoint(host: "arch"))
        next.extend(clip)
        expect(
            next.recipe.frame == .clipEnd(ForgeAsset(filename: "x.mp4", subfolder: "video"))
                && next.recipe.size == .portrait && next.recipe.seed != clip.recipe.seed,
            "Continue it opens on the end of that clip, in its shape, on a fresh seed")
        next.start(from: nil)
        expect(next.recipe.frame == nil, "and letting go of the frame is one row")

        let uploaded = ForgeGraph(recipe: recipe().with(frame: .file("/tmp/a.png")), uploadedFrame: "a_1.png")
        expect(
            uploaded.startsFromFrame && uploaded.node("still")?.classType == "LoadImage"
                && uploaded.node("still")?.inputs["image"] == .text("a_1.png")
                && uploaded.node("start1")?.classType == "LTXVImgToVideoInplace"
                && uploaded.node("start2") != nil && uploaded.problems.isEmpty,
            "a picture from this Mac becomes the graph's LoadImage, held by both passes, with nothing dangling")
        let payload = uploaded.payload["still"] as? [String: Any]
        expect(
            payload?["class_type"] as? String == "LoadImage",
            "and that is what is posted to the machine")
        let kept = ForgeGraph(recipe: recipe().with(frame: .kept("tailscode_00002_.png [output]")), uploadedFrame: nil)
        expect(
            kept.node("still")?.inputs["image"] == .text("tailscode_00002_.png [output]") && kept.problems.isEmpty,
            "a picture the machine keeps is named where it is and nothing travels")
        let continued = ForgeGraph(
            recipe: recipe().with(frame: .clipEnd(ForgeAsset(filename: "x.mp4", subfolder: "video"))),
            uploadedFrame: nil)
        expect(
            continued.node("reel")?.classType == "LoadVideo" && continued.node("last")?.classType == "ImageFromBatch"
                && continued.node("last")?.inputs["batch_index"] == .whole(ForgeGraph.lastFrameIndex)
                && continued.problems.isEmpty,
            "the end of a clip is its last frame, taken by the graph on the machine")
        expect(
            ForgeGraph(recipe: recipe(), uploadedFrame: nil).startsFromFrame == false,
            "and a clip from words alone has no start nodes")
    }

    private static func progressLine(_ expect: (Bool, String) -> Void) {
        let first = job {
            $0.submitting()
            $0.accepted(promptID: "p")
            $0.saw(.started("p"))
            $0.saw(.progressed("p", census: ForgeCensus(finished: 5, total: 28, running: "pass1")))
            $0.saw(.sampling("p", node: "pass1", step: 4, steps: 8))
        }
        let segments = StudioProgressLine.segments(job: first)
        expect(
            segments == [
                StudioProgressLine.Segment(name: Localized.text("First pass"), fraction: 0.5),
                StudioProgressLine.Segment(name: Localized.text("Second pass"), fraction: 0),
            ],
            "a render in its first pass fills the first of two segments by the sampler's own count")
        let second = job {
            $0.submitting()
            $0.accepted(promptID: "p")
            $0.saw(.started("p"))
            $0.saw(.progressed("p", census: ForgeCensus(finished: 15, total: 28, running: "pass2")))
            $0.saw(.sampling("p", node: "pass2", step: 1, steps: 4))
        }
        expect(
            StudioProgressLine.segments(job: second).map(\.fraction) == [1, 0.25],
            "in its second the first is full and the second fills from its own count, not the first's")
        let laid = StudioProgressLine.filled(segments, width: 100, gap: 4)
        expect(
            laid.count == 2 && laid[0].origin == 0 && laid[0].length == 48 && laid[0].filled == 24
                && laid[1].origin == 52 && laid[1].filled == 0,
            "two segments share the stage's edge with a gap between and fill from the left")
        let loading = job {
            $0.submitting()
            $0.accepted(promptID: "p")
            $0.saw(.started("p"))
        }
        expect(
            StudioProgressLine.segments(job: loading).isEmpty,
            "before the first pass has said a step there is nothing true to draw")
        let counted = job {
            $0.submitting()
            $0.accepted(promptID: "p")
            $0.saw(.started("p"))
            $0.saw(.progressed("p", census: ForgeCensus(finished: 14, total: 28, running: "unet")))
        }
        expect(
            StudioProgressLine.segments(job: counted) == [StudioProgressLine.Segment(name: nil, fraction: 0.5)],
            "a render whose passes are not yet known is one bar from its own fraction")
        expect(
            StudioProgressLine.segments(job: ForgeJob(recipe: recipe())).isEmpty
                && StudioProgressLine.filled([], width: 100, gap: 4).isEmpty,
            "and a job that is not out has no line")
    }

    private static func videoChanges(_ expect: (Bool, String) -> Void) {
        let base = ForgeDemo.board("running")
        let reading = StudioVideoReading(board: base, missing: [])
        expect(
            StudioVideoReading(board: base, missing: []).change(from: reading, sketchMoved: false) == nil,
            "nothing moving is nothing to redraw")
        var typed = base
        typed.describe("another sentence entirely")
        expect(
            StudioVideoReading(board: typed, missing: []).change(from: reading, sketchMoved: false) == nil,
            "the words being typed are the box's own, and move nothing else")
        var stepped = base
        var walking = stepped.job
        walking.saw(.sampling(ForgeDemo.promptID, node: "pass2", step: 4, steps: 4))
        stepped.saw(walking)
        expect(
            StudioVideoReading(board: stepped, missing: []).change(from: reading, sketchMoved: false) == .progress,
            "a sampler step is one line and one bar")
        expect(
            StudioVideoReading(board: base, missing: []).change(from: reading, sketchMoved: true) == .sketch,
            "a sketch is one layer")
        var landed = base
        var finishing = landed.job
        finishing.delivered(ForgeDemo.asset)
        landed.saw(finishing)
        expect(
            StudioVideoReading(board: landed, missing: []).change(from: reading, sketchMoved: false) == .everything,
            "a render that ends is the whole picture")
        expect(
            StudioVideoReading(board: base, missing: ["demo-0"]).change(from: reading, sketchMoved: false) == .everything,
            "and so is a clip the renderer turns out to have lost")
        var chosen = base
        chosen.pick(.seconds, id: "8")
        expect(
            StudioVideoReading(board: chosen, missing: []).change(from: reading, sketchMoved: false) == .everything,
            "a setting changing redraws the pills and the estimate")
    }

    private static func laneSwitch(_ expect: (Bool, String) -> Void) {
        let studio = MacImageStudio(endpoint: ImageGenEndpoint(host: "127.0.0.1"))
        StudioDemo.apply("drafting", to: studio)
        let image = ImageLane(studio: studio)
        ForgeRunner.shared.stage(ForgeDemo.board("history"))
        let video = VideoLane(runner: .shared)
        let workspace = StudioWorkspaceView(scoped: true)
        workspace.setLane(image)
        image.dock.take(brief: "a lighthouse on a cliff")
        expect(workspace.lane === image, "the workspace holds the lane it was given")
        workspace.setLane(video)
        expect(workspace.lane === video, "and the Video lane replaces it")
        video.dock.take(brief: "a cat asleep on a roof")
        workspace.setLane(image)
        expect((image.dock as? StudioDockView)?.text == "a lighthouse on a cliff", "switching back finds each lane's own words")
        workspace.setLane(video)
        expect(
            (video.dock as? StudioDockView)?.text == "a cat asleep on a roof"
                && ForgeRunner.shared.board.recipe.prompt == "a cat asleep on a roof",
            "in both directions, and the clip's words are the board's, which outlives the panel")
        expect(
            image.shelfTitle != video.shelfTitle && image.id != video.id,
            "each lane brings its own shelf")
        ForgeRunner.shared.demonstrate("history")
        video.select(tile: "demo-1")
        expect(video.selectedTile == "demo-1", "what a lane had on stage is still on it")
        workspace.setLane(image)
        workspace.setLane(video)
        expect(video.selectedTile == "demo-1", "after the other lane has been in front")
        expect(
            !video.offers(.imageLane) && !video.offers(.videoLane),
            "the lane switch is the shell's, never a lane's")
    }
}

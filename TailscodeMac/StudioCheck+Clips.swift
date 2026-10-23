import AppKit
import Foundation
import TailscodeCore

extension StudioCheck {
    static func recipe(words: String = "a cat asleep on a warm tiled roof") -> ForgeRecipe {
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

    static func clipShelf(_ expect: (Bool, String) -> Void) {
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
    }

    static func clipNames(_ expect: (Bool, String) -> Void) {
        let first = entry("n", at: 1, asset: "forge_00007.mp4")
        let rerolled = ForgeEntry(
            id: "m", recipe: recipe().with(seed: 8), asset: ForgeAsset(filename: "forge_00008.mp4"))
        expect(
            first.fileName == "a-cat-asleep-on-a-warm-tiled-roof-7.mp4",
            "a saved clip is named by its words and its seed and keeps the machine's extension")
        expect(
            first.fileName != rerolled.fileName,
            "two takes of the same words are two names, so one never overwrites the other")
        expect(
            entry("k", at: 1).fileName.hasSuffix(".mp4"),
            "a receipt with no file still has a name to offer")
        let elsewhere = ForgeEndpoint(host: "elsewhere")
        let there = ForgeEntry(
            id: first.id, recipe: first.recipe, asset: first.asset, endpoint: elsewhere)
        let arch = ForgeEndpoint(host: "arch")
        expect(
            MacClipPosters.key(for: first, on: arch) != MacClipPosters.key(for: there, on: arch)
                && MacClipPosters.key(for: first, on: arch) != MacClipPosters.key(for: rerolled, on: arch),
            "a poster is the clip of one machine's receipt, never of a file name two machines share")
        expect(
            MacClipPosters.key(for: first, on: arch) == MacClipPosters.key(for: first, on: arch),
            "and the same receipt on the same machine is the same poster")
    }

    static func job(_ steps: (inout ForgeJob) -> Void) -> ForgeJob {
        var job = ForgeJob(recipe: recipe())
        steps(&job)
        return job
    }

    static func videoStage(_ expect: (Bool, String) -> Void) {
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

    static func videoVerbs(_ expect: (Bool, String) -> Void) {
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

    static func videoChips(_ expect: (Bool, String) -> Void) {
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
}

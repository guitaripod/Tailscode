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
        expect(
            StudioShell.videoLane == nil,
            "until a Video lane exists the Video segment has nothing to switch to")
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
}

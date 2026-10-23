import AppKit
import Foundation
import TailscodeCore

extension StudioCheck {
    static func startFrom(_ expect: (Bool, String) -> Void) {
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

    static func progressLine(_ expect: (Bool, String) -> Void) {
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

    static func videoChanges(_ expect: (Bool, String) -> Void) {
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

    private static let dummyClip = URL(fileURLWithPath: "/nonexistent/studio-check.mp4")

    private static func elsewhereBoard(_ other: ForgeEndpoint) -> ForgeBoard {
        var board = ForgeDemo.board("history")
        let moved = board.history.map {
            ForgeEntry(
                id: $0.id, recipe: $0.recipe, asset: $0.asset, failure: $0.failure,
                finishedAt: $0.finishedAt, endpoint: other)
        }
        board.filled(history: moved)
        return board
    }

    static func videoContinue(_ expect: (Bool, String) -> Void) {
        var noted = StudioFailureLedger()
        let start = Date(timeIntervalSince1970: 1000)
        noted.note("a", sentence: "down", at: start)
        expect(
            noted.sentence(for: "a", at: start.addingTimeInterval(StudioFailureLedger.lifetime - 1)) == "down",
            "a failure is believed for a while")
        expect(
            noted.sentence(for: "a", at: start.addingTimeInterval(StudioFailureLedger.lifetime + 1)) == nil
                && !noted.holds("a", at: start.addingTimeInterval(StudioFailureLedger.lifetime + 1)),
            "and then the machine is asked again")
        noted.forget("a")
        expect(!noted.holds("a", at: start), "or the moment somebody asks to check again")

        let idle = ForgeJob(recipe: recipe())
        func read(_ clip: StudioClipSource?, continuing: Bool = false, job: ForgeJob? = nil) -> StudioVideoState {
            StudioVideoState.read(
                job: job ?? idle, clip: clip, hasStart: true, hasWords: true, remedy: .retry,
                continuing: continuing)
        }
        expect(
            read(.playable, continuing: true) == .continuing && read(.playable) == .done,
            "a clip being continued is held back from playing and a clip chosen is a clip to watch")
        expect(
            read(.unreachable("down")) == .failed("down", .wake),
            "a clip that could not be located offers to check the machine again, not to render")
        expect(
            read(.unavailable("gone"), continuing: true) == .failed("gone", .reuse),
            "and a clip that cannot be played is not continued from")
        var busy = ForgeJob(recipe: recipe())
        busy.submitting()
        expect(
            read(.playable, continuing: true, job: busy) == .waiting(busy.subtitle),
            "a render out outranks the card")
        expect(
            StudioVideoVerbs.offered(state: .continuing, hasWords: true, playing: false, isHistory: true).isEmpty,
            "the card is the only thing a continuation offers")
        expect(
            !StudioVideoVerbs.offered(
                state: .done, hasWords: true, playing: false, isHistory: true, canContinue: false
            ).contains { $0.id == "continue" },
            "a clip on another machine is not offered Continue it")

        let runnerBoard = ForgeDemo.board("history")
        ForgeRunner.shared.stage(runnerBoard, clip: dummyClip)
        let lane = VideoLane(runner: .shared)
        guard let newest = runnerBoard.history.first(where: \.isPlayable),
            let older = runnerBoard.history.last(where: \.isPlayable), let asset = newest.asset
        else {
            expect(false, "the demo shelf has clips")
            return
        }
        lane.select(tile: newest.id)
        expect(lane.offers(.editThis), "a clip on the stage that this machine holds can be continued")
        var said: [String] = []
        lane.onNotice = { said.append($0) }
        lane.perform(.editThis)
        expect(
            ForgeRunner.shared.board.recipe.frame == .clipEnd(asset)
                && ForgeRunner.shared.board.continuing?.id == newest.id,
            "Continue it opens the next clip on the end of the clip on the stage")
        expect(
            lane.driveState.contains("state=continuing") && lane.selectedTile == newest.id,
            "the stage says it is waiting for the next clip, with the continued clip still selected")
        expect(
            said == [ForgeWords.continuingNotice(newest)],
            "and the press is answered in a line naming the clip")
        lane.select(tile: older.id)
        lane.select(tile: newest.id)
        expect(
            lane.driveState.contains("state=done"),
            "a clip chosen from the shelf is there to be watched, even when the draft starts from it")

        lane.select(tile: older.id)
        let sideShelf = lane.shelf.first { $0.id == newest.id }
        expect(sideShelf != nil, "the clip being continued is still on the shelf")
        if let sideShelf {
            lane.perform(.verb(StudioStageVerb(id: "continue", title: "", hint: "", symbol: "")), on: sideShelf)
        }
        expect(
            lane.selectedTile == newest.id && lane.driveState.contains("state=continuing"),
            "Continue it from a shelf tile puts that clip on the stage first")

        let other = ForgeEndpoint(host: "elsewhere")
        let away = elsewhereBoard(other)
        ForgeRunner.shared.stage(away, clip: dummyClip)
        lane.select(tile: newest.id)
        expect(!lane.offers(.editThis), "a clip that lives on another machine cannot be continued from this one")
        said = []
        lane.perform(.editThis)
        expect(
            said == [ForgeWords.continueElsewhere(other.shortName)]
                && ForgeRunner.shared.board.recipe.frame == nil,
            "and says which machine has it instead of doing nothing")
        let tile = lane.shelf.first { $0.id == newest.id }
        let verbs = tile.map { lane.tileVerbs(for: $0) } ?? []
        expect(
            !verbs.contains { if case .verb(let verb) = $0 { return verb.id == "continue" } else { return false } },
            "nor does its tile offer to")

        ForgeRunner.shared.stage(ForgeDemo.board("running"), clip: dummyClip)
        let running = lane.shelf.first { !$0.isJob && !$0.isMissing }
        let whileRunning = running.map { lane.tileVerbs(for: $0) } ?? []
        expect(
            !whileRunning.contains {
                if case .verb(let verb) = $0 { return verb.id == "continue" || verb.id == "again" }
                return false
            },
            "while a render is out a tile offers no verb that would be refused")
        ForgeRunner.shared.stage(ForgeDemo.board("history"))
    }

    private final class LightWatcher {
        var calls = 0
    }

    static func videoLight(_ expect: (Bool, String) -> Void) {
        let runner = ForgeRunner.shared
        func light(_ name: String, arriving: Bool = false) -> ForgeLight {
            runner.stage(ForgeDemo.board(name), clip: dummyClip, arriving: arriving)
            return runner.light
        }
        expect(light("history") == .dark, "a shelf of old clips and nothing out leaves the button dark")
        expect(light("waking") == .waking, "a render being filed with the machine is the wake")
        expect(light("queued") == .waiting(ahead: 2), "and one behind two others says how many")
        let running = light("running")
        expect(running.isOut && running.motion.isAnimated, "a render under way is out and moves")
        expect(light("collecting") == .saving, "a render with every step done is the file being written")
        expect(light("done", arriving: true) == .landed, "a clip nobody has seen is lit")
        runner.present(ForgeDemo.asset)
        expect(runner.light == .dark, "and goes dark once it has been put in front of somebody")
        expect(light("done") == .dark, "a clip staged as already shown never lights the button")
        expect(light("failed") == .failed, "a failure nobody has read is lit")
        runner.acknowledgeFailure()
        expect(runner.light == .dark, "and goes dark once its card has been on the stage")
        expect(light("failed") == .failed, "the next failure is news again")
        expect(light("stopped") == .dark, "a stop was never news to the person who pressed it")

        let watcher = LightWatcher()
        runner.watch(watcher) {
            watcher.calls += 1
            runner.acknowledgeFailure()
        }
        runner.stage(ForgeDemo.board("failed"), clip: dummyClip)
        expect(
            watcher.calls == 1 && runner.light == .dark,
            "a watcher that reads the failure is answered on the next turn, not before the first round of calls is over")
        runner.unwatch(watcher)
        runner.stage(ForgeDemo.board("history"))
    }

    static func videoRing(_ expect: (Bool, String) -> Void) {
        let size = CGSize(width: 44, height: 32)
        var points: [CGPoint] = []
        ForgeRingView.path(in: CGRect(origin: .zero, size: size)).applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: points.append(element.pointee.points[0])
            default: break
            }
        }
        expect(
            points.first == CGPoint(x: size.width / 2, y: size.height - ForgeRingView.lineWidth / 2)
                && points.dropFirst().first.map({ $0.x > size.width / 2 && $0.y == points[0].y }) == true,
            "the ring begins at the top centre and sets off to the right, which is clockwise as it is seen")

        let wild = ForgeRingFrame.Stroke(start: -0.2, length: 1.6, intensity: 3)
        let held = ForgeRingView.span(of: wild)
        expect(held.start == 0 && held.end == 1, "a stroke past either end of the path is held to it")

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
            defer: false)
        let ring = ForgeRingView()
        ring.frame = NSRect(origin: .zero, size: size)
        window.contentView?.addSubview(ring)
        ring.layoutSubtreeIfNeeded()
        let faces: [ForgeLight] = [
            .waking, .waiting(ahead: 2), .rendering(0.001), .rendering(0.5), .rendering(0.999),
            .saving, .landed, .failed,
        ]
        var inside = true
        var still = true
        for face in faces {
            ring.show(face)
            for tick in 0..<120 {
                ring.paint(at: Double(tick) * 0.0731)
                for stroke in ring.drawnStrokes {
                    if !(0...1).contains(stroke.start) || !(0...1).contains(stroke.end)
                        || stroke.start > stroke.end || !(0...1).contains(stroke.alpha)
                    {
                        inside = false
                    }
                }
                if !(0...1).contains(ring.trackAlpha) { inside = false }
            }
            let moves = face.motion.honoring(reduceMotion: !ActivityPulse.motionAllowed).isAnimated
            if ring.isTicking != moves { still = false }
        }
        expect(inside, "no stroke handed to a layer, at any instant of any face, leaves the path's 0...1")
        expect(still, "the display's clock runs for a face that moves and for no other")
        ring.show(.dark)
        ring.layoutSubtreeIfNeeded()
        expect(!ring.isTicking, "a ring that went dark has no clock")
        ring.removeFromSuperview()
    }

    static func videoLanding(_ expect: (Bool, String) -> Void) {
        var done = ForgeDemo.board("done")
        let landed = ForgeEntry(id: ForgeDemo.promptID, recipe: done.recipe, asset: ForgeDemo.asset)
        done.filled(history: [landed] + done.history)
        expect(
            StudioVideoRetake.needsNewSeed(job: done.job)
                && !StudioVideoRetake.needsNewSeed(job: ForgeDemo.board("running").job)
                && !StudioVideoRetake.needsNewSeed(job: ForgeDemo.board("history").job),
            "the button that renders asks for another take of a clip that has landed, and of nothing else")
        let twin = ForgeEntry(id: "someone-else", recipe: done.recipe, asset: ForgeDemo.asset)
        expect(
            StudioVideoSelection.landed(job: done.job, history: [twin, landed])?.id == landed.id
                && StudioVideoSelection.landed(job: done.job, history: [twin]) == nil,
            "the clip a render delivered is found by the machine's id for it, not by a file name")
        expect(
            StudioVideoSelection.shelfID(staged: "x", job: done.job) == "x"
                && StudioVideoSelection.shelfID(staged: "x", job: ForgeDemo.board("running").job)
                    == StudioShelfMerge.jobID
                && StudioVideoSelection.shelfID(staged: "x", job: ForgeDemo.board("failed").job) == nil
                && StudioVideoSelection.shelfID(staged: "x", job: ForgeDemo.board("stopped").job) == nil,
            "the shelf marks the render while it is out and nothing while the stage shows how one ended")

        ForgeRunner.shared.stage(ForgeDemo.board("history"), clip: dummyClip)
        let lane = VideoLane(runner: .shared)
        ForgeRunner.shared.stage(done, clip: dummyClip, arriving: true)
        expect(
            lane.selectedTile == ForgeDemo.promptID,
            "a render that lands puts its own clip on the stage and on the shelf")
        expect(
            ForgeRunner.shared.unpresented == ForgeDemo.asset,
            "and it has not been shown to anybody yet")
        ForgeRunner.shared.present(ForgeDemo.asset)
        expect(
            ForgeRunner.shared.unpresented == nil,
            "a clip is presented once, however often the Studio opens")
        ForgeRunner.shared.stage(done, clip: dummyClip)
        expect(
            ForgeRunner.shared.unpresented == nil,
            "a landed clip staged for a look is not played at whoever opens the window")
        ForgeRunner.shared.stage(ForgeDemo.board("failed"), clip: dummyClip)
        expect(lane.selectedTile == nil, "nothing is selected while the stage shows a render that failed")
        ForgeRunner.shared.stage(ForgeDemo.board("running"), clip: dummyClip)
        expect(lane.selectedTile == StudioShelfMerge.jobID, "the render is selected while it is out")
        ForgeRunner.shared.stage(ForgeDemo.board("history"))
    }
}

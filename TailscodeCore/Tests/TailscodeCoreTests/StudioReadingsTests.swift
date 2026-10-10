import Foundation
import Testing

@testable import TailscodeCore

/// What the studio's line, pill and announcements say, proved once so the phone and both desks
/// cannot describe the same machine or the same render two ways.
@Suite("Studio readings")
struct StudioReadingsTests {
    private let recipe = ForgeRecipe(
        prompt: "a cat asleep on a warm roof", width: 1280, height: 704, seconds: 5, fps: 24, seed: 7)

    private func job(_ walk: (inout ForgeJob) -> Void) -> ForgeJob {
        var job = ForgeJob(recipe: recipe)
        job.submitting()
        job.accepted(promptID: "p")
        walk(&job)
        return job
    }

    @Test("The line has no segments until the first pass has said a step")
    func noLineBeforeSampling() {
        let loading = job {
            $0.saw(.progressed("p", census: ForgeCensus(finished: 3, total: 28, running: "unet")))
        }
        #expect(loading.passSegments == nil)
        let reading = job {
            $0.saw(.progressed("p", census: ForgeCensus(finished: 8, total: 28, running: "pass1")))
        }
        #expect(reading.passSegments == nil, "a pass with no step yet would be a bar at zero")
    }

    @Test("The first pass fills its own segment from the sampler's step and leaves the second empty")
    func firstPass() throws {
        let walking = job {
            $0.saw(.progressed("p", census: ForgeCensus(finished: 9, total: 28, running: "pass1")))
            $0.saw(.sampling("p", node: "pass1", step: 2, steps: 8))
        }
        let segments = try #require(walking.passSegments)
        #expect(segments.count == 2)
        #expect(segments[0].name == Localized.text("First pass"))
        #expect(segments[0].fraction == 0.25)
        #expect(segments[0].isCurrent)
        #expect(segments[1].fraction == 0)
        #expect(!segments[1].isCurrent)
    }

    @Test("The sampler's counter restarting for the second pass never empties the first segment")
    func secondPass() throws {
        let walking = job {
            $0.saw(.progressed("p", census: ForgeCensus(finished: 17, total: 28, running: "pass2")))
            $0.saw(.sampling("p", node: "pass2", step: 3, steps: 4))
        }
        let segments = try #require(walking.passSegments)
        #expect(segments[0].fraction == 1)
        #expect(!segments[0].isCurrent)
        #expect(segments[1].fraction == 0.75)
        #expect(segments[1].isCurrent)
    }

    @Test("Between the passes the first is full and the second not begun, and decoding fills both")
    func betweenAndAfter() throws {
        let upscaling = job {
            $0.saw(.progressed("p", census: ForgeCensus(finished: 14, total: 28, running: "up")))
        }
        let between = try #require(upscaling.passSegments)
        #expect(between.map(\.fraction) == [1, 0])
        let decoding = job {
            $0.saw(.progressed("p", census: ForgeCensus(finished: 24, total: 28, running: "pixels")))
        }
        let after = try #require(decoding.passSegments)
        #expect(after.map(\.fraction) == [1, 1])
    }

    @Test("A render that is not running has no segments")
    func settledHasNone() {
        let finished = job {
            $0.delivered(ForgeAsset(filename: "forge_00001.mp4", subfolder: "video"))
        }
        #expect(finished.passSegments == nil)
        #expect(ForgeJob(recipe: recipe).passSegments == nil)
    }

    @Test("A machine nobody has looked at is said to be unchecked, not described")
    func machineUnchecked() throws {
        let door = ImageGenDoor(endpoint: ImageGenEndpoint(host: "arch"))
        let reading = try #require(StudioMachineReading.image(door))
        #expect(reading.name == "arch")
        #expect(reading.fact == ImageGenMachineWords.neverChecked)
        #expect(reading.tone == .quiet)
        #expect(!reading.cannotPaint)
    }

    @Test("A machine with every file is live, one with only some is attention, one that cannot paint is danger")
    func machineTones() throws {
        let endpoint = ImageGenEndpoint(host: "arch")
        let host = endpoint.displayHost
        let ready = ImageGenDoor(
            endpoint: endpoint, sighting: ImageGenSighting(host: host, reachable: true))
        #expect(StudioMachineReading.image(ready)?.tone == .live)

        let quality = ImageGenEngine.quality.files.map(\.name)
        let partial = ImageGenDoor(
            endpoint: endpoint,
            sighting: ImageGenSighting(host: host, reachable: true, missingModels: quality))
        let half = try #require(StudioMachineReading.image(partial))
        #expect(half.tone == .attention)
        #expect(!half.cannotPaint)
        let named = partial.sighting?.readyEngines.map(\.label).joined(separator: ", ") ?? ""
        #expect(half.fact == Localized.text("%@ only", named), "every engine that is ready is named")

        let both = ImageGenEngine.allCases.flatMap { $0.files.map(\.name) }
        let empty = ImageGenDoor(
            endpoint: endpoint,
            sighting: ImageGenSighting(host: host, reachable: true, missingModels: both))
        #expect(StudioMachineReading.image(empty)?.tone == .danger)
        #expect(StudioMachineReading.image(empty)?.cannotPaint == true)

        let asleep = ImageGenDoor(
            endpoint: endpoint, sighting: ImageGenSighting(host: host, reachable: false))
        let down = try #require(StudioMachineReading.image(asleep))
        #expect(down.tone == .danger)
        #expect(down.cannotPaint)
    }

    @Test("No machine, no pill")
    func noMachine() {
        #expect(StudioMachineReading.image(ImageGenDoor(endpoint: nil)) == nil)
        #expect(StudioMachineReading.forge(ForgeBoard()) == nil)
    }

    @Test("The video pill wears the renderer's own row")
    func forgePill() throws {
        var board = ForgeBoard(recipe: recipe, endpoint: ForgeEndpoint(host: "arch"))
        board.reached(.listening)
        let up = try #require(StudioMachineReading.forge(board))
        #expect(up.tone == .live)
        #expect(up.name == "arch")
        board.reached(.refused)
        let down = try #require(StudioMachineReading.forge(board))
        #expect(down.tone == .danger)
        #expect(down.cannotPaint)
    }

    @Test("A landing is announced with its words, cut to a line, and without them says only that it landed")
    func landing() {
        #expect(StudioStageWords.landed(words: nil) == Localized.text("Picture ready"))
        #expect(StudioStageWords.landed(words: "  ") == Localized.text("Picture ready"))
        #expect(StudioStageWords.landed(words: "a lighthouse").contains("a lighthouse"))
        #expect(StudioStageWords.clipLanded(words: nil) == Localized.text("Clip ready"))
    }
}

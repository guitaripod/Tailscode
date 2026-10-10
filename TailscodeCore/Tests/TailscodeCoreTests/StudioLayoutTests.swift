import Foundation
import Testing

@testable import TailscodeCore

@Suite struct StudioLayoutTests {
    @Test func theStudioChecksItselfClean() {
        #expect(StudioLayoutCheck.run().isEmpty, "\(StudioLayoutCheck.run())")
    }

    @Test func theRailStartsAtNineHundredAndTheChipsFoldUnderFiveTwenty() {
        #expect(StudioArrangement.resolve(width: 900, height: 700).shelf == .rail)
        #expect(StudioArrangement.resolve(width: 899.5, height: 700).shelf == .strip)
        #expect(StudioArrangement.resolve(width: 1200, height: 520).chips == .row)
        #expect(StudioArrangement.resolve(width: 1200, height: 519.5).chips == .settings)
    }

    @Test func aNarrowPaneFoldsTheChipsToo() {
        #expect(StudioArrangement.resolve(width: 559, height: 700).chips == .settings)
        #expect(StudioArrangement.resolve(width: 560, height: 700).chips == .row)
        #expect(StudioArrangement.resolve(width: 900, height: 700).chips == .row)
    }

    @Test func aWindowHasNoBarOfItsOwnAbovetheStage() {
        let room = StudioSize(width: 1180, height: 820)
        let arrangement = StudioArrangement.resolve(width: 1180, height: 820)
        let pane = StudioStageGeometry.resolve(
            pane: room, dockHeight: 132, arrangement: arrangement, aspect: nil,
            metrics: .pane)
        let window = StudioStageGeometry.resolve(
            pane: room, dockHeight: 132, arrangement: arrangement, aspect: nil,
            metrics: .window)
        #expect(window.stage.height - pane.stage.height == StudioMetrics.pane.toolbarHeight)
    }

    @Test func theStageOwnsMostOfANormalPaneInBothArrangements() {
        let roomy = StudioSize(width: 1180, height: 820)
        let rail = StudioStageGeometry.resolve(
            pane: roomy, dockHeight: 132,
            arrangement: StudioArrangement.resolve(width: 1180, height: 820), aspect: 1.5)
        #expect(rail.share(of: roomy) >= 0.6)

        let tight = StudioSize(width: 700, height: 760)
        let strip = StudioStageGeometry.resolve(
            pane: tight, dockHeight: 132,
            arrangement: StudioArrangement.resolve(width: 700, height: 760), aspect: 1.5)
        #expect(strip.share(of: tight) >= 0.6)
    }

    @Test func aPictureIsFittedWithinTheRoomTheVerbsAndMarginsLeave() throws {
        let pane = StudioSize(width: 1180, height: 820)
        let arrangement = StudioArrangement.resolve(width: 1180, height: 820)
        for aspect in [1.0, 1.5, 2.0 / 3.0, 16.0 / 9.0, 9.0 / 16.0, 21.0 / 9.0] {
            let result = StudioStageGeometry.resolve(
                pane: pane, dockHeight: 132, arrangement: arrangement, aspect: aspect)
            let picture = try #require(result.picture)
            #expect(abs(picture.width / picture.height - aspect) < 0.001)
            #expect(picture.width <= result.stage.width - 48 + 0.001)
            #expect(picture.height <= result.stage.height - 48 - 52 + 0.001)
        }
    }

    @Test func theSketchAndThePictureLandInTheSameRectangle() throws {
        let pane = StudioSize(width: 1180, height: 820)
        let arrangement = StudioArrangement.resolve(width: 1180, height: 820)
        let ratio = ImageGenAspect.landscape.ratio
        let asked = Double(ratio.width) / Double(ratio.height)
        let sketch = StudioStageGeometry.resolve(
            pane: pane, dockHeight: 132, arrangement: arrangement, aspect: asked)
        let landed = StudioStageGeometry.resolve(
            pane: pane, dockHeight: 132, arrangement: arrangement, aspect: 3.0 / 2.0)
        #expect(sketch == landed)
    }

    @Test func theShelfMergesTheSessionAndTheMachineIntoOneNewestFirstList() {
        let mine = ImageGenPicture(
            path: "/tmp/one.png", prompt: "one", engine: .quality, mode: .generate, aspect: .square,
            seconds: 30, seed: 1, remoteName: "ComfyUI_00003_.png")
        let unlisted = ImageGenPicture(
            path: "/tmp/two.png", prompt: "two", engine: .quality, mode: .generate, aspect: .square,
            seconds: 30, seed: 2)
        let machine = ["ComfyUI_00003_.png", "ComfyUI_00002_.png", "ComfyUI_00001_.png"]
            .map { ImageGenLibraryItem(filename: $0) }
        let entries = StudioShelf.merge(session: [unlisted, mine], machine: machine, inFlight: true)
        #expect(
            entries.map(\.id) == [
                "job", "session:/tmp/two.png", "ComfyUI_00003_.png", "ComfyUI_00002_.png",
                "ComfyUI_00001_.png",
            ])
        #expect(entries[2].localPath == "/tmp/one.png")
        #expect(entries[3].localPath == nil)
        #expect(entries.filter(\.isInFlight).count == 1)
    }

    @Test func aMachineThatCannotListStillShowsTheSession() {
        let mine = ImageGenPicture(
            path: "/tmp/one.png", prompt: "one", engine: .fast, mode: .generate, aspect: .wide,
            seconds: 4, seed: 1, remoteName: "ComfyUI_00003_.png")
        let entries = StudioShelf.merge(session: [mine], machine: [], inFlight: false)
        #expect(entries.map(\.id) == ["session:/tmp/one.png"])
    }

    @Test func theSelectionFollowsThePictureOnStageToItsTile() {
        let mine = ImageGenPicture(
            path: "/tmp/one.png", prompt: "one", engine: .quality, mode: .generate, aspect: .square,
            seconds: 30, seed: 1, remoteName: "ComfyUI_00003_.png")
        let machine = [ImageGenLibraryItem(filename: "ComfyUI_00003_.png")]
        let entries = StudioShelf.merge(session: [mine], machine: machine, inFlight: false)
        #expect(
            StudioShelf.selection(in: entries, keptID: nil, picturePath: "/tmp/one.png")
                == "ComfyUI_00003_.png")
        #expect(
            StudioShelf.selection(in: entries, keptID: "ComfyUI_00003_.png", picturePath: nil)
                == "ComfyUI_00003_.png")
        #expect(StudioShelf.selection(in: entries, keptID: nil, picturePath: nil) == nil)
    }

    @Test func theArrowsWalkTheShelfAndStopAtItsEnds() {
        let machine = ["a.png", "b.png", "c.png"].map { ImageGenLibraryItem(filename: $0) }
        let entries = StudioShelf.merge(session: [], machine: machine, inFlight: true)
        #expect(StudioShelf.step(from: nil, by: 1, in: entries) == "a.png")
        #expect(StudioShelf.step(from: nil, by: -1, in: entries) == "c.png")
        #expect(StudioShelf.step(from: "a.png", by: 1, in: entries) == "b.png")
        #expect(StudioShelf.step(from: "a.png", by: -1, in: entries) == "a.png")
        #expect(StudioShelf.step(from: "c.png", by: 1, in: entries) == "c.png")
        #expect(StudioShelf.step(from: nil, by: 1, in: []) == nil)
    }

    @Test func aLongShelfKeepsOnlyWhatIsNearTheEyeDecoded() {
        let top = StudioShelfWindow.visible(offset: 0, viewport: 600, pitch: 96, count: 400)
        let middle = StudioShelfWindow.visible(offset: 19_200, viewport: 600, pitch: 96, count: 400)
        #expect(top.lowerBound == 0)
        #expect(top.count < 20)
        #expect(middle.count < 24)
        #expect(middle.contains(200))
        #expect(StudioShelfWindow.visible(offset: 0, viewport: 600, pitch: 96, count: 0).isEmpty)
        #expect(StudioShelfWindow.visible(offset: 0, viewport: 600, pitch: 0, count: 5).isEmpty)
    }

    @Test func everyChipIsReadAsItsLabelAndItsValue() {
        let slot = ImageGenSlot(endpoint: ImageGenEndpoint(host: "arch"))
        let chips = StudioChips.image(for: slot, sighting: nil)
        #expect(chips.map(\.id).prefix(4) == [.engine, .aspect, .size, .detail])
        #expect(chips[0].accessibility == "Engine, Quality")
        #expect(chips[1].accessibility == "Aspect, 1:1")
        #expect(chips.first(where: { $0.id == .seed })?.accessibility == "Seed, rolls")
        #expect(chips.map(\.id).contains(.craft))
    }

    @Test func aPictureInHandTakesItsShapeFromThePictureAndSaysSo() {
        var slot = ImageGenSlot(endpoint: ImageGenEndpoint(host: "arch"))
        slot.attach(ImageGenReference(path: "/tmp/ref.png"))
        let chips = StudioChips.image(for: slot, sighting: nil)
        #expect(chips.first(where: { $0.id == .aspect })?.isEnabled == false)
        #expect(chips.first(where: { $0.id == .size })?.isEnabled == false)
        #expect(chips.first(where: { $0.id == .reference })?.isOn == true)
    }

    @Test func theEngineChipWearsTheMissingFilesWarningOnlyForARealLook() {
        let slot = ImageGenSlot(endpoint: ImageGenEndpoint(host: "arch"))
        let missing = ImageGenSighting(
            host: "arch:8188", reachable: true,
            missingModels: ["diffusion_models/qwen_image_2.1_int8_convrot.safetensors"])
        let asleep = ImageGenSighting(host: "arch:8188", reachable: false)
        #expect(StudioChips.image(for: slot, sighting: missing).first?.warning != nil)
        #expect(StudioChips.image(for: slot, sighting: asleep).first?.warning == nil)
        #expect(StudioChips.image(for: slot, sighting: nil).first?.warning == nil)
    }

    @Test func theMachinePillSaysOnlyWhatTheLastLookSaw() {
        let well = ImageGenSighting(host: "arch:8188", reachable: true, version: "0.36")
        let pill = StudioMachinePill.image(
            machine: "arch", sighting: well, engine: .quality, painting: false)
        #expect(pill.line == "arch · Quality ready · ComfyUI 0.36")
        #expect(pill.tone == .ready)
        #expect(!pill.breathes)

        let working = StudioMachinePill.image(
            machine: "arch", sighting: well, engine: .quality, painting: true)
        #expect(working.breathes)
        #expect(working.state == pill.state)

        let unknown = StudioMachinePill.image(
            machine: "arch", sighting: nil, engine: .quality, painting: false)
        #expect(unknown.line == "arch")
        #expect(unknown.tone == .unknown)

        let none = ImageGenSighting(
            host: "arch:8188", reachable: true,
            missingModels: ImageGenModelFile.all.map(\.path))
        let bare = StudioMachinePill.image(
            machine: "arch", sighting: none, engine: .quality, painting: false)
        #expect(bare.tone == .danger)
        #expect(bare.state == "No engine has all its files")

        let klein = ImageGenSighting(
            host: "arch:8188", reachable: true,
            missingModels: ImageGenModelFile.all.filter { $0.engine != .fast }.map(\.path))
        let partial = StudioMachinePill.image(
            machine: "arch", sighting: klein, engine: .quality, painting: false)
        #expect(partial.state == "Fast only — Quality files missing")
        #expect(partial.tone == .danger)
    }

    @Test func theEstimateIsLearnedFromRendersAndNeverInvented() {
        func picture(_ seconds: Double, engine: ImageGenEngine = .quality, size: ImageGenSize = .standard)
            -> ImageGenPicture
        {
            ImageGenPicture(
                path: "/tmp/\(seconds).png", prompt: "p", engine: engine, mode: .generate,
                aspect: .square, size: size, seconds: seconds, seed: 1)
        }
        #expect(
            StudioEstimate.image(
                engine: .quality, size: .standard, mode: .generate, pictures: [], machine: "arch")
                == nil)
        #expect(
            StudioEstimate.image(
                engine: .quality, size: .standard, mode: .generate,
                pictures: [picture(80, engine: .fast), picture(60, size: .large)], machine: "arch")
                == nil)
        #expect(
            StudioEstimate.image(
                engine: .quality, size: .standard, mode: .generate,
                pictures: [picture(80), picture(100), picture(90)], machine: "arch")
                == "about 1 min 30 s on arch")
    }

    @Test func theTwoPassesFillTheirOwnSegments() {
        #expect(StudioProgress.passes(running: "unet", step: 0, steps: 0) == [0, 0])
        #expect(StudioProgress.passes(running: "pass1", step: 3, steps: 8) == [0.375, 0])
        #expect(StudioProgress.passes(running: "up", step: 8, steps: 8) == [1, 0])
        #expect(StudioProgress.passes(running: "pass2", step: 1, steps: 4) == [1, 0.25])
        #expect(StudioProgress.passes(running: "save", step: 4, steps: 4) == [1, 1])
        #expect(StudioProgress.passes(running: "mystery", step: 1, steps: 2) == nil)
        #expect(StudioProgress.passes(running: nil, step: 1, steps: 2) == nil)
        #expect(StudioProgress.passes(running: "pass1", step: 99, steps: 8) == [1, 0])
    }
}

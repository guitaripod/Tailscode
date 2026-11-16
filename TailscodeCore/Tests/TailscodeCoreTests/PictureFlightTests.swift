import Testing

@testable import TailscodeCore

@Suite struct PictureFlightTests {
    private let room = PictureFlight.Rect(x: 20, y: 60, width: 1200, height: 800)
    private let tile = PictureFlight.Rect(x: 340, y: 210, width: 87, height: 87)

    @Test func aPictureIsFittedIntoItsRoomAndCentred() {
        let wide = PictureFlight.stage(aspect: 2, in: room)
        #expect(wide == PictureFlight.Rect(x: 20, y: 160, width: 1200, height: 600))
        let tall = PictureFlight.stage(aspect: 0.5, in: room)
        #expect(tall == PictureFlight.Rect(x: 420, y: 60, width: 400, height: 800))
    }

    @Test func aCroppedTileIsLeftWholeAndAFittedOneFromItsPictureOnly() {
        #expect(PictureFlight.origin(tile: tile, aspect: 1.5, fitted: false) == tile)
        let fitted = PictureFlight.origin(tile: tile, aspect: 0.5, fitted: true)
        #expect(fitted.height == 87 && fitted.width == 43.5 && fitted.midX == tile.midX)
    }

    @Test func fillingAFrameCoversItAndStopsCroppingAtThePicturesOwnShape() {
        let cropped = PictureFlight.fill(aspect: 2, frame: tile)
        #expect(cropped.width == 174 && cropped.height == 87)
        #expect(cropped.midX == tile.midX && cropped.midY == tile.midY)
        let stage = PictureFlight.stage(aspect: 2, in: room)
        #expect(PictureFlight.fill(aspect: 2, frame: stage) == stage)
    }

    @Test func aFlightStartsInTheTileAndEndsOnTheStage() {
        let stage = PictureFlight.stage(aspect: 1.4, in: room)
        let start = PictureFlight.moment(
            time: 0, opening: true, origin: tile, stage: stage, tileRadius: 10)
        #expect(start.frame == tile && start.cornerRadius == 10)
        #expect(start.backdrop == 0 && start.chrome == 0)
        let rest = PictureFlight.moment(
            time: 1, opening: true, origin: tile, stage: stage, tileRadius: 10)
        #expect(rest.frame == stage && rest.cornerRadius == 0)
        #expect(rest.backdrop == 1 && rest.chrome == 1)
    }

    @Test func goingHomeEndsInTheTile() {
        let stage = PictureFlight.stage(aspect: 1.4, in: room)
        let home = PictureFlight.moment(
            time: 0, opening: false, origin: tile, stage: stage, tileRadius: 10)
        #expect(home.frame == tile && home.cornerRadius == 10)
        let leaving = PictureFlight.moment(
            time: 1, opening: false, origin: tile, stage: stage, tileRadius: 10)
        #expect(leaving.frame == stage)
    }

    @Test func theBackdropIsInBeforeTheWordsStart() {
        #expect(PictureFlight.backdrop(time: 0.45) == 1)
        #expect(PictureFlight.chrome(time: 0.45) == 0)
        #expect(PictureFlight.chrome(time: 0.55) == 0)
        #expect(PictureFlight.chrome(time: 0.775) > 0.49 && PictureFlight.chrome(time: 0.775) < 0.51)
        for step in 0...20 {
            let time = Double(step) / 20
            #expect(!(PictureFlight.backdrop(time: time) < 1 && PictureFlight.chrome(time: time) > 0))
        }
    }

    @Test func onTheWayHomeTheWordsGoFirstAndTheChatShowsEarly() {
        #expect(PictureFlight.chrome(time: 1, opening: false) == 1)
        #expect(PictureFlight.chrome(time: 0.7, opening: false) == 0)
        #expect(PictureFlight.backdrop(time: 0.85, opening: false) == 1)
        #expect(PictureFlight.backdrop(time: 0.5, opening: false) < 0.6)
        #expect(PictureFlight.backdrop(time: 0, opening: false) == 0)
        let stage = PictureFlight.stage(aspect: 1.4, in: room)
        let half = PictureFlight.moment(
            time: 0.5, opening: false, origin: tile, stage: stage, tileRadius: 10)
        #expect(half.chrome == 0 && half.backdrop > 0.5 && half.backdrop < 0.6)
    }

    @Test func theCurvesEaseTheWayTheyAreNamed() {
        let out = PictureFlight.curve(opening: true)
        #expect(PictureFlight.eased(0, out) == 0 && PictureFlight.eased(1, out) == 1)
        #expect(PictureFlight.eased(0.3, out) > 0.6)
        let home = PictureFlight.curve(opening: false)
        #expect(abs(PictureFlight.eased(0.5, home) - 0.5) < 0.03)
        #expect(PictureFlight.eased(0.2, home) < 0.1)
        var last = -1.0
        for step in 0...50 {
            let value = PictureFlight.eased(Double(step) / 50, out)
            #expect(value >= last)
            last = value
        }
    }

    @Test func timeRunsForwardOutAndBackwardHome() {
        #expect(PictureFlight.time(elapsed: 0, opening: true, reduced: false) == 0)
        #expect(PictureFlight.time(elapsed: 0.14, opening: true, reduced: false) == 0.5)
        #expect(PictureFlight.time(elapsed: 9, opening: true, reduced: false) == 1)
        #expect(PictureFlight.time(elapsed: 0, opening: false, reduced: false) == 1)
        #expect(PictureFlight.time(elapsed: 0.22, opening: false, reduced: false) == 0)
        #expect(PictureFlight.time(elapsed: 0.06, opening: true, reduced: true) == 0.5)
        #expect(PictureFlight.time(elapsed: .nan, opening: true, reduced: false) == 1)
    }

    @Test func aPictureWithNoHomeShrinksALittleAboutItsCentreAndFades() {
        let stage = PictureFlight.stage(aspect: 1, in: room)
        let gone = PictureFlight.fading(time: 0, stage: stage)
        #expect(gone.opacity == 0)
        #expect(abs(gone.frame.width - stage.width * 0.96) < 0.001)
        #expect(abs(gone.frame.midX - stage.midX) < 0.001 && abs(gone.frame.midY - stage.midY) < 0.001)
        #expect(PictureFlight.fading(time: 1, stage: stage).frame == stage)
    }

    @Test func nothingHereDrawsFromANumberThatIsNotOne() {
        let broken = PictureFlight.Rect(x: 0, y: 0, width: .infinity, height: 10)
        #expect(PictureFlight.stage(aspect: 1, in: broken) == broken)
        #expect(PictureFlight.stage(aspect: .nan, in: room) == room)
        #expect(PictureFlight.fill(aspect: 0, frame: tile) == tile)
        #expect(PictureFlight.backdrop(time: .nan) == 0)
    }
}

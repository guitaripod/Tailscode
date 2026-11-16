import Foundation
import Testing

@testable import TailscodeCore

@Suite struct PictureGalleryTests {
    private let compact = ChatMetrics.metrics(for: .compact, input: .touch)
    private let comfortable = ChatMetrics.metrics(for: .comfortable, input: .touch)

    @Test func aLonePictureFillsTheSquare() {
        let tiles = PictureGalleryLayout.grid(count: 1, side: 180).tiles
        #expect(tiles == [PictureGalleryLayout.Tile(index: 0, x: 0, y: 0, width: 180, height: 180)])
    }

    @Test func aLonePictureKeepsItsOwnShape() {
        let wide = PictureGalleryLayout.grid(count: 1, side: 180, shape: 1.6, maxWidth: 340).tiles
        #expect(abs(wide[0].width - 288) < 0.001 && wide[0].height == 180)
        let tall = PictureGalleryLayout.grid(count: 1, side: 180, shape: 0.7).tiles
        #expect(abs(tall[0].width - 126) < 0.001 && tall[0].height == 180)
        let panorama = PictureGalleryLayout.grid(
            count: 1, side: 180, shape: 6, maxWidth: 340).tiles
        #expect(panorama[0].width == 340, "a panorama stops at the row's width")
        let unknown = PictureGalleryLayout.grid(count: 1, side: 180, shape: nil).tiles
        #expect(unknown[0].width == 180, "a picture still on its way takes the widest square")
    }

    @Test func severalPicturesAreOneRowOfSmallSquaresFlushLeft() {
        let strip = PictureGalleryLayout.grid(count: 3, side: 180, available: 800)
        let tile = PictureGalleryLayout.stripSide(for: 180)
        #expect(tile == 72)
        #expect(strip.tiles.count == 3)
        #expect(strip.hidden == 0)
        #expect(strip.tiles.allSatisfy { $0.y == 0 && $0.height == tile && $0.width == tile })
        #expect(strip.tiles[0].x == 0)
        #expect(abs(strip.height - tile) < 0.001, "the block is one small tile tall")
        #expect(abs(strip.width - (3 * tile + 2 * PictureGalleryLayout.stripGap)) < 0.001)
    }

    @Test func aStripTileGrowsWithTheBlockBetweenItsBounds() {
        #expect(PictureGalleryLayout.stripSide(for: 100) == PictureGalleryLayout.smallestStripTile)
        #expect(PictureGalleryLayout.stripSide(for: 300) == PictureGalleryLayout.largestStripTile)
        #expect(PictureGalleryLayout.stripSide(for: 40) == 40, "never taller than the block")
    }

    @Test func aLonePictureIsLetterboxedOnlyWhereItsShapeIsWiderThanTheRowHolds() {
        let fits = PictureGalleryLayout.grid(count: 1, side: 180, shape: 1.6, maxWidth: 340).tiles[0]
        #expect(abs(fits.width / fits.height - 1.6) < 0.001, "the tile takes the picture's own shape")
        let cramped = PictureGalleryLayout.grid(count: 1, side: 180, shape: 2.4, maxWidth: 300).tiles[0]
        #expect(cramped.width == 300 && cramped.height == 180, "the height does not move for a shape")
        for shape in stride(from: 0.2, through: 8.0, by: 0.3) {
            let tile = PictureGalleryLayout.grid(
                count: 1, side: 180, shape: shape, maxWidth: 600).tiles[0]
            #expect(tile.height == 180, "a lone picture's block is always one picture tall")
            let wanted = min(600, 180 * PictureShape.shape(of: shape))
            #expect(abs(tile.width - wanted) < 0.001, "shape \(shape)")
        }
    }

    @Test func aPhoneRowShowsWhatFitsAndCountsTheRest() {
        let phone = PictureGalleryLayout.grid(count: 14, side: 180, available: 358)
        #expect(phone.tiles.count == 4)
        #expect(phone.hidden == 10)
        #expect(phone.width <= 358.001)
        let wide = PictureGalleryLayout.grid(count: 40, side: 300, available: 4000)
        #expect(wide.tiles.count == PictureGalleryLayout.maximumColumns)
    }

    @Test func theGutterIsTheStripGap() {
        let four = PictureGalleryLayout.grid(count: 4, side: 180, available: 800)
        #expect(four.tiles[1].x - (four.tiles[0].x + four.tiles[0].width) == PictureGalleryLayout.stripGap)
    }

    @Test func whatTheRowCannotShowIsCountedOnItsLastTile() {
        let many = PictureGalleryLayout.grid(count: 30, side: 180, available: 490)
        #expect(many.tiles.count + many.hidden == 30)
        #expect(many.hidden > 0)
        #expect(PictureGalleryReading.badge(hidden: many.hidden) == "+\(many.hidden)")
        #expect(PictureGalleryReading.badge(hidden: 0) == nil)
        #expect(PictureGalleryReading.badge(hidden: -3) == nil)
    }

    @Test func theBlockIsNeverTallerThanAPictureNorWiderThanTheRow() {
        for width in stride(from: 40.0, through: 2600, by: 23) {
            let side = PictureGalleryLayout.side(metrics: comfortable, width: width)
            for count in 1...30 {
                let arrangement = PictureGalleryLayout.grid(
                    count: count, side: side, available: width, shape: count == 1 ? 3 : nil,
                    maxWidth: width)
                #expect(arrangement.height <= side + 0.001, "\(count) in \(width)")
                #expect(arrangement.width <= width + 0.001, "\(count) in \(width)")
                #expect(arrangement.tiles.count + arrangement.hidden == count)
                #expect(arrangement.tiles.map(\.index) == Array(0..<arrangement.tiles.count))
                if count > 1 {
                    #expect(arrangement.height <= PictureGalleryLayout.largestStripTile + 0.001)
                }
            }
        }
    }

    @Test func theBadgeIsACornerChipOnTheLastTileNotTheTile() {
        let tile = PictureGalleryLayout.Tile(index: 15, x: 100, y: 91, width: 89, height: 89)
        let chip = PictureGalleryLayout.badge(on: tile, textWidth: 24)
        #expect(chip.x + chip.width == tile.x + tile.width - PictureGalleryLayout.chipInset)
        #expect(chip.y + chip.height == tile.y + tile.height - PictureGalleryLayout.chipInset)
        #expect(chip.width < tile.width / 2 && chip.height <= tile.height / 2)
        #expect(chip.width >= chip.height && chip.width >= 24)
        let thin = PictureGalleryLayout.badge(
            on: PictureGalleryLayout.Tile(index: 0, x: 0, y: 0, width: 40, height: 40), textWidth: 60)
        #expect(thin.x >= 0 && thin.x + thin.width <= 40 && thin.y >= 0 && thin.y + thin.height <= 40)
    }

    @Test func snappingKeepsTheGutterEvenWhereRoundingEachTileWouldNot() {
        for width in stride(from: 240.0, through: 1200, by: 13.7) {
            let strip = PictureGalleryLayout.grid(count: 17, side: 173.3, available: width).snapped()
            let gaps = Set(zip(strip.tiles, strip.tiles.dropFirst()).map { $1.x - ($0.x + $0.width) })
            #expect(gaps.count <= 1, "\(width): \(gaps)")
            #expect(strip.tiles.allSatisfy { $0.x == $0.x.rounded() && $0.width == $0.width.rounded() })
            #expect(strip.width <= width + 0.5)
        }
        let loose = PictureGalleryLayout.Arrangement(
            tiles: [PictureGalleryLayout.Tile(index: 0, x: 0, y: 0, width: 10.4, height: 9)], hidden: 0)
        #expect(loose.snapped(to: 0).tiles == loose.tiles)
    }

    @Test func everyTileStaysInsideTheBlock() {
        for width in [240.0, 360, 490, 800, 1200, 2400] {
            for count in 1...24 {
                let side = PictureGalleryLayout.side(metrics: compact, width: width)
                let arrangement = PictureGalleryLayout.grid(
                    count: count, side: side, available: width, maxWidth: width)
                #expect(!arrangement.tiles.isEmpty)
                #expect(arrangement.width <= width + 0.001)
                #expect(arrangement.height <= side + 0.001)
                for tile in arrangement.tiles {
                    #expect(tile.x >= 0 && tile.y >= 0)
                    #expect(tile.x + tile.width <= width + 0.001)
                    #expect(tile.y + tile.height <= side + 0.001)
                }
                #expect(arrangement.tiles.count + arrangement.hidden == count)
            }
        }
    }

    @Test func theBlockIsAPicturesHeightAndNeverWiderThanTheRow() {
        #expect(PictureGalleryLayout.side(metrics: compact, width: 370) == compact.imageMaxHeight)
        #expect(PictureGalleryLayout.side(metrics: comfortable, width: 370) == comfortable.imageMaxHeight)
        #expect(PictureGalleryLayout.side(metrics: comfortable, width: 240) == 240)
        #expect(PictureGalleryLayout.side(metrics: compact, width: 0) == 0)
        #expect(PictureGalleryLayout.grid(count: 3, side: 0).tiles.isEmpty)
        #expect(PictureGalleryLayout.grid(count: 0, side: 180).tiles.isEmpty)
    }

    @Test func aGutterWiderThanTheSquareStillLeavesOnePictureToDraw() {
        let arrangement = PictureGalleryLayout.grid(count: 4, side: 10, available: 10, gap: 20)
        #expect(arrangement.tiles == [PictureGalleryLayout.Tile(index: 0, x: 0, y: 0, width: 10, height: 10)])
        #expect(arrangement.hidden == 3)
    }

    @Test func theTileSaysHowMany() {
        #expect(PictureGalleryReading.label(count: 1) == "1 picture")
        #expect(PictureGalleryReading.label(count: 16) == "16 pictures")
    }

    @Test func aScreenReaderHearsTheCountThenThePicturesByName() {
        #expect(PictureGalleryReading.spoken(count: 2, names: ["a.png", "b.png"]) == "2 pictures, a.png, b.png")
        #expect(
            PictureGalleryReading.spoken(count: 6, names: (1...6).map { "s\($0).png" })
                == "6 pictures, s1.png, s2.png, s3.png, s4.png and 2 more")
        #expect(PictureGalleryReading.spoken(count: 3, names: []) == "3 pictures")
    }

    @Test func shapesAreClampedAndUnknownOnesAreAssumed() {
        #expect(PictureShape.shape(of: 10) == 2.4)
        #expect(PictureShape.shape(of: 0.1) == 0.55)
        #expect(PictureShape.shape(of: nil) == PictureShape.placeholderAspect)
        #expect(PictureShape.shape(of: .nan) == PictureShape.placeholderAspect)
        #expect(PictureShape.shape(of: -1) == PictureShape.placeholderAspect)
    }

    @Test func aTurnsPicturesGatherUnderItsCardInTheOrderTheyArrived() {
        let marks: [TurnPictureGathering.Mark] = [
            .boundary, .card, .other, .picture, .other, .picture, .picture, .other,
        ]
        #expect(TurnPictureGathering.order(marks) == [0, 1, 3, 5, 6, 2, 4, 7])
    }

    @Test func aBoundaryEndsTheTurnAndAPictureBeforeAnyCardStays() {
        let marks: [TurnPictureGathering.Mark] = [
            .picture, .card, .picture, .boundary, .other, .picture, .card, .other, .picture,
        ]
        #expect(TurnPictureGathering.order(marks) == [0, 1, 2, 3, 4, 5, 6, 8, 7])
        let rows = ["p", "c", "x", "q"]
        let gathered = TurnPictureGathering.gathered(rows) { row in
            row == "c" ? .card : (row == "p" || row == "q") ? .picture : .other
        }
        #expect(gathered == ["p", "c", "q", "x"])
        #expect(TurnPictureGathering.gathered(["x", "y"]) { _ in .other } == ["x", "y"])
    }
}

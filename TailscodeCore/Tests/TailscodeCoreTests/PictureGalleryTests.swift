import Foundation
import Testing

@testable import TailscodeCore

@Suite struct PictureGalleryTests {
    private let compact = ChatMetrics.metrics(for: .compact, input: .touch)
    private let comfortable = ChatMetrics.metrics(for: .comfortable, input: .touch)

    @Test func aLonePictureFillsTheSquare() {
        let tiles = PictureGalleryLayout.mosaic(count: 1, side: 180, gap: 8)
        #expect(tiles == [PictureGalleryLayout.Tile(index: 0, x: 0, y: 0, width: 180, height: 180)])
    }

    @Test func aLonePictureKeepsItsOwnShape() {
        let wide = PictureGalleryLayout.mosaic(
            count: 1, side: 180, gap: 8, shape: 1.6, maxWidth: 340)
        #expect(abs(wide[0].width - 288) < 0.001 && wide[0].height == 180)
        let tall = PictureGalleryLayout.mosaic(count: 1, side: 180, gap: 8, shape: 0.7)
        #expect(abs(tall[0].width - 126) < 0.001 && tall[0].height == 180)
        let panorama = PictureGalleryLayout.mosaic(
            count: 1, side: 180, gap: 8, shape: 6, maxWidth: 340)
        #expect(panorama[0].width == 340, "a panorama stops at the row's width")
        let unknown = PictureGalleryLayout.mosaic(count: 1, side: 180, gap: 8, shape: nil)
        #expect(unknown[0].width == 180, "a picture still on its way takes the widest square")
    }

    @Test func twoSplitTheSquareTopToBottom() {
        let tiles = PictureGalleryLayout.mosaic(count: 2, side: 180, gap: 8)
        #expect(tiles.count == 2)
        #expect(tiles[0].height == 180)
        #expect(tiles[1].x == 86 + 8)
        #expect(tiles[1].y == 0)
        #expect(tiles.allSatisfy { $0.x + $0.width <= 180.001 })
    }

    @Test func threeGiveHalfTheSquareToTheFirst() {
        let tiles = PictureGalleryLayout.mosaic(count: 3, side: 180, gap: 8)
        #expect(tiles.count == 3)
        #expect(tiles[0].height == 180)
        #expect(tiles[1].y == 0 && tiles[2].y == 94)
        #expect(tiles[1].height == 86 && tiles[2].height == 86)
    }

    @Test func fourAndMoreAreTheTwoByTwoTheTileIsNamedFor() {
        let tiles = PictureGalleryLayout.mosaic(count: 16, side: 180, gap: 8)
        #expect(tiles.count == PictureGalleryLayout.maximumTiles)
        #expect(Set(tiles.map(\.x)) == [0, 94])
        #expect(Set(tiles.map(\.y)) == [0, 94])
        #expect(PictureGalleryLayout.hidden(count: 16) == 12)
        #expect(PictureGalleryLayout.hidden(count: 4) == 0)
        #expect(PictureGalleryLayout.hidden(count: 1) == 0)
    }

    @Test func everyTileStaysInsideTheSquare() {
        for count in 1...9 {
            let side = PictureGalleryLayout.side(metrics: compact, width: 370)
            let tiles = PictureGalleryLayout.mosaic(count: count, side: side, gap: compact.imageStripGap)
            #expect(!tiles.isEmpty)
            for tile in tiles {
                #expect(tile.x >= 0 && tile.y >= 0)
                #expect(tile.x + tile.width <= side + 0.001)
                #expect(tile.y + tile.height <= side + 0.001)
            }
        }
    }

    @Test func theSquareIsAPicturesHeightAndNeverWiderThanTheRow() {
        #expect(PictureGalleryLayout.side(metrics: compact, width: 370) == compact.imageMaxHeight)
        #expect(PictureGalleryLayout.side(metrics: comfortable, width: 370) == comfortable.imageMaxHeight)
        #expect(PictureGalleryLayout.side(metrics: comfortable, width: 240) == 240)
        #expect(PictureGalleryLayout.side(metrics: compact, width: 0) == 0)
        #expect(PictureGalleryLayout.mosaic(count: 3, side: 0, gap: 6).isEmpty)
        #expect(PictureGalleryLayout.mosaic(count: 0, side: 180, gap: 6).isEmpty)
    }

    @Test func aGutterWiderThanTheSquareStillLeavesOnePictureToDraw() {
        let tiles = PictureGalleryLayout.mosaic(count: 4, side: 10, gap: 20)
        #expect(tiles == [PictureGalleryLayout.Tile(index: 0, x: 0, y: 0, width: 10, height: 10)])
    }

    @Test func theTileSaysHowManyAndCountsTheRest() {
        #expect(PictureGalleryReading.label(count: 1) == "1 picture")
        #expect(PictureGalleryReading.label(count: 16) == "16 pictures")
        #expect(PictureGalleryReading.badge(count: 1) == nil)
        #expect(PictureGalleryReading.badge(count: 4) == nil)
        #expect(PictureGalleryReading.badge(count: 9) == "+5")
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
}

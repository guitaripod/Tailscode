import Foundation
import Testing

@testable import TailscodeCore

@Suite struct PictureGalleryTests {
    private let compact = ChatMetrics.metrics(for: .compact, input: .touch)
    private let comfortable = ChatMetrics.metrics(for: .comfortable, input: .touch)

    @Test func aLonePictureFillsTheSquare() {
        let tiles = PictureGalleryLayout.grid(count: 1, side: 180, gap: 8).tiles
        #expect(tiles == [PictureGalleryLayout.Tile(index: 0, x: 0, y: 0, width: 180, height: 180)])
    }

    @Test func aLonePictureKeepsItsOwnShape() {
        let wide = PictureGalleryLayout.grid(
            count: 1, side: 180, gap: 8, shape: 1.6, maxWidth: 340).tiles
        #expect(abs(wide[0].width - 288) < 0.001 && wide[0].height == 180)
        let tall = PictureGalleryLayout.grid(count: 1, side: 180, gap: 8, shape: 0.7).tiles
        #expect(abs(tall[0].width - 126) < 0.001 && tall[0].height == 180)
        let panorama = PictureGalleryLayout.grid(
            count: 1, side: 180, gap: 8, shape: 6, maxWidth: 340).tiles
        #expect(panorama[0].width == 340, "a panorama stops at the row's width")
        let unknown = PictureGalleryLayout.grid(count: 1, side: 180, gap: 8, shape: nil).tiles
        #expect(unknown[0].width == 180, "a picture still on its way takes the widest square")
    }

    @Test func aFewPicturesStandInOneStripAcrossTheRow() {
        let strip = PictureGalleryLayout.grid(count: 3, side: 180, gap: 8, available: 800)
        #expect(strip.tiles.count == 3)
        #expect(strip.hidden == 0)
        #expect(strip.tiles.allSatisfy { $0.y == 0 && $0.height == 180 })
        #expect(strip.tiles.allSatisfy { $0.width == 180 })
        #expect(abs(strip.width - (3 * 180 + 2 * 8)) < 0.001)
        let filled = PictureGalleryLayout.grid(count: 4, side: 180, gap: 8, available: 600)
        #expect(filled.tiles.allSatisfy { $0.y == 0 })
        #expect(abs(filled.width - 600) < 0.001, "a strip spreads to the row it was given")
        #expect(abs(filled.tiles[0].width - (600 - 24) / 4) < 0.001)
    }

    @Test func manyPicturesAreASheetOfSquaresOnePictureTall() {
        let sheet = PictureGalleryLayout.grid(count: 10, side: 180, gap: 8, available: 800)
        #expect(sheet.tiles.count == 10)
        #expect(sheet.hidden == 0)
        #expect(Set(sheet.tiles.map(\.y)) == [0, 94])
        #expect(abs(sheet.height - 180) < 0.001)
        #expect(sheet.width > 500 && sheet.width <= 800.001, "the sheet uses the row: \(sheet.width)")
    }

    @Test func aNarrowRowTakesASecondRowRatherThanNeedles() {
        let phone = PictureGalleryLayout.grid(count: 10, side: 180, gap: 8, available: 360)
        #expect(phone.tiles.count == 6)
        #expect(phone.hidden == 4)
        #expect(Set(phone.tiles.map(\.y)) == [0, 94])
        #expect(phone.width <= 360.001)
        #expect(phone.tiles.allSatisfy { $0.height == 86 })
    }

    @Test func whatTheSheetCannotShowIsCountedOnItsLastTile() {
        let small = PictureGalleryLayout.grid(count: 17, side: 180, gap: 8, available: 490)
        #expect(small.tiles.count + small.hidden == 17)
        #expect(small.hidden > 0)
        #expect(PictureGalleryReading.badge(hidden: small.hidden) == "+\(small.hidden)")
        #expect(PictureGalleryReading.badge(hidden: 0) == nil)
        let ruled = PictureGalleryLayout.grid(count: 40, side: 180, gap: 8, available: 4000)
        #expect(ruled.tiles.count <= PictureGalleryLayout.maximumColumns * 2)
    }

    @Test func everyTileStaysInsideTheBlock() {
        for width in [240.0, 360, 490, 800, 1200, 2400] {
            for count in 1...24 {
                let side = PictureGalleryLayout.side(metrics: compact, width: width)
                let arrangement = PictureGalleryLayout.grid(
                    count: count, side: side, gap: compact.imageStripGap, available: width,
                    maxWidth: width)
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

    @Test func aTileNeverGetsSoThinItStopsBeingAPicture() {
        for width in [240.0, 360, 800, 1200] {
            let arrangement = PictureGalleryLayout.grid(
                count: 12, side: 180, gap: 8, available: width)
            let thinnest = arrangement.tiles.map(\.width).min() ?? 0
            #expect(thinnest >= 180 * PictureGalleryLayout.narrowestStripShare - 0.001
                || arrangement.tiles.allSatisfy { $0.y == 0 && $0.height == 86 }
                || thinnest >= 86 * 0.99)
        }
    }

    @Test func theBlockIsAPicturesHeightAndNeverWiderThanTheRow() {
        #expect(PictureGalleryLayout.side(metrics: compact, width: 370) == compact.imageMaxHeight)
        #expect(PictureGalleryLayout.side(metrics: comfortable, width: 370) == comfortable.imageMaxHeight)
        #expect(PictureGalleryLayout.side(metrics: comfortable, width: 240) == 240)
        #expect(PictureGalleryLayout.side(metrics: compact, width: 0) == 0)
        #expect(PictureGalleryLayout.grid(count: 3, side: 0, gap: 6).tiles.isEmpty)
        #expect(PictureGalleryLayout.grid(count: 0, side: 180, gap: 6).tiles.isEmpty)
    }

    @Test func aGutterWiderThanTheSquareStillLeavesOnePictureToDraw() {
        let arrangement = PictureGalleryLayout.grid(count: 4, side: 10, gap: 20, available: 10)
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
}

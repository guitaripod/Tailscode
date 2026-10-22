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

    @Test func aFewPicturesStandInOneStripOfSquaresFlushLeft() {
        let strip = PictureGalleryLayout.grid(count: 3, side: 180, available: 800)
        #expect(strip.tiles.count == 3)
        #expect(strip.hidden == 0)
        #expect(strip.tiles.allSatisfy { $0.y == 0 && $0.height == 180 })
        #expect(strip.tiles.allSatisfy { $0.width == 180 }, "a strip tile is never wider than it is tall")
        #expect(strip.tiles[0].x == 0)
        #expect(abs(strip.width - (3 * 180 + 2 * 2)) < 0.001, "a roomy row is not filled, the strip stays squares")
        let squeezed = PictureGalleryLayout.grid(count: 4, side: 180, available: 600)
        #expect(squeezed.tiles.allSatisfy { $0.y == 0 })
        #expect(abs(squeezed.width - 600) < 0.001, "a strip the row cannot hold shrinks to the row")
        #expect(abs(squeezed.tiles[0].width - (600 - 6) / 4) < 0.001)
    }

    @Test func aStripOnlyShrinksWhileItsTilesStayPictures() {
        for available in stride(from: 120.0, through: 1400, by: 7) {
            for count in 2...5 {
                let arrangement = PictureGalleryLayout.grid(
                    count: count, side: 180, available: available)
                guard Set(arrangement.tiles.map(\.y)) == [0] else { continue }
                let widths = Set(arrangement.tiles.map(\.width))
                #expect(widths.count == 1, "one strip, one tile width")
                let width = widths.first ?? 0
                #expect(width <= 180 + 0.001)
                #expect(
                    width >= 180 * PictureGalleryLayout.narrowestStripShare - 0.001,
                    "\(count) in \(available): \(width)")
                let expected = min(180, (available - Double(count - 1) * 2) / Double(count))
                #expect(abs(width - expected) < 0.001, "\(count) in \(available)")
            }
        }
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

    @Test func manyPicturesAreTwoRowsOfSmallTilesOnePictureTall() {
        let sheet = PictureGalleryLayout.grid(count: 10, side: 180, available: 800)
        #expect(sheet.tiles.count == 10)
        #expect(sheet.hidden == 0)
        #expect(Set(sheet.tiles.map(\.y)) == [0, 91])
        #expect(abs(sheet.height - 180) < 0.001)
        #expect(sheet.tiles.allSatisfy { $0.height == 89 })
        #expect(sheet.width > 500 && sheet.width <= 800.001, "the grid uses the row: \(sheet.width)")
    }

    @Test func theGridShrinksItsTilesToFitMoreRatherThanCountThem() {
        let seventeen = PictureGalleryLayout.grid(count: 17, side: 180, available: 490)
        #expect(seventeen.tiles.count == 17)
        #expect(seventeen.hidden == 0)
        #expect(Set(seventeen.tiles.map(\.y)) == [0, 91])
        #expect(abs(seventeen.width - 490) < 0.001, "seventeen fill the row: \(seventeen.width)")
        #expect(seventeen.tiles.allSatisfy { $0.width >= PictureGalleryLayout.narrowestTile })
        let phone = PictureGalleryLayout.grid(count: 17, side: 180, available: 360)
        #expect(phone.hidden == 1)
        #expect(phone.width <= 360.001)
        #expect(phone.tiles.count == 16)
    }

    @Test func aTileIsNeverThinnerThanAPress() {
        for width in [240.0, 360, 490, 800, 1200] {
            for count in 2...40 {
                let arrangement = PictureGalleryLayout.grid(
                    count: count, side: 180, available: width)
                for tile in arrangement.tiles where arrangement.tiles.count > 1 {
                    #expect(
                        tile.width >= PictureGalleryLayout.narrowestTile - 0.001
                            || abs(tile.width - width) < 0.001,
                        "\(count) pictures in \(width): a \(tile.width) pt tile")
                }
            }
        }
    }

    @Test func theGutterIsTwoPoints() {
        let two = PictureGalleryLayout.grid(count: 4, side: 180, available: 800)
        #expect(two.tiles[1].x - (two.tiles[0].x + two.tiles[0].width) == 2)
        let sheet = PictureGalleryLayout.grid(count: 12, side: 180, available: 800)
        #expect(sheet.tiles[1].x - (sheet.tiles[0].x + sheet.tiles[0].width) == 2)
        #expect(sheet.tiles.last!.y - (sheet.tiles.first!.y + sheet.tiles.first!.height) == 2)
    }

    @Test func whatTheGridCannotShowIsCountedOnItsLastTile() {
        let many = PictureGalleryLayout.grid(count: 30, side: 180, available: 490)
        #expect(many.tiles.count + many.hidden == 30)
        #expect(many.hidden > 0)
        #expect(PictureGalleryReading.badge(hidden: many.hidden) == "+\(many.hidden)")
        #expect(PictureGalleryReading.badge(hidden: 0) == nil)
        #expect(PictureGalleryReading.badge(hidden: -3) == nil)
        let ruled = PictureGalleryLayout.grid(count: 40, side: 180, available: 1200)
        #expect(ruled.tiles.count <= PictureGalleryLayout.maximumColumns * 2)
    }

    @Test func theBlockIsOnePictureTallAtEveryWidthAndCount() {
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
            let sheet = PictureGalleryLayout.grid(count: 17, side: 180, available: width).snapped()
            let firstRow = sheet.tiles.filter { $0.y == sheet.tiles[0].y }
            let gaps = Set(zip(firstRow, firstRow.dropFirst()).map { $1.x - ($0.x + $0.width) })
            #expect(gaps.count <= 1, "\(width): \(gaps)")
            #expect(sheet.tiles.allSatisfy { $0.x == $0.x.rounded() && $0.width == $0.width.rounded() })
            #expect(sheet.width <= width + 0.5)
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
}

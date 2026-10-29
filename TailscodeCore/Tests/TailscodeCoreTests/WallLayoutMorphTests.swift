import Foundation
import Testing

@testable import TailscodeCore

@Suite struct WallLayoutMorphTests {
    private func layout(_ width: Double, _ height: Double, tiles: Int) -> (WallLayout, [String]) {
        let wall = WallFixtures.wall(sessions: tiles)
        let made = WallLayout.make(
            width: width, height: height, safe: .zero, fold: nil, wall: wall, style: .studio)
        return (made, wall.tiles.map(\.id))
    }

    @Test func aTurnGlidesEachTileFromWhereTheSameTileStood() {
        let (wide, ids) = layout(1376, 1032, tiles: 4)
        let (tall, idsTall) = layout(1032, 1376, tiles: 4)
        let start = tall.morphed(from: wide, oldIDs: ids, newIDs: idsTall, progress: 0)
        let end = tall.morphed(from: wide, oldIDs: ids, newIDs: idsTall, progress: 1)
        #expect(start.tiles == wide.tiles)
        #expect(end == tall)
        let half = tall.morphed(from: wide, oldIDs: ids, newIDs: idsTall, progress: 0.5)
        #expect(abs(half.tiles[0].x - (wide.tiles[0].x + tall.tiles[0].x) / 2) < 0.001)
    }

    @Test func aNewcomerGrowsFromItsOwnCentre() {
        let (three, ids) = layout(1376, 1032, tiles: 3)
        let (four, idsFour) = layout(1376, 1032, tiles: 4)
        let start = four.morphed(from: three, oldIDs: ids, newIDs: idsFour, progress: 0)
        let last = four.tiles[3]
        #expect(start.tiles[3].width == 0)
        #expect(abs(start.tiles[3].x - last.midX) < 0.001)
    }
}

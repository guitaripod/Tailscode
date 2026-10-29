import Foundation
import Testing

@testable import TailscodeCore

private struct Screen: CustomStringConvertible {
    let name: String
    let width: Double
    let height: Double
    let safe: WallInsets
    let fold: WallFold?
    let mode: WallLayout.Mode

    var description: String { name }
    var frame: WallRect {
        WallRect(
            x: safe.leading, y: safe.top, width: width - safe.leading - safe.trailing,
            height: height - safe.top - safe.bottom)
    }
}

private let vertical = WallFold(axis: .vertical, from: 455.5, to: 495.5)
private let horizontal = WallFold(axis: .horizontal, from: 455.5, to: 495.5)

private let screens: [Screen] = [
    Screen(name: "iPad landscape", width: 1376, height: 1032, safe: WallInsets(bottom: 20), fold: nil, mode: .stack),
    Screen(name: "iPad portrait", width: 1032, height: 1376, safe: WallInsets(bottom: 20), fold: nil, mode: .stack),
    Screen(name: "Duo wide", width: 951, height: 669, safe: WallInsets(trailing: 84), fold: nil, mode: .stack),
    Screen(name: "Duo tall", width: 669, height: 951, safe: WallInsets(top: 82, bottom: 34), fold: nil, mode: .stack),
    Screen(name: "Duo book", width: 951, height: 669, safe: .zero, fold: vertical, mode: .book),
    Screen(name: "Duo book with camera", width: 951, height: 669, safe: WallInsets(trailing: 84), fold: vertical, mode: .book),
    Screen(name: "Duo laptop", width: 669, height: 951, safe: .zero, fold: horizontal, mode: .laptop),
    Screen(name: "Duo laptop with safe", width: 669, height: 951, safe: WallInsets(top: 82, bottom: 34), fold: horizontal, mode: .laptop),
    Screen(name: "Duo closed", width: 466, height: 678, safe: WallInsets(top: 82, bottom: 34, trailing: 84), fold: nil, mode: .stack),
    Screen(name: "Duo tent", width: 678, height: 466, safe: WallInsets(bottom: 21, trailing: 84), fold: nil, mode: .side),
    Screen(name: "iPhone on a stand", width: 912, height: 420, safe: WallInsets(leading: 62, bottom: 21, trailing: 62), fold: nil, mode: .side),
    Screen(name: "display", width: 1920, height: 1080, safe: .zero, fold: nil, mode: .stack),
    Screen(name: "window", width: 760, height: 560, safe: .zero, fold: nil, mode: .stack),
]

private func layout(_ screen: Screen, tiles: Int, style: WallStyle = .studio) -> (WallLayout, AgentWall) {
    let reading = WallLayout.reading(
        width: screen.width, height: screen.height, safe: screen.safe, fold: screen.fold, style: style)
    let wall = WallFixtures.wall(sessions: tiles, crew: tiles == 0 ? 0 : 3, reading: reading)
    let made = WallLayout.make(
        width: screen.width, height: screen.height, safe: screen.safe, fold: screen.fold, wall: wall,
        style: style)
    return (made, wall)
}

private func inside(_ rect: WallRect, _ frame: WallRect) -> Bool {
    rect.x >= frame.x - 0.01 && rect.y >= frame.y - 0.01 && rect.maxX <= frame.maxX + 0.01
        && rect.maxY <= frame.maxY + 0.01
}

private func chrome(_ layout: WallLayout) -> [WallRect] {
    var out = [layout.headline, layout.watchLine, layout.clock, layout.date]
    out += [layout.ribbon, layout.recentRail, layout.listedRail, layout.controls].compactMap { $0 }
    return out
}

private func band(_ fold: WallFold, in screen: Screen) -> WallRect {
    switch fold.axis {
    case .vertical: return WallRect(x: fold.from, y: 0, width: fold.to - fold.from, height: screen.height)
    case .horizontal: return WallRect(x: 0, y: fold.from, width: screen.width, height: fold.to - fold.from)
    }
}

@Suite struct WallLayoutModeTests {
    @Test(arguments: screens) private func theModeFollowsTheScreen(_ screen: Screen) {
        let (made, _) = layout(screen, tiles: 3)
        #expect(made.mode == screen.mode)
        #expect(made.width == screen.width && made.height == screen.height)
        #expect(made.unit == max(1, min(screen.width, screen.height) / 100))
    }

    @Test func aFoldDecidesBeforeTheShape() {
        #expect(WallLayout.chooseMode(width: 951, height: 669, fold: vertical) == .book)
        #expect(WallLayout.chooseMode(width: 669, height: 951, fold: horizontal) == .laptop)
        #expect(WallLayout.chooseMode(width: 912, height: 420, fold: nil) == .side)
        #expect(WallLayout.chooseMode(width: 678, height: 466, fold: nil) == .side)
        #expect(WallLayout.chooseMode(width: 1920, height: 1080, fold: nil) == .stack)
        #expect(WallLayout.chooseMode(width: 760, height: 560, fold: nil) == .stack)
        #expect(WallLayout.chooseMode(width: 1000, height: 700, fold: nil) == .stack)
        #expect(WallLayout.chooseMode(width: 560, height: 420, fold: nil) == .stack)
        #expect(WallLayout.chooseMode(width: 951, height: 669, fold: WallFold(axis: .vertical, from: 500, to: 500)) == .stack)
    }

    @Test func typeScalesWithTheUnitAndNeverDropsBelowItsFloor() {
        let (made, _) = layout(screens[11], tiles: 2)
        #expect(abs(made.type(1.75) - 18.9) < 0.001)
        #expect(made.type(0.5) == 11)
        #expect(made.type(0.5, floor: 14) == 14)
    }
}

@Suite struct WallLayoutFitTests {
    @Test(arguments: screens) private func everythingStaysInsideTheSafeFrameAndTilesNeverOverlap(_ screen: Screen) {
        for count in 0...6 {
            let (made, wall) = layout(screen, tiles: count)
            #expect(made.tiles.count == wall.tiles.count && made.squads.count == wall.tiles.count)
            for rect in chrome(made) + made.tiles + [made.grid, made.centre, made.calmLine] {
                #expect(inside(rect, screen.frame), "\(screen) \(count): \(rect)")
            }
            for (index, cell) in made.tiles.enumerated() {
                #expect(cell.width > 0 && cell.height > 0, "\(screen) \(count): empty cell \(index)")
                for other in made.tiles.dropFirst(index + 1) {
                    #expect(!cell.intersects(other), "\(screen) \(count): \(cell) meets \(other)")
                }
                for text in chrome(made) {
                    #expect(!cell.intersects(text), "\(screen) \(count): \(cell) meets chrome \(text)")
                }
            }
        }
    }

    @Test(arguments: screens) private func squadsStayInsideTheirCell(_ screen: Screen) {
        for count in 1...6 {
            let (made, _) = layout(screen, tiles: count)
            for (cell, squad) in zip(made.tiles, made.squads) {
                guard let squad else { continue }
                for rect in [squad.parent] + squad.slots + [squad.more].compactMap({ $0 }) {
                    #expect(inside(rect, cell), "\(screen) \(count)")
                }
            }
        }
    }

    @Test(arguments: screens.filter { $0.fold != nil }) private func nothingSitsOnTheFold(_ screen: Screen) throws {
        let fold = try #require(screen.fold)
        let division = band(fold, in: screen)
        for count in 0...6 {
            let (made, _) = layout(screen, tiles: count)
            for rect in chrome(made) + made.tiles + [made.centre, made.calmLine] {
                #expect(!rect.intersects(division), "\(screen) \(count): \(rect)")
            }
            switch fold.axis {
            case .vertical:
                for cell in made.tiles { #expect(cell.maxX <= fold.from + 0.01 || cell.x >= fold.to - 0.01) }
            case .horizontal:
                for cell in made.tiles { #expect(cell.maxY <= fold.from + 0.01) }
            }
        }
    }

    @Test func aBookPutsColumnZeroOnTheLeftPageAndColumnOneOnTheRight() throws {
        let screen = screens[4]
        let (two, _) = layout(screen, tiles: 4)
        #expect(two.pages.count == 2)
        for cell in two.tiles.enumerated() {
            let page = two.pages[cell.offset % 2]
            #expect(cell.element.x == page.x && cell.element.width == page.width)
        }
        let (one, _) = layout(screen, tiles: 1)
        #expect(one.tiles.count == 1 && one.tiles[0].x == one.pages[0].x)
        #expect(one.recentRail?.x == one.pages[1].x)
        #expect(one.ribbon?.x == one.pages[0].x)
        #expect(one.listedRail == nil && one.clockAlignment == .trailing)
        #expect(one.clock.maxX <= one.pages[1].maxX + 0.01 && one.clock.x >= one.pages[1].x)
    }

    @Test func aLaptopKeepsTheBaseBelowTheFoldWithAFortyEightPointControlBand() throws {
        let screen = screens[6]
        let (made, _) = layout(screen, tiles: 2)
        let controls = try #require(made.controls)
        #expect(controls.height == 48 && controls.y > 495.5)
        #expect(made.clockAlignment == .leading)
        #expect(made.clock.y > 495.5 && made.headline.y > 495.5)
        #expect(made.headline.x >= made.clock.maxX - 0.01)
        #expect(made.grid.maxY <= 455.5)
        for other in screens where other.mode != .laptop { #expect(layout(other, tiles: 1).0.controls == nil) }
    }

    @Test func aSideColumnHoldsTheClockAndHeadlineBesideTheGrid() {
        let (made, _) = layout(screens[10], tiles: 3)
        #expect(made.mode == .side && made.clockAlignment == .leading)
        #expect(made.recentRail == nil && made.listedRail == nil)
        #expect(made.headlineLines == 3)
        #expect(made.grid.x > made.headline.maxX)
        #expect(made.clock.width >= 170 && made.clock.width <= 330)
    }
}

@Suite struct WallLayoutStackTests {
    @Test func theDisplayMatchesTheLinuxGeometry() {
        let screen = screens[11]
        let (made, wall) = layout(screen, tiles: 3)
        let u = 10.8
        let margin = 3 * u
        func near(_ rect: WallRect, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Bool {
            abs(rect.x - x) < 0.5 && abs(rect.y - y) < 0.5 && abs(rect.width - w) < 0.5 && abs(rect.height - h) < 0.5
        }
        let clockWidth = 30 * u
        let headlineWidth = 1920 - 2 * margin - clockWidth - 2 * u
        #expect(near(made.headline, margin, 2.4 * u, headlineWidth, 14 * u - 4.2 * u))
        #expect(near(made.watchLine, margin, 2.4 * u + 14 * u - 4.2 * u + 0.2 * u, headlineWidth, 3 * u))
        let clockX = 1920 - margin - clockWidth
        #expect(near(made.clock, clockX, 2.4 * u, clockWidth, 8.4 * u))
        #expect(near(made.date, clockX, 2.4 * u + 8.4 * u + 0.2 * u, clockWidth, 3 * u))
        let bottom = 1080 - 1.8 * u
        let rail = bottom - 4.4 * u
        let ribbonY = rail - 0.8 * u - 8.8 * u
        #expect(near(made.ribbon ?? .zero, margin, ribbonY, 1920 - 2 * margin, 8.8 * u))
        let railWidth = 1920 - 2 * margin
        #expect(near(made.recentRail ?? .zero, margin, rail, railWidth * 0.56 - u, 4.4 * u))
        #expect(near(made.listedRail ?? .zero, margin + railWidth * 0.56, rail, railWidth * 0.44, 4.4 * u))
        let gridTop = 2.4 * u + 14 * u - 4.2 * u + 0.2 * u + 3 * u + 1.6 * u
        let gridBottom = ribbonY - 1.4 * u
        #expect(near(made.grid, margin, gridTop, 1920 - 2 * margin, gridBottom - gridTop))
        let side = min(made.grid.width, made.grid.height) * 0.62
        #expect(near(made.centre, made.grid.midX - side / 2, made.grid.midY - side / 2, side, side))
        #expect(made.headlineLines == 1 && made.watchLines == 1 && made.clockAlignment == .trailing)
        #expect(wall.tiles.count == 3 && made.tiles.count == 3)
        let gutter = 1.2 * u
        let cellWidth = (made.grid.width - 2 * gutter) / 3
        #expect(near(made.tiles[1], made.grid.x + cellWidth + gutter, made.grid.y, cellWidth, made.grid.height))
    }

    @Test func aPortraitScreenSetsTheHeadlineOnTwoLines() {
        #expect(layout(screens[1], tiles: 2).0.headlineLines == 2)
        #expect(layout(screens[0], tiles: 2).0.headlineLines == 1)
    }

    @Test func aCalmEmptyWallGivesTheHourItsBigRibbon() {
        let (calm, _) = layout(screens[11], tiles: 0)
        let (busy, _) = layout(screens[11], tiles: 1)
        #expect(abs((calm.ribbon?.height ?? 0) - 14 * 10.8) < 0.01)
        #expect(abs((busy.ribbon?.height ?? 0) - 8.8 * 10.8) < 0.01)
    }

    @Test func hidingTheHourOrTheRailsGivesTheirRoomToTheGrid() {
        let screen = screens[11]
        let (full, _) = layout(screen, tiles: 2)
        var noHour = WallStyle.studio
        noHour.showsHour = false
        let (withoutHour, _) = layout(screen, tiles: 2, style: noHour)
        #expect(withoutHour.ribbon == nil && withoutHour.recentRail != nil)
        #expect(withoutHour.grid.height > full.grid.height + 8 * 10.8)
        var noRails = WallStyle.studio
        noRails.showsRails = false
        let (withoutRails, _) = layout(screen, tiles: 2, style: noRails)
        #expect(withoutRails.recentRail == nil && withoutRails.listedRail == nil && withoutRails.ribbon != nil)
        #expect(withoutRails.grid.height > full.grid.height + 4 * 10.8)
        var bare = noHour
        bare.showsRails = false
        let (neither, _) = layout(screen, tiles: 2, style: bare)
        #expect(neither.grid.height > withoutHour.grid.height && neither.grid.height > withoutRails.grid.height)
        #expect(inside(neither.grid, screen.frame))
    }

    @Test func hidingTheClockGivesItsWidthToTheHeadline() {
        var style = WallStyle.studio
        style.showsClock = false
        let (full, _) = layout(screens[11], tiles: 2)
        let (without, _) = layout(screens[11], tiles: 2, style: style)
        #expect(without.clock.width == 0 && without.date.width == 0)
        #expect(without.headline.width > full.headline.width + 30 * 10.8)
    }

    @Test func theChromeDriftsAndTheGridStays() {
        let screen = screens[11]
        let wall = WallFixtures.wall(sessions: 2)
        let still = WallLayout.make(
            width: screen.width, height: screen.height, safe: .zero, fold: nil, wall: wall, style: .studio)
        let drifted = WallLayout.make(
            width: screen.width, height: screen.height, safe: .zero, fold: nil, wall: wall, style: .studio,
            drift: (3, -2))
        #expect(abs(drifted.headline.x - still.headline.x - 3) < 0.001)
        #expect(abs(drifted.headline.y - still.headline.y + 2) < 0.001)
        #expect(drifted.grid.x == still.grid.x)
    }

    @Test func aSessionWithWorkersGetsSquadRectsUnlessSquadsAreOff() {
        let screen = screens[11]
        let (made, _) = layout(screen, tiles: 1)
        let squad = made.squads[0]
        #expect(squad != nil && squad?.slots.count == 3)
        var style = WallStyle.studio
        style.showsSquads = false
        let (without, _) = layout(screen, tiles: 1, style: style)
        #expect(without.squads == [nil])
    }

    @Test func aSingleTileFillsTheGrid() {
        let (made, _) = layout(screens[11], tiles: 1)
        #expect(made.tiles[0] == made.grid)
    }
}

@Suite struct WallLayoutReadingTests {
    @Test func aStackReadsWithTheScreensShapeAndTheGridsOwn() {
        let reading = WallLayout.reading(width: 1920, height: 1080, safe: .zero, fold: nil, style: .studio)
        #expect(abs(reading.aspect - 16.0 / 9.0) < 0.0001 && !reading.pages)
        #expect(reading.gridAspect > 1 && reading.gridAspect != reading.aspect)
    }

    @Test func aSideAndALaptopReadWithTheGridAreasShape() {
        for screen in [screens[10], screens[6]] {
            let reading = WallLayout.reading(
                width: screen.width, height: screen.height, safe: screen.safe, fold: screen.fold, style: .studio)
            let (made, _) = layout(screen, tiles: 3)
            #expect(abs(reading.aspect - made.grid.width / made.grid.height) < 0.0001)
            #expect(reading.aspect == reading.gridAspect && !reading.pages)
        }
    }

    @Test func aBookReadsInPages() {
        let reading = WallLayout.reading(width: 951, height: 669, safe: .zero, fold: vertical, style: .studio)
        #expect(reading.pages)
        let wall = WallFixtures.wall(sessions: 4, reading: reading)
        #expect(wall.columns == 2 && wall.rows == 2 && wall.tiles.allSatisfy { $0.span == 1 })
    }
}

import Testing

@testable import TailscodeCore

@Suite struct HandReachTests {
    @Test func uprightTabletIsHeldTheOrdinaryWay() {
        let reach = HandReach.read(windowX: 0, windowWidth: 834, screenWidth: 834, screenHeight: 1194)
        #expect(reach == .ordinary)
    }

    @Test func phoneOnItsSideIsCrossedByEitherThumb() {
        let reach = HandReach.read(windowX: 0, windowWidth: 956, screenWidth: 956, screenHeight: 440)
        #expect(reach == .ordinary)
    }

    @Test func fullScreenTabletOnItsSideReachesBothEdges() {
        let reach = HandReach.read(windowX: 0, windowWidth: 1194, screenWidth: 1194, screenHeight: 834)
        #expect(reach.isTwoThumbs)
        #expect(reach.reachesLeading)
        #expect(reach.reachesTrailing)
        #expect(reach.outerSide == .trailing)
    }

    @Test func windowOnTheLeftOfASplitIsReachedByTheLeftThumb() {
        let reach = HandReach.read(windowX: 0, windowWidth: 834, screenWidth: 1194, screenHeight: 834)
        #expect(reach.isTwoThumbs)
        #expect(reach.reachesLeading)
        #expect(!reach.reachesTrailing)
        #expect(reach.outerSide == .leading)
    }

    @Test func windowOnTheRightOfASplitIsReachedByTheRightThumb() {
        let reach = HandReach.read(windowX: 819, windowWidth: 375, screenWidth: 1194, screenHeight: 834)
        #expect(!reach.reachesLeading)
        #expect(reach.reachesTrailing)
        #expect(reach.outerSide == .trailing)
    }

    @Test func tiledWindowKeepsItsMarginFromTheGlass() {
        let reach = HandReach.read(windowX: 8, windowWidth: 580, screenWidth: 1194, screenHeight: 834)
        #expect(reach.reachesLeading)
        #expect(reach.outerSide == .leading)
    }

    @Test func floatingWindowTouchesNeitherEdge() {
        let reach = HandReach.read(windowX: 200, windowWidth: 700, screenWidth: 1194, screenHeight: 834)
        #expect(reach.isTwoThumbs)
        #expect(!reach.reachesLeading)
        #expect(!reach.reachesTrailing)
        #expect(reach.outerSide == .trailing)
    }

    @Test func rightToLeftTurnsTheSides() {
        let reach = HandReach.read(
            windowX: 0, windowWidth: 834, screenWidth: 1194, screenHeight: 834, rightToLeft: true)
        #expect(!reach.reachesLeading)
        #expect(reach.reachesTrailing)
        #expect(reach.outerSide == .trailing)
        let right = HandReach.read(
            windowX: 819, windowWidth: 375, screenWidth: 1194, screenHeight: 834, rightToLeft: true)
        #expect(right.outerSide == .leading)
    }
}

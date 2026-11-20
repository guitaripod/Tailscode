import Testing

@testable import TailscodeCore

@Suite struct HandReachTests {
    @Test func uprightTabletIsATabletButNotTwoThumbs() {
        let reach = HandReach.read(windowX: 0, windowWidth: 834, screenWidth: 834, screenHeight: 1194)
        #expect(reach.hold == .upright)
        #expect(reach.isTablet)
        #expect(!reach.isTwoThumbs)
        #expect(reach.reachesLeading)
        #expect(reach.reachesTrailing)
    }

    @Test func miniIsATabletEitherWay() {
        let sideways = HandReach.read(windowX: 0, windowWidth: 1158, screenWidth: 1158, screenHeight: 756)
        #expect(sideways.isTwoThumbs)
        let upright = HandReach.read(windowX: 0, windowWidth: 756, screenWidth: 756, screenHeight: 1158)
        #expect(upright.hold == .upright)
        let halfUpright = HandReach.read(windowX: 381, windowWidth: 375, screenWidth: 756, screenHeight: 1158)
        #expect(!halfUpright.reachesLeading)
        #expect(halfUpright.reachesTrailing)
    }

    @Test func phoneUprightAndFoldingPhoneOpenAreOrdinary() {
        #expect(HandReach.read(windowX: 0, windowWidth: 402, screenWidth: 402, screenHeight: 874) == .ordinary)
        #expect(HandReach.read(windowX: 0, windowWidth: 951, screenWidth: 951, screenHeight: 669) == .ordinary)
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

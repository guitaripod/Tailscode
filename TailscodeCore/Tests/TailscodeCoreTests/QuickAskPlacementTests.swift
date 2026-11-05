import Foundation
import Testing

@testable import TailscodeCore

extension DeviceStores {
    @Suite("Quick ask placement", .serialized)
    struct QuickAskPlacementTests {
        @Test("First run is a palette's size and place: centred across, a little above the middle")
        func firstRun() {
            let empty = QuickAskPlacement()
            let size = QuickAskGeometry.size(empty, screenWidth: 2560, screenHeight: 1440)
            #expect(size.width == 680 && size.height == 600)
            let origin = QuickAskGeometry.origin(
                empty, screen: "DP-1", screenWidth: 2560, screenHeight: 1440, width: size.width,
                height: size.height)
            #expect(origin.x == (2560 - 680) / 2 && origin.y == (1440 * 0.18).rounded(.down) || origin.y == 1440 * 0.18)
            let small = QuickAskGeometry.size(empty, screenWidth: 1280, screenHeight: 600)
            #expect(small.height == 420)
        }

        @Test("A remembered size is kept, and clamped into a smaller screen and above the minimum")
        func sizeClamps() {
            let placement = QuickAskPlacement(width: 2000, height: 100)
            let size = QuickAskGeometry.size(placement, screenWidth: 1920, screenHeight: 1080)
            #expect(size.width == 1920 - 16 && size.height == QuickAskGeometry.minimumHeight)
        }

        @Test("Each screen keeps its own place; a new screen gets the last place at the same share")
        func spots() {
            var placement = QuickAskPlacement()
            placement.spots["HDMI-A-1"] = .init(x: 1000, y: 200, screenWidth: 2000, screenHeight: 1000)
            placement.spots["eDP-1"] = .init(x: 40, y: 40, screenWidth: 1440, screenHeight: 900)
            placement.lastScreen = "HDMI-A-1"
            let own = QuickAskGeometry.origin(
                placement, screen: "eDP-1", screenWidth: 1440, screenHeight: 900, width: 600, height: 400)
            #expect(own.x == 40 && own.y == 40)
            let carried = QuickAskGeometry.origin(
                placement, screen: "DP-3", screenWidth: 4000, screenHeight: 2000, width: 600, height: 400)
            #expect(carried.x == 2000 && carried.y == 400)
            let clamped = QuickAskGeometry.origin(
                placement, screen: "HDMI-A-1", screenWidth: 1200, screenHeight: 500, width: 600, height: 400)
            #expect(clamped.x == 1200 - 600 - 8 && clamped.y == 500 - 400 - 8)
        }

        @Test("It opens with the head of the question box under the pointer, slid in from an edge")
        func pointer() {
            let anchor = (x: 28.0, y: 34.0)
            let middle = QuickAskGeometry.origin(
                pointer: (x: 900, y: 500), anchor: anchor, screenWidth: 2560, screenHeight: 1440,
                width: 680, height: 600)
            #expect(middle.x == 872 && middle.y == 466)
            let corner = QuickAskGeometry.origin(
                pointer: (x: 2550, y: 1430), anchor: anchor, screenWidth: 2560, screenHeight: 1440,
                width: 680, height: 600)
            #expect(corner.x == 2560 - 680 - 8 && corner.y == 1440 - 600 - 8)
            let top = QuickAskGeometry.origin(
                pointer: (x: 3, y: 2), anchor: anchor, screenWidth: 2560, screenHeight: 1440,
                width: 680, height: 600)
            #expect(top.x == 8 && top.y == 8)
            let cramped = QuickAskGeometry.origin(
                pointer: (x: 300, y: 200), anchor: anchor, screenWidth: 600, screenHeight: 400,
                width: 680, height: 600)
            #expect(cramped.x == 8 && cramped.y == 8)
        }

        @Test("The border is held by edge and corner, never away from it")
        func edges() {
            #expect(QuickAskGeometry.edges(atX: 2, y: 300, width: 600, height: 500) == .left)
            #expect(QuickAskGeometry.edges(atX: -4, y: 300, width: 600, height: 500) == .left)
            #expect(QuickAskGeometry.edges(atX: 598, y: 497, width: 600, height: 500) == [.right, .bottom])
            #expect(QuickAskGeometry.edges(atX: 603, y: 503, width: 600, height: 500) == [.right, .bottom])
            #expect(QuickAskGeometry.edges(atX: 590, y: 502, width: 600, height: 500) == [.right, .bottom])
            #expect(QuickAskGeometry.edges(atX: 2, y: 10, width: 600, height: 500) == [.left, .top])
            #expect(QuickAskGeometry.edges(atX: 300, y: 250, width: 600, height: 500).isEmpty)
            #expect(QuickAskGeometry.edges(atX: -20, y: 250, width: 600, height: 500).isEmpty)
            #expect(QuickAskGeometry.edges(atX: 300, y: 520, width: 600, height: 500).isEmpty)
            #expect(QuickAskEdges([.left, .top]).cursor == "nwse-resize")
            #expect(QuickAskEdges([.right, .top]).cursor == "nesw-resize")
            #expect(QuickAskEdges.bottom.cursor == "ns-resize")
        }

        @Test("A drag of the border moves only the held edges and keeps the minimum and the screen")
        func resize() {
            let frame = QuickAskRect(x: 100, y: 100, width: 600, height: 500)
            let wider = QuickAskGeometry.resized(frame, edges: .right, dx: 120, dy: 0, screenWidth: 1920, screenHeight: 1080)
            #expect(wider == QuickAskRect(x: 100, y: 100, width: 720, height: 500))
            let fromLeft = QuickAskGeometry.resized(frame, edges: .left, dx: -50, dy: 0, screenWidth: 1920, screenHeight: 1080)
            #expect(fromLeft == QuickAskRect(x: 50, y: 100, width: 650, height: 500))
            let squashed = QuickAskGeometry.resized(frame, edges: [.top], dx: 0, dy: 400, screenWidth: 1920, screenHeight: 1080)
            #expect(squashed.height == QuickAskGeometry.minimumHeight && squashed.y + squashed.height == 600)
            let past = QuickAskGeometry.resized(frame, edges: [.right, .bottom], dx: 5000, dy: 5000, screenWidth: 1920, screenHeight: 1080)
            #expect(past.x + past.width == 1912 && past.y + past.height == 1072)
        }

        @Test("The placement round-trips through the device's store")
        func store() {
            let kept = UserDefaults.standard.string(forKey: QuickAskPlacementStore.key)
            defer {
                if let kept { UserDefaults.standard.set(kept, forKey: QuickAskPlacementStore.key) } else {
                    QuickAskPlacementStore.clear()
                }
            }
            QuickAskPlacementStore.clear()
            QuickAskPlacementStore.recordSize(width: 720.4, height: 512.6)
            QuickAskPlacementStore.recordSpot(x: 10.2, y: 20.7, screen: "DP-2", screenWidth: 2560, screenHeight: 1440)
            let read = QuickAskPlacementStore.load()
            #expect(read.width == 720 && read.height == 513)
            #expect(read.spots["DP-2"] == .init(x: 10, y: 21, screenWidth: 2560, screenHeight: 1440))
            #expect(read.lastScreen == "DP-2")
        }
    }
}

import Foundation
import Testing

@testable import TailscodeCore

/// The tiling tree is the one place all three clients agree on what splits mean, so its verbs
/// are pinned here as behavior: geometry, focus travel, collapse rules, and the persisted shape.
@Suite("Split layout")
struct SplitLayoutTests {

    @Test("A split makes a sibling and moves focus to it")
    func splitCreatesSiblingAndFocuses() {
        var layout = SplitLayout()
        let original = layout.focusedPane
        let fresh = layout.split(original, axis: .horizontal)

        #expect(fresh != nil)
        #expect(layout.paneCount == 2)
        #expect(layout.focusedPane == fresh)
        #expect(layout.paneIDs.first == original)
    }

    @Test("Closing a pane hands its space to the sibling and focus to the last-used pane")
    func closeCollapsesAndFocusReturnsToMostRecent() {
        var layout = SplitLayout()
        let a = layout.focusedPane
        let b = layout.split(a, axis: .horizontal)!
        let c = layout.split(b, axis: .vertical)!
        layout.focus(a)
        layout.focus(c)

        let survivor = layout.close(c)

        #expect(survivor == a)
        #expect(layout.paneCount == 2)
        #expect(layout.focusedPane == a)
        #expect(layout.frames()[b]?.width == 0.5)
    }

    @Test("The last pane refuses to close")
    func lastPaneRefusesToClose() {
        var layout = SplitLayout()
        #expect(layout.close(layout.focusedPane) == nil)
        #expect(layout.paneCount == 1)
    }

    @Test("Frames tile the unit square exactly")
    func framesTileTheUnitSquare() {
        var layout = SplitLayout()
        let a = layout.focusedPane
        let b = layout.split(a, axis: .horizontal)!
        let c = layout.split(b, axis: .vertical)!
        layout.split(c, axis: .horizontal)

        let frames = layout.frames()
        let area = frames.values.reduce(0.0) { $0 + $1.width * $1.height }

        #expect(frames.count == 4)
        #expect(abs(area - 1.0) < 1e-9)
        for frame in frames.values {
            #expect(frame.x >= 0 && frame.maxX <= 1.0 + 1e-9)
            #expect(frame.y >= 0 && frame.maxY <= 1.0 + 1e-9)
            #expect(frame.width > 0 && frame.height > 0)
        }
    }

    @Test("Directional focus crosses the geometry, not the tree")
    func neighborNavigationFollowsGeometry() {
        var layout = SplitLayout()
        let a = layout.focusedPane
        let b = layout.split(a, axis: .horizontal)!
        let c = layout.split(b, axis: .vertical)!

        #expect(layout.neighbor(of: a, direction: .right) != nil)
        #expect(layout.neighbor(of: b, direction: .left) == a)
        #expect(layout.neighbor(of: c, direction: .left) == a)
        #expect(layout.neighbor(of: b, direction: .down) == c)
        #expect(layout.neighbor(of: c, direction: .up) == b)
        #expect(layout.neighbor(of: a, direction: .left) == nil)
        #expect(layout.neighbor(of: b, direction: .up) == nil)

        layout.focus(a)
        let movedRight = layout.focusNeighbor(.right)
        #expect(movedRight)
        #expect(layout.focusedPane == b || layout.focusedPane == c)
        layout.focus(a)
        let movedLeft = layout.focusNeighbor(.left)
        #expect(!movedLeft)
    }

    @Test("Ratios clamp to something a divider can sit at")
    func ratioClamps() {
        var layout = SplitLayout()
        let a = layout.focusedPane
        layout.split(a, axis: .horizontal)
        guard case .split(let id, _, _, _, _) = layout.root else {
            Issue.record("a split root was expected")
            return
        }

        layout.setRatio(0.0, of: id)
        #expect(layout.ratio(of: id) == 0.05)
        layout.setRatio(2.0, of: id)
        #expect(layout.ratio(of: id) == 0.95)
        layout.setRatio(0.3, of: id)
        #expect(layout.ratio(of: id) == 0.3)
    }

    @Test("Equalize gives a row of panes a third each")
    func equalizeSharesRowEvenly() {
        var layout = SplitLayout()
        let a = layout.focusedPane
        let b = layout.split(a, axis: .horizontal)!
        layout.split(b, axis: .horizontal)

        layout.equalize()
        let widths = layout.paneIDs.compactMap { layout.frames()[$0]?.width }

        #expect(widths.count == 3)
        for width in widths { #expect(abs(width - 1.0 / 3.0) < 1e-9) }
    }

    @Test("Equalize keeps half the window for a pane beside a stack")
    func equalizePaneBesideStackKeepsHalf() {
        var layout = SplitLayout()
        let a = layout.focusedPane
        let b = layout.split(a, axis: .horizontal)!
        layout.split(b, axis: .vertical)

        layout.equalize()
        let frames = layout.frames()

        #expect(abs(frames[a]!.width - 0.5) < 1e-9)
        #expect(abs(frames[a]!.height - 1.0) < 1e-9)
        let stacked = layout.paneIDs.filter { $0 != a }
        for id in stacked {
            #expect(abs(frames[id]!.width - 0.5) < 1e-9)
            #expect(abs(frames[id]!.height - 0.5) < 1e-9)
        }
    }

    @Test("Equalize squares up a two-by-two grid")
    func equalizeSquaresGrid() {
        var layout = SplitLayout()
        let a = layout.focusedPane
        let b = layout.split(a, axis: .horizontal)!
        layout.split(a, axis: .vertical)
        layout.split(b, axis: .vertical)
        guard case .split(let rootID, _, _, _, _) = layout.root else {
            Issue.record("a split root was expected")
            return
        }
        layout.setRatio(0.8, of: rootID)

        layout.equalize()
        let frames = layout.frames()

        for id in layout.paneIDs {
            #expect(abs(frames[id]!.width - 0.5) < 1e-9)
            #expect(abs(frames[id]!.height - 0.5) < 1e-9)
        }
    }

    @Test("Zoom toggles and any structural change clears it")
    func zoomTogglesAndClears() {
        var layout = SplitLayout()
        let a = layout.focusedPane
        let b = layout.split(a, axis: .horizontal)!

        layout.toggleZoom(b)
        #expect(layout.zoomedPane == b)
        layout.toggleZoom(b)
        #expect(layout.zoomedPane == nil)

        layout.toggleZoom(b)
        layout.split(b, axis: .vertical)
        #expect(layout.zoomedPane == nil)

        layout.toggleZoom(layout.focusedPane)
        _ = layout.focusNeighbor(.up)
        #expect(layout.zoomedPane == nil)
    }

    @Test("Exchange swaps a pane with its sibling in place")
    func exchangeSwapsSiblings() {
        var layout = SplitLayout()
        let a = layout.focusedPane
        let b = layout.split(a, axis: .horizontal)!

        #expect(layout.paneIDs == [a, b])
        layout.exchange(a)
        #expect(layout.paneIDs == [b, a])
        #expect(layout.frames()[b]?.x == 0)
    }

    @Test("A snapshot survives the round trip and its key has not moved")
    func snapshotRoundTripsAndKeyIsPinned() throws {
        var layout = SplitLayout()
        let a = layout.focusedPane
        let b = layout.split(a, axis: .horizontal)!
        layout.split(b, axis: .vertical)
        let snapshot = SplitSnapshot(
            layout: layout,
            sessions: [a.raw: SplitPaneSession(profileID: "p1", sessionID: "s1")])

        let encoded = try #require(snapshot.encoded)
        let decoded = try #require(SplitSnapshot.decode(encoded))

        #expect(decoded == snapshot)
        #expect(decoded.session(for: a)?.sessionID == "s1")
        #expect(decoded.session(for: b) == nil)
        #expect(SplitSnapshot.defaultsKey == "tailscode.layout.tree")
    }

    @Test("A broken snapshot is refused whole")
    func brokenSnapshotIsRefused() {
        #expect(SplitSnapshot.decode("not json") == nil)
        #expect(SplitSnapshot.decode("{\"layout\":{},\"sessions\":{}}") == nil)
    }

    @Test("The split verbs are in the registry with the vim vocabulary")
    func splitShortcutsAreRegistered() {
        let set = ShortcutSet.build(overrides: [:])
        #expect(set.issues.isEmpty)
        let ids = Set(ShortcutRegistry.all.map(\.id))
        for id in [
            "split.right", "split.down", "split.close", "split.zoom", "split.exchange",
            "split.equalize", "split.focusLeft", "split.focusDown", "split.focusUp",
            "split.focusRight",
        ] {
            #expect(ids.contains(id))
        }
        let prefix = KeySpec.parse("ctrl+w v")
        #expect(prefix?.chords.count == 2)
        let token = prefix!.chords[0].token
        #expect(set.prefixes[.normal]?.contains(token) == true)
    }
}

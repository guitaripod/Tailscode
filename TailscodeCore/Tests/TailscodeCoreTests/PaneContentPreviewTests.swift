import Foundation
import Testing

@testable import TailscodeCore

@Suite("Preview pane content")
struct PaneContentPreviewTests {

    private let target = PreviewTarget(host: "studio", project: "/Users/me/My Apps/Notes")

    private func decode(_ json: String) throws -> PaneContent {
        try JSONDecoder().decode(PaneContent.self, from: Data(json.utf8))
    }

    @Test("A preview pane has its own kind")
    func kind() {
        #expect(PaneContent.preview(target.address).kind == .preview)
        #expect(PaneKind.allCases.contains(.preview))
    }

    @Test("A preview pane survives encoding and decoding")
    func codableRoundTrip() throws {
        let content = PaneContent.preview(target.address)
        let data = try JSONEncoder().encode(content)
        #expect(try JSONDecoder().decode(PaneContent.self, from: data) == content)
    }

    @Test("An address nobody can read decodes as an empty pane")
    func garbageIsEmpty() throws {
        #expect(try decode(#"{"kind":"preview","address":"garbage"}"#) == .empty)
        #expect(try decode(#"{"kind":"preview","address":"https://example.com"}"#) == .empty)
        #expect(try decode(#"{"kind":"preview","address":"preview://studio:4300/"}"#) == .empty)
        #expect(try decode(#"{"kind":"preview"}"#) == .empty)
    }

    @Test("A preview pane stays one kind of pane and does not become a page")
    func kindsStayApart() throws {
        let address = target.address
        let data = Data(#"{"kind":"web","address":"\#(address)"}"#.utf8)
        #expect(try JSONDecoder().decode(PaneContent.self, from: data).kind == .web)
    }

    @Test("The snapshot hands back the app and the Mac a pane was pointed at")
    func snapshotAccessor() throws {
        let layout = try #require(SplitEven.layout(count: 4, as: .grid))
        let ids = layout.paneIDs
        let snapshot = SplitSnapshot(
            layout: layout,
            contents: [
                ids[0].raw: .preview(target.address),
                ids[1].raw: .web("https://example.com"),
            ])
        #expect(snapshot.preview(for: ids[0]) == target)
        #expect(snapshot.preview(for: ids[1]) == nil)
        #expect(snapshot.content(for: ids[0]) == .preview(target.address))
    }

    @Test("A snapshot with a preview pane encodes, decodes and restores the same app")
    func snapshotRoundTrip() throws {
        let layout = try #require(SplitEven.layout(count: 4, as: .grid))
        let ids = layout.paneIDs
        let snapshot = SplitSnapshot(
            layout: layout, contents: [ids[1].raw: .preview(target.address)])
        let text = try #require(snapshot.encoded)
        let restored = try #require(SplitSnapshot.decode(text))
        #expect(restored.preview(for: ids[1]) == target)
        #expect(restored.preview(for: ids[0]) == nil)
    }

    @Test("A preview pane is as small as a video pane may get")
    func sizing() {
        #expect(
            PaneSizing.minimum(kind: .preview, density: .full)
                == PaneSizing.minimum(kind: .video, density: .full))
        #expect(
            PaneSizing.layoutMinimum(kind: .preview) == PaneSizing.layoutMinimum(kind: .video))
    }

    @Test("A preview owns a stream, so a hidden or second one is parked")
    func streamsAreParked() {
        #expect(PaneKind.preview.ownsStream)
        #expect(PaneKind.video.ownsStream)
        #expect(!PaneKind.draw.ownsStream)
        #expect(!PaneKind.chat.ownsStream)
    }
}

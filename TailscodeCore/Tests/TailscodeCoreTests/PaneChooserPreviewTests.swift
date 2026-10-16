import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Pane chooser preview rows")
struct PaneChooserPreviewTests {

    private let alpha = PaneChooserServer(
        profileID: "a", name: "alpha", backend: .claudeCode, address: "100.0.0.1:4098")
    private let beta = PaneChooserServer(
        profileID: "b", name: "beta", backend: .openCode, address: "100.0.0.2:4096")

    private func previewRows(_ chooser: PaneChooser) -> [PaneChooserRow] {
        chooser.rows.filter {
            if case .preview = $0.action { return true }
            return false
        }
    }

    @Test("A chooser offers no preview until a client opens the gate")
    func gateClosedByDefault() {
        var chooser = PaneChooser(servers: [alpha], entries: [])
        chooser.previewHosts = [PreviewAccess(host: "studio")]
        #expect(!chooser.offersPreview)
        #expect(previewRows(chooser).isEmpty)

        var two = PaneChooser(servers: [alpha, beta], entries: [])
        two.previewHosts = [PreviewAccess(host: "studio")]
        #expect(previewRows(two).isEmpty)
    }

    @Test("With the gate open and no Mac known, one row sets one up")
    func addMacRow() {
        var chooser = PaneChooser(servers: [alpha], entries: [])
        chooser.offersPreview = true
        let rows = previewRows(chooser)
        #expect(rows.count == 1)
        #expect(rows[0].action == .preview(.addMac))
        #expect(rows[0].title == "Preview an app on a Mac")
    }

    @Test("With the gate open, each known Mac is a row of its own")
    func rowPerMac() {
        var chooser = PaneChooser(servers: [alpha], entries: [])
        chooser.offersPreview = true
        chooser.previewHosts = [
            PreviewAccess(host: "studio", name: "Studio"), PreviewAccess(host: "mini"),
        ]
        let rows = previewRows(chooser)
        #expect(rows.map(\.action) == [.preview(.app(host: "studio")), .preview(.app(host: "mini"))])
        #expect(rows.map(\.title) == ["Preview an app on Studio", "Preview an app on mini"])
        #expect(!rows.contains { $0.action == .preview(.addMac) })
    }

    @Test("The rows come after the ones a pane could already hold")
    func order() {
        var chooser = PaneChooser(servers: [alpha], entries: [])
        chooser.offersPreview = true
        chooser.previewHosts = [PreviewAccess(host: "studio")]
        let actions = chooser.rows.map(\.action)
        #expect(actions.last == .preview(.app(host: "studio")))
        let draw = actions.firstIndex(of: .draw)
        let preview = actions.firstIndex(of: .preview(.app(host: "studio")))
        #expect(draw != nil && preview != nil && draw! < preview!)
    }

    @Test("Two servers offer the rows on the server step too")
    func serverStep() {
        var chooser = PaneChooser(servers: [alpha, beta], entries: [])
        chooser.offersPreview = true
        #expect(previewRows(chooser).count == 1)
        chooser.previewHosts = [PreviewAccess(host: "studio"), PreviewAccess(host: "mini")]
        #expect(previewRows(chooser).count == 2)
    }

    @Test("Choosing a preview row is an outcome for the pane, not a step")
    func activation() {
        var chooser = PaneChooser(servers: [alpha], entries: [])
        chooser.offersPreview = true
        chooser.previewHosts = [PreviewAccess(host: "studio")]
        let index = chooser.rows.firstIndex { $0.action == .preview(.app(host: "studio")) }
        #expect(index != nil)
        let result = chooser.handle(.pick(index!))
        #expect(result.handled)
        #expect(result.action == .preview(.app(host: "studio")))
    }

    @Test("A fresh listing keeps the gate and the Macs")
    func restatedKeepsThem() {
        var chooser = PaneChooser(servers: [alpha], entries: [])
        chooser.offersPreview = true
        chooser.previewHosts = [PreviewAccess(host: "studio")]
        let next = chooser.restated(servers: [alpha, beta], entries: [])
        #expect(next.offersPreview)
        #expect(next.previewHosts.map(\.host) == ["studio"])
        #expect(previewRows(next).count == 1)

        var closed = PaneChooser(servers: [alpha], entries: [])
        closed.previewHosts = [PreviewAccess(host: "studio")]
        #expect(previewRows(closed.restated(servers: [alpha], entries: [])).isEmpty)
    }

    @Test("The shared chooser check still passes with the gate closed")
    func sharedCheck() {
        #expect(PaneChooserCheck.run().isEmpty)
    }
}

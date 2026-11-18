import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The quick ask is a surface over the desktop rather than a window of the app: the style mask,
    /// the level and the collection behaviour are what let it answer over the program somebody is
    /// working in, on the Space they are on, over a full-screen app, and never behind the
    /// conversation it belongs to. They are read here because a panel that quietly lost one of
    /// them still looks right in a picture and still types — it just stops feeling like the
    /// system's own.
    static func checkQuickAskPresence() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure(label) }
            checks += 1
        }
        let profile = ConnectionProfile(
            id: "selftest-presence", name: "Presence", backend: .openCode,
            baseURL: URL(string: "http://127.0.0.1:9")!)
        let panel = QuickAskPanel(
            servers: [profile], preferredServer: profile.id, recents: [],
            onAsk: { _, _, _, done in done(nil) }, onResume: { _ in },
            onAskParty: { _, done in done(nil) })
        defer { panel.close() }
        try expect(
            panel.styleMask.contains(.nonactivatingPanel),
            "the panel is key without bringing the app forward")
        try expect(panel.level == .floating, "the panel stands over ordinary windows")
        try expect(
            panel.collectionBehavior.contains(.canJoinAllSpaces),
            "the panel opens on the Space in front")
        try expect(
            panel.collectionBehavior.contains(.fullScreenAuxiliary),
            "the panel answers over a full-screen program")
        try expect(!panel.hidesOnDeactivate, "the panel stays while the desktop moves")
        panel.orderFrontRegardless()
        try expect(panel.isVisible, "the panel is on screen")
        return checks
    }
}

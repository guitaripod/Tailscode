import Foundation
import TailscodeCore

extension SelfTest {
    /// The app left standing with no window, which is the promise behind the chord: a chord the
    /// desktop granted stops answering when the process ends, so an installed copy writes itself
    /// an autostart entry and says how far the key reaches. No file is written here — the entry's
    /// own text and the state it produces are the whole claim.
    static func checkBackgroundAgent() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure(label) }
            checks += 1
        }
        let entry = BackgroundAgent.entryText(exec: "/opt/tailscode")
        try expect(entry.contains("Exec=/opt/tailscode --background"), "the login entry asks for a hidden start")
        try expect(entry.contains("X-GNOME-Autostart-enabled=true"), "the entry is an autostart entry")
        try expect(
            entry.contains("Icon=\(DesktopIntegration.appID)"), "the entry wears this app's icon")
        try expect(
            BackgroundAgent.entryURL.path.hasSuffix(
                "autostart/\(DesktopIntegration.appID).desktop"),
            "the entry lives where the desktop reads login entries")
        try expect(
            BackgroundAgent.reach == (BackgroundAgent.isInstalled ? .readyInBackground : .whileRunning),
            "the chord claims only the reach this machine has")
        let detail = SummonState.bound(.standard, reach: BackgroundAgent.reach).detail(on: .linux)
        try expect(detail?.isEmpty == false, "a claimed chord states how far it reaches")
        return checks
    }
}

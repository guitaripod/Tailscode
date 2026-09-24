import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// A Mac server's grants are a first-run checklist. What these pin is that the checklist appears
/// only for a Mac that reports something to grant, that the press names where the pane will open,
/// and that the steps stop claiming System Settings is open once the switch is on or the moment
/// has long passed.
@Suite("Machine permissions")
struct MachinePermissionTests {
    private func mac(_ state: MachinePermissions.Grant.State, requestedAt: Date? = nil)
        -> MachinePermissions
    {
        MachinePermissions(
            platform: .macOS, host: "macbook",
            executable: "/Users/m/Dev/swift/claude-bridge/.build/release/claude-bridge",
            grants: [.init(.fullDiskAccess, state: state)], requestedAt: requestedAt)
    }

    @Test("only a Mac with something to grant is shown, and only a missing grant stops first run")
    func shown() {
        #expect(!MachinePermissionReading.isShown(nil))
        #expect(!MachinePermissionReading.isShown(MachinePermissions(platform: .linux, grants: [])))
        #expect(MachinePermissionReading.isShown(mac(.granted)))
        #expect(!MachinePermissionReading.needsAttention(mac(.granted)))
        #expect(MachinePermissionReading.needsAttention(mac(.missing)))
        #expect(!MachinePermissionReading.needsAttention(nil))
    }

    @Test("the press says which Mac the pane opens on, unless it is this one")
    func action() {
        #expect(MachinePermissionReading.action(mac(.missing), local: false) == "Open on macbook")
        #expect(MachinePermissionReading.action(mac(.missing), local: true) == "Open System Settings")
        #expect(MachinePermissionReading.isLocal(mac(.missing), thisHost: "MacBook.local"))
        #expect(!MachinePermissionReading.isLocal(mac(.missing), thisHost: "arch"))
        #expect(!MachinePermissionReading.isLocal(mac(.missing), thisHost: nil))
    }

    @Test("the steps name the Mac and the binary to drag")
    func steps() {
        let steps = MachinePermissionReading.steps(mac(.missing), local: false)
        #expect(steps.count == 3)
        #expect(steps[0].contains("macbook"))
        #expect(steps[1].contains("claude-bridge"))
    }

    @Test("the steps are shown only while the pane is plausibly still open and the switch is off")
    func waiting() {
        let now = Date()
        #expect(!MachinePermissionReading.isWaiting(mac(.missing), now: now))
        #expect(MachinePermissionReading.isWaiting(mac(.missing, requestedAt: now.addingTimeInterval(-30)), now: now))
        #expect(!MachinePermissionReading.isWaiting(mac(.granted, requestedAt: now.addingTimeInterval(-30)), now: now))
        #expect(!MachinePermissionReading.isWaiting(mac(.missing, requestedAt: now.addingTimeInterval(-3600)), now: now))
        #expect(MachinePermissionReading.showsDone(mac(.granted, requestedAt: now.addingTimeInterval(-30)), now: now))
        #expect(!MachinePermissionReading.showsDone(mac(.granted, requestedAt: now.addingTimeInterval(-3600)), now: now))
        #expect(!MachinePermissionReading.showsDone(mac(.granted), now: now))
    }

    @Test("a row's line says what goes wrong while the grant is off")
    func line() {
        #expect(MachinePermissionReading.line(nil) == nil)
        #expect(
            MachinePermissionReading.line(mac(.missing))
                == "Full Disk Access is off — agents will stop at dialogs on the Mac")
        #expect(MachinePermissionReading.line(mac(.granted)) == "Agents can work anywhere in your files")
    }
}

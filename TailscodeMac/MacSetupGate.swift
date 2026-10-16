import AppKit
import CodingAgentKitApple
import TailscodeCore

/// The one door into machine setup on the Mac. It owns the process's single `SetupDesk`, made with
/// the keychain the rest of the app keeps its passwords in, and opens the checklist for a capability
/// on a machine as a sheet on whichever window asked.
@MainActor
enum MacSetupGate {
    static let desk = SetupDesk(secrets: KeychainSecretStore())

    /// Opens the checklist over `window`. Finishing it ends the sheet and runs `onFinish`, which is
    /// how a call that was pressed for starts once voice is ready. A checklist already up is raised
    /// rather than stacked.
    static func present(
        _ target: SetupTarget, on window: NSWindow?, reportLines: @escaping () -> [String] = { [] },
        onFinish: (() -> Void)? = nil
    ) {
        SetupSheet.present(target: target, on: window, reportLines: reportLines, onFinish: onFinish)
    }
}

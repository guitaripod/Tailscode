import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore
import UIKit

/// What happens once a machine is saved: a Mac claude-bridge is asked for its grants once, right
/// after the machine is reached, so a missing Full Disk Access is a step in this checklist rather
/// than a turn stalling later behind a dialog nobody is watching.
@MainActor
enum MachineConnectedStep {
    static func proceed(
        profile: ConnectionProfile?, in navigation: UINavigationController?,
        finished: @escaping () -> Void
    ) {
        guard let profile, profile.backend == .claudeCode, let navigation else {
            finished()
            return
        }
        Task {
            guard
                let backend = ConnectionController.shared.makeBackend(for: profile)
                    as? any PermissionReportingBackend
            else {
                finished()
                return
            }
            let permissions = try? await backend.machinePermissions()
            guard MachinePermissionReading.needsAttention(permissions), let permissions else {
                finished()
                return
            }
            let step = MachinePermissionsStepViewController(
                backend: backend, profileName: profile.name, permissions: permissions)
            step.onFinished = finished
            navigation.pushViewController(step, animated: true)
        }
    }
}

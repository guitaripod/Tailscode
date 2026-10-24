import LocalAuthentication
import MidgarCore

/// The unlock a command's approval waits behind, exactly as the notification's Approve action asks
/// for it: the device owner, by Face ID or the passcode. The lock screen enforces it for a
/// notification (`authenticationRequired`); a board in the app has to ask for it itself, because
/// an approval typed into an unlocked, borrowed phone is the thing the gate exists to stop.
///
/// A phone with no passcode has nothing to ask, as it has for the notification. Deny and a
/// question's options never come here.
@MainActor
enum AgentsApprovalGate {
    enum Outcome: Equatable {
        case allowed
        case cancelled
        case refused(String)
    }

    static func confirm(reason: String) async -> Outcome {
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            if let problem, LAError.Code(rawValue: problem.code) == .passcodeNotSet { return .allowed }
            MidgarLog.error("agents approval gate unavailable: \(problem?.code ?? 0)", category: .ui)
            return .refused(
                problem?.localizedDescription ?? String(localized: "This device cannot confirm it is you."))
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return .allowed
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel: return .cancelled
            default:
                MidgarLog.error("agents approval gate refused: \(error.code.rawValue)", category: .ui)
                return .refused(error.localizedDescription)
            }
        } catch {
            return .refused(error.localizedDescription)
        }
    }
}

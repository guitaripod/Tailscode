import CodingAgentKitApple
import TailscodeCore

extension ProPersonalDetails.Facts {
    /// What this iPhone or iPad knows about the person: the turns counted for the review prompt, which never stop, and
    /// the saved servers by name, the demo world's left out.
    @MainActor
    static var onThisDevice: ProPersonalDetails.Facts {
        let connection = ConnectionController.shared
        let saved = connection.savedProfiles.filter { !$0.id.hasPrefix(DemoWorld.profilePrefix) }
        return ProPersonalDetails.Facts(
            turns: ReviewPromptPolicy.successCount,
            connected: saved.filter { !connection.isResting($0.id) }.map(\.name),
            resting: saved.filter { connection.isResting($0.id) }.map(\.name))
    }
}

import CodingAgentKitApple
import TailscodeCore

extension ProPersonalDetails.Facts {
    /// What this Mac knows about the person: the turns counted for the review prompt, which never stop, and the saved
    /// servers by name, the demo world's left out.
    @MainActor
    static var onThisMac: ProPersonalDetails.Facts {
        let directory = ServerDirectory.shared
        let saved = directory.savedProfiles.filter { !$0.id.hasPrefix(DemoWorld.profilePrefix) }
        return ProPersonalDetails.Facts(
            turns: ReviewPromptPolicy.successCount,
            connected: saved.filter { !directory.isResting($0.id) }.map(\.name),
            resting: saved.filter { directory.isResting($0.id) }.map(\.name))
    }
}

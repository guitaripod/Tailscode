import TailscodeCore
import UIKit

/// What a step of the effort dial says to VoiceOver. The pill's word and bars move for everyone
/// who can see them, so a step is never written out as a toast; a screen reader hears where the
/// level landed, or that it is pinned at an end, once the hand has stopped.
@MainActor
enum EffortSpeech {
    private static let voice = EffortVoice { words in
        Task { @MainActor in
            guard UIAccessibility.isVoiceOverRunning else { return }
            UIAccessibility.post(notification: .announcement, argument: words)
        }
    }

    static func note(_ notch: EffortNotch) {
        voice.note(notch)
    }
}

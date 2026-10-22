import AppKit
import TailscodeCore

/// What a step of the effort dial says to VoiceOver. The pill's word and bars move for everyone
/// who can see them, so a step is never written out as text; a screen reader hears where the
/// level landed, or that it is pinned at an end, once the hand has stopped.
@MainActor
enum EffortSpeech {
    private static let voice = EffortVoice { words in
        Task { @MainActor in
            guard NSWorkspace.shared.isVoiceOverEnabled,
                let window = NSApp.keyWindow ?? NSApp.mainWindow
            else { return }
            NSAccessibility.post(
                element: window, notification: .announcementRequested,
                userInfo: [
                    .announcement: words,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
    }

    static func note(_ notch: EffortNotch) {
        voice.note(notch)
    }
}

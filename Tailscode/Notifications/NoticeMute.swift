import TailscodeCore
import UIKit

/// One chat's mute, offered wherever the chat's own marks are: the chat list, Home and the chat's
/// menu. The words are Core's, so the desktops say the same.
@MainActor
enum NoticeMute {
    static func action(sessionID: String) -> UIAction {
        let muted = AppPreferences.noticeRules.isMuted(sessionID)
        return UIAction(
            title: NoticeRulesWords.muteTitle(muted: muted),
            subtitle: NoticeRulesWords.muteDetail(muted: muted),
            image: UIImage(systemName: muted ? "bell" : "bell.slash")
        ) { _ in
            Theme.Haptics.tap()
            AppPreferences.noticeRules = AppPreferences.noticeRules.togglingMute(sessionID)
        }
    }
}

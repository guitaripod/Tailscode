import UIKit

/// What the app lets go of when the system asks for memory back.
///
/// Every cache named here is a convenience that can be rebuilt from what is on screen or on the
/// server, kept so a scroll back or a second open of a chat costs nothing; none of them is state.
/// `NSCache` sheds some of its contents on its own when the system is short, but the system's idea
/// of which pieces to shed is not the app's, and a warning is the one moment the app should not be
/// holding on to rendered answers, decoded pictures and highlighted code that nobody is looking at.
@MainActor
enum MemoryRelief {
    static func install() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { relieve() }
        }
    }

    static func relieve() {
        TextBubbleCell.relieveRenderCache()
        CodeBlockCell.relieveHighlightCache()
        AttachmentImageStore.shared.relieve()
        LinkPreviewStore.shared.relieve()
        AppLogger.lifecycle.info("memory warning: render, highlight, picture and link caches released")
    }
}

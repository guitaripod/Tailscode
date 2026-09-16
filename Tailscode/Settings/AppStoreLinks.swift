import Foundation

/// The two doors to the App Store a person opens on purpose — the review form, and the
/// listing handed to the share sheet with one sentence saying what the app is — as opposed to
/// the review the app asks for by itself (`ReviewPromptCoordinator`).
enum AppStoreLinks {
    static let appID = "6791660932"
    static let listing = URL(string: "https://apps.apple.com/app/id\(appID)")!
    static let writeReview = URL(string: "https://apps.apple.com/app/id\(appID)?action=write-review")!

    /// The line beside the link in the share sheet, so the message is not a bare URL.
    static var sharePitch: String {
        String(
            localized: "Tailscode — Claude Code, opencode and Oh My Pi from your phone, over your own tailnet.",
            comment: "Text beside the App Store link in the share sheet")
    }

    static var shareItems: [Any] { [sharePitch, listing] }
}

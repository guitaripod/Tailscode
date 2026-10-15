import Foundation

/// The words every beta mark and card share, so no client spells one for itself.
public enum BetaWords {
    public static var badge: String { Localized.text("BETA") }

    public static var label: String { Localized.text("Beta") }

    public static var gotIt: String { Localized.text("Got it") }

    public static var copyReport: String { Localized.text("Copy report") }

    public static var reportCopied: String { Localized.text("Report copied") }

    public static var sinceYouLastLooked: String { Localized.text("Since you last looked") }

    public static var solid: String { Localized.text("Solid") }

    public static var rough: String { Localized.text("Still rough") }

    /// A line that already says something, with the mark in front of it.
    public static func marked(_ line: String) -> String { Localized.text("Beta · %@", line) }
}

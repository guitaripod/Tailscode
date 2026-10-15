import Foundation

/// The block Copy report puts on the pasteboard. It is plain text, the same in every language, and
/// holds no clock of its own: whatever the feature's surface knows goes in `lines`.
public enum BetaReport {
    public static let heading = "Tailscode beta report"

    public static func compose(feature: BetaFeature, app: String, system: String, lines: [String]) -> String {
        ([heading, "Feature: \(feature.rawValue)", "App: \(app)", "System: \(system)"] + lines)
            .joined(separator: "\n")
    }
}

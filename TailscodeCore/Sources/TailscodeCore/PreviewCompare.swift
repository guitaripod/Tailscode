import CodingAgentKit
import Foundation

/// The views a preview pane can be asked to show. The picture is always the first; the others
/// are the same running app read another way, and each says why it is missing when it is.
public enum PreviewLens: String, Sendable, CaseIterable, Equatable {
    case look
    case compare
    case inspect
    case quality
    case matrix
    case rewind

    public var title: String {
        switch self {
        case .look: return Localized.text("Look")
        case .compare: return Localized.text("Compare")
        case .inspect: return Localized.text("Inspect")
        case .quality: return Localized.text("Quality")
        case .matrix: return Localized.text("Matrix")
        case .rewind: return Localized.text("Rewind")
        }
    }

    /// The plain digit that picks this lens while a pane has the keyboard, in the order the
    /// switcher lists them.
    public var digit: Character {
        switch self {
        case .look: return "1"
        case .compare: return "2"
        case .inspect: return "3"
        case .quality: return "4"
        case .matrix: return "5"
        case .rewind: return "6"
        }
    }

    public init?(digit: Character) {
        guard let lens = Self.allCases.first(where: { $0.digit == digit }) else { return nil }
        self = lens
    }

    /// Whether the lens reads the running app's own views, and so draws on the picture itself
    /// rather than on a stage of its own.
    public var readsViews: Bool { self == .inspect || self == .quality }
}

/// What two pictures of the same screen say about each other, in the words of someone comparing
/// them: how many places changed, how much of the screen that is, and which turn each came from.
public enum PreviewCompareReading {
    public static func summary(_ report: DiffReport) -> String {
        guard report.sameSize else { return Localized.text("The screen changed size, so the pictures cannot be laid over each other") }
        guard !report.regions.isEmpty else { return Localized.text("Nothing changed on screen") }
        let percent = String(format: "%.1f", report.changed * 100)
        if report.regions.count == 1 {
            return Localized.text("1 region changed · %@%% of the pixels", percent)
        }
        return Localized.text("%@ regions changed · %@%% of the pixels", String(report.regions.count), percent)
    }

    public static func title(of shot: HistoryInfo) -> String {
        if shot.trigger == "start" { return Localized.text("App opened") }
        return shot.title
    }

    public static func detail(of shot: HistoryInfo, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(shot.at)))
        let ago: String
        switch seconds {
        case ..<5: ago = Localized.text("Now")
        case ..<90: ago = Localized.text("%@ s ago", String(seconds))
        default: ago = Localized.text("%@ min ago", String(seconds / 60))
        }
        guard let path = shot.path else { return ago }
        return "\(PreviewReading.words(for: path)) · \(ago)"
    }

    /// The two pictures a person most likely wants first: the one before the newest and the newest.
    public static func defaultPair(_ history: [HistoryInfo]) -> (before: Int, after: Int)? {
        let ids = history.map(\.id).sorted()
        guard ids.count >= 2 else { return nil }
        return (ids[ids.count - 2], ids[ids.count - 1])
    }

    /// A region of the picture as fractions of its size, so any view that shows the picture at any
    /// size can lay the outline over it.
    public static func fractions(of region: DiffRegion, in report: DiffReport) -> (x: Double, y: Double, width: Double, height: Double) {
        let w = Double(max(1, report.width))
        let h = Double(max(1, report.height))
        return (Double(region.x) / w, Double(region.y) / h, Double(region.width) / w, Double(region.height) / h)
    }

    public static func variantSpecs() -> [VariantSpec] {
        [
            VariantSpec(label: Localized.text("Light"), appearance: "light"),
            VariantSpec(label: Localized.text("Dark"), appearance: "dark"),
            VariantSpec(label: Localized.text("Large text"), contentSize: "extra-large"),
            VariantSpec(label: Localized.text("Largest text"), contentSize: "accessibility-extra-extra-extra-large"),
            VariantSpec(
                label: Localized.text("Right to left"),
                arguments: ["-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES"]),
        ]
    }
}

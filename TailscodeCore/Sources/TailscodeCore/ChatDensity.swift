import Foundation

/// How much height a transcript spends on everything that is not the answer. Two tables, one
/// setting: the numbers themselves are ``ChatMetrics``, and a client only maps them onto its own
/// tokens.
public enum ChatDensity: String, Sendable, CaseIterable {
    case compact
    case comfortable

    public var title: String {
        switch self {
        case .compact: return Localized.text("Compact")
        case .comfortable: return Localized.text("Comfortable")
        }
    }

    public var explanation: String {
        switch self {
        case .compact:
            return Localized.text(
                "Furniture takes a line, not a card: tool calls, links, pictures and seams sit close to the words they belong to.")
        case .comfortable:
            return Localized.text("Every row keeps its own plate and the same generous air around it.")
        }
    }
}

/// The reader's choice of ``ChatDensity``, device-local like every other thing about how this app
/// looks. Compact until somebody asks otherwise.
public enum ChatDensitySetting {
    public static let key = "tailscode.chatDensity"
    public static let didChange = Notification.Name("tailscode.chatDensity.didChange")

    public static var current: ChatDensity {
        UserDefaults.standard.string(forKey: key).flatMap(ChatDensity.init(rawValue:)) ?? .compact
    }

    public static func set(_ value: ChatDensity) {
        UserDefaults.standard.set(value.rawValue, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static var title: String { Localized.text("Chat density") }

    public static var explanation: String {
        Localized.text(
            "How close the transcript sets its rows. Compact folds furniture to a line; comfortable keeps the airier layout.")
    }

    /// What a client stores for the density once the old Linux `denseRows` switch is read. The only
    /// thing that switch ever meant was "tighter", and tighter is now the default, so an explicit
    /// `true`, an explicit `false` and no answer at all all arrive at ``ChatDensity/compact``;
    /// someone who wants the old airy rhythm picks comfortable themselves.
    public static func migrate(legacyDenseRows: Bool?) -> ChatDensity { .compact }
}

/// What a transcript row is, for the purpose of the space around it.
public enum ChatRowClass: Sendable, CaseIterable {
    case prompt
    case prose
    case code
    /// Tool, activity, subagent and thinking lines, and notes.
    case furniture
    /// Compaction, model-change and interruption divider lines.
    case seam
    /// The link rail.
    case rail
    case picture
}

/// Whether a touch or a pointer presses the row, which decides how tall a pressable line must be.
public enum ChatInput: Sendable {
    case touch
    case pointer
}

/// The table of numbers a transcript is laid out with, in points. Compact is the design's;
/// comfortable is today's rhythm, rounded: one gap between every pair of rows — 16 on touch, 12
/// on a pointer, which is what the phone and the desktops draw today — and a larger one between
/// turns. A client maps a value onto its own tokens and never hard-codes a gap.
public struct ChatMetrics: Sendable, Equatable {
    public var paragraphGap: Double
    public var proseToFurnitureGap: Double
    public var proseToCodeGap: Double
    public var furnitureGap: Double
    public var pictureStripGap: Double
    public var turnGap: Double

    /// The pressable row of a flat activity line. The visible line is 24 pt, inside the 32 pt a
    /// finger needs.
    public var activityRowHeight: Double
    public var seamRowHeight: Double
    public var railRowHeight: Double
    /// An address row of the opened rail, which is an actual target.
    public var railOpenRowHeight: Double
    public var railPlateWidth: Double
    public var railPlateRows: Int

    public var imageMaxHeight: Double
    public var imageStripGap: Double
    public var codeCollapseLines: Int
    public var promptBubblePadding: Double

    public static func metrics(for density: ChatDensity, input: ChatInput) -> ChatMetrics {
        let flat: Double = input == .touch ? 32 : 24
        let open: Double = input == .touch ? 44 : 36
        let air: Double = input == .touch ? 16 : 12
        switch density {
        case .compact:
            return ChatMetrics(
                paragraphGap: 8, proseToFurnitureGap: 4, proseToCodeGap: 6, furnitureGap: 2,
                pictureStripGap: 6, turnGap: 16, activityRowHeight: flat, seamRowHeight: flat,
                railRowHeight: flat, railOpenRowHeight: open, railPlateWidth: 440, railPlateRows: 8,
                imageMaxHeight: 180, imageStripGap: 8, codeCollapseLines: 14, promptBubblePadding: 6)
        case .comfortable:
            return ChatMetrics(
                paragraphGap: air, proseToFurnitureGap: air, proseToCodeGap: air, furnitureGap: air,
                pictureStripGap: air, turnGap: 24, activityRowHeight: flat, seamRowHeight: flat,
                railRowHeight: flat, railOpenRowHeight: open, railPlateWidth: 440, railPlateRows: 8,
                imageMaxHeight: 300, imageStripGap: 8, codeCollapseLines: 14, promptBubblePadding: 8)
        }
    }

    /// The air between two neighbouring rows, from the row above to the row below; zero above the
    /// first. A prompt starts a turn, so the space on either side of one is the turn gap; a picture
    /// beside anything is the strip gap, and beside another picture the strip's gutter; code beside
    /// anything is the code gap; prose beside a flat line is the furniture-edge gap; two flat lines
    /// sit nearly touching. Symmetric by construction, so a client never asks which way round a
    /// pair is.
    public func gap(from previous: ChatRowClass?, to next: ChatRowClass) -> Double {
        guard let previous else { return 0 }
        if previous == .prompt || next == .prompt { return turnGap }
        if previous == .picture && next == .picture { return imageStripGap }
        if previous == .picture || next == .picture { return pictureStripGap }
        switch (previous, next) {
        case (.prose, .prose): return paragraphGap
        case (.code, _), (_, .code): return proseToCodeGap
        case (.prose, _), (_, .prose): return proseToFurnitureGap
        default: return furnitureGap
        }
    }
}

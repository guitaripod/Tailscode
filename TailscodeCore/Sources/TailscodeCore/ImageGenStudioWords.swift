import Foundation

/// Every word the desktop studio's brief column says that the chips did not already: the section
/// labels over each decision, the count under the words, and the one-line key legend. Held in
/// Core so a desk that lays the ask out as a form and one that wears it as chips can never name
/// the same decision two ways.
public enum ImageGenStudioWords {
    public static var wordsTitle: String { Localized.text("Words") }
    public static var avoidTitle: String { Localized.text("Avoid") }
    public static var engineTitle: String { Localized.text("Engine") }
    public static var shapeTitle: String { Localized.text("Shape") }
    public static var sizeTitle: String { Localized.text("Size") }
    public static var detailTitle: String { Localized.text("Detail") }
    public static var referencesTitle: String {
        Localized.text("References · <image1>, <image2>")
    }

    public static var holdSeedTitle: String { Localized.text("Hold the seed") }

    /// The switch's own detail: the number it holds when it holds one, and what holding means.
    public static func holdSeedDetail(seed: ImageGenSeed) -> String {
        if seed.isHeld, let held = seed.held {
            return Localized.text(
                "%@ · change a word, only that word changes", ImageGenFacts.seedMark(held))
        }
        return Localized.text("Every render rolls a new number")
    }

    public static var cutoutDetail: String { Localized.text("Paint on transparency") }

    /// What the words weigh, and — for the engine that was trained behind a rewriter — a nudge
    /// toward the paragraph it expects. A count with no consequence is left as a count.
    public static func countLine(words: Int, engine: ImageGenEngine) -> String {
        let count =
            words == 1
            ? Localized.text("1 word") : Localized.text("%@ words", "\(words)")
        guard engine == .quality, words < ImageGenBrief.thinWordCount else { return count }
        return Localized.text("%@ · Qwen likes a paragraph", count)
    }

    /// The elapsed clock beside the machine's own progress line, and the queue when there is one.
    public static func clockLine(since started: Date?, ahead: Int?, now: Date = Date()) -> String {
        var parts: [String] = []
        if let started {
            let seconds = max(0, Int(now.timeIntervalSince(started).rounded()))
            parts.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
        if let ahead {
            parts.append(
                ahead <= 0
                    ? Localized.text("behind nobody")
                    : ahead == 1
                        ? Localized.text("behind 1 render")
                        : Localized.text("behind %@ renders", "\(ahead)"))
        }
        return parts.joined(separator: " · ")
    }

    /// The previous picture stays on the stage, dimmed, while the next one is painted over it.
    public static var previousShownNote: String {
        Localized.text("previous render shown until this one lands")
    }

    /// The picture being edited stays on the stage, dimmed, until the result replaces it.
    public static var editingShownNote: String {
        Localized.text("the picture being edited is shown until the result lands")
    }

    /// The empty stage, in a studio whose words are beside it rather than under it.
    public static var emptyBody: String {
        Localized.text("Describe a picture on the left. It is painted on the machine with the card.")
    }

    public static var keysLine: String {
        Localized.text("Return renders · Esc closes · ⌘E ⌘A ⌘U ⌘D ⌘K ⌘J ⌘R")
    }

    /// The render in flight, as a row on the shelf beside the pictures it will join.
    public static func inFlightFacts(engine: ImageGenEngine, aspect: ImageGenAspect?, since: Date?)
        -> String
    {
        var parts = [engine.short, aspect?.ratioLabel ?? ImageGenMode.edit.label]
        let clock = clockLine(since: since, ahead: nil)
        if !clock.isEmpty { parts.append(clock) }
        return parts.joined(separator: " · ")
    }
}

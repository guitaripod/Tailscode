import Foundation

/// How much room a block of machine text — a tool's output, a fenced code block, a diff — is
/// given inside a transcript, decided once so the three clients agree.
///
/// The rule is that a block short enough to be read whole is drawn whole, with no scroller at all,
/// and only a genuinely long one is capped and scrolls inside itself. A scroller around a short
/// block is worse than useless in both directions: it costs a reader a second gesture to see four
/// lines they could have been shown, and on a toolkit that measures a wrapping label at its
/// unwrapped width it collapses the box to one or two lines, which is how a forty-line command
/// ends up behind a four-line window with a scrollbar beside it.
///
/// The ceiling is deliberately generous. A desktop transcript is a reading surface; the reason to
/// cap at all is that one chatty tool must not push the conversation off the screen, and 300 points
/// is a long way below where that starts to be true.
public enum TranscriptBlocks {
    /// Lines a block may have and still be drawn in full.
    public static let inlineLines = 26
    /// Characters a block may have and still be drawn in full, which catches the block that is
    /// four lines of a thousand characters each.
    public static let inlineCharacters = 2200
    /// How tall a capped block is, in points on the Apple clients and pixels on GTK. Both are
    /// device-independent, and a block that scrolls at all is worth showing a screenful of.
    public static let cappedHeight: Double = 520

    /// Whether the block can simply be drawn, with no scroller and no cap.
    public static func fitsInline(_ text: String) -> Bool {
        text.count <= inlineCharacters && lineCount(text) <= inlineLines
    }

    public static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }
}

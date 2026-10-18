import Foundation

extension NeuralReading {
    /// What the line under a clipped diff says: it opens the whole of what was written.
    public static func showAllLines(_ count: Int) -> String {
        Localized.text("Show all %lld lines", count)
    }

    /// What it says once the whole is open.
    public static var showFewerLines: String { Localized.text("Show fewer lines") }

    /// The button that puts the whole file, or the whole diff, on the pasteboard.
    public static var copyAllLabel: String { Localized.text("Copy all") }

    /// Whether a diff's lines are a file written whole, which a gutter may number from one: nothing
    /// in it was taken away and every line is new.
    public static func isWholeFile(_ lines: [NeuralReadout.DiffLine]) -> Bool {
        !lines.isEmpty && lines.allSatisfy { $0.kind == .add }
    }

    /// The text of a diff as it would be pasted: the lines as they are for a file written whole,
    /// each with its `+` or `-` for an edit.
    public static func pasteText(of lines: [NeuralReadout.DiffLine]) -> String {
        if isWholeFile(lines) { return lines.map(\.text).joined(separator: "\n") }
        return lines.map { line in
            switch line.kind {
            case .add: return "+ " + line.text
            case .remove: return "- " + line.text
            case .context: return "  " + line.text
            }
        }.joined(separator: "\n")
    }
}

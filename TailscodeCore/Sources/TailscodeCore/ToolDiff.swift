import CodingAgentKit

/// The lines of an Edit or Write call rendered the way a reviewer reads them: what left in red,
/// what arrived in green. Derived from the structured input, which is the same source the CLI's
/// own display uses.
public enum ToolDiff {
    public static func lines(for call: ToolCall) -> [(prefix: String, text: String)]? {
        guard let input = call.input?.objectValue else { return nil }
        var lines: [(String, String)] = []
        if let old = input["old_string"]?.stringValue {
            lines += old.split(separator: "\n", omittingEmptySubsequences: false)
                .map { ("-", String($0)) }
        }
        if let new = input["new_string"]?.stringValue {
            lines += new.split(separator: "\n", omittingEmptySubsequences: false)
                .map { ("+", String($0)) }
        }
        if lines.isEmpty, let content = input["content"]?.stringValue {
            lines = content.split(separator: "\n", omittingEmptySubsequences: false)
                .map { ("+", String($0)) }
        }
        return lines.isEmpty ? nil : lines
    }

    /// What a run of calls changed, in lines — the tally a folded run wears beside its tools.
    ///
    /// Only an edit or a write can have changed a file, so every other call is passed over on its
    /// name alone. Building a whole summary strips the markup off the call's whole output, and a
    /// run header used to ask that of every call it held, twice, each time the row was built: more
    /// than half of what drawing a transcript cost went to shell output nobody was counting.
    public static func tally(_ calls: [ToolCall]) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for call in calls where call.summaryKind == .fileEdit || call.summaryKind == .fileWrite {
            guard let stats = call.summary.diffStats else { continue }
            added += stats.added
            removed += stats.removed
        }
        return (added, removed)
    }

    /// The language of the file the call edits, read from its own path, so the diff's lines can
    /// carry the file's syntax colours and not just their red and green.
    public static func language(for call: ToolCall) -> String? {
        guard let input = call.input?.objectValue else { return nil }
        let path = input["file_path"]?.stringValue ?? input["filePath"]?.stringValue
            ?? input["path"]?.stringValue
        return path.flatMap(SyntaxHighlighter.language(forPath:))
    }
}

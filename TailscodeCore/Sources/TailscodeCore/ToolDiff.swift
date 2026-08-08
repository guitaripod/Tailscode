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

    /// The language of the file the call edits, read from its own path, so the diff's lines can
    /// carry the file's syntax colours and not just their red and green.
    public static func language(for call: ToolCall) -> String? {
        guard let input = call.input?.objectValue else { return nil }
        let path = input["file_path"]?.stringValue ?? input["filePath"]?.stringValue
            ?? input["path"]?.stringValue
        return path.flatMap(SyntaxHighlighter.language(forPath:))
    }
}

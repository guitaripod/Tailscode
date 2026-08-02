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
}

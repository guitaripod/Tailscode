import Foundation

/// What a selection in a prompt box can be turned into with one press. A phone's keyboard keeps
/// the backtick three keys deep, and a prompt to a coding agent is full of names that should be
/// set as code.
public enum DraftVerbs {
    /// A rewrite of part of a draft: what replaces the selection, and where the selection sits
    /// afterwards, both in UTF-16 offsets from the start of the replacement.
    public struct Edit: Sendable, Equatable {
        public let text: String
        public let selectedStart: Int
        public let selectedLength: Int

        public init(text: String, selectedStart: Int, selectedLength: Int) {
            self.text = text
            self.selectedStart = selectedStart
            self.selectedLength = selectedLength
        }
    }

    /// The selection set as code: backticks around a name, a fence around anything that spans
    /// lines. Code that is already wrapped is unwrapped, so the verb undoes itself. An empty
    /// selection gets an empty pair with the caret between them.
    public static func code(_ selection: String) -> Edit {
        if let bare = unwrapped(selection) { return whole(bare) }
        if selection.contains("\n") {
            let body = selection.hasSuffix("\n") ? String(selection.dropLast()) : selection
            return whole("```\n\(body)\n```")
        }
        let fence = selection.contains("`") ? "``" : "`"
        guard !selection.isEmpty else { return Edit(text: "``", selectedStart: 1, selectedLength: 0) }
        return whole("\(fence)\(selection)\(fence)")
    }

    private static func unwrapped(_ selection: String) -> String? {
        if selection.hasPrefix("```\n"), selection.hasSuffix("\n```"), selection.utf16.count >= 8 {
            return String(selection.dropFirst(4).dropLast(4))
        }
        guard selection.utf16.count > 2, selection.hasPrefix("`"), selection.hasSuffix("`"),
            !selection.hasPrefix("``")
        else { return nil }
        let inner = selection.dropFirst().dropLast()
        return inner.contains("`") || inner.contains("\n") ? nil : String(inner)
    }

    /// The selection set off as a quote, a mark on every line of it.
    public static func quote(_ selection: String) -> Edit {
        let lines = selection.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.allSatisfy({ $0.hasPrefix("> ") || $0 == ">" }), !selection.isEmpty {
            return whole(lines.map { $0.dropFirst($0.hasPrefix("> ") ? 2 : 1) }.joined(separator: "\n"))
        }
        return whole(lines.map { "> \($0)" }.joined(separator: "\n"))
    }

    private static func whole(_ text: String) -> Edit {
        Edit(text: text, selectedStart: 0, selectedLength: text.utf16.count)
    }

    public static var codeTitle: String { Localized.text("Code") }
    public static var quoteTitle: String { Localized.text("Quote") }
    public static var lastPromptTitle: String { Localized.text("Last prompt") }
}

import CodingAgentKit
import Foundation

/// The words a chat already knows — its project, branch, the files the agent touched, the
/// identifiers in what was said, the server's commands, the models on the pill — read once when
/// the microphone opens. Only the tail of the transcript is read, because the conversation can be
/// any size and the microphone has to open now.
public struct DictationVocabulary: Sendable, Equatable {
    public static let tailMessages = 40
    public static let textBudget = 12_000
    public static let termLimit = 300
    public static let phraseLimit = 100

    public let terms: [String]
    public let commands: [String]

    public init(terms: [String], commands: [String] = []) {
        self.terms = terms
        self.commands = commands
    }

    public static let empty = DictationVocabulary(terms: [])

    /// Most recent first: a file the agent just edited outranks one it read an hour ago. `notes` is
    /// text in hand outside any transcript — what a quick ask has on offer from the pasteboard — and
    /// is read ahead of the messages, out of the same budget.
    public static func read(
        messages: [ChatMessage], project: String? = nil, branch: String? = nil,
        commands: [String] = [], models: [String] = [], notes: [String] = []
    ) -> DictationVocabulary {
        var ranked = RankedTerms(limit: termLimit)
        for name in [project, branch].compactMap({ $0 }) {
            ranked.add(name)
        }
        var budget = textBudget
        for note in notes where budget > 0 {
            let slice = String(note.prefix(budget))
            budget -= slice.count
            for identifier in identifiers(in: slice) { ranked.add(identifier) }
        }
        for message in messages.suffix(tailMessages).reversed() {
            for part in message.parts.reversed() {
                switch part.kind {
                case .tool(let call):
                    for path in paths(of: call) {
                        let name = (path as NSString).lastPathComponent
                        ranked.add(name)
                        ranked.add((name as NSString).deletingPathExtension)
                    }
                case .text(let text):
                    guard budget > 0 else { continue }
                    let slice = String(text.suffix(budget))
                    budget -= slice.count
                    for identifier in identifiers(in: slice).reversed() { ranked.add(identifier) }
                case .file(let file):
                    if let name = file.filename ?? file.path.map({ ($0 as NSString).lastPathComponent }) {
                        ranked.add(name)
                    }
                case .reasoning, .compaction, .note, .unknown:
                    continue
                }
            }
        }
        for model in models { ranked.add(model) }
        return DictationVocabulary(terms: ranked.terms, commands: commands)
    }

    /// What Apple's engine is given: at most a hundred phrases of one or two words. A file name is
    /// given without its extension, the part a voice actually says.
    public var phrases: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for term in terms {
            let stem = term.contains(".") ? (term as NSString).deletingPathExtension : term
            let phrase = stem.isEmpty ? term : stem
            guard phrase.split(separator: " ").count <= 2, seen.insert(phrase.lowercased()).inserted else { continue }
            out.append(phrase)
            if out.count == Self.phraseLimit { break }
        }
        return out
    }

    private static func paths(of call: ToolCall) -> [String] {
        switch call.summaryKind {
        case .fileRead, .fileEdit, .fileWrite:
            break
        default:
            return []
        }
        guard case .object(let fields)? = call.input else { return [] }
        return ["file_path", "filePath", "path", "notebook_path"].compactMap { key in
            if case .string(let value)? = fields[key], !value.isEmpty { return value }
            return nil
        }
    }

    /// Code-shaped words: CamelCase, snake_case, dotted names and anything with a digit in it, the
    /// words a recognizer would otherwise spell as English.
    static func identifiers(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: ".-/"))
            if isCodeShaped(trimmed) { out.append(trimmed) }
            current = ""
        }
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || "_.-/".unicodeScalars.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    static func isCodeShaped(_ word: String) -> Bool {
        guard word.count >= 3, word.count <= 48, !word.contains("//"), !word.hasPrefix("http"),
            word.first?.isLetter == true || word.first == "_"
        else { return false }
        if word.contains("/") { return false }
        let letters = word.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        let innerCapital = word.dropFirst().contains(where: \.isUppercase) && word.contains(where: \.isLowercase)
        let dotted = word.split(separator: ".")
        let structured = word.contains("_") || (dotted.count >= 2 && (dotted.map(\.count).max() ?? 0) >= 3)
        let digits = word.contains(where: \.isNumber)
        return innerCapital || structured || digits
    }
}

/// An ordered set of terms, first seen first kept, capped.
private struct RankedTerms {
    let limit: Int
    private(set) var terms: [String] = []
    private var seen = Set<String>()

    init(limit: Int) {
        self.limit = limit
    }

    mutating func add(_ term: String) {
        let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2, terms.count < limit, seen.insert(clean.lowercased()).inserted else { return }
        terms.append(clean)
    }
}

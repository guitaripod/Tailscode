import Foundation

/// A pipe table read into its cells, so a client renders columns instead of punctuation. The
/// grammar is GitHub's: a header row, a delimiter row of dashes with optional alignment colons,
/// then body rows — pipes at the edges optional, a `\|` or a pipe inside backticks staying text.
/// Parsing is shared so the three clients can never disagree about what was a table; only how a
/// column is drawn belongs to a client.
public struct MarkdownTable: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable {
        case leading
        case center
        case trailing
    }

    public let header: [String]
    public let alignments: [Alignment]
    public let rows: [[String]]

    public var columnCount: Int { header.count }

    public init(header: [String], alignments: [Alignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }

    /// Every cell of one body row, padded to the header's width so a short row still lines up
    /// and a long one never spills into a phantom column.
    public func cells(in row: Int) -> [String] {
        guard rows.indices.contains(row) else { return [] }
        var cells = rows[row]
        if cells.count > header.count { cells = Array(cells.prefix(header.count)) }
        while cells.count < header.count { cells.append("") }
        return cells
    }

    public func alignment(of column: Int) -> Alignment {
        alignments.indices.contains(column) ? alignments[column] : .leading
    }

    /// The table written back as the pipes it came from, for exports and copies that must stay
    /// markdown.
    public var markdown: String {
        func row(_ cells: [String]) -> String {
            "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }
                .joined(separator: " | ") + " |"
        }
        let delimiter = alignments.map { alignment -> String in
            switch alignment {
            case .leading: return "---"
            case .center: return ":-:"
            case .trailing: return "--:"
            }
        }
        var lines = [row(header), "| " + delimiter.joined(separator: " | ") + " |"]
        for index in rows.indices { lines.append(row(cells(in: index))) }
        return lines.joined(separator: "\n")
    }

    /// The table starting at `start`, and the index of the first line past it — or nil when
    /// `start` does not begin one. A table begins only where a header row is immediately
    /// followed by a delimiter row of the same width; body rows run until the first line that
    /// carries no pipe.
    public static func scan(
        _ lines: [String], from start: Int
    ) -> (table: MarkdownTable, end: Int)? {
        guard start + 1 < lines.count,
            let header = columns(lines[start]),
            let alignments = delimiterRow(lines[start + 1]),
            alignments.count == header.count
        else { return nil }
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count, delimiterRow(lines[index]) == nil,
            let cells = columns(lines[index])
        {
            rows.append(cells)
            index += 1
        }
        return (MarkdownTable(header: header, alignments: alignments, rows: rows), index)
    }

    /// One row's cells, or nil when the line is not a row at all. A row must carry a pipe that
    /// separates — a pipe inside backticks is code and `\|` is a literal — and edge pipes frame
    /// the row without contributing empty cells.
    public static func columns(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), !trimmed.hasPrefix(">") else { return nil }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for character in trimmed {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\":
                escaped = true
            case "`":
                inCode.toggle()
                current.append(character)
            case "|" where !inCode:
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default:
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        if trimmed.hasPrefix("|"), cells.first?.isEmpty == true { cells.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|"), cells.last?.isEmpty == true {
            cells.removeLast()
        }
        guard !cells.isEmpty, cells.contains(where: { !$0.isEmpty }) || cells.count > 1 else {
            return nil
        }
        return cells
    }

    /// The delimiter row that turns the line above it into a header: every cell dashes, with a
    /// colon on the side the column keeps.
    public static func delimiterRow(_ line: String) -> [Alignment]? {
        guard let cells = columns(line) else { return nil }
        var alignments: [Alignment] = []
        for cell in cells {
            var body = Substring(cell)
            let leadingColon = body.hasPrefix(":")
            if leadingColon { body = body.dropFirst() }
            let trailingColon = body.hasSuffix(":")
            if trailingColon { body = body.dropLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
            switch (leadingColon, trailingColon) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }
}

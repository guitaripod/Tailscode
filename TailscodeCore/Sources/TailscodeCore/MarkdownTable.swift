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
    /// Whether the author actually said where each column sits — a colon in the delimiter row —
    /// rather than leaving markdown's own default. `---` is not a decision, and the difference
    /// matters: a column of figures nobody placed reads under its own last digit, while one the
    /// author pushed left stays left.
    public let declared: [Bool]
    public let rows: [[String]]

    public var columnCount: Int { header.count }

    public init(
        header: [String], alignments: [Alignment], rows: [[String]], declared: [Bool]? = nil
    ) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
        self.declared = declared ?? [Bool](repeating: false, count: alignments.count)
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

    /// Where the author said the column sits, exactly as written.
    public func alignment(of column: Int) -> Alignment {
        alignments.indices.contains(column) ? alignments[column] : .leading
    }

    /// Whether the author placed this column themselves.
    public func isDeclared(_ column: Int) -> Bool {
        declared.indices.contains(column) ? declared[column] : false
    }

    /// Where a column actually sits. What the author wrote is kept exactly as written; a column
    /// nobody placed carries markdown's default rather than a decision, and a column of figures
    /// nobody placed lands under its own last digit — a stack of numbers is compared down the page,
    /// and ragged right-hand ends is what stops it being compared at all.
    public func effectiveAlignment(of column: Int) -> Alignment {
        let stated = alignment(of: column)
        guard stated == .leading, !isDeclared(column), kind(of: column) == .number else {
            return stated
        }
        return .trailing
    }

    /// Every cell of one column, header included, which is what a client measures a width from.
    public func column(_ index: Int) -> [String] {
        guard header.indices.contains(index) else { return [] }
        return [header[index]] + rows.indices.map { cells(in: $0)[index] }
    }

    /// Whether a column is numbers. Digits that sit in a stack meant to be compared down the page
    /// are set on one width so a column of figures reads as a column rather than as ragged text,
    /// and — where the author placed nothing — land under each other (`effectiveAlignment`).
    ///
    /// A column of numbers is one where every cell that says anything is a number: a sign, digits
    /// with the separators numbers are written with, the marks a number wears — a percent, a
    /// currency, an `×` — and the unit a reading is quoted in, whether it is written against the
    /// digits or a space away from them. `130 Mb/s` and `2437 MHz` are readings; `WPA2 (PSK)` is
    /// a word that happens to have a digit in it.
    public func isNumeric(column index: Int) -> Bool {
        let cells = column(index).dropFirst().filter { !$0.isEmpty && $0 != "-" && $0 != "—" }
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy(Self.readsAsNumber)
    }

    private static let numberMarks = Set("+-−$€£¥%×x*/ ")

    static func readsAsNumber(_ cell: String) -> Bool {
        var digits = 0
        var letters = 0
        for character in cell {
            if character.isNumber {
                digits += 1
                continue
            }
            if character == "." || character == "," || character == "_" { continue }
            if numberMarks.contains(character) { continue }
            if character.isLetter || character == "°" {
                guard digits > 0 else { return false }
                letters += 1
                continue
            }
            return false
        }
        return digits > 0 && letters <= Self.unitLength
    }

    /// How many letters a unit may spend before the cell is a phrase rather than a reading: `MHz`,
    /// `Mb/s`, `ms`, `kB`, `°C` all fit, and anything longer is prose.
    private static let unitLength = 4

    /// What a column holds, which is most of what a client needs in order to set it: figures share
    /// one digit width and land under each other, code keeps the machine's face and has no word in
    /// it to break, and everything else is prose that may fold.
    public enum Kind: Hashable, Sendable {
        case text
        case number
        case code
    }

    public func kind(of column: Int) -> Kind {
        if isNumeric(column: column) { return .number }
        if isCode(column: column) { return .code }
        return .text
    }

    /// Every column's kind, read once, because a client asks per cell and the answer is per column.
    public var kinds: [Kind] { header.indices.map(kind(of:)) }

    /// Whether every cell of a column is one span of inline code — a column of addresses, paths,
    /// identifiers or hashes. It is set in the machine's face whole, rather than as prose with
    /// backticks scattered through it.
    public func isCode(column index: Int) -> Bool {
        let cells = column(index).dropFirst().filter { !$0.isEmpty && $0 != "-" && $0 != "\u{2014}" }
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            cell.hasPrefix("`") && cell.hasSuffix("`") && cell.count > 2
                && !cell.dropFirst().dropLast().contains("`")
        }
    }

    /// Whether a column has nothing in it worth breaking. Squeezing a width onto a column of
    /// addresses, codes or short readings does not fold it — it hyphenates a token that was never
    /// a word, or stacks `MHz` under `2437` — so a rigid column keeps its whole measure and the
    /// prose columns pay for the room instead (`TableLayout.widths(rigid:)`).
    public func isRigid(column index: Int) -> Bool {
        let cells = column(index).filter { !$0.isEmpty }
        guard !cells.isEmpty else { return true }
        return cells.allSatisfy { $0.count <= Self.foldableLength || !$0.contains(" ") }
    }

    public var rigidColumns: [Bool] { header.indices.map(isRigid(column:)) }

    /// The longest run in a column with nowhere to break — the widest single word of prose, a
    /// whole address, a reading with its unit. No column may be squeezed narrower than this,
    /// because below it a cell does not fold, it *breaks*: a number splits across two lines and
    /// stops being a number, and an address stops being an address.
    ///
    /// It is handed back as the text rather than as a width, because only the client knows what
    /// its own face makes of it. A client whose toolkit already reports a wrapping cell's minimum
    /// has the same answer for free and should use that instead.
    public func unbreakable(column index: Int) -> String {
        column(index)
            .flatMap { $0.split(separator: " ").map(String.init) }
            .max { $0.count < $1.count } ?? ""
    }

    /// How long a cell has to be before folding it is better than keeping it whole.
    static let foldableLength = 16

    /// Whether the first column reads as the name of its row rather than as one more reading.
    /// Pipe tables are written key-first far more often than not, and a name set in the heavier
    /// voice is what lets a row be found before it is read — the rule a tool's name and its
    /// arguments already follow. A column of figures is never a name, and neither is one with a
    /// hole in it or an essay in it.
    public var namesItsRows: Bool {
        guard columnCount > 1, rows.count > 1, kind(of: 0) == .text else { return false }
        return rows.indices.map { cells(in: $0)[0] }
            .allSatisfy { !$0.isEmpty && $0.count <= Self.nameLength }
    }

    static let nameLength = 40

    /// Whether this table is the same table as `other` with more rows under it — which is what a
    /// table being written looks like, and the one shape a client may grow into rather than
    /// redraw. Everything else is a different table and is drawn again from the top.
    public func extends(_ other: MarkdownTable) -> Bool {
        header == other.header && alignments == other.alignments
            && rows.count >= other.rows.count
            && Array(rows.prefix(other.rows.count)) == other.rows
    }

    /// The table written back as the pipes it came from, for exports and copies that must stay
    /// markdown.
    public var markdown: String {
        func row(_ cells: [String]) -> String {
            "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }
                .joined(separator: " | ") + " |"
        }
        let delimiter = alignments.indices.map { column -> String in
            switch alignments[column] {
            case .leading: return isDeclared(column) ? ":--" : "---"
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
    /// - Parameter limit: how many lines may be read. A line still being typed is not a row, so a
    ///   caller reading an answer as it arrives stops the scan short of it.
    public static func scan(
        _ lines: [String], from start: Int, limit: Int? = nil
    ) -> (table: MarkdownTable, end: Int)? {
        let end = min(limit ?? lines.count, lines.count)
        guard start + 1 < end,
            let header = columns(lines[start]),
            let delimiter = delimiter(lines[start + 1]),
            delimiter.count == header.count
        else { return nil }
        let alignments = delimiter.map(\.alignment)
        var rows: [[String]] = []
        var index = start + 2
        while index < end, delimiterRow(lines[index]) == nil, let cells = columns(lines[index]) {
            rows.append(cells)
            index += 1
        }
        return (
            MarkdownTable(
                header: header, alignments: alignments, rows: rows,
                declared: delimiter.map(\.declared)),
            index
        )
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
        delimiter(line)?.map(\.alignment)
    }

    /// The delimiter row read whole: where each column sits, and whether the author said so.
    static func delimiter(_ line: String) -> [(alignment: Alignment, declared: Bool)]? {
        guard let cells = columns(line) else { return nil }
        var alignments: [(alignment: Alignment, declared: Bool)] = []
        for cell in cells {
            var body = Substring(cell)
            let leadingColon = body.hasPrefix(":")
            if leadingColon { body = body.dropFirst() }
            let trailingColon = body.hasSuffix(":")
            if trailingColon { body = body.dropLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
            switch (leadingColon, trailingColon) {
            case (true, true): alignments.append((.center, true))
            case (false, true): alignments.append((.trailing, true))
            default: alignments.append((.leading, leadingColon))
            }
        }
        return alignments
    }
}

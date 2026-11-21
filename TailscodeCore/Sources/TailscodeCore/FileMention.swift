import Foundation

/// The `@name` under the caret: the half-typed reference to a file that a prompt box completes
/// against the project the chat lives in. Every agent this app talks to reads `@path` as "this
/// file", so the box writes exactly that and nothing a model has to be taught.
public struct MentionToken: Sendable, Equatable {
    /// Where the `@` sits, in UTF-16 offsets.
    public let start: Int
    /// From the `@` through the caret.
    public let length: Int
    /// What has been typed after the `@`, without the quote a spaced path opens with.
    public let query: String

    public init(start: Int, length: Int, query: String) {
        self.start = start
        self.length = length
        self.query = query
    }

    private static let at: UInt16 = 0x40
    private static let quote: UInt16 = 0x22
    private static let newline: UInt16 = 0x0A
    private static let reach = 400

    /// The token the caret is at the end of, or nil when the caret is in ordinary words. The `@`
    /// has to open a word: one in the middle of an address is part of the address.
    public static func at(caret: Int, in text: String) -> MentionToken? {
        let units = Array(text.utf16)
        guard caret > 0, caret <= units.count else { return nil }
        var index = caret - 1
        let floor = max(0, caret - reach)
        while index >= floor {
            let unit = units[index]
            if unit == newline { return nil }
            if unit == at, opens(units, at: index) {
                let typed = units[(index + 1)..<caret]
                guard holdsOneName(typed) else { return nil }
                let query = String(decoding: typed, as: UTF16.self)
                return MentionToken(
                    start: index, length: caret - index,
                    query: query.hasPrefix("\"") ? String(query.dropFirst()) : query)
            }
            index -= 1
        }
        return nil
    }

    /// Whether what sits between an `@` and the caret is still one name: no space unless a quote
    /// opened it and has not closed, and no second `@`.
    private static func holdsOneName(_ typed: ArraySlice<UInt16>) -> Bool {
        guard !typed.contains(at) else { return false }
        if typed.first == quote { return !typed.dropFirst().contains(quote) }
        return !typed.contains(where: isSpace)
    }

    static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == newline || unit == 0x0D || unit == 0xA0
    }

    private static let openers: Set<UInt16> = [0x28, 0x5B, 0x7B, 0x2C, 0x3A, 0x3B]
    private static let trailers: Set<UInt16> = [0x2E, 0x2C, 0x3B, 0x3A, 0x21, 0x3F, 0x29, 0x5D, 0x7D]

    /// Whether the `@` at this offset begins a word.
    static func opens(_ units: [UInt16], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let before = units[index - 1]
        return isSpace(before) || openers.contains(before)
    }

    /// Where the name that starts at this `@` stops: at the closing quote of a spaced path, or at
    /// the first space, less any punctuation the sentence put after it.
    static func end(of units: [UInt16], from start: Int) -> Int {
        var index = start + 1
        if index < units.count, units[index] == quote {
            index += 1
            while index < units.count, units[index] != newline {
                if units[index] == quote { return index + 1 }
                index += 1
            }
            return index
        }
        while index < units.count, !isSpace(units[index]) { index += 1 }
        while index > start + 1, trailers.contains(units[index - 1]) { index -= 1 }
        return index
    }

    static func unquoted(_ name: String) -> String {
        guard name.hasPrefix("\"") else { return name }
        let body = name.dropFirst()
        return String(body.hasSuffix("\"") ? body.dropLast() : body)
    }

    /// A name reads as a path when it has a folder in it or ends in an extension. `@MainActor`
    /// and `@objc` have neither, and stay words.
    public static func looksLikePath(_ name: String) -> Bool {
        guard !name.contains("@"), name.contains(where: \.isLetter) else { return false }
        if name.contains("/") { return true }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ending = name[name.index(after: dot)...]
        return (1...8).contains(ending.count) && ending.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// The range a chosen file replaces: the whole name under the caret, including what the caret
    /// had not reached yet.
    public func replaced(in text: String) -> Range<Int> {
        let units = Array(text.utf16)
        guard start < units.count else { return start..<(start + length) }
        return start..<max(start + length, MentionToken.end(of: units, from: start))
    }

    /// What a chosen row writes. A folder ends in its slash and keeps the list open on what is
    /// inside it; a file ends in a space, because the next thing typed is the rest of the sentence.
    public static func completion(for entry: MentionEntry) -> String {
        let spaced = entry.path.contains(where: \.isWhitespace)
        let lead = spaced ? "@\"" : "@"
        if entry.isDirectory { return "\(lead)\(entry.path)/" }
        return spaced ? "\(lead)\(entry.path)\" " : "\(lead)\(entry.path) "
    }
}

/// One file or folder of the project, by its path from the project's root.
public struct MentionEntry: Sendable, Hashable {
    public let path: String
    public let isDirectory: Bool

    public init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }

    public var name: String {
        path.lastIndex(of: "/").map { String(path[path.index(after: $0)...]) } ?? path
    }

    /// The folder it sits in, empty for the root.
    public var folder: String {
        path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
    }

    public var depth: Int { path.reduce(0) { $1 == "/" ? $0 + 1 : $0 } }
}

public struct MentionRow: Sendable, Equatable {
    public let entry: MentionEntry
    /// Offsets into the entry's name that the typed letters landed on.
    public let highlight: [Int]
    /// Whether the working tree has changed this file.
    public let changed: Bool

    public init(entry: MentionEntry, highlight: [Int] = [], changed: Bool = false) {
        self.entry = entry
        self.highlight = highlight
        self.changed = changed
    }
}

public struct MentionSection: Sendable, Equatable {
    public enum Title: Sendable, Equatable {
        /// What the working tree has changed: what the next question is usually about.
        case changed
        case files
        /// The folder being walked, by its path from the root.
        case folder(String)
    }

    public let title: Title
    public let rows: [MentionRow]

    public init(title: Title, rows: [MentionRow]) {
        self.title = title
        self.rows = rows
    }
}

public struct MentionAnswer: Sendable, Equatable {
    public let sections: [MentionSection]
    /// A folder whose listing this answer is waiting for, by its path from the root.
    public let wanted: String?

    public init(sections: [MentionSection], wanted: String? = nil) {
        self.sections = sections
        self.wanted = wanted
    }

    public var rows: [MentionRow] { sections.flatMap(\.rows) }
    public var isEmpty: Bool { sections.allSatisfy(\.rows.isEmpty) }
}

/// What the app has learned of one project's files, a folder at a time, and how typed letters find
/// a file in it. Nothing here asks a server anything: a client lists folders with the route it
/// already has, shelves the answers, and reads rows back.
public struct MentionShelf: Sendable {
    /// The project's folder on the machine, absolute.
    public let root: String
    private var folders: [String: [MentionEntry]] = [:]
    private var dead: Set<String> = []
    /// Paths the working tree has changed, from the root, most telling first.
    public var changed: [String] = []

    public init(root: String) {
        self.root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
    }

    public var listedFolders: Int { folders.count }
    public var entryCount: Int { folders.values.reduce(0) { $0 + $1.count } }

    /// The absolute path a folder is listed by.
    public func absolute(_ folder: String) -> String {
        folder.isEmpty ? root : (root == "/" ? "/\(folder)" : "\(root)/\(folder)")
    }

    /// A path from a listing or a status, as this shelf names it: from the root, or nil when it
    /// lies outside the project.
    public func relative(_ path: String, under base: String? = nil) -> String? {
        let whole: String
        if path.hasPrefix("/") {
            whole = path
        } else if let base {
            whole = base.hasSuffix("/") ? "\(base)\(path)" : "\(base)/\(path)"
        } else {
            return path
        }
        if whole == root { return "" }
        let lead = root == "/" ? "/" : "\(root)/"
        guard whole.hasPrefix(lead) else { return nil }
        return String(whole.dropFirst(lead.count))
    }

    public func isListed(_ folder: String) -> Bool { folders[folder] != nil || dead.contains(folder) }

    public mutating func shelve(_ children: [(name: String, isDirectory: Bool)], in folder: String) {
        dead.remove(folder)
        folders[folder] = children
            .filter { !$0.name.isEmpty && !$0.name.hasPrefix(".") }
            .map {
                MentionEntry(
                    path: folder.isEmpty ? $0.name : "\(folder)/\($0.name)",
                    isDirectory: $0.isDirectory)
            }
            .sorted(by: MentionShelf.shelfOrder)
    }

    /// A folder the machine could not list is remembered, so it is not asked again every keystroke.
    public mutating func fail(_ folder: String) {
        dead.insert(folder)
    }

    /// Folders that could not be listed get another chance: the machine may have been out of
    /// reach rather than the folder gone.
    public mutating func forgive() {
        dead.removeAll()
    }

    /// Every folder on the shelf, nearest the root first.
    public var folderPaths: [String] {
        folders.keys.sorted {
            let left = $0.isEmpty ? -1 : $0.reduce(0) { $1 == "/" ? $0 + 1 : $0 }
            let right = $1.isEmpty ? -1 : $1.reduce(0) { $1 == "/" ? $0 + 1 : $0 }
            return (left, $0) < (right, $1)
        }
    }

    /// Whether a name written after an `@` is a file this shelf has seen.
    public func holds(_ path: String) -> Bool {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !trimmed.isEmpty else { return false }
        if changed.contains(trimmed) { return true }
        let entry = MentionEntry(path: trimmed, isDirectory: false)
        return folders[entry.folder]?.contains { $0.path == trimmed } ?? false
    }

    private static func shelfOrder(_ lhs: MentionEntry, _ rhs: MentionEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    /// The folders worth listing next, nearest the root first: the walk that lets letters find a
    /// file the person has not opened a folder for.
    public func frontier(excluding asked: Set<String>, limit: Int) -> [String] {
        guard limit > 0, folders.count < MentionCrawl.folderLimit,
            entryCount < MentionCrawl.entryLimit
        else { return [] }
        guard folders[""] != nil || dead.contains("") else { return asked.contains("") ? [] : [""] }
        let known = folders.values.joined()
            .filter {
                $0.isDirectory && $0.depth < MentionCrawl.depthLimit
                    && MentionCrawl.worthWalking($0.name)
                    && folders[$0.path] == nil && !dead.contains($0.path) && !asked.contains($0.path)
            }
            .sorted { ($0.depth, $0.path) < ($1.depth, $1.path) }
        let room = min(limit, MentionCrawl.folderLimit - folders.count)
        return known.prefix(room).map(\.path)
    }

    /// The rows for what has been typed after the `@`. A path from the machine's root or the
    /// home folder is not this project's to complete, and gets no rows.
    public func answer(_ query: String, limit: Int = 24) -> MentionAnswer {
        if query.hasPrefix("/") || query.hasPrefix("~") { return MentionAnswer(sections: []) }
        if let slash = query.lastIndex(of: "/") {
            return walk(
                folder: MentionShelf.tidy(String(query[..<slash])),
                component: String(query[query.index(after: slash)...]), limit: limit)
        }
        if query.isEmpty { return opening(limit: limit) }
        return find(query, limit: limit)
    }

    private static func tidy(_ folder: String) -> String {
        folder.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }.joined(separator: "/")
    }

    private var changedSet: Set<String> { Set(changed) }

    private func opening(limit: Int) -> MentionAnswer {
        let marks = changedSet
        let touched = changed.prefix(MentionCrawl.changedShown).map {
            MentionRow(entry: MentionEntry(path: $0, isDirectory: false), changed: true)
        }
        let top = (folders[""] ?? []).prefix(max(0, limit - touched.count)).map {
            MentionRow(entry: $0, changed: marks.contains($0.path))
        }
        return MentionAnswer(
            sections: [
                MentionSection(title: .changed, rows: Array(touched)),
                MentionSection(title: .files, rows: Array(top)),
            ],
            wanted: isListed("") ? nil : "")
    }

    private func walk(folder: String, component: String, limit: Int) -> MentionAnswer {
        guard let children = folders[folder] else {
            return MentionAnswer(
                sections: [MentionSection(title: .folder(folder), rows: [])],
                wanted: dead.contains(folder) ? nil : folder)
        }
        let marks = changedSet
        let rows: [MentionRow]
        if component.isEmpty {
            rows = children.map { MentionRow(entry: $0, changed: marks.contains($0.path)) }
        } else {
            rows = ranked(children, by: component, marks: marks)
        }
        return MentionAnswer(
            sections: [MentionSection(title: .folder(folder), rows: Array(rows.prefix(limit)))])
    }

    private func find(_ letters: String, limit: Int) -> MentionAnswer {
        let marks = changedSet
        var seen = Set<String>()
        var pool: [MentionEntry] = []
        for path in changed where seen.insert(path).inserted {
            pool.append(MentionEntry(path: path, isDirectory: false))
        }
        for entry in folders.values.joined() where seen.insert(entry.path).inserted {
            pool.append(entry)
        }
        let rows = ranked(pool, by: letters, marks: marks)
        return MentionAnswer(
            sections: [MentionSection(title: .files, rows: Array(rows.prefix(limit)))],
            wanted: isListed("") ? nil : "")
    }

    /// Best match first: how the letters landed, then a changed file, then the shorter name and
    /// the shallower one, so `brst` finds `BridgeStream.swift` before its tests and `pack` finds
    /// `Package.swift` at the root before one four folders down.
    private func ranked(_ entries: [MentionEntry], by letters: String, marks: Set<String>)
        -> [MentionRow]
    {
        struct Scored {
            let row: MentionRow
            let tier: FuzzyTier
        }
        let scored = entries.compactMap { entry -> Scored? in
            let name = entry.name
            guard let hit = FuzzyRank.hit(letters, in: name, separators: [".", "-", "_", " "]) else {
                return nil
            }
            return Scored(
                row: MentionRow(
                    entry: entry, highlight: hit.highlight, changed: marks.contains(entry.path)),
                tier: hit.tier)
        }
        return scored.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.row.changed != rhs.row.changed { return lhs.row.changed }
            let left = lhs.row.entry
            let right = rhs.row.entry
            if left.name.count != right.name.count { return left.name.count < right.name.count }
            if left.depth != right.depth { return left.depth < right.depth }
            return left.path < right.path
        }.map(\.row)
    }
}

/// How far the app walks a project on its own, and what it does not bother with. The walk is a
/// courtesy for finding a file by a few letters, never an index: it stops at a few dozen folders,
/// and a file past it is still one typed slash away.
public enum MentionCrawl {
    public static let depthLimit = 5
    public static let folderLimit = 64
    public static let entryLimit = 6_000
    public static let changedShown = 6
    /// How many folders are asked for at once.
    public static let abreast = 4

    private static let skipped: Set<String> = [
        "node_modules", "build", "Build", "DerivedData", "Pods", "target", "dist", "vendor", "venv",
        "__pycache__", "Carthage", "out", "coverage", "xcuserdata", "bower_components", "obj", "bin",
    ]
    private static let bundles: Set<String> = [
        "xcodeproj", "xcworkspace", "xcassets", "app", "framework", "bundle", "lproj", "appiconset",
        "imageset", "colorset", "playground", "docc",
    ]

    /// Whether a folder is worth listing unasked: not hidden, not somebody's build output, and
    /// not a bundle whose insides nobody names in a prompt.
    public static func worthWalking(_ name: String) -> Bool {
        guard !name.hasPrefix("."), !skipped.contains(name) else { return false }
        guard let dot = name.lastIndex(of: ".") else { return true }
        return !bundles.contains(String(name[name.index(after: dot)...]))
    }
}

public enum MentionWords {
    public static func title(_ title: MentionSection.Title) -> String {
        switch title {
        case .changed: return Localized.text("In this change")
        case .files: return Localized.text("Files")
        case .folder(let path): return path.isEmpty ? Localized.text("Files") : path
        }
    }

    /// What the list says while a folder's listing is on its way.
    public static var looking: String { Localized.text("Looking…") }

    public static var door: String { Localized.text("Find a file") }
    public static var commandsDoor: String { Localized.text("Commands") }
    public static var changed: String { Localized.text("Changed") }
}

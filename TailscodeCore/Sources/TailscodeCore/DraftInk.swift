import Foundation

/// What a prompt box can tell about the words in it while they are still being written: a command
/// the catalog knows, a file that was named, code set off by backticks, and the word that summons
/// ultracode. A box that shows these in their own ink says, before anything is sent, how the
/// message will be read. Anything it does not recognise stays ordinary ink — an unknown slash is
/// a slash, and `@MainActor` is a word.
public enum DraftInk {
    public enum Kind: Sendable, Equatable {
        case command
        case mention
        case code
        case power
    }

    /// One stretch of the draft, in UTF-16 offsets, which is what every text view counts in.
    public struct Run: Sendable, Hashable {
        public let start: Int
        public let length: Int
        public let kind: Kind

        public init(start: Int, length: Int, kind: Kind) {
            self.start = start
            self.length = length
            self.kind = kind
        }

        public var end: Int { start + length }
    }

    /// The runs of a draft, in order and never overlapping. Code wins over anything written inside
    /// it: a backticked `@name` is code, not a file.
    ///
    /// - Parameters:
    ///   - knowsCommand: whether a name typed after the leading slash is a command this chat has.
    ///   - knowsPath: whether what follows an `@` names a file; the default reads its shape.
    public static func read(
        _ text: String,
        knowsCommand: (String) -> Bool,
        knowsPath: (String) -> Bool = MentionToken.looksLikePath
    ) -> [Run] {
        let units = utf16(of: text)
        guard !units.isEmpty else { return [] }
        var runs = code(in: units)
        if let command = command(in: units, knows: knowsCommand), !overlaps(command, runs) {
            runs.append(command)
        }
        for run in mentions(in: units, knows: knowsPath) + power(in: text) where !overlaps(run, runs) {
            runs.append(run)
        }
        return runs.sorted { $0.start < $1.start }
    }

    /// One change to the words, in UTF-16 offsets: `removed` units at `location` gave way to
    /// `written` new ones.
    public struct Edit: Sendable, Equatable {
        public let location: Int
        public let removed: Int
        public let written: Int

        public init(location: Int, removed: Int, written: Int) {
            self.location = location
            self.removed = removed
            self.written = written
        }
    }

    /// What has to be put back to ordinary ink and what painted, after one edit, for a box to
    /// look as though it had been painted whole. Ink set over a whole draft makes the text view
    /// lay every line out again, which a long draft feels on every key, while an edit only ever
    /// disturbs the ink it touched.
    public struct Repaint: Sendable, Equatable {
        public let clear: [Range<Int>]
        public let paint: [Run]
    }

    /// Runs the edit left alone keep their ink and move with their words. A run the edit reached
    /// into, the words the edit wrote, and a run that is no longer wanted go back to ordinary ink;
    /// then every wanted run that was not already there, or that lies in what was cleared, is
    /// painted.
    ///
    /// - Parameters:
    ///   - old: the runs painted before the edit, in the old offsets.
    ///   - new: the runs the draft reads as now.
    ///   - length: the draft's length after the edit.
    public static func repaint(from old: [Run], to new: [Run], after edit: Edit, length: Int) -> Repaint {
        let delta = edit.written - edit.removed
        let removedEnd = edit.location + edit.removed
        let writtenEnd = edit.location + edit.written
        var kept: [Run] = []
        var clear: [Range<Int>] = edit.written > 0 ? [edit.location..<writtenEnd] : []
        for run in old {
            if run.end <= edit.location {
                kept.append(run)
            } else if run.start >= removedEnd {
                kept.append(Run(start: run.start + delta, length: run.length, kind: run.kind))
            } else {
                clear.append(min(run.start, edit.location)..<max(run.end + delta, writtenEnd))
            }
        }
        let wanted = Set(new)
        for run in kept where !wanted.contains(run) {
            clear.append(run.start..<run.end)
        }
        let whole = 0..<max(0, length)
        clear = clear.map { $0.clamped(to: whole) }.filter { !$0.isEmpty }
        let had = Set(kept)
        let paint = new.filter { run in
            !had.contains(run) || clear.contains { $0.overlaps(run.start..<run.end) }
        }
        return Repaint(clear: clear, paint: paint)
    }

    /// The text's UTF-16 units in one copy. A text view's words reach Swift as a bridged string,
    /// and reading those a unit at a time was a third of what reading a long draft cost.
    static func utf16(of text: String) -> [UInt16] {
        let length = text.utf16.count
        guard length > 0 else { return [] }
        #if canImport(ObjectiveC)
            let string = text as NSString
        #else
            let string = NSString(string: text)
        #endif
        return [UInt16](unsafeUninitializedCapacity: length) { buffer, count in
            guard let base = buffer.baseAddress else { return }
            string.getCharacters(base, range: NSRange(location: 0, length: length))
            count = length
        }
    }

    private static let slash: UInt16 = 0x2F
    private static let at: UInt16 = 0x40
    private static let tick: UInt16 = 0x60
    private static let newline: UInt16 = 0x0A

    private static func overlaps(_ run: Run, _ others: [Run]) -> Bool {
        others.contains { run.start < $0.end && $0.start < run.end }
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == newline || unit == 0x0D || unit == 0xA0
    }

    /// A name read out of the draft. Nearly every one is ASCII, which is copied byte for byte
    /// instead of being transcoded a unit at a time.
    static func string(_ units: ArraySlice<UInt16>) -> String {
        guard units.allSatisfy({ $0 < 0x80 }) else { return String(decoding: units, as: UTF16.self) }
        return String(unsafeUninitializedCapacity: units.count) { buffer in
            for (offset, unit) in units.enumerated() { buffer[offset] = UInt8(truncatingIfNeeded: unit) }
            return units.count
        }
    }

    private static func command(in units: [UInt16], knows: (String) -> Bool) -> Run? {
        guard units.first == slash else { return nil }
        let end = units.firstIndex(where: isSpace) ?? units.count
        guard end > 1, knows(string(units[1..<end])) else { return nil }
        return Run(start: 0, length: end, kind: .command)
    }

    /// Fences first, then spans on one line. Only what has been closed counts, so a backtick typed
    /// a moment ago does not repaint the rest of the draft while its partner is still to come.
    private static func code(in units: [UInt16]) -> [Run] {
        var runs: [Run] = []
        var index = 0
        while index < units.count {
            guard units[index] == tick else {
                index += 1
                continue
            }
            if let close = fenceClose(in: units, openedAt: index) {
                runs.append(Run(start: index, length: close - index, kind: .code))
                index = close
            } else if isFence(units, at: index) {
                index += 3
            } else if let close = spanClose(in: units, openedAt: index) {
                runs.append(Run(start: index, length: close - index, kind: .code))
                index = close
            } else {
                index += 1
            }
        }
        return runs
    }

    private static func isFence(_ units: [UInt16], at index: Int) -> Bool {
        index + 2 < units.count && units[index + 1] == tick && units[index + 2] == tick
    }

    private static func fenceClose(in units: [UInt16], openedAt start: Int) -> Int? {
        guard isFence(units, at: start) else { return nil }
        var index = start + 3
        while index < units.count {
            if units[index] == tick, isFence(units, at: index) { return index + 3 }
            index += 1
        }
        return nil
    }

    private static func spanClose(in units: [UInt16], openedAt start: Int) -> Int? {
        var index = start + 1
        while index < units.count, units[index] != newline {
            if units[index] == tick { return index > start + 1 ? index + 1 : nil }
            index += 1
        }
        return nil
    }

    private static func mentions(in units: [UInt16], knows: (String) -> Bool) -> [Run] {
        var runs: [Run] = []
        var index = 0
        while index < units.count {
            guard units[index] == at, MentionToken.opens(units, at: index) else {
                index += 1
                continue
            }
            let end = MentionToken.end(of: units, from: index)
            let named = MentionToken.unquoted(string(units[(index + 1)..<end]))
            if !named.isEmpty, knows(named) {
                runs.append(Run(start: index, length: end - index, kind: .mention))
            }
            index = max(end, index + 1)
        }
        return runs
    }

    private static let powerWord = try! NSRegularExpression(pattern: #"(?i)\bultracode\b"#)

    private static func power(in text: String) -> [Run] {
        guard text.range(of: Ultracode.effortLevel, options: .caseInsensitive) != nil else { return [] }
        let whole = NSRange(location: 0, length: (text as NSString).length)
        return powerWord.matches(in: text, options: [], range: whole).map {
            Run(start: $0.range.location, length: $0.range.length, kind: .power)
        }
    }
}

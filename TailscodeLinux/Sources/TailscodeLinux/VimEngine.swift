import Foundation

/// A vim editor over a plain string, with no toolkit in it at all: the composer hands it the text
/// and the caret, it answers with the text and the caret. Everything vim-shaped lives here so it
/// can be reasoned about — and tested — without a window.
enum VimMode: String {
    case insert
    case normal
    case visual
    case visualLine

    var label: String {
        switch self {
        case .insert: return "INSERT"
        case .normal: return "NORMAL"
        case .visual: return "VISUAL"
        case .visualLine: return "V-LINE"
        }
    }
}

/// One keystroke as the engine wants it: a character, or one of the few keys that have no
/// character. Modifiers other than shift arrive as `control`, because vim's own chords are the
/// only ones the composer intercepts.
struct VimKey {
    let character: Character?
    let isEscape: Bool
    let isEnter: Bool
    let isBackspace: Bool
    let control: Bool

    init(
        character: Character? = nil, isEscape: Bool = false, isEnter: Bool = false,
        isBackspace: Bool = false, control: Bool = false
    ) {
        self.character = character
        self.isEscape = isEscape
        self.isEnter = isEnter
        self.isBackspace = isBackspace
        self.control = control
    }
}

/// What the composer must do after a keystroke.
enum VimOutcome {
    /// The engine consumed the key; the buffer and caret are whatever the document now says.
    case handled
    /// The key belongs to the text view — ordinary typing in insert mode.
    case passThrough
    /// Normal-mode Enter: send the prompt, the way `:w` would commit it.
    case send
}

struct VimDocument {
    var characters: [Character]
    var cursor: Int

    init(text: String, cursor: Int) {
        characters = Array(text)
        self.cursor = max(0, min(cursor, characters.count))
    }

    var text: String { String(characters) }
}

final class VimEngine {
    private(set) var mode: VimMode = .insert
    private(set) var document = VimDocument(text: "", cursor: 0)

    private var count = ""
    private var pendingOperator: Character?
    private var pendingOperatorCount = 1
    private var pendingG = false
    private var pendingFind: Character?
    private var pendingReplace = false
    private var awaitingTextObject: Character?
    private var lastFind: (command: Character, target: Character)?
    private var anchor = 0
    private var register = ""
    private var registerIsLinewise = false
    private var undoStack: [VimDocument] = []
    private var redoStack: [VimDocument] = []

    /// The visual selection as a buffer range, or nil outside visual modes — the composer paints
    /// it as the text view's own selection so it looks like every other selection on the desktop.
    var selection: Range<Int>? {
        switch mode {
        case .visual:
            let lower = min(anchor, document.cursor)
            let upper = max(anchor, document.cursor)
            return lower..<min(upper + 1, document.characters.count)
        case .visualLine:
            let lower = lineStart(of: min(anchor, document.cursor))
            let upper = min(lineEnd(of: max(anchor, document.cursor)) + 1, document.characters.count)
            return lower..<upper
        case .insert, .normal:
            return nil
        }
    }

    func reset(to text: String, cursor: Int, mode: VimMode) {
        document = VimDocument(text: text, cursor: cursor)
        self.mode = mode
        clearPending()
        undoStack = []
        redoStack = []
    }

    func syncFromEditor(text: String, cursor: Int) {
        document = VimDocument(text: text, cursor: cursor)
    }

    func handle(_ key: VimKey, text: String, cursor: Int) -> VimOutcome {
        document = VimDocument(text: text, cursor: cursor)

        if key.isEscape {
            if mode == .insert { clampCursorLeftOfLineEnd() }
            mode = .normal
            clearPending()
            return .handled
        }
        if mode == .insert { return .passThrough }

        if key.control, let character = key.character {
            switch character {
            case "r": redo(); return .handled
            case "d": moveCursor(by: 10, lines: true); return .handled
            case "u": moveCursor(by: -10, lines: true); return .handled
            default: return .handled
            }
        }
        if key.isEnter { return mode == .normal ? .send : .handled }
        guard let character = key.character else { return .handled }
        return handle(character)
    }

    private func handle(_ character: Character) -> VimOutcome {
        if pendingReplace {
            pendingReplace = false
            replaceCharacter(with: character)
            return .handled
        }
        if let command = pendingFind {
            pendingFind = nil
            lastFind = (command, character)
            applyFind(command: command, target: character)
            return .handled
        }
        if let kind = awaitingTextObject {
            awaitingTextObject = nil
            if let range = textObject(kind: kind, delimiter: character) {
                applyPendingOperator(to: range, linewise: false)
            }
            return .handled
        }
        if pendingG {
            pendingG = false
            return handleAfterG(character)
        }

        if character.isNumber, !(character == "0" && count.isEmpty) {
            count.append(character)
            return .handled
        }

        if pendingOperator != nil {
            return handleOperatorPending(character)
        }
        return handleNormal(character)
    }

    // MARK: - Normal and visual commands

    private func handleNormal(_ character: Character) -> VimOutcome {
        let repeats = takeCount()
        // In visual mode `u` and `U` case the selection rather than undoing it — the one place
        // where a normal-mode letter means something else entirely.
        if mode == .visual || mode == .visualLine, character == "u" || character == "U",
            let range = selection
        {
            push()
            changeCase(in: range, uppercase: character == "U")
            mode = .normal
            clampCursorLeftOfLineEnd()
            return .handled
        }
        switch character {
        case "i", "a", "I", "A", "o", "O":
            guard mode == .normal else { return enterInsertFromVisual(character) }
            push()
            switch character {
            case "a": document.cursor = min(document.cursor + 1, document.characters.count)
            case "I": document.cursor = firstNonBlank(of: document.cursor)
            case "A": document.cursor = lineEnd(of: document.cursor) + 1
            case "o":
                document.cursor = min(lineEnd(of: document.cursor) + 1, document.characters.count)
                insert("\n", at: document.cursor)
                document.cursor += 1
            case "O":
                document.cursor = lineStart(of: document.cursor)
                insert("\n", at: document.cursor)
            default: break
            }
            mode = .insert
        case "v":
            if mode == .visual {
                mode = .normal
            } else {
                anchor = document.cursor
                mode = .visual
            }
        case "V":
            if mode == .visualLine {
                mode = .normal
            } else {
                anchor = document.cursor
                mode = .visualLine
            }
        case "d", "c", "y", "<", ">", "=":
            if mode == .normal {
                pendingOperator = character
                pendingOperatorCount = repeats
            } else if let range = selection {
                let linewise = mode == .visualLine
                pendingOperator = character
                pendingOperatorCount = 1
                applyPendingOperator(to: range, linewise: linewise)
            }
        case "x":
            applyDeletion(range: forwardRange(repeats), linewise: false, yank: true)
        case "X":
            let start = max(lineStart(of: document.cursor), document.cursor - repeats)
            applyDeletion(range: start..<document.cursor, linewise: false, yank: true)
        case "s":
            let range = mode == .normal ? forwardRange(repeats) : (selection ?? forwardRange(repeats))
            let linewise = mode == .visualLine
            mode = .insert
            applyDeletion(range: range, linewise: linewise, yank: true)
        case "S", "C":
            let range = character == "S"
                ? lineRange(of: document.cursor, includingNewline: false)
                : document.cursor..<(lineEnd(of: document.cursor) + 1)
            mode = .insert
            applyDeletion(range: clamped(range), linewise: false, yank: true)
        case "D":
            applyDeletion(
                range: clamped(document.cursor..<(lineEnd(of: document.cursor) + 1)),
                linewise: false, yank: true)
        case "Y":
            yank(range: lineRange(of: document.cursor, includingNewline: true), linewise: true)
        case "p", "P":
            paste(after: character == "p", times: repeats)
        case "u":
            undo()
        case "~":
            toggleCase(count: repeats)
        case "J":
            joinLines(count: max(2, repeats))
        case "r":
            pendingReplace = true
        case "f", "F", "t", "T":
            pendingFind = character
        case ";", ",":
            if let last = lastFind {
                let command = character == ";" ? last.command : inverted(last.command)
                applyFind(command: command, target: last.target)
            }
        case "g":
            pendingG = true
            count = "\(repeats == 1 ? "" : String(repeats))"
        case "G":
            document.cursor = repeats == 1 && count.isEmpty
                ? firstNonBlank(of: max(0, document.characters.count - 1))
                : firstNonBlank(of: offsetOfLine(repeats - 1))
        default:
            if let target = motionTarget(character, count: repeats) {
                document.cursor = target
            }
        }
        if mode == .normal { clampCursorLeftOfLineEnd() }
        return .handled
    }

    private func enterInsertFromVisual(_ character: Character) -> VimOutcome {
        guard let range = selection else { return .handled }
        push()
        document.cursor = character == "a" || character == "A" ? range.upperBound : range.lowerBound
        mode = .insert
        return .handled
    }

    private func handleAfterG(_ character: Character) -> VimOutcome {
        let repeats = takeCount()
        switch character {
        case "g":
            document.cursor = firstNonBlank(of: offsetOfLine(max(0, repeats - 1)))
        case "u", "U":
            if mode == .normal {
                pendingOperator = character == "u" ? "\u{1}" : "\u{2}"
                pendingOperatorCount = repeats
            } else if let range = selection {
                push()
                changeCase(in: range, uppercase: character == "U")
                mode = .normal
            }
        default:
            break
        }
        if mode == .normal { clampCursorLeftOfLineEnd() }
        return .handled
    }

    /// The second half of an operator: a doubled key means the line, `i`/`a` a text object,
    /// anything else a motion whose span is what the operator eats.
    private func handleOperatorPending(_ character: Character) -> VimOutcome {
        guard let pending = pendingOperator else { return .handled }
        if character.isNumber, !(character == "0" && count.isEmpty) {
            count.append(character)
            return .handled
        }
        let motionCount = takeCount()
        let total = max(1, pendingOperatorCount * motionCount)

        if character == pending
            || (pending == "\u{1}" && character == "u") || (pending == "\u{2}" && character == "U")
        {
            var range = lineRange(of: document.cursor, includingNewline: true)
            if total > 1 {
                let endLine = min(document.characters.count, offsetOfLine(lineIndex(of: document.cursor) + total))
                range = range.lowerBound..<max(range.upperBound, endLine)
            }
            applyPendingOperator(to: clamped(range), linewise: true)
            return .handled
        }
        if character == "i" || character == "a" {
            awaitingTextObject = character
            pendingOperatorCount = total
            return .handled
        }
        if character == "g" {
            pendingG = true
            return .handled
        }
        if character == "f" || character == "F" || character == "t" || character == "T" {
            pendingFind = character
            pendingOperatorCount = total
            return .handled
        }
        guard var target = motionTarget(character, count: total) else {
            clearPending()
            return .handled
        }
        // `dw` on the last word of a line stops at the line's end rather than swallowing the
        // newline, and `de` takes the character it lands on — the two places where an operator's
        // span differs from the same motion's landing spot.
        if character == "w" || character == "W" {
            target = min(target, max(lineEnd(of: document.cursor), document.cursor))
        }
        if character == "e" || character == "E" {
            target = min(target + 1, document.characters.count)
        }
        let linewise = character == "j" || character == "k"
        var range = target > document.cursor ? document.cursor..<target : target..<document.cursor
        if linewise {
            range = lineStart(of: range.lowerBound)..<min(
                document.characters.count, lineEnd(of: max(range.lowerBound, range.upperBound - 1)) + 1)
        }
        applyPendingOperator(to: clamped(range), linewise: linewise)
        return .handled
    }

    private func applyPendingOperator(to range: Range<Int>, linewise: Bool) {
        defer { clearPending() }
        guard let pending = pendingOperator else { return }
        switch pending {
        case "d":
            applyDeletion(range: range, linewise: linewise, yank: true)
            mode = .normal
        case "c":
            mode = .insert
            applyDeletion(range: range, linewise: false, yank: true)
        case "y":
            yank(range: range, linewise: linewise)
            document.cursor = range.lowerBound
            mode = .normal
        case ">", "<":
            push()
            indent(range: range, out: pending == "<")
            mode = .normal
        case "\u{1}", "\u{2}":
            push()
            changeCase(in: range, uppercase: pending == "\u{2}")
            mode = .normal
        default:
            mode = .normal
        }
        if mode == .normal { clampCursorLeftOfLineEnd() }
    }

    // MARK: - Motions

    private func motionTarget(_ character: Character, count: Int) -> Int? {
        var target = document.cursor
        for _ in 0..<max(1, count) {
            switch character {
            case "h": target = max(lineStart(of: target), target - 1)
            case "l": target = min(lineEnd(of: target), target + 1)
            case "j": target = verticalTarget(from: target, delta: 1)
            case "k": target = verticalTarget(from: target, delta: -1)
            case "w": target = nextWordStart(from: target, bigWord: false)
            case "W": target = nextWordStart(from: target, bigWord: true)
            case "b": target = previousWordStart(from: target, bigWord: false)
            case "B": target = previousWordStart(from: target, bigWord: true)
            case "e": target = wordEnd(from: target, bigWord: false)
            case "E": target = wordEnd(from: target, bigWord: true)
            case "0": target = lineStart(of: target)
            case "^": target = firstNonBlank(of: target)
            case "$": target = lineEnd(of: target)
            case "{": target = paragraphTarget(from: target, forward: false)
            case "}": target = paragraphTarget(from: target, forward: true)
            case "%": target = matchingBracket(from: target) ?? target
            default: return nil
            }
        }
        return target
    }

    private func verticalTarget(from index: Int, delta: Int) -> Int {
        let column = index - lineStart(of: index)
        let line = lineIndex(of: index) + delta
        guard line >= 0, line < lineCount else { return index }
        let start = offsetOfLine(line)
        return min(start + column, lineEnd(of: start))
    }

    private func moveCursor(by amount: Int, lines: Bool) {
        guard lines else { return }
        document.cursor = verticalTarget(from: document.cursor, delta: amount)
    }

    private func applyFind(command: Character, target: Character) {
        let forward = command == "f" || command == "t"
        let till = command == "t" || command == "T"
        let bounds = lineStart(of: document.cursor)...lineEnd(of: document.cursor)
        var index = document.cursor
        while true {
            index += forward ? 1 : -1
            guard bounds.contains(index), index < document.characters.count else { return }
            if document.characters[index] == target {
                let landing = till ? (forward ? index - 1 : index + 1) : index
                if pendingOperator != nil {
                    let range = landing >= document.cursor
                        ? document.cursor..<min(landing + 1, document.characters.count)
                        : landing..<document.cursor
                    applyPendingOperator(to: clamped(range), linewise: false)
                } else {
                    document.cursor = landing
                }
                return
            }
        }
    }

    private func inverted(_ command: Character) -> Character {
        switch command {
        case "f": return "F"
        case "F": return "f"
        case "t": return "T"
        default: return "t"
        }
    }

    /// `iw`, `aw`, and the paired delimiters — the objects that make `ci"` and `da(` work, which
    /// is most of why a person turns vim mode on in a prompt box.
    private func textObject(kind: Character, delimiter: Character) -> Range<Int>? {
        let inner = kind == "i"
        if delimiter == "w" || delimiter == "W" {
            let big = delimiter == "W"
            var start = document.cursor
            while start > 0, isWordCharacter(document.characters[start - 1], bigWord: big) { start -= 1 }
            var end = document.cursor
            while end < document.characters.count, isWordCharacter(document.characters[end], bigWord: big) {
                end += 1
            }
            if !inner {
                while end < document.characters.count, document.characters[end] == " " { end += 1 }
            }
            return start..<end
        }
        guard let pair = pairing(for: delimiter) else { return nil }
        let bounds: (open: Int, close: Int)?
        if pair.open == pair.close {
            bounds = symmetricPair(of: pair.open)
        } else if let open = searchBackward(for: pair.open, close: pair.close),
            let close = searchForward(for: pair.close, open: pair.open)
        {
            bounds = (open, close)
        } else {
            bounds = nil
        }
        guard let bounds, bounds.close > bounds.open else { return nil }
        return inner
            ? (bounds.open + 1)..<bounds.close
            : bounds.open..<min(bounds.close + 1, document.characters.count)
    }

    /// Quotes have no direction, so they are paired by counting along the line rather than by
    /// nesting: the pair that contains the caret, or the next one after it.
    private func symmetricPair(of delimiter: Character) -> (open: Int, close: Int)? {
        let start = lineStart(of: document.cursor)
        let end = lineEnd(of: document.cursor)
        var positions: [Int] = []
        var index = start
        while index < end {
            if document.characters[index] == delimiter { positions.append(index) }
            index += 1
        }
        var pair = 0
        while pair + 1 < positions.count {
            let open = positions[pair]
            let close = positions[pair + 1]
            if document.cursor <= close { return (open, close) }
            pair += 2
        }
        return nil
    }

    private func pairing(for delimiter: Character) -> (open: Character, close: Character)? {
        switch delimiter {
        case "(", ")", "b": return ("(", ")")
        case "{", "}", "B": return ("{", "}")
        case "[", "]": return ("[", "]")
        case "<", ">": return ("<", ">")
        case "\"": return ("\"", "\"")
        case "'": return ("'", "'")
        case "`": return ("`", "`")
        default: return nil
        }
    }

    private func searchBackward(for open: Character, close: Character) -> Int? {
        var depth = 0
        var index = document.cursor
        if index < document.characters.count, document.characters[index] == open { return index }
        while index > 0 {
            index -= 1
            let character = document.characters[index]
            if character == close, open != close { depth += 1 }
            if character == open {
                if depth == 0 { return index }
                depth -= 1
            }
        }
        return nil
    }

    private func searchForward(for close: Character, open: Character) -> Int? {
        var depth = 0
        var index = document.cursor
        if index < document.characters.count, document.characters[index] == open, open != close {
            index += 1
        }
        while index < document.characters.count {
            let character = document.characters[index]
            if character == open, open != close, index != document.cursor { depth += 1 }
            if character == close {
                if depth == 0 { return index }
                depth -= 1
            }
            index += 1
        }
        return nil
    }

    private func matchingBracket(from index: Int) -> Int? {
        guard index < document.characters.count else { return nil }
        let character = document.characters[index]
        let opens: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
        let closes: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        if let close = opens[character] {
            var depth = 0
            var cursor = index
            while cursor < document.characters.count {
                if document.characters[cursor] == character { depth += 1 }
                if document.characters[cursor] == close {
                    depth -= 1
                    if depth == 0 { return cursor }
                }
                cursor += 1
            }
        } else if let open = closes[character] {
            var depth = 0
            var cursor = index
            while cursor >= 0 {
                if document.characters[cursor] == character { depth += 1 }
                if document.characters[cursor] == open {
                    depth -= 1
                    if depth == 0 { return cursor }
                }
                cursor -= 1
            }
        }
        return nil
    }

    private func paragraphTarget(from index: Int, forward: Bool) -> Int {
        var line = lineIndex(of: index)
        repeat {
            line += forward ? 1 : -1
            if line <= 0 { return 0 }
            if line >= lineCount { return max(0, document.characters.count - 1) }
        } while !isBlankLine(line)
        return offsetOfLine(line)
    }

    // MARK: - Edits

    private func applyDeletion(range: Range<Int>, linewise: Bool, yank shouldYank: Bool) {
        let range = clamped(range)
        guard !range.isEmpty else { return }
        push()
        if shouldYank { yank(range: range, linewise: linewise) }
        document.characters.removeSubrange(range)
        document.cursor = min(range.lowerBound, max(0, document.characters.count))
        if mode != .insert { clampCursorLeftOfLineEnd() }
        mode = mode == .visual || mode == .visualLine ? .normal : mode
    }

    private func yank(range: Range<Int>, linewise: Bool) {
        let range = clamped(range)
        register = String(document.characters[range])
        registerIsLinewise = linewise
        if mode == .visual || mode == .visualLine { mode = .normal }
    }

    private func paste(after: Bool, times: Int) {
        guard !register.isEmpty else { return }
        push()
        let payload = String(repeating: register, count: max(1, times))
        if registerIsLinewise {
            let insertion = after ? min(lineEnd(of: document.cursor) + 1, document.characters.count)
                : lineStart(of: document.cursor)
            let block = payload.hasSuffix("\n") ? payload : payload + "\n"
            insert(block, at: insertion)
            document.cursor = firstNonBlank(of: insertion)
        } else {
            let insertion = after
                ? min(document.cursor + (document.characters.isEmpty ? 0 : 1), document.characters.count)
                : document.cursor
            insert(payload, at: insertion)
            document.cursor = insertion + payload.count - 1
        }
        clampCursorLeftOfLineEnd()
    }

    private func replaceCharacter(with character: Character) {
        guard document.cursor < document.characters.count else { return }
        push()
        document.characters[document.cursor] = character
    }

    private func toggleCase(count: Int) {
        push()
        for _ in 0..<max(1, count) {
            guard document.cursor < document.characters.count else { break }
            let character = document.characters[document.cursor]
            document.characters[document.cursor] =
                character.isUppercase
                ? Character(character.lowercased()) : Character(character.uppercased())
            document.cursor += 1
        }
        clampCursorLeftOfLineEnd()
    }

    private func changeCase(in range: Range<Int>, uppercase: Bool) {
        let range = clamped(range)
        for index in range {
            let character = document.characters[index]
            document.characters[index] =
                uppercase
                ? Character(character.uppercased()) : Character(character.lowercased())
        }
        document.cursor = range.lowerBound
    }

    private func joinLines(count: Int) {
        push()
        for _ in 0..<max(1, count - 1) {
            let end = lineEnd(of: document.cursor)
            guard end < document.characters.count else { break }
            document.characters.remove(at: end)
            var trailing = end
            while trailing < document.characters.count, document.characters[trailing] == " " {
                document.characters.remove(at: trailing)
            }
            document.characters.insert(" ", at: end)
            document.cursor = end
            _ = trailing
        }
    }

    private func indent(range: Range<Int>, out: Bool) {
        let unit = "    "
        var line = lineIndex(of: range.lowerBound)
        let lastLine = lineIndex(of: max(range.lowerBound, range.upperBound - 1))
        while line <= lastLine {
            let start = offsetOfLine(line)
            if out {
                var removed = 0
                while removed < unit.count, start < document.characters.count,
                    document.characters[start] == " "
                {
                    document.characters.remove(at: start)
                    removed += 1
                }
            } else {
                document.characters.insert(contentsOf: Array(unit), at: start)
            }
            line += 1
        }
        document.cursor = firstNonBlank(of: min(document.cursor, max(0, document.characters.count - 1)))
    }

    private func insert(_ text: String, at index: Int) {
        document.characters.insert(contentsOf: Array(text), at: min(index, document.characters.count))
    }

    // MARK: - Undo

    private func push() {
        undoStack.append(document)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack = []
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
        clampCursorLeftOfLineEnd()
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
        clampCursorLeftOfLineEnd()
    }

    // MARK: - Geometry

    private var lineCount: Int {
        document.characters.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private func lineIndex(of index: Int) -> Int {
        document.characters.prefix(max(0, index)).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private func offsetOfLine(_ line: Int) -> Int {
        guard line > 0 else { return 0 }
        var seen = 0
        for (index, character) in document.characters.enumerated() where character == "\n" {
            seen += 1
            if seen == line { return index + 1 }
        }
        return max(0, document.characters.count)
    }

    private func lineStart(of index: Int) -> Int {
        var cursor = min(index, max(0, document.characters.count - 1))
        while cursor > 0, document.characters[cursor - 1] != "\n" { cursor -= 1 }
        return max(0, cursor)
    }

    private func lineEnd(of index: Int) -> Int {
        var cursor = min(index, document.characters.count)
        while cursor < document.characters.count, document.characters[cursor] != "\n" { cursor += 1 }
        return cursor
    }

    private func lineRange(of index: Int, includingNewline: Bool) -> Range<Int> {
        let start = lineStart(of: index)
        let end = lineEnd(of: index)
        return start..<(includingNewline ? min(end + 1, document.characters.count) : end)
    }

    private func firstNonBlank(of index: Int) -> Int {
        var cursor = lineStart(of: index)
        let end = lineEnd(of: index)
        while cursor < end, document.characters[cursor] == " " || document.characters[cursor] == "\t" {
            cursor += 1
        }
        return cursor
    }

    private func isBlankLine(_ line: Int) -> Bool {
        let start = offsetOfLine(line)
        return start >= document.characters.count || document.characters[start] == "\n"
    }

    private func forwardRange(_ count: Int) -> Range<Int> {
        let end = min(lineEnd(of: document.cursor), document.cursor + max(1, count))
        return document.cursor..<end
    }

    private func clamped(_ range: Range<Int>) -> Range<Int> {
        let lower = max(0, min(range.lowerBound, document.characters.count))
        let upper = max(lower, min(range.upperBound, document.characters.count))
        return lower..<upper
    }

    /// Normal mode's caret sits on a character, never past the last one — the difference that
    /// makes `$x` delete the final character rather than nothing.
    private func clampCursorLeftOfLineEnd() {
        let end = lineEnd(of: document.cursor)
        let start = lineStart(of: document.cursor)
        if document.cursor >= end, end > start { document.cursor = end - 1 }
        document.cursor = max(0, min(document.cursor, max(0, document.characters.count)))
    }

    private func isWordCharacter(_ character: Character, bigWord: Bool) -> Bool {
        if bigWord { return !character.isWhitespace }
        return character.isLetter || character.isNumber || character == "_"
    }

    private func nextWordStart(from index: Int, bigWord: Bool) -> Int {
        var cursor = index
        let count = document.characters.count
        guard cursor < count else { return cursor }
        let onWord = isWordCharacter(document.characters[cursor], bigWord: bigWord)
        if onWord {
            while cursor < count, isWordCharacter(document.characters[cursor], bigWord: bigWord) {
                cursor += 1
            }
        } else if !document.characters[cursor].isWhitespace {
            while cursor < count, !isWordCharacter(document.characters[cursor], bigWord: bigWord),
                !document.characters[cursor].isWhitespace
            {
                cursor += 1
            }
        }
        while cursor < count, document.characters[cursor].isWhitespace { cursor += 1 }
        return cursor
    }

    private func previousWordStart(from index: Int, bigWord: Bool) -> Int {
        var cursor = index
        while cursor > 0, document.characters[cursor - 1].isWhitespace { cursor -= 1 }
        guard cursor > 0 else { return 0 }
        let isWord = isWordCharacter(document.characters[cursor - 1], bigWord: bigWord)
        while cursor > 0 {
            let character = document.characters[cursor - 1]
            if character.isWhitespace { break }
            if isWordCharacter(character, bigWord: bigWord) != isWord { break }
            cursor -= 1
        }
        return cursor
    }

    private func wordEnd(from index: Int, bigWord: Bool) -> Int {
        var cursor = index + 1
        let count = document.characters.count
        while cursor < count, document.characters[cursor].isWhitespace { cursor += 1 }
        while cursor + 1 < count, isWordCharacter(document.characters[cursor + 1], bigWord: bigWord) {
            cursor += 1
        }
        return min(cursor, max(0, count - 1))
    }

    private func takeCount() -> Int {
        defer { count = "" }
        return max(1, Int(count) ?? 1)
    }

    private func clearPending() {
        count = ""
        pendingOperator = nil
        pendingOperatorCount = 1
        pendingG = false
        pendingFind = nil
        pendingReplace = false
        awaitingTextObject = nil
    }
}

@_exported import CTerminalEngine
import Foundation

/// A terminal's screen: what a shell's bytes add up to, and what a keyboard and a pointer turn
/// into on the way back.
///
/// It may be used from any thread. The usual arrangement is one thread feeding it the shell's
/// bytes while the client's own thread takes frames, and only ``frame(force:)`` has a rule: one
/// thread takes frames, because a frame's rows are read after the lock is let go.
public final class TerminalScreen: @unchecked Sendable {
    /// False in a build made without the engine: there is no screen to make, and the pane says so.
    public static var isAvailable: Bool { ts_engine_available() }

    private let handle: OpaquePointer

    public init?(cols: Int, rows: Int, scrollbackLines: Int = 10_000) {
        guard
            let handle = ts_terminal_new(
                UInt16(clamping: cols), UInt16(clamping: rows), UInt32(clamping: scrollbackLines))
        else { return nil }
        self.handle = handle
    }

    deinit {
        ts_terminal_free(handle)
    }

    private static func taken(_ bytes: UnsafeMutablePointer<UInt8>?, _ length: Int) -> Data {
        guard let bytes else { return Data() }
        defer { ts_bytes_free(bytes) }
        return Data(bytes: bytes, count: length)
    }

    /// Draws the shell's bytes. What comes back is what the terminal owes the shell in answer (a
    /// status report, a size), to be sent as if it had been typed; usually nothing.
    @discardableResult
    public func feed(_ data: Data) -> Data {
        data.withUnsafeBytes { raw in
            ts_terminal_write(handle, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        var length = 0
        return Self.taken(ts_terminal_take_replies(handle, &length), length)
    }

    public func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        ts_terminal_resize(
            handle, UInt16(clamping: cols), UInt16(clamping: rows), UInt32(clamping: cellWidth),
            UInt32(clamping: cellHeight))
    }

    /// Forgets the screen, the scrollback and every mode, for a stream that starts over.
    public func reset() {
        ts_terminal_reset(handle)
    }

    public func apply(_ colors: TerminalColors) {
        var ansi = colors.ansi
        while ansi.count < 16 { ansi.append(colors.foreground) }
        ts_terminal_set_theme(
            handle, colors.foreground, colors.background, colors.cursor, ansi,
            colors.selectionForeground, colors.selectionBackground, colors.isDark)
    }

    /// What there is to draw. The frame's rows belong to the screen and are good until the next
    /// frame is taken.
    public func frame(force: Bool = false) -> TerminalFrame {
        var raw = TSFrame()
        ts_terminal_frame(handle, &raw, force)
        return TerminalFrame(raw: raw, held: nil)
    }

    private func string(_ read: (UnsafeMutablePointer<CChar>?, Int) -> Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = min(read(&buffer, buffer.count), buffer.count)
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The title a program gave the window, when one did.
    public var title: String? { string { ts_terminal_title(handle, $0, $1) } }

    /// The folder a shell said it is in (OSC 7), when its setup reports one.
    public var reportedDirectory: String? {
        guard let raw = string({ ts_terminal_reported_directory(handle, $0, $1) }) else { return nil }
        guard raw.hasPrefix("file://") else { return raw.hasPrefix("/") ? raw : nil }
        return URL(string: raw)?.path
    }

    private func encoded(_ capacity: Int = 128, _ write: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> Data {
        var buffer = [UInt8](repeating: 0, count: capacity)
        let length = min(write(&buffer, capacity), capacity)
        return Data(buffer.prefix(max(length, 0)))
    }

    /// The bytes a key press is, for the program that is listening now.
    public func bytes(for press: TerminalKeyPress) -> Data {
        let unshifted = press.unshifted?.unicodeScalars.first?.value ?? 0
        let text = Array(press.text.utf8)
        return encoded { out, capacity in
            text.withUnsafeBufferPointer { raw in
                raw.withMemoryRebound(to: CChar.self) { chars in
                    ts_terminal_key(
                        handle, press.key.rawValue, press.modifiers.rawValue,
                        UInt8(press.isRepeat ? TS_KEY_REPEAT : TS_KEY_PRESS), chars.baseAddress,
                        chars.count, unshifted, out, capacity)
                }
            }
        }
    }

    /// Text that did not come from a key: bracketed when the program asked for that.
    public func bytes(pasting text: String) -> Data {
        let utf8 = Array(text.utf8)
        var length = 0
        let bytes = utf8.withUnsafeBufferPointer { raw in
            raw.withMemoryRebound(to: CChar.self) { ts_terminal_paste(handle, $0.baseAddress, $0.count, &length) }
        }
        return Self.taken(bytes, length)
    }

    /// Whether pasting this could run a command before the person has read it.
    public func pasteIsRisky(_ text: String) -> Bool {
        let utf8 = Array(text.utf8)
        return utf8.withUnsafeBufferPointer { raw in
            raw.withMemoryRebound(to: CChar.self) { ts_terminal_paste_is_risky(handle, $0.baseAddress, $0.count) }
        }
    }

    /// What a program that asked to know is told when the pane gains or loses the keyboard.
    public func bytes(focused: Bool) -> Data {
        encoded(16) { ts_terminal_focus(handle, focused, $0, $1) }
    }

    /// Where the cells are, in pixels, so a pointer position can be turned into one.
    public func setGeometry(
        cellWidth: Int, cellHeight: Int, paddingLeft: Int, paddingTop: Int, width: Int, height: Int
    ) {
        ts_terminal_set_geometry(
            handle, UInt32(clamping: cellWidth), UInt32(clamping: cellHeight),
            UInt32(clamping: paddingLeft), UInt32(clamping: paddingTop), UInt32(clamping: width),
            UInt32(clamping: height))
    }

    public enum PointerAction: UInt8, Sendable {
        case press = 0
        case release = 1
        case motion = 2
    }

    public enum PointerButton: UInt8, Sendable {
        case none = 0
        case left = 1
        case right = 2
        case middle = 3
    }

    /// A pointer event for a program that asked for the mouse. Empty when no program is
    /// listening, or Shift is held: the pointer is then the person's, for selecting.
    public func bytes(
        pointer action: PointerAction, button: PointerButton, modifiers: TerminalModifiers, x: Double,
        y: Double, anyPressed: Bool
    ) -> Data {
        encoded(64) {
            ts_terminal_mouse(
                handle, action.rawValue, button.rawValue, modifiers.rawValue, Float(x), Float(y),
                anyPressed, $0, $1)
        }
    }

    /// A turn of the wheel, negative up. Scrolls the scrollback, unless a full-screen program has
    /// the screen: then it is told, and its bytes come back.
    public func wheel(rows: Int, modifiers: TerminalModifiers, x: Double, y: Double) -> Data {
        encoded(512) {
            ts_terminal_wheel(handle, Int32(clamping: rows), modifiers.rawValue, Float(x), Float(y), $0, $1)
        }
    }

    public func scrollToBottom() {
        ts_terminal_scroll_to_bottom(handle)
    }

    public func scroll(toRow row: UInt64) {
        ts_terminal_scroll_to_row(handle, row)
    }

    public func scroll(pages: Int) {
        ts_terminal_scroll_pages(handle, Int32(clamping: pages))
    }

    public enum SelectPhase: UInt8, Sendable {
        case press = 0
        case release = 1
        case drag = 2
    }

    /// The selecting pointer. Two presses close together take the word, three the line.
    public func select(_ phase: SelectPhase, x: Double, y: Double) {
        ts_terminal_select(handle, phase.rawValue, Float(x), Float(y), DispatchTime.now().uptimeNanoseconds)
    }

    public func selectAll() {
        ts_terminal_select_all(handle)
    }

    public func clearSelection() {
        ts_terminal_clear_selection(handle)
    }

    public var hasSelection: Bool { ts_terminal_has_selection(handle) }

    private func text(_ read: (inout Int) -> UnsafeMutablePointer<UInt8>?) -> String? {
        var length = 0
        guard let bytes = read(&length) else { return nil }
        defer { ts_bytes_free(bytes) }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
    }

    /// The selected text, wrapped lines joined, nil with nothing selected.
    public var selectionText: String? { text { ts_terminal_selection_text(handle, &$0) } }

    /// Everything the screen holds, scrollback first.
    public var text: String { text { ts_terminal_text(handle, &$0) } ?? "" }
}

/// One frame of a terminal: every cell with its final colours, which rows changed, the cursor and
/// where the scrollback stands. It borrows the screen's memory, so it is drawn and dropped.
public struct TerminalFrame {
    public let raw: TSFrame
    /// Memory a frame drawn over (``PredictiveEcho``) points into, kept for as long as the frame.
    private let held: FrameCopy?

    init(raw: TSFrame, held: FrameCopy? = nil) {
        self.raw = raw
        self.held = held
    }

    /// The frame with `bytes` drawn from the cursor on, the cursor after them, and `stale` rows
    /// marked changed, for rows a drawing over left behind. Nil when there is nothing to change or
    /// the screen is not one to draw over: a full-screen program, scrollback, a hidden cursor.
    func drawn(over bytes: [UInt8], stale: Int?) -> (frame: TerminalFrame, row: Int?)? {
        guard !isEmpty, let cells = raw.cells, let dirtyRows = raw.row_dirty else { return nil }
        let row = Int(raw.cursor_y)
        let column = Int(raw.cursor_x)
        let fits = !raw.alternate_screen && raw.cursor_visible && rowsBelow == 0 && row < rows && column < cols
        let count = fits ? min(bytes.count, cols - 1 - column) : 0
        let staleRow = stale.flatMap { $0 < rows ? $0 : nil }
        guard count > 0 || staleRow != nil else { return nil }
        let copy = FrameCopy(cells: cells, count: rows * cols, dirty: dirtyRows, rows: rows)
        var patched = raw
        if let staleRow { copy.dirty[staleRow] = 1 }
        if count > 0 {
            let base = row * cols + column
            let under = copy.cells[base]
            for index in 0..<count {
                var cell = copy.cells[base + index]
                cell.codepoint = UInt32(bytes[index])
                cell.fg = raw.foreground
                cell.bg = index == 0 ? under.bg : cell.bg
                cell.width = 1
                cell.extra = 0
                cell.extra_offset = 0
                cell.flags = 0
                cell.decoration = 0
                copy.cells[base + index] = cell
            }
            copy.dirty[row] = 1
            patched.cursor_x = UInt16(column + count)
        }
        patched.cells = UnsafePointer(copy.cells)
        patched.row_dirty = UnsafePointer(copy.dirty)
        if patched.dirty == UInt8(TS_DIRTY_NONE) { patched.dirty = UInt8(TS_DIRTY_ROWS) }
        return (TerminalFrame(raw: patched, held: copy), count > 0 ? row : nil)
    }

    public var cols: Int { Int(raw.cols) }
    public var rows: Int { Int(raw.rows) }
    public var isEmpty: Bool { raw.cells == nil || raw.cols == 0 || raw.rows == 0 }
    /// Whether anything changed since the frame before.
    public var changed: Bool { raw.dirty != UInt8(TS_DIRTY_NONE) }
    public var everythingChanged: Bool { raw.dirty == UInt8(TS_DIRTY_ALL) }

    public func rowChanged(_ row: Int) -> Bool {
        guard let dirty = raw.row_dirty, row >= 0, row < rows else { return false }
        return dirty[row] != 0
    }

    public func cells(row: Int) -> UnsafeBufferPointer<TSCell> {
        guard let cells = raw.cells, row >= 0, row < rows else { return UnsafeBufferPointer(start: nil, count: 0) }
        return UnsafeBufferPointer(start: cells + row * cols, count: cols)
    }

    /// What a cell shows, as one string: its first codepoint and whatever was joined to it.
    public func text(of cell: TSCell, row: Int) -> String {
        guard cell.codepoint != 0, let first = Unicode.Scalar(cell.codepoint) else { return "" }
        var scalars = String.UnicodeScalarView([first])
        if cell.extra > 0, let extras = raw.row_extras?[row] {
            for index in 0..<Int(cell.extra) {
                if let scalar = Unicode.Scalar(extras[Int(cell.extra_offset) + index]) { scalars.append(scalar) }
            }
        }
        return String(scalars)
    }

    /// The row as plain text, trailing blanks dropped: what a test or an accessibility reader wants.
    public func text(row: Int) -> String {
        var line = ""
        for cell in cells(row: row) where cell.width != 0 {
            line += cell.codepoint == 0 ? " " : text(of: cell, row: row)
        }
        while line.last == " " { line.removeLast() }
        return line
    }

    public var cursor: (column: Int, row: Int)? {
        raw.cursor_visible ? (Int(raw.cursor_x), Int(raw.cursor_y)) : nil
    }

    /// How far back the screen is scrolled, in rows above the newest.
    public var rowsBelow: Int {
        Int(clamping: raw.scroll_total &- raw.scroll_offset &- raw.scroll_length)
    }
}

/// A frame's cells and changed rows copied out of the screen, so they can be drawn over.
final class FrameCopy: @unchecked Sendable {
    let cells: UnsafeMutablePointer<TSCell>
    let dirty: UnsafeMutablePointer<UInt8>
    private let cellCount: Int
    private let rowCount: Int

    init(cells source: UnsafePointer<TSCell>, count: Int, dirty source2: UnsafePointer<UInt8>, rows: Int) {
        cellCount = count
        rowCount = rows
        cells = .allocate(capacity: count)
        cells.initialize(from: source, count: count)
        dirty = .allocate(capacity: rows)
        dirty.initialize(from: source2, count: rows)
    }

    deinit {
        cells.deallocate()
        dirty.deallocate()
    }
}

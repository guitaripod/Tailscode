import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A shell on the machine the conversation in focus works on.
///
/// The shell is the server's: it runs where the agent runs, in the folder the agent works in, and
/// it is still there after this window has been closed and opened. This pane is one desk's view of
/// it. Each server the window has looked at keeps its own shell and its own scrollback, and the
/// pane shows the one that belongs to the conversation in focus, walking it to that
/// conversation's folder when the shell is at its prompt to be walked.
///
/// The picture is `TerminalSession`'s screen drawn by `tailscode_term_view`: bytes are parsed off
/// this thread, and a frame is taken at most once per display frame and only while the pane is on
/// screen.
final class TerminalPane: @unchecked Sendable {
    let widget = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)

    private let caption = Gtk.label("", css: "dim", selectable: false)
    private var view: UnsafeMutablePointer<GtkWidget>!
    private var sessions: [String: TerminalSession] = [:]
    private var shownServer: String?
    private var colors = TerminalColors(palette: MatrixTheme.palette)
    private var fontScale = 1.0
    private var grid = Grid()
    private var wheel = 0.0
    private var programHasPointer = false
    private let desk = TerminalDeskName.current(client: "linux")

    private struct Grid {
        var cols = 80
        var rows = 24
        var cellWidth = 8
        var cellHeight = 16
        var padding = 6
        var width = 0
        var height = 0
    }

    /// What the view's callbacks are handed: the pane, held weakly, so a view that outlives its
    /// pane calls into nothing.
    private final class Hold {
        weak var pane: TerminalPane?
    }

    private var session: TerminalSession? { shownServer.flatMap { sessions[$0] } }

    init() {
        Gtk.addClass(widget, "canvas")
        gtk_label_set_xalign(op(caption), 0)
        gtk_label_set_ellipsize(op(caption), PANGO_ELLIPSIZE_MIDDLE)
        Gtk.margins(caption, top: 5, bottom: 3, leading: 10, trailing: 10)
        gtk_box_append(ptr(widget), caption)
        view = makeView()
        gtk_box_append(ptr(widget), view)
        restate()
    }

    private func makeView() -> UnsafeMutablePointer<GtkWidget> {
        let hold = Hold()
        hold.pane = self
        var callbacks = TailscodeTermCallbacks()
        callbacks.resized = { cols, rows, cellWidth, cellHeight, padding, width, height, raw in
            TerminalPane.pane(raw)?.resized(
                Grid(
                    cols: Int(cols), rows: Int(rows), cellWidth: Int(cellWidth),
                    cellHeight: Int(cellHeight), padding: Int(padding), width: Int(width),
                    height: Int(height)))
        }
        callbacks.key = { keyval, _, state, raw in
            TerminalPane.pane(raw)?.key(keyval: UInt32(keyval), state: UInt32(state)) == true ? 1 : 0
        }
        callbacks.text = { text, raw in
            guard let text else { return }
            TerminalPane.pane(raw)?.session?.type(String(cString: text))
        }
        callbacks.pointer = { kind, button, x, y, state, raw in
            TerminalPane.pane(raw)?.pointer(kind: Int(kind), button: Int(button), x: x, y: y, state: UInt32(state))
        }
        callbacks.scroll = { rows, x, y, state, raw in
            TerminalPane.pane(raw)?.scroll(rows: rows, x: x, y: y, state: UInt32(state))
        }
        callbacks.focus = { focused, raw in
            TerminalPane.pane(raw)?.session?.focus(focused != 0)
        }
        callbacks.tick = { raw in
            TerminalPane.pane(raw)?.draw()
        }
        let view = tailscode_term_view_new(&callbacks, Unmanaged.passRetained(hold).toOpaque()) { raw in
            guard let raw else { return }
            Unmanaged<Hold>.fromOpaque(raw).release()
        }!
        tailscode_term_view_set_font(view, "monospace", tailscode_term_default_points() * fontScale)
        tailscode_term_view_set_canvas(view, colors.background)
        return view
    }

    private static func pane(_ raw: UnsafeMutableRawPointer?) -> TerminalPane? {
        raw.flatMap { Unmanaged<Hold>.fromOpaque($0).takeUnretainedValue().pane }
    }

    func takeFocus() {
        gtk_widget_grab_focus(view)
    }

    func ownsFocus(in window: UnsafeMutablePointer<GtkWidget>) -> Bool {
        tailscode_focused_widget(window) == view
    }

    func setFontScale(_ scale: Double) {
        fontScale = scale
        tailscode_term_view_set_font(view, "monospace", tailscode_term_default_points() * scale)
    }

    func applyPalette(_ palette: Palette) {
        colors = TerminalColors(palette: palette)
        tailscode_term_view_set_canvas(view, colors.background)
        for session in sessions.values { session.screen?.apply(colors) }
        draw(force: true)
    }

    /// The folder the shell on screen stands in, as its server last read it.
    func standingDirectory() -> String? {
        session?.standingDirectory
    }

    /// The server that holds the shell on screen.
    var standingServer: String? {
        session?.standingDirectory == nil ? nil : shownServer
    }

    /// Points the pane at the conversation in focus: its server's shell, walked to its folder.
    /// A pane with no conversation leaves the terminal where it is.
    func show(
        profileID: String?, server: String?, backend: (any CodingAgentBackend)?, directory: String?,
        sessionID: String?
    ) {
        guard let profileID, let backend else { return }
        if let existing = sessions[profileID] {
            let switched = shownServer != profileID
            shownServer = profileID
            existing.follow(directory: directory)
            if switched {
                existing.resize(
                    cols: grid.cols, rows: grid.rows, cellWidth: grid.cellWidth, cellHeight: grid.cellHeight)
                restate()
                draw(force: true)
            }
            return
        }
        let session = TerminalSession(
            backend: backend,
            target: .init(server: server ?? profileID, directory: directory, sessionID: sessionID),
            desk: desk, colors: colors, cols: grid.cols, rows: grid.rows)
        sessions[profileID] = session
        shownServer = profileID
        applyGeometry(to: session)
        session.onChange { [weak self] in
            Gtk.onMain { [weak self] in self?.restate() }
        }
        session.onDirty { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.shownServer == profileID else { return }
                tailscode_term_view_request_tick(self.view)
            }
        }
        session.start()
        restate()
        draw(force: true)
    }

    /// Forgets a server that was removed, ending nothing: the shell stays on its machine.
    func forget(profileID: String) {
        sessions.removeValue(forKey: profileID)?.leave()
        if shownServer == profileID {
            shownServer = nil
            restate()
        }
    }

    /// Lets go of every shell as the window closes. They stay running for this desk to find.
    func leaveAll() {
        for session in sessions.values { session.leave() }
    }

    private func restate() {
        let words =
            session?.reading.caption
            ?? Localized.text("Open a chat and a shell opens here, on the machine that chat runs on")
        gtk_label_set_text(op(caption), words)
    }

    private func applyGeometry(to session: TerminalSession) {
        session.resize(
            cols: grid.cols, rows: grid.rows, cellWidth: grid.cellWidth, cellHeight: grid.cellHeight)
        session.screen?.setGeometry(
            cellWidth: grid.cellWidth, cellHeight: grid.cellHeight, paddingLeft: grid.padding,
            paddingTop: grid.padding, width: grid.width, height: grid.height)
    }

    private func resized(_ grid: Grid) {
        self.grid = grid
        guard let session else { return }
        applyGeometry(to: session)
        draw(force: true)
    }

    /// Takes the frame there is and hands it to the view, which rebuilds the rows that changed.
    private func draw(force: Bool = false) {
        guard let session, tailscode_term_view_is_mapped(view) != 0, let frame = session.frame(force: force)
        else { return }
        var raw = frame.raw
        tailscode_term_view_update(view, &raw)
    }

    private static func modifiers(_ state: UInt32) -> TerminalModifiers {
        var modifiers: TerminalModifiers = []
        if state & 1 != 0 { modifiers.insert(.shift) }
        if state & 4 != 0 { modifiers.insert(.control) }
        if state & 8 != 0 { modifiers.insert(.alt) }
        if state & (1 << 26) != 0 { modifiers.insert(.command) }
        return modifiers
    }

    /// The keys that are named, not typed, as GDK numbers them.
    private static let named: [UInt32: TerminalKey] = [
        0xff0d: .enter, 0xff8d: .numpadEnter, 0xff08: .backspace, 0xff09: .tab, 0xfe20: .tab,
        0xff1b: .escape, 0xffff: .delete, 0xff50: .home, 0xff51: .arrowLeft, 0xff52: .arrowUp,
        0xff53: .arrowRight, 0xff54: .arrowDown, 0xff55: .pageUp, 0xff56: .pageDown, 0xff57: .end,
        0xff63: .insert, 0xff95: .home, 0xff96: .arrowLeft, 0xff97: .arrowUp, 0xff98: .arrowRight,
        0xff99: .arrowDown, 0xff9a: .pageUp, 0xff9b: .pageDown, 0xff9c: .end, 0xff9e: .insert,
        0xff9f: .delete,
    ]

    /// A key that typed no text. The terminal's own few chords come first (copy, paste, a page of
    /// scrollback), then everything else is the shell's.
    private func key(keyval: UInt32, state: UInt32) -> Bool {
        guard let session else { return false }
        let modifiers = Self.modifiers(state)
        if modifiers == [.control, .shift] {
            switch keyval {
            case 0x43, 0x63:
                copySelection()
                return true
            case 0x56, 0x76:
                pasteClipboard()
                return true
            default:
                break
            }
        }
        if modifiers == .shift {
            switch keyval {
            case 0xff63, 0xff9e:
                pasteClipboard()
                return true
            case 0xff55, 0xff9a:
                session.screen?.scroll(pages: -1)
                tailscode_term_view_request_tick(view)
                return true
            case 0xff56, 0xff9b:
                session.screen?.scroll(pages: 1)
                tailscode_term_view_request_tick(view)
                return true
            default:
                break
            }
        }
        if let key = Self.named[keyval] {
            var held = modifiers
            if keyval == 0xfe20 { held.insert(.shift) }
            session.press(TerminalKeyPress(key: key, modifiers: held))
            return true
        }
        if (0xffbe...0xffd5).contains(keyval) {
            session.press(TerminalKeyPress(key: .function(Int(keyval - 0xffbe) + 1), modifiers: modifiers))
            return true
        }
        let unicode = gdk_keyval_to_unicode(keyval)
        guard unicode >= 0x20, unicode != 0x7f, let scalar = Unicode.Scalar(unicode) else { return false }
        let typed = Character(scalar)
        let cap = Character(String(typed).lowercased())
        let text = modifiers.contains(.control) ? "" : String(typed)
        session.press(
            TerminalKeyPress(key: .typing(cap), modifiers: modifiers, text: text, unshifted: cap))
        return true
    }

    private func copySelection() {
        guard let text = session?.screen?.selectionText, !text.isEmpty else { return }
        Gtk.copyToClipboard(text)
    }

    private func pasteClipboard() {
        let hold = Unmanaged.passRetained(PasteHold(self)).toOpaque()
        tailscode_clipboard_read_text(
            { text, raw in
                guard let raw else { return }
                let hold = Unmanaged<PasteHold>.fromOpaque(raw).takeRetainedValue()
                guard let text else { return }
                hold.pane?.session?.paste(String(cString: text))
            }, hold)
    }

    private final class PasteHold {
        weak var pane: TerminalPane?
        init(_ pane: TerminalPane) { self.pane = pane }
    }

    /// The pointer belongs to the program on screen when it asked for the mouse and Shift is not
    /// held; otherwise it is the person's, and the left button selects.
    private func pointer(kind: Int, button: Int, x: Double, y: Double, state: UInt32) {
        guard let session, let screen = session.screen else { return }
        let modifiers = Self.modifiers(state)
        let which = TerminalScreen.PointerButton(rawValue: UInt8(clamping: button)) ?? .none
        switch kind {
        case 0:
            let bytes = screen.bytes(
                pointer: .press, button: Self.button(button), modifiers: modifiers, x: x, y: y, anyPressed: true)
            programHasPointer = !bytes.isEmpty
            if programHasPointer {
                session.send(bytes)
            } else if button == 1 {
                screen.select(.press, x: x, y: y)
                tailscode_term_view_request_tick(view)
            } else if button == 2 {
                pasteClipboard()
            }
        case 1:
            if programHasPointer {
                session.send(
                    screen.bytes(
                        pointer: .release, button: Self.button(button), modifiers: modifiers, x: x, y: y,
                        anyPressed: false))
            } else if button == 1 {
                screen.select(.release, x: x, y: y)
                tailscode_term_view_request_tick(view)
            }
            programHasPointer = false
        default:
            let held = which != .none
            let bytes = screen.bytes(
                pointer: .motion, button: held ? .left : .none, modifiers: modifiers, x: x, y: y,
                anyPressed: held)
            if !bytes.isEmpty {
                session.send(bytes)
            } else if held, !programHasPointer {
                screen.select(.drag, x: x, y: y)
                tailscode_term_view_request_tick(view)
            }
        }
    }

    /// GDK counts the middle button second and the right one third; the terminal counts them the
    /// other way round.
    private static func button(_ gdk: Int) -> TerminalScreen.PointerButton {
        switch gdk {
        case 1: return .left
        case 2: return .middle
        case 3: return .right
        default: return .none
        }
    }

    /// A wheel turn in rows, which a touchpad delivers in fractions: whole rows are spent as they
    /// add up.
    private func scroll(rows: Double, x: Double, y: Double, state: UInt32) {
        guard let session, let screen = session.screen else { return }
        wheel += rows
        let whole = Int(wheel.rounded(.towardZero))
        guard whole != 0 else { return }
        wheel -= Double(whole)
        let bytes = screen.wheel(rows: whole, modifiers: Self.modifiers(state), x: x, y: y)
        if bytes.isEmpty {
            tailscode_term_view_request_tick(view)
        } else {
            session.send(bytes)
        }
    }
}

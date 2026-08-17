import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The board, opened. One artboard fills the window at a time with its letter and name over it and
/// the case it makes for itself beside it — a wall of thumbnails would be a wall of unreadable
/// mocks, and the question a board asks is which one, not how many there are.
///
/// The mocks live on the server, so they arrive as markup over the file route and are handed
/// straight to WebKitGTK: writing them to this disk to give them a URL would leave somebody else's
/// work here after the window closed.
final class DesignBoardWindow: @unchecked Sendable {
    private var state: DesignBoardState
    private let files: (any FileBrowsingBackend)?
    private let send: @Sendable (String) -> Void
    private let notice: @Sendable (String) -> Void

    private var window: UnsafeMutablePointer<GtkWidget>?
    private let titleLabel = Gtk.label("", css: "card-title", selectable: false)
    private let subtitleLabel = Gtk.label("", css: "row-detail", selectable: false)
    private let letterRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private let frame = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let notesColumn = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
    private let notesScroller = gtk_scrolled_window_new()!
    private let footnote = Gtk.label("", css: "seam-footnote", selectable: false)
    private let buildButton: UnsafeMutablePointer<GtkWidget>
    private var web: OpaquePointer?
    private var webWidget: UnsafeMutablePointer<GtkWidget>?
    private var loading = Set<String>()
    private var shown: String?
    private let hasEngine = tailscode_web_available() != 0

    static func present(
        directory: String, backend: (any CodingAgentBackend)?,
        parent: UnsafeMutablePointer<GtkWidget>?,
        send: @escaping @Sendable (String) -> Void,
        notice: @escaping @Sendable (String) -> Void
    ) {
        let window = DesignBoardWindow(
            directory: directory, backend: backend, send: send, notice: notice)
        window.presentWindow(parent: parent)
        window.read()
    }

    /// The same surface over a board that is already in hand, which is how the headless driver
    /// photographs it without a machine on the other end drawing mocks first.
    static func present(
        board: DesignBoard, pages: [String: String],
        parent: UnsafeMutablePointer<GtkWidget>?,
        send: @escaping @Sendable (String) -> Void,
        notice: @escaping @Sendable (String) -> Void
    ) {
        let window = DesignBoardWindow(
            directory: board.directory, backend: nil, send: send, notice: notice)
        window.state.arrived(board)
        for (letter, html) in pages { window.state.loaded(DesignRender.prepared(html), for: letter) }
        window.presentWindow(parent: parent)
    }

    private init(
        directory: String, backend: (any CodingAgentBackend)?,
        send: @escaping @Sendable (String) -> Void, notice: @escaping @Sendable (String) -> Void
    ) {
        state = DesignBoardState(directory: directory)
        files = backend as? any FileBrowsingBackend
        self.send = send
        self.notice = notice
        buildButton = gtk_button_new_with_label("")!
    }

    private func presentWindow(parent: UnsafeMutablePointer<GtkWidget>?) {
        let hostWidth = parent.map { gtk_widget_get_width($0) } ?? 0
        let hostHeight = parent.map { gtk_widget_get_height($0) } ?? 0
        let width = max(1040, hostWidth - 100)
        let height = max(720, hostHeight - 80)
        let window = gtk_window_new()!
        gtk_window_set_title(ptr(window), state.title)
        gtk_window_set_default_size(ptr(window), width, height)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }
        self.window = window

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(column, "canvas")

        let header = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        Gtk.margins(header, top: 14, bottom: 10, leading: 18, trailing: 18)
        gtk_box_append(ptr(header), titleLabel)
        gtk_box_append(ptr(header), subtitleLabel)
        gtk_box_append(ptr(column), header)

        Gtk.margins(letterRow, top: 0, bottom: 10, leading: 18, trailing: 18)
        gtk_box_append(ptr(column), letterRow)
        gtk_box_append(ptr(column), Gtk.hairline())

        let middle = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_vexpand(middle, 1)
        Gtk.addClass(frame, "design-frame")
        gtk_widget_set_hexpand(frame, 1)
        gtk_widget_set_vexpand(frame, 1)
        gtk_box_append(ptr(middle), frame)

        Gtk.margins(notesColumn, 16)
        gtk_scrolled_window_set_policy(op(notesScroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(op(notesScroller), notesColumn)
        gtk_widget_set_size_request(notesScroller, 320, -1)
        gtk_box_append(ptr(middle), notesScroller)
        gtk_box_append(ptr(column), middle)

        gtk_box_append(ptr(column), Gtk.hairline())
        let actions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(actions, top: 10, bottom: 12, leading: 18, trailing: 18)
        gtk_box_append(ptr(actions), footnote)
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(actions), spacer)
        gtk_box_append(
            ptr(actions),
            Gtk.button(state.browserTitle, css: ["flat", "seam-read"]) { [self] in
                Gtk.onMain { [self] in self.openInBrowser() }
            })
        gtk_box_append(
            ptr(actions),
            Gtk.button(state.tweakTitle, css: ["flat", "seam-read"]) { [self] in
                Gtk.onMain { [self] in self.askTweak() }
            })
        gtk_box_append(
            ptr(actions),
            Gtk.button(state.anotherTitle, css: ["flat", "seam-read"]) { [self] in
                Gtk.onMain { [self] in self.askAnother() }
            })
        Gtk.addClass(buildButton, "suggested-action")
        Gtk.connect(UnsafeMutableRawPointer(buildButton), "clicked") { [self] in
            Gtk.onMain { [self] in self.askImplement() }
        }
        gtk_box_append(ptr(actions), buildButton)
        gtk_box_append(ptr(column), actions)

        gtk_window_set_child(ptr(window), column)
        Gtk.onKey(window) { [self] keyval, _ in
            Gtk.onMain { [self] in self.handle(keyval) }
            return Self.claims(keyval)
        }
        render()
        gtk_window_present(ptr(window))
    }

    /// Every key the board answers, and no others: the mock is a page and the page keeps the rest.
    private static func claims(_ keyval: UInt32) -> Bool {
        switch keyval {
        case Keymap.escape, 0xFF51, 0xFF53, 0xFF0D, 0xFF8D: return true
        default:
            guard let character = Keymap.scalar(keyval) else { return false }
            return character == "n" || character == "h" || character == "l"
                || (character.isNumber && character != "0")
        }
    }

    private func handle(_ keyval: UInt32) {
        switch keyval {
        case Keymap.escape:
            close()
        case 0xFF51:
            state.step(-1)
            render()
        case 0xFF53:
            state.step(1)
            render()
        case 0xFF0D, 0xFF8D:
            askImplement()
        default:
            guard let character = Keymap.scalar(keyval) else { return }
            switch character {
            case "h":
                state.step(-1)
                render()
            case "l":
                state.step(1)
                render()
            case "n":
                state.showsNotes.toggle()
                render()
            case "1"..."9":
                state.select(Int(String(character))! - 1)
                render()
            default:
                break
            }
        }
    }

    private func close() {
        guard let window else { return }
        gtk_window_destroy(ptr(window))
        self.window = nil
    }

    /// The manifest first, then the mock the reader is looking at. Reading all of them up front
    /// would spend a round trip per artboard before the first one could be seen, on a link where
    /// every one of them is a hop across the tailnet.
    private func read() {
        guard let files else {
            state.failed(Localized.text("This server cannot hand over files, so a board cannot open."))
            render()
            return
        }
        let path = DesignPaths.manifest(in: state.directory)
        Task { [weak self] in
            let text = try? await files.fileContent(path: path)
            Gtk.onMain { [weak self] in
                guard let self else { return }
                guard let text, let manifest = DesignManifest.parse(text) else {
                    self.state.failed(
                        text == nil
                            ? Localized.text("%@ could not be read from the server.", path)
                            : Localized.text("%@ is not a board this app can read.", path))
                    self.render()
                    return
                }
                self.state.arrived(DesignBoard(directory: self.state.directory, manifest: manifest))
                self.render()
            }
        }
    }

    private func readArtboard(_ artboard: DesignArtboard) {
        guard let files, let board = boardValue else { return }
        guard state.page(for: artboard) == nil, !loading.contains(artboard.letter) else { return }
        loading.insert(artboard.letter)
        let path = board.path(of: artboard)
        let letter = artboard.letter
        Task { [weak self] in
            let text = try? await files.fileContent(path: path)
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.loading.remove(letter)
                guard let text, !text.isEmpty else {
                    self.notice(Localized.text("%@ could not be read from the server.", path))
                    return
                }
                self.state.loaded(DesignRender.prepared(text), for: letter)
                self.render()
            }
        }
    }

    private var boardValue: DesignBoard? {
        guard case .ready = state.phase else { return nil }
        return DesignBoard(
            directory: state.directory,
            manifest: DesignManifest(
                title: state.title, artboards: state.artboards))
    }

    private func render() {
        gtk_label_set_text(op(titleLabel), state.title)
        gtk_label_set_text(op(subtitleLabel), state.subtitle)
        gtk_label_set_text(op(footnote), state.footnote)
        gtk_button_set_label(ptr(buildButton), state.implementTitle)
        gtk_widget_set_sensitive(buildButton, state.isReady ? 1 : 0)
        renderLetters()
        renderNotes()
        renderFrame()
    }

    private func renderLetters() {
        Gtk.removeChildren(of: letterRow)
        for (index, artboard) in state.artboards.enumerated() {
            let button = Gtk.button(artboard.caption, css: ["design-letter"]) { [self] in
                Gtk.onMain { [self] in
                    self.state.select(index)
                    self.render()
                }
            }
            if index == state.selection { Gtk.addClass(button, "design-letter-on") }
            gtk_box_append(ptr(letterRow), button)
        }
        gtk_widget_set_visible(letterRow, state.artboards.count > 1 ? 1 : 0)
    }

    private func renderNotes() {
        Gtk.removeChildren(of: notesColumn)
        guard state.showsNotes, let artboard = state.current else {
            gtk_widget_set_visible(notesScroller, 0)
            return
        }
        gtk_widget_set_visible(notesScroller, 1)
        let caption = Gtk.label(artboard.caption, css: "design-caption", wrap: true, selectable: false)
        gtk_box_append(ptr(notesColumn), caption)
        if !artboard.rationale.isEmpty {
            gtk_box_append(
                ptr(notesColumn),
                Gtk.label(artboard.rationale, css: "design-rationale", wrap: true))
        }
        for note in artboard.notes {
            gtk_box_append(ptr(notesColumn), Gtk.label(note, css: "design-note", wrap: true))
        }
        let hint = Gtk.label(state.hint, css: "seam-footnote", wrap: true, selectable: false)
        gtk_widget_set_margin_top(hint, 8)
        gtk_box_append(ptr(notesColumn), hint)
    }

    private func renderFrame() {
        switch state.phase {
        case .loading, .empty, .failed:
            dropWeb()
            Gtk.removeChildren(of: frame)
            let message = Gtk.label(
                state.phase == .empty ? state.emptyLine : state.subtitle, css: "row-detail",
                wrap: true, selectable: false)
            gtk_widget_set_valign(message, GTK_ALIGN_CENTER)
            gtk_widget_set_halign(message, GTK_ALIGN_CENTER)
            gtk_widget_set_vexpand(message, 1)
            gtk_box_append(ptr(frame), message)
        case .ready:
            guard let artboard = state.current else { return }
            guard hasEngine else {
                Gtk.removeChildren(of: frame)
                let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 12)
                gtk_widget_set_valign(column, GTK_ALIGN_CENTER)
                gtk_widget_set_halign(column, GTK_ALIGN_CENTER)
                gtk_widget_set_vexpand(column, 1)
                let line = Gtk.label(
                    state.noEngineLine, css: "row-detail", wrap: true, selectable: false)
                gtk_widget_set_size_request(line, 320, -1)
                gtk_box_append(ptr(column), line)
                let open = Gtk.button(state.browserTitle, css: ["suggested-action"]) { [self] in
                    Gtk.onMain { [self] in self.openInBrowser() }
                }
                gtk_widget_set_halign(open, GTK_ALIGN_CENTER)
                gtk_box_append(ptr(column), open)
                gtk_box_append(ptr(frame), column)
                if state.page(for: artboard) == nil { readArtboard(artboard) }
                return
            }
            guard let html = state.page(for: artboard) else {
                readArtboard(artboard)
                Gtk.removeChildren(of: frame)
                dropWeb()
                let waiting = Gtk.label(
                    Localized.text("Reading %@…", artboard.file), css: "row-detail",
                    selectable: false)
                gtk_widget_set_valign(waiting, GTK_ALIGN_CENTER)
                gtk_widget_set_halign(waiting, GTK_ALIGN_CENTER)
                gtk_widget_set_vexpand(waiting, 1)
                gtk_box_append(ptr(frame), waiting)
                return
            }
            guard ensureView() else { return }
            guard shown != artboard.letter else { return }
            shown = artboard.letter
            tailscode_web_load_html(web, html, nil)
        }
    }

    private func ensureView() -> Bool {
        if web != nil { return true }
        guard hasEngine else { return false }
        guard let made = tailscode_web_new({ _, _, _ in }, nil),
            let widget = tailscode_web_widget(made)
        else {
            state.failed(Localized.text("The web view would not start."))
            renderFrame()
            return false
        }
        web = made
        Gtk.removeChildren(of: frame)
        gtk_widget_set_hexpand(widget, 1)
        gtk_widget_set_vexpand(widget, 1)
        gtk_box_append(ptr(frame), widget)
        webWidget = widget
        return true
    }

    private func dropWeb() {
        guard let web else { return }
        tailscode_web_free(web)
        self.web = nil
        webWidget = nil
        shown = nil
    }

    private func askImplement() {
        guard let board = boardValue, let artboard = state.current else { return }
        let prompt = state.implementPrompt
        Dialogs.prompt(
            title: state.implementTitle, body: DesignFollowUp.summary(artboard),
            placeholder: prompt, confirmLabel: state.implementTitle, parent: window
        ) { [self] notes in
            self.dispatch(DesignFollowUp.implement(board: board, artboard: artboard, notes: notes))
        }
    }

    private func askTweak() {
        guard let board = boardValue, let artboard = state.current else { return }
        Dialogs.prompt(
            title: state.tweakTitle, body: state.tweakPrompt, placeholder: state.tweakPrompt,
            confirmLabel: Localized.text("Send"), parent: window
        ) { [self] instruction in
            guard !instruction.isEmpty else { return }
            self.dispatch(
                DesignFollowUp.tweak(board: board, artboard: artboard, instruction: instruction))
        }
    }

    private func askAnother() {
        guard let board = boardValue else { return }
        Dialogs.prompt(
            title: state.anotherTitle, body: state.anotherPrompt, placeholder: state.anotherPrompt,
            confirmLabel: Localized.text("Send"), parent: window
        ) { [self] instruction in
            guard !instruction.isEmpty else { return }
            self.dispatch(DesignFollowUp.another(board: board, instruction: instruction))
        }
    }

    /// The mock, handed to the desktop's own browser. It is written under the app's runtime
    /// directory rather than into the project: the bytes belong to the server's disk, and a copy
    /// made to satisfy a browser's need for a URL is this machine's scratch, not the person's work.
    private func openInBrowser() {
        guard let artboard = state.current else { return }
        guard let html = state.page(for: artboard) else {
            readArtboard(artboard)
            notice(Localized.text("Reading %@…", artboard.file))
            return
        }
        let base = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"].map(
            URL.init(fileURLWithPath:)) ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("tailscode-design", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(artboard.letter).html")
        guard (try? html.write(to: file, atomically: true, encoding: .utf8)) != nil else {
            notice(Localized.text("That mock could not be handed to a browser."))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [file.path]
        try? process.run()
    }

    /// A follow-up leaves through the composer like every other send, and the board closes behind
    /// it: what happens next is a turn in the conversation, and a window over the top of it would
    /// hide the answer it asked for.
    private func dispatch(_ prompt: String) {
        let send = send
        close()
        Gtk.onMain { send(prompt) }
    }
}

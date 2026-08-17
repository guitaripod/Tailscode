import AppKit
import CodingAgentKit
import TailscodeCore
import WebKit

/// The board, opened. One artboard fills the window at a time with its letter and name over it and
/// the case it makes for itself beside it — a wall of thumbnails is a wall of unreadable mocks, and
/// the question a board asks is which one, not how many there are.
///
/// The mocks live on the server, so they arrive as markup over the file route and are handed
/// straight to WebKit: writing them to this disk to give them a URL would leave somebody else's
/// work here after the window closed.
@MainActor
final class DesignBoardWindowController: NSWindowController {
    private var state: DesignBoardState
    private let files: (any FileBrowsingBackend)?
    private let send: (String) -> Void

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let picker = NSSegmentedControl()
    private let frame = NSView()
    private let notesColumn = FillingStack()
    private let notesScroll = NSScrollView()
    private let footnote = NSTextField(labelWithString: "")
    private var buildButton = RowKit.ActionButton(title: "") {}
    private var webView: WKWebView?
    private var drawn: String?
    private var loading: Set<String> = []

    private static let notesWidth: CGFloat = 300

    convenience init(
        directory: String, backend: any CodingAgentBackend, send: @escaping (String) -> Void
    ) {
        self.init(directory: directory, files: backend as? any FileBrowsingBackend, send: send)
    }

    /// A board already in hand, for the self-test walk — the same surface with nothing to fetch.
    convenience init(board: DesignBoard, pages: [String: String], send: @escaping (String) -> Void)
    {
        self.init(directory: board.directory, files: nil, send: send)
        state.arrived(board)
        for (letter, html) in pages { state.loaded(DesignRender.prepared(html), for: letter) }
        window?.title = state.title
        render()
    }

    private init(
        directory: String, files: (any FileBrowsingBackend)?, send: @escaping (String) -> Void
    ) {
        state = DesignBoardState(directory: directory)
        self.files = files
        self.send = send
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = state.title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 480)
        MacTheme.Chrome.adopt(window)
        super.init(window: window)
        let host = NSViewController(nibName: nil, bundle: nil)
        host.view = makeContent()
        window.contentViewController = host
        render()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        readManifest()
    }

    private func makeContent() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = MacTheme.Ramp.font(.panelTitle)
        subtitleLabel.font = MacTheme.Ramp.font(.panelFootnote)
        subtitleLabel.textColor = MacTheme.Color.secondaryLabel

        picker.segmentStyle = .automatic
        picker.trackingMode = .selectOne
        picker.target = self
        picker.action = #selector(pickerChanged)

        let header = NSStackView(views: [titleLabel, subtitleLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 1
        header.translatesAutoresizingMaskIntoConstraints = false

        frame.wantsLayer = true
        frame.translatesAutoresizingMaskIntoConstraints = false

        notesColumn.spacing = MacTheme.Spacing.m
        notesColumn.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        notesScroll.translatesAutoresizingMaskIntoConstraints = false
        let holder = MacDialogs.scrollColumn(holding: notesColumn)
        holder.translatesAutoresizingMaskIntoConstraints = false

        footnote.font = MacTheme.Ramp.font(.panelFootnote)
        footnote.textColor = MacTheme.Color.tertiaryLabel

        let tweak = RowKit.ActionButton(title: state.tweakTitle) { [weak self] in self?.askTweak() }
        let another = RowKit.ActionButton(title: state.anotherTitle) {
            [weak self] in self?.askAnother()
        }
        buildButton = RowKit.ActionButton(title: "") { [weak self] in self?.askImplement() }
        buildButton.keyEquivalent = "\r"

        let actions = NSStackView(views: [
            footnote, RowKit.spacer(), tweak, another, buildButton,
        ])
        actions.orientation = .horizontal
        actions.spacing = MacTheme.Spacing.s
        actions.translatesAutoresizingMaskIntoConstraints = false

        picker.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(picker)
        root.addSubview(frame)
        root.addSubview(holder)
        root.addSubview(actions)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: MacTheme.Spacing.m),
            header.leadingAnchor.constraint(
                equalTo: root.leadingAnchor, constant: MacTheme.Spacing.l),
            header.trailingAnchor.constraint(
                lessThanOrEqualTo: root.trailingAnchor, constant: -MacTheme.Spacing.l),

            picker.topAnchor.constraint(equalTo: header.bottomAnchor, constant: MacTheme.Spacing.s),
            picker.leadingAnchor.constraint(
                equalTo: root.leadingAnchor, constant: MacTheme.Spacing.l),
            picker.trailingAnchor.constraint(
                lessThanOrEqualTo: root.trailingAnchor, constant: -MacTheme.Spacing.l),

            frame.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: MacTheme.Spacing.s),
            frame.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            frame.trailingAnchor.constraint(equalTo: holder.leadingAnchor),
            frame.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -MacTheme.Spacing.s),

            holder.topAnchor.constraint(equalTo: frame.topAnchor),
            holder.bottomAnchor.constraint(equalTo: frame.bottomAnchor),
            holder.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            holder.widthAnchor.constraint(equalToConstant: Self.notesWidth),

            actions.leadingAnchor.constraint(
                equalTo: root.leadingAnchor, constant: MacTheme.Spacing.l),
            actions.trailingAnchor.constraint(
                equalTo: root.trailingAnchor, constant: -MacTheme.Spacing.l),
            actions.bottomAnchor.constraint(
                equalTo: root.bottomAnchor, constant: -MacTheme.Spacing.m),
        ])
        return root
    }

    @objc private func pickerChanged() {
        state.select(picker.selectedSegment)
        render()
    }

    private func readManifest() {
        guard state.board == nil else { return }
        guard let files else {
            state.failed(
                Localized.text("This server cannot hand over files, so a board cannot open."))
            render()
            return
        }
        let path = DesignPaths.manifest(in: state.directory)
        Task { [weak self] in
            let text = try? await files.fileContent(path: path)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let text, let manifest = DesignManifest.parse(text) else {
                    self.state.failed(
                        text == nil
                            ? Localized.text("%@ could not be read from the server.", path)
                            : Localized.text("%@ is not a board this app can read.", path))
                    self.render()
                    return
                }
                self.state.arrived(
                    DesignBoard(directory: self.state.directory, manifest: manifest))
                self.window?.title = self.state.title
                self.render()
            }
        }
    }

    private func readArtboard(_ artboard: DesignArtboard) {
        guard let files, let board else { return }
        guard state.page(for: artboard) == nil, !loading.contains(artboard.letter) else { return }
        loading.insert(artboard.letter)
        let path = board.path(of: artboard)
        let letter = artboard.letter
        Task { [weak self] in
            let text = try? await files.fileContent(path: path)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading.remove(letter)
                guard let text, !text.isEmpty else { return }
                self.state.loaded(DesignRender.prepared(text), for: letter)
                self.render()
            }
        }
    }

    private var board: DesignBoard? {
        guard state.isReady else { return nil }
        return DesignBoard(
            directory: state.directory,
            manifest: DesignManifest(title: state.title, artboards: state.artboards))
    }

    private func render() {
        titleLabel.stringValue = state.title
        subtitleLabel.stringValue = state.subtitle
        footnote.stringValue = state.footnote
        buildButton.title = state.implementTitle
        buildButton.isEnabled = state.isReady

        let artboards = state.artboards
        if picker.segmentCount != artboards.count {
            picker.segmentCount = artboards.count
            for (index, artboard) in artboards.enumerated() {
                picker.setLabel(artboard.caption, forSegment: index)
                picker.setWidth(0, forSegment: index)
            }
        }
        picker.isHidden = artboards.count < 2
        if picker.selectedSegment != state.selection, artboards.count > state.selection {
            picker.selectedSegment = state.selection
        }
        renderNotes()
        renderFrame()
    }

    private func renderNotes() {
        notesColumn.setViews([], in: .top)
        guard let artboard = state.current else {
            notesScroll.isHidden = true
            return
        }
        var views: [NSView] = []
        let caption = NSTextField(labelWithString: artboard.caption)
        caption.font = MacTheme.Ramp.font(.cardTitle)
        caption.textColor = MacTheme.Color.accent
        views.append(caption)
        if !artboard.rationale.isEmpty {
            let body = NSTextField(wrappingLabelWithString: artboard.rationale)
            body.font = MacTheme.Ramp.font(.cardBody)
            body.textColor = MacTheme.Color.label
            body.preferredMaxLayoutWidth = Self.notesWidth - 40
            views.append(body)
        }
        for note in artboard.notes { views.append(Self.note(note)) }
        notesColumn.setViews(views, in: .top)
    }

    /// An annotation reads as something stuck onto the mock rather than as another paragraph about
    /// it: the special slot, a rule down its leading edge, and the words the agent wrote.
    private static func note(_ text: String) -> NSView {
        let holder = RowKit.Ground(frame: .zero)
        holder.fill = MacTheme.Color.mark.withAlphaComponent(0.12)
        holder.radius = 6

        let rule = RowKit.Ground(frame: .zero)
        rule.fill = MacTheme.Color.mark

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = MacTheme.Ramp.font(.cardBody)
        label.textColor = MacTheme.Color.label
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = notesWidth - 60
        holder.addSubview(rule)
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            rule.topAnchor.constraint(equalTo: holder.topAnchor),
            rule.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            rule.widthAnchor.constraint(equalToConstant: 2),
            label.leadingAnchor.constraint(
                equalTo: rule.trailingAnchor, constant: MacTheme.Spacing.s),
            label.trailingAnchor.constraint(
                equalTo: holder.trailingAnchor, constant: -MacTheme.Spacing.s),
            label.topAnchor.constraint(equalTo: holder.topAnchor, constant: MacTheme.Spacing.xs),
            label.bottomAnchor.constraint(
                equalTo: holder.bottomAnchor, constant: -MacTheme.Spacing.xs),
        ])
        return holder
    }

    private func renderFrame() {
        frame.subviews.forEach { $0.removeFromSuperview() }
        webView = nil
        switch state.phase {
        case .loading, .empty, .failed:
            drawn = nil
            let message = NSTextField(
                wrappingLabelWithString: state.phase == .empty ? state.emptyLine : state.subtitle)
            message.font = MacTheme.Ramp.font(.panelLabel)
            message.textColor = MacTheme.Color.secondaryLabel
            message.alignment = .center
            message.translatesAutoresizingMaskIntoConstraints = false
            frame.addSubview(message)
            NSLayoutConstraint.activate([
                message.centerXAnchor.constraint(equalTo: frame.centerXAnchor),
                message.centerYAnchor.constraint(equalTo: frame.centerYAnchor),
                message.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            ])
        case .ready:
            guard let artboard = state.current else { return }
            guard let html = state.page(for: artboard) else {
                readArtboard(artboard)
                drawn = nil
                let waiting = NSTextField(
                    labelWithString: Localized.text("Reading %@…", artboard.file))
                waiting.font = MacTheme.Ramp.font(.panelLabel)
                waiting.textColor = MacTheme.Color.secondaryLabel
                waiting.translatesAutoresizingMaskIntoConstraints = false
                frame.addSubview(waiting)
                NSLayoutConstraint.activate([
                    waiting.centerXAnchor.constraint(equalTo: frame.centerXAnchor),
                    waiting.centerYAnchor.constraint(equalTo: frame.centerYAnchor),
                ])
                return
            }
            let configuration = WKWebViewConfiguration()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            let web = WKWebView(frame: .zero, configuration: configuration)
            web.translatesAutoresizingMaskIntoConstraints = false
            web.allowsMagnification = true
            frame.addSubview(web)
            NSLayoutConstraint.activate([
                web.topAnchor.constraint(equalTo: frame.topAnchor),
                web.bottomAnchor.constraint(equalTo: frame.bottomAnchor),
                web.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
                web.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
            ])
            web.loadHTMLString(html, baseURL: nil)
            webView = web
            drawn = artboard.letter
        }
    }

    private func askImplement() {
        guard let board, let artboard = state.current else { return }
        MacDialogs.prompt(
            on: window, title: state.implementTitle, body: DesignFollowUp.summary(artboard),
            placeholder: state.implementPrompt, confirmLabel: state.implementTitle
        ) { [weak self] notes in
            self?.dispatch(
                DesignFollowUp.implement(board: board, artboard: artboard, notes: notes))
        }
    }

    private func askTweak() {
        guard let board, let artboard = state.current else { return }
        MacDialogs.prompt(
            on: window, title: state.tweakTitle, body: state.tweakPrompt,
            placeholder: Localized.text("What should change?"),
            confirmLabel: Localized.text("Send")
        ) { [weak self] instruction in
            guard !instruction.isEmpty else { return }
            self?.dispatch(
                DesignFollowUp.tweak(board: board, artboard: artboard, instruction: instruction))
        }
    }

    private func askAnother() {
        guard let board else { return }
        MacDialogs.prompt(
            on: window, title: state.anotherTitle, body: state.anotherPrompt,
            placeholder: Localized.text("What should it try?"),
            confirmLabel: Localized.text("Send")
        ) { [weak self] instruction in
            guard !instruction.isEmpty else { return }
            self?.dispatch(DesignFollowUp.another(board: board, instruction: instruction))
        }
    }

    /// A follow-up leaves through the conversation's own send, and the board closes behind it:
    /// what happens next is a turn in the transcript, and a window over the top of it would hide
    /// the answer it asked for.
    private func dispatch(_ prompt: String) {
        let send = send
        close()
        send(prompt)
    }
}

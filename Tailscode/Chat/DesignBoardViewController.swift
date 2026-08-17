import CodingAgentKit
import TailscodeCore
import UIKit
import WebKit

/// The board, opened. One artboard fills the screen at a time and the letters pick between them:
/// a wall of thumbnails on a phone is a wall of unreadable mocks, and the question a board asks is
/// which one, not how many there are.
///
/// The mocks live on the server, so they arrive as markup over the file route and are handed
/// straight to WebKit. Nothing is written to this device: a design is somebody else's work in
/// progress, not a download.
final class DesignBoardViewController: UIViewController {
    private var state: DesignBoardState
    private let files: (any FileBrowsingBackend)?
    private let onSend: (String) -> Void

    private let picker = UISegmentedControl()
    private let pager = UIScrollView()
    private let pages = UIStackView()
    private let statusLabel = UILabel()
    private let captionLabel = UILabel()
    private let rationaleLabel = UILabel()
    private let bottomBar = Theme.Glass.view()
    private let buildButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let notesButton = UIButton(type: .system)
    private var webViews: [String: WKWebView] = [:]
    private var drawn: [String: Int] = [:]
    private var loading: Set<String> = []

    init(directory: String, backend: any CodingAgentBackend, onSend: @escaping (String) -> Void) {
        state = DesignBoardState(directory: directory)
        files = backend as? any FileBrowsingBackend
        self.onSend = onSend
        super.init(nibName: nil, bundle: nil)
    }

    /// A board already in hand, for the demo walk — the same surface with nothing to fetch.
    init(board: DesignBoard, pages: [String: String], onSend: @escaping (String) -> Void) {
        state = DesignBoardState(directory: board.directory)
        files = nil
        self.onSend = onSend
        super.init(nibName: nil, bundle: nil)
        state.arrived(board)
        for (letter, html) in pages { state.loaded(DesignRender.prepared(html), for: letter) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        title = state.title
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.close() })
        build()
        render()
        readManifest()
    }

    private func build() {
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.state.select(self.picker.selectedSegmentIndex)
                Theme.Haptics.step()
                self.render()
                self.scrollToSelection(animated: true)
            }, for: .valueChanged)

        pager.translatesAutoresizingMaskIntoConstraints = false
        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.delegate = self
        pager.contentInsetAdjustmentBehavior = .never
        pages.axis = .horizontal
        pages.distribution = .fillEqually
        pages.translatesAutoresizingMaskIntoConstraints = false
        pager.addSubview(pages)
        view.addSubview(pager)

        statusLabel.font = Theme.Ramp.font(.panelDetail)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = Theme.Color.secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        captionLabel.font = Theme.Ramp.font(.cardTitle)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = Theme.Color.onGlass
        captionLabel.numberOfLines = 1
        rationaleLabel.font = Theme.Ramp.font(.panelFootnote)
        rationaleLabel.adjustsFontForContentSizeCategory = true
        rationaleLabel.textColor = Theme.Color.onGlass.withAlphaComponent(0.75)
        rationaleLabel.numberOfLines = 2

        notesButton.setImage(Self.symbol("info.circle"), for: .normal)
        notesButton.accessibilityLabel = state.notesTitle
        notesButton.addAction(UIAction { [weak self] _ in self?.presentNotes() }, for: .touchUpInside)

        moreButton.setImage(Self.symbol("ellipsis"), for: .normal)
        moreButton.accessibilityLabel = String(localized: "More")
        moreButton.showsMenuAsPrimaryAction = true

        var build = Theme.Glass.buttonConfiguration(prominent: true)
        build.cornerStyle = .capsule
        buildButton.configuration = build
        buildButton.addAction(UIAction { [weak self] _ in self?.askImplement() }, for: .touchUpInside)
        buildButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titles = UIStackView(arrangedSubviews: [captionLabel, rationaleLabel])
        titles.axis = .vertical
        titles.spacing = 1
        let row = UIStackView(arrangedSubviews: [titles, notesButton, moreButton, buildButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.clipsToBounds = true
        bottomBar.layer.cornerCurve = .continuous
        bottomBar.contentView.addSubview(row)
        view.addSubview(picker)
        view.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.xs),
            picker.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            picker.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),

            pager.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: Theme.Spacing.s),
            pager.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pager.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pager.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pages.topAnchor.constraint(equalTo: pager.contentLayoutGuide.topAnchor),
            pages.bottomAnchor.constraint(equalTo: pager.contentLayoutGuide.bottomAnchor),
            pages.leadingAnchor.constraint(equalTo: pager.contentLayoutGuide.leadingAnchor),
            pages.trailingAnchor.constraint(equalTo: pager.contentLayoutGuide.trailingAnchor),
            pages.heightAnchor.constraint(equalTo: pager.frameLayoutGuide.heightAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Theme.Spacing.xl),
            statusLabel.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Theme.Spacing.xl),

            bottomBar.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Theme.Spacing.m),
            bottomBar.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Theme.Spacing.m),
            bottomBar.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Theme.Spacing.s),
            row.topAnchor.constraint(
                equalTo: bottomBar.contentView.topAnchor, constant: Theme.Spacing.s),
            row.bottomAnchor.constraint(
                equalTo: bottomBar.contentView.bottomAnchor, constant: -Theme.Spacing.s),
            row.leadingAnchor.constraint(
                equalTo: bottomBar.contentView.leadingAnchor, constant: Theme.Spacing.m),
            row.trailingAnchor.constraint(
                equalTo: bottomBar.contentView.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        bottomBar.layer.cornerRadius = bottomBar.bounds.height / 2
        scrollToSelection(animated: false)
    }

    private static func symbol(_ name: String) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
    }

    private func close() {
        dismiss(animated: true)
    }

    private func readManifest() {
        guard state.board == nil else { return }
        guard let files else {
            state.failed(
                String(localized: "This server cannot hand over files, so a board cannot open."))
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
                            ? String(localized: "\(path) could not be read from the server.")
                            : String(localized: "\(path) is not a board this app can read."))
                    self.render()
                    return
                }
                self.state.arrived(
                    DesignBoard(directory: self.state.directory, manifest: manifest))
                self.title = self.state.title
                self.render()
            }
        }
    }

    private func readArtboard(_ artboard: DesignArtboard) {
        guard let files, let board = board else { return }
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
        let artboards = state.artboards
        if picker.numberOfSegments != artboards.count {
            picker.removeAllSegments()
            for (index, artboard) in artboards.enumerated() {
                picker.insertSegment(withTitle: artboard.caption, at: index, animated: false)
            }
        }
        picker.isHidden = artboards.count < 2
        if picker.selectedSegmentIndex != state.selection, artboards.count > state.selection {
            picker.selectedSegmentIndex = state.selection
        }
        rebuildPages()
        statusLabel.text = state.isReady ? nil : state.subtitle
        statusLabel.isHidden = state.isReady
        captionLabel.text = state.current?.caption ?? state.title
        rationaleLabel.text = state.current?.rationale ?? state.footnote
        buildButton.configuration?.title = state.implementTitle
        bottomBar.isHidden = !state.isReady
        notesButton.isHidden = !state.isReady
        moreButton.isHidden = !state.isReady
        moreButton.menu = moreMenu()
        navigationItem.prompt = state.isReady ? state.subtitle : nil
    }

    private func rebuildPages() {
        let artboards = state.artboards
        if pages.arrangedSubviews.count != artboards.count {
            for view in pages.arrangedSubviews {
                pages.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            webViews.removeAll()
            drawn.removeAll()
            for artboard in artboards {
                let container = UIView()
                container.backgroundColor = Theme.Color.secondaryBackground
                pages.addArrangedSubview(container)
                container.widthAnchor.constraint(equalTo: pager.frameLayoutGuide.widthAnchor)
                    .isActive = true
                let web = Self.makeWebView()
                web.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(web)
                NSLayoutConstraint.activate([
                    web.topAnchor.constraint(equalTo: container.topAnchor),
                    web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                    web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                ])
                webViews[artboard.letter] = web
            }
        }
        for artboard in artboards {
            guard let web = webViews[artboard.letter] else { continue }
            guard let html = state.page(for: artboard) else {
                readArtboard(artboard)
                continue
            }
            guard drawn[artboard.letter] != html.hashValue else { continue }
            drawn[artboard.letter] = html.hashValue
            web.loadHTMLString(html, baseURL: nil)
        }
    }

    private static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        return web
    }

    private func scrollToSelection(animated: Bool) {
        guard state.isReady, pager.bounds.width > 0 else { return }
        let target = CGPoint(x: pager.bounds.width * CGFloat(state.selection), y: 0)
        guard abs(pager.contentOffset.x - target.x) > 1 else { return }
        pager.setContentOffset(target, animated: animated)
    }

    private func moreMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: state.tweakTitle, image: UIImage(systemName: "pencil")) {
                [weak self] _ in self?.askTweak()
            },
            UIAction(title: state.anotherTitle, image: UIImage(systemName: "plus.rectangle")) {
                [weak self] _ in self?.askAnother()
            },
        ])
    }

    private func presentNotes() {
        guard let artboard = state.current else { return }
        let notes = DesignNotesViewController(artboard: artboard, footnote: state.footnote)
        notes.sheetPresentationController?.detents = [.medium(), .large()]
        notes.sheetPresentationController?.prefersGrabberVisible = true
        present(notes, animated: true)
    }

    private func askImplement() {
        guard let board, let artboard = state.current else { return }
        prompt(
            title: state.implementTitle, message: DesignFollowUp.summary(artboard),
            placeholder: state.implementPrompt, confirm: state.implementTitle, requiresText: false
        ) { [weak self] notes in
            self?.send(DesignFollowUp.implement(board: board, artboard: artboard, notes: notes))
        }
    }

    private func askTweak() {
        guard let board, let artboard = state.current else { return }
        prompt(
            title: state.tweakTitle, message: state.tweakPrompt,
            placeholder: String(localized: "What should change?"),
            confirm: String(localized: "Send"), requiresText: true
        ) { [weak self] instruction in
            self?.send(
                DesignFollowUp.tweak(board: board, artboard: artboard, instruction: instruction))
        }
    }

    private func askAnother() {
        guard let board else { return }
        prompt(
            title: state.anotherTitle, message: state.anotherPrompt,
            placeholder: String(localized: "What should it try?"),
            confirm: String(localized: "Send"), requiresText: true
        ) { [weak self] instruction in
            self?.send(DesignFollowUp.another(board: board, instruction: instruction))
        }
    }

    private func prompt(
        title: String, message: String, placeholder: String, confirm: String, requiresText: Bool,
        then act: @escaping (String) -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = placeholder
            field.autocapitalizationType = .sentences
            field.returnKeyType = .send
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: confirm, style: .default) { _ in
                let text = alert.textFields?.first?.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !requiresText || !text.isEmpty else { return }
                act(text)
            })
        present(alert, animated: true)
    }

    /// A follow-up leaves through the conversation's own send, and the board closes behind it:
    /// what happens next is a turn in the transcript, and a screen over the top of it would hide
    /// the answer it asked for.
    private func send(_ prompt: String) {
        Theme.Haptics.send()
        let onSend = onSend
        dismiss(animated: true) { onSend(prompt) }
    }
}

extension DesignBoardViewController: UIScrollViewDelegate {
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView.bounds.width > 0 else { return }
        let page = Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())
        guard page != state.selection else { return }
        state.select(page)
        Theme.Haptics.step()
        render()
    }
}

/// The case an artboard makes for itself, and the annotations that would be stuck to it on a wall.
/// A sheet rather than a panel beside the mock: on a phone the mock is the whole screen, and the
/// argument is read once and put away.
final class DesignNotesViewController: UIViewController {
    private let artboard: DesignArtboard
    private let footnote: String

    init(artboard: DesignArtboard, footnote: String) {
        self.artboard = artboard
        self.footnote = footnote
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background

        let title = UILabel()
        title.font = Theme.Ramp.font(.panelTitle)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = Theme.Color.label
        title.numberOfLines = 0
        title.text = artboard.caption

        let rationale = UILabel()
        rationale.font = Theme.Ramp.font(.panelDetail)
        rationale.adjustsFontForContentSizeCategory = true
        rationale.textColor = Theme.Color.secondaryLabel
        rationale.numberOfLines = 0
        rationale.text = artboard.rationale

        let stack = UIStackView(arrangedSubviews: [title, rationale])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        stack.translatesAutoresizingMaskIntoConstraints = false

        for note in artboard.notes { stack.addArrangedSubview(Self.note(note)) }

        let closing = UILabel()
        closing.font = Theme.Ramp.font(.panelFootnote)
        closing.adjustsFontForContentSizeCategory = true
        closing.textColor = Theme.Color.tertiaryLabel
        closing.numberOfLines = 0
        closing.text = footnote
        stack.addArrangedSubview(closing)
        stack.setCustomSpacing(Theme.Spacing.m, after: rationale)

        let scroller = UIScrollView()
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(stack)
        view.addSubview(scroller)

        NSLayoutConstraint.activate([
            scroller.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroller.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroller.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(
                equalTo: scroller.contentLayoutGuide.topAnchor, constant: Theme.Spacing.l),
            stack.bottomAnchor.constraint(
                equalTo: scroller.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xl),
            stack.leadingAnchor.constraint(
                equalTo: scroller.contentLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(
                equalTo: scroller.contentLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            stack.widthAnchor.constraint(
                equalTo: scroller.frameLayoutGuide.widthAnchor, constant: -2 * Theme.Spacing.l),
        ])
    }

    /// An annotation reads as something stuck onto the mock rather than as another paragraph about
    /// it: the special slot, a rule down its leading edge, and the words the agent wrote.
    private static func note(_ text: String) -> UIView {
        let holder = UIView()
        holder.backgroundColor = Theme.Color.special.withAlphaComponent(0.12)
        holder.layer.cornerRadius = Theme.Radius.card
        holder.layer.cornerCurve = .continuous

        let rule = UIView()
        rule.backgroundColor = Theme.Color.special
        rule.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(rule)

        let label = UILabel()
        label.font = Theme.Ramp.font(.cardBody)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.label
        label.numberOfLines = 0
        label.text = text
        label.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(label)

        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            rule.topAnchor.constraint(equalTo: holder.topAnchor),
            rule.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            rule.widthAnchor.constraint(equalToConstant: 2),
            label.topAnchor.constraint(equalTo: holder.topAnchor, constant: Theme.Spacing.s),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -Theme.Spacing.s),
            label.leadingAnchor.constraint(equalTo: rule.trailingAnchor, constant: Theme.Spacing.m),
            label.trailingAnchor.constraint(
                equalTo: holder.trailingAnchor, constant: -Theme.Spacing.m),
        ])
        return holder
    }
}

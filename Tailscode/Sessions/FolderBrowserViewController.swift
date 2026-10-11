import CodingAgentKit
import TailscodeCore
import UIKit

/// The phone's way of walking another machine's disk to pick where a chat starts.
///
/// The arithmetic is `FolderBrowser` (Core), the same walk the desktops draw: a path to jump back
/// along, up and back, a filter that narrows the folder in view, the places a person already works
/// as one-press jumps, every server a menu away, and one verb that picks the folder you are
/// standing in. This controller only draws it, reads folders over the server's own listing when
/// the browser says it is waiting for one, and hands the answer back.
@MainActor
final class FolderBrowserViewController: UIViewController {
    /// What the primary button promises: a chat that starts there, or a folder handed back to a
    /// caller that will use it when its message is sent.
    enum Verb {
        case start
        case use

        var format: String {
            switch self {
            case .start: return "Start in %@"
            case .use: return "Use %@"
            }
        }

        var placeholder: String {
            switch self {
            case .start: return "Start here"
            case .use: return "Use here"
            }
        }
    }

    var onSelect: (@MainActor (String, String) -> Void)?
    var onStarred: (@MainActor () -> Void)?

    private let verb: Verb
    private let backends: @MainActor (String) -> (any FileBrowsingBackend)?
    private let directories: @MainActor () -> [String: NewChatDirectories]
    private var browser: FolderBrowser
    private var inFlight: Set<FolderRequest> = []
    private var finished = false
    private var cursorVisible = false
    private var shownLocation: String?
    private var shownServer: String?
    private var rowsByPath: [String: FolderRow] = [:]

    private let search = UISearchController(searchResultsController: nil)
    private let backButton = UIButton(configuration: .plain())
    private let upButton = UIButton(configuration: .plain())
    private let crumbStrip = ChipStrip()
    private let placeStrip = ChipStrip()
    private let stateView = UIContentUnavailableView(configuration: .empty())
    private let startBar = UIView()
    private var stripColumn: UIView!
    private let startButton = UIButton(configuration: Theme.Glass.buttonConfiguration(prominent: true))
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    init(
        servers: [NewChatServer], directories known: [String: NewChatDirectories],
        entries: [SessionEntry], preferredServer: String?, start: String?, verb: Verb,
        backends: @escaping @MainActor (String) -> (any FileBrowsingBackend)?,
        directories: @escaping @MainActor () -> [String: NewChatDirectories]
    ) {
        self.verb = verb
        self.backends = backends
        self.directories = directories
        self.browser = FolderBrowser(
            servers: servers, directories: known, entries: entries,
            preferredServer: preferredServer, start: start)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        navigationItem.largeTitleDisplayMode = .never
        configureSearch()
        configureNavigationStrips()
        configureCollectionView()
        configureStartBar()
        configureDataSource()
        update()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { true }

    private func configureSearch() {
        search.searchResultsUpdater = self
        search.searchBar.delegate = self
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        search.searchBar.placeholder = Localized.text("Filter folders")
        search.searchBar.autocapitalizationType = .none
        search.searchBar.autocorrectionType = .no
        search.searchBar.spellCheckingType = .no
        search.searchBar.smartQuotesType = .no
        search.searchBar.smartDashesType = .no
        search.searchBar.returnKeyType = .go
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        if #available(iOS 26.0, *) { navigationItem.preferredSearchBarPlacement = .stacked }
        definesPresentationContext = true
    }

    private func configureNavigationStrips() {
        configureStep(
            backButton, symbol: "arrow.uturn.backward",
            label: Localized.text("Back to the previous folder")
        ) { [weak self] in self?.run(.back) }
        configureStep(upButton, symbol: "arrow.up", label: Localized.text("Go up one folder")) {
            [weak self] in self?.run(.ascend)
        }
        let steps = UIStackView(arrangedSubviews: [backButton, upButton])
        steps.axis = .horizontal
        steps.spacing = 0
        steps.setContentHuggingPriority(.required, for: .horizontal)
        steps.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [steps, crumbStrip])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.xs

        let column = UIStackView(arrangedSubviews: [row, placeStrip])
        column.axis = .vertical
        column.spacing = Theme.Spacing.xs
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setContentHuggingPriority(.required, for: .vertical)
        row.setContentHuggingPriority(.required, for: .vertical)
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.xs),
            column.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.xs),
            column.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
        stripColumn = column
    }

    private func configureStep(
        _ button: UIButton, symbol: String, label: String, action: @escaping @MainActor () -> Void
    ) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)
        config.baseForegroundColor = Theme.Color.accent
        config.contentInsets = NSDirectionalEdgeInsets(
            top: Theme.Spacing.s, leading: Theme.Spacing.m, bottom: Theme.Spacing.s,
            trailing: Theme.Spacing.m)
        button.configuration = config
        button.accessibilityLabel = label
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.backgroundColor = .clear
        config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let path = self.dataSource.itemIdentifier(for: indexPath),
                let row = self.rowsByPath[path]
            else { return nil }
            let action = UIContextualAction(
                style: .normal,
                title: row.starred ? Localized.text("Remove star") : Localized.text("Star")
            ) { _, _, done in
                self.toggleStar(path: row.path)
                done(true)
            }
            action.image = UIImage(systemName: row.starred ? "star.slash.fill" : "star.fill")
            action.backgroundColor = Theme.Color.special
            return UISwipeActionsConfiguration(actions: [action])
        }
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.readableList(using: config))
        collectionView.backgroundColor = .clear
        collectionView.keyboardDismissMode = .onDrag
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.isHidden = true
        view.addSubview(stateView)
    }

    private func configureStartBar() {
        startBar.translatesAutoresizingMaskIntoConstraints = false
        startButton.translatesAutoresizingMaskIntoConstraints = false
        startButton.addAction(
            UIAction { [weak self] _ in self?.run(.chooseHere) }, for: .touchUpInside)
        startBar.addSubview(startButton)
        view.addSubview(startBar)
        let fill = collectionView.heightAnchor.constraint(equalToConstant: 10_000)
        fill.priority = .defaultLow
        NSLayoutConstraint.activate([
            fill,
            collectionView.topAnchor.constraint(
                equalTo: stripColumn.bottomAnchor, constant: Theme.Spacing.xs),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: startBar.topAnchor),

            stateView.topAnchor.constraint(equalTo: collectionView.topAnchor),
            stateView.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor),
            stateView.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor),

            startBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            startBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            startBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            startButton.topAnchor.constraint(equalTo: startBar.topAnchor, constant: Theme.Spacing.s),
            startButton.bottomAnchor.constraint(
                equalTo: startBar.bottomAnchor, constant: -Theme.Spacing.s),
            startButton.leadingAnchor.constraint(
                equalTo: startBar.leadingAnchor, constant: Theme.Spacing.l),
            startButton.trailingAnchor.constraint(
                equalTo: startBar.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
            [weak self] cell, _, path in
            guard let self, let row = self.rowsByPath[path] else { return }
            self.configure(cell, row: row)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, path in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: path)
        }
    }

    /// One folder: its name with the letters the filter landed on in the accent, where chats
    /// already work said under it, and a chevron because a tap goes in. The row the keyboard's
    /// cursor stands on wears the tint this app uses wherever a set is being walked.
    private func configure(_ cell: UICollectionViewListCell, row: FolderRow) {
        var content = UIListContentConfiguration.subtitleCell()
        content.attributedText = Self.highlighted(row)
        content.textProperties.numberOfLines = 1
        content.secondaryText = Self.detail(for: row)
        content.secondaryTextProperties.font = Theme.Ramp.font(.panelDetail)
        content.secondaryTextProperties.color = Theme.Color.secondaryLabel
        content.secondaryTextProperties.numberOfLines = 1
        content.textToSecondaryTextVerticalPadding = 2
        content.image = UIImage(systemName: "folder.fill")
        content.imageProperties.tintColor = Theme.Color.accent
        content.imageProperties.maximumSize = CGSize(width: 24, height: 24)
        content.imageProperties.reservedLayoutSize = CGSize(width: 24, height: 24)
        content.imageToTextPadding = Theme.Spacing.m
        cell.contentConfiguration = content

        var background = UIBackgroundConfiguration.listCell()
        if browser.focused?.path == row.path, cursorVisible || !browser.filter.isEmpty {
            background.backgroundColor = Theme.Color.accent.withAlphaComponent(0.18)
        }
        cell.backgroundConfiguration = background

        var accessories: [UICellAccessory] = []
        if row.starred {
            let star = UIImageView(image: UIImage(systemName: "star.fill"))
            star.tintColor = Theme.Color.special
            star.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
            accessories.append(
                .customView(
                    configuration: .init(
                        customView: star, placement: .trailing(displayed: .always),
                        maintainsFixedSize: true)))
        }
        accessories.append(.disclosureIndicator())
        cell.accessories = accessories
        cell.accessibilityLabel = Self.spoken(row)
    }

    private static func detail(for row: FolderRow) -> String? {
        var parts: [String] = []
        if row.chats > 0 {
            parts.append(
                row.chats == 1
                    ? String(localized: "1 chat") : String(localized: "\(row.chats) chats"))
        }
        if row.chatsBelow > 0 { parts.append(String(localized: "\(row.chatsBelow) inside")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func spoken(_ row: FolderRow) -> String {
        var parts = [row.name]
        if row.starred { parts.append(Localized.text("Starred")) }
        if let detail = detail(for: row) { parts.append(detail) }
        return parts.joined(separator: ", ")
    }

    /// Offsets from `FuzzyRank` count characters, so they are walked into UTF-16 ranges: a name
    /// with one accented letter in it must not shift every highlight after it.
    private static func highlighted(_ row: FolderRow) -> NSAttributedString {
        let base = Theme.Ramp.font(.rowTitle)
        let text = NSMutableAttributedString(
            string: row.name,
            attributes: [.font: base, .foregroundColor: Theme.Color.label])
        let marks = Set(row.highlight)
        guard !marks.isEmpty else { return text }
        var offset = 0
        for (index, character) in row.name.enumerated() {
            let length = String(character).utf16.count
            if marks.contains(index) {
                text.addAttributes(
                    [
                        .font: Theme.Ramp.font(.rowTitleStrong),
                        .foregroundColor: Theme.Color.accent,
                    ],
                    range: NSRange(location: offset, length: length))
            }
            offset += length
        }
        return text
    }

    private func update() {
        render()
        service()
    }

    /// The shell half: whatever folder the browser says it is waiting for is read off the server
    /// once. An answer for a folder the person has already left is kept by the browser for later
    /// and never drawn.
    private func service() {
        guard let request = browser.wanted else { return }
        guard inFlight.insert(request).inserted else { return }
        guard let backend = backends(request.profileID) else {
            inFlight.remove(request)
            AppLogger.ui.error(
                "folder browser has no listing backend profile=\(request.profileID) path=\(request.path)"
            )
            browser.offer(request, nodes: nil)
            render()
            return
        }
        AppLogger.ui.info(
            "folder browser reads profile=\(request.profileID) path=\(request.path)")
        Task { [weak self] in
            var nodes: [FileNode]?
            do {
                nodes = try await backend.listFiles(path: request.path)
            } catch {
                AppLogger.ui.error(
                    "folder browser read failed profile=\(request.profileID) path=\(request.path): \(AgentErrorText.readable(error))"
                )
            }
            guard let self else { return }
            self.inFlight.remove(request)
            self.browser.offer(request, nodes: nodes)
            self.render()
            self.service()
        }
    }

    private func render() {
        let moved = shownLocation != browser.location || shownServer != browser.server?.profileID
        if moved {
            cursorVisible = false
            if let location = browser.location, let server = browser.server {
                AppLogger.ui.info(
                    "folder browser at profile=\(server.profileID) path=\(location)")
            }
        }
        shownLocation = browser.location
        shownServer = browser.server?.profileID

        navigationItem.title = browser.currentName
        if #available(iOS 26.0, *) { navigationItem.subtitle = browser.server?.title }
        if (search.searchBar.text ?? "") != browser.filter { search.searchBar.text = browser.filter }
        backButton.isEnabled = browser.canGoBack
        upButton.isEnabled = browser.canGoUp
        renderBarItems()
        renderCrumbs()
        renderPlaces()
        renderRows(moved: moved)
        renderState()
        renderStartButton()
    }

    private func renderBarItems() {
        let starred = browser.isStarredHere
        let star = UIBarButtonItem(
            image: UIImage(systemName: starred ? "star.fill" : "star"), style: .plain,
            target: self, action: #selector(starTapped))
        star.accessibilityLabel = starred ? Localized.text("Remove star") : Localized.text("Star")
        star.isEnabled = browser.location != nil
        var items = [star]
        if browser.servers.count > 1, let current = browser.server {
            let menu = UIMenu(
                title: Localized.text("Servers"),
                children: browser.servers.map { candidate in
                    UIAction(
                        title: candidate.title, subtitle: candidate.address,
                        image: UIImage(systemName: candidate.backend.symbolName),
                        state: candidate.profileID == current.profileID ? .on : .off
                    ) { [weak self] _ in
                        guard let self else { return }
                        Theme.Haptics.selection()
                        self.browser.chooseServer(candidate.profileID)
                        self.update()
                    }
                })
            let switcher = UIBarButtonItem(
                image: UIImage(systemName: current.backend.symbolName), menu: menu)
            switcher.accessibilityLabel = Localized.text("Server: %@", current.title)
            items.append(switcher)
        }
        navigationItem.rightBarButtonItems = items
    }

    private func renderCrumbs() {
        let crumbs = browser.crumbs
        let chips = crumbs.map { crumb in
            ChipStrip.Chip(
                key: crumb.path, title: crumb.title, symbol: nil, emphasised: crumb.isCurrent,
                label: crumb.title == "~"
                    ? Localized.text("Home") : Localized.text("Folder %@", crumb.title),
                selected: crumb.isCurrent
            ) { [weak self] in
                guard let self else { return }
                Theme.Haptics.selection()
                self.browser.open(crumb.path)
                self.update()
            }
        }
        crumbStrip.isHidden = chips.isEmpty
        crumbStrip.set(chips, scrollTo: .end)
    }

    private func renderPlaces() {
        let places = browser.places
        let chips = places.enumerated().map { index, place in
            ChipStrip.Chip(
                key: "\(place.kind)|\(place.path)", title: place.title,
                symbol: Self.symbol(for: place.kind), emphasised: false,
                label: place.title, selected: false
            ) { [weak self] in
                guard let self else { return }
                Theme.Haptics.selection()
                self.browser.openPlace(index)
                self.update()
            }
        }
        placeStrip.isHidden = !browser.filter.isEmpty || chips.isEmpty
        placeStrip.set(chips, scrollTo: .start)
    }

    private static func symbol(for kind: FolderPlaceKind) -> String {
        switch kind {
        case .home: return "house"
        case .root: return "internaldrive"
        case .favorite: return "star.fill"
        case .recent: return "clock"
        case .project: return "bubble.left"
        }
    }

    private func renderRows(moved: Bool) {
        let rows = browser.rows
        rowsByPath = Dictionary(rows.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = rows.map(\.path)
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let retained = ids.filter { existing.contains($0) }
        if !retained.isEmpty { snapshot.reconfigureItems(retained) }
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.accessibilityLabel = browser.summary
        if moved {
            collectionView.setContentOffset(
                CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
        } else if cursorVisible, rows.indices.contains(browser.cursor) {
            collectionView.scrollToItem(
                at: IndexPath(item: browser.cursor, section: 0), at: .centeredVertically,
                animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }

    /// What stands in for the list while there is no list: the read under way, a server that
    /// cannot list at all, a folder it refused, or a folder with nothing in it. A refused folder
    /// leaves the path and the up button live, because nobody is stranded by a bad path.
    private func renderState() {
        var config: UIContentUnavailableConfiguration?
        switch browser.phase {
        case .loading:
            var loading = UIContentUnavailableConfiguration.loading()
            loading.text = Localized.text("Reading…")
            config = loading
        case .failed(.cannotList):
            var failed = UIContentUnavailableConfiguration.empty()
            failed.image = UIImage(systemName: "exclamationmark.triangle")
            failed.text = Localized.text("This server can’t list its folders")
            failed.secondaryText = Localized.text(
                "It may be offline, waiting for a password, or too old to list folders. Typing a path in the new-chat field still works."
            )
            config = withRetry(failed)
        case .failed(.missing(let path)):
            var failed = UIContentUnavailableConfiguration.empty()
            failed.image = UIImage(systemName: "folder.badge.questionmark")
            failed.text = Localized.text("The server couldn’t open that folder")
            failed.secondaryText = Localized.text(
                "%@ didn’t open. Go up along the path above, or pick another place.", path)
            config = withRetry(failed)
        case .ready:
            if browser.rows.isEmpty {
                var empty = UIContentUnavailableConfiguration.empty()
                empty.image = UIImage(systemName: "folder")
                empty.text = browser.summary
                config = empty
            }
        }
        stateView.configuration = config ?? .empty()
        stateView.isHidden = config == nil
        collectionView.isHidden = config != nil
    }

    private func withRetry(_ base: UIContentUnavailableConfiguration)
        -> UIContentUnavailableConfiguration
    {
        var config = base
        var button = UIButton.Configuration.tinted()
        button.title = Localized.text("Retry")
        button.cornerStyle = .capsule
        config.button = button
        config.buttonProperties.primaryAction = UIAction { [weak self] _ in
            self?.run(.refresh)
        }
        return config
    }

    private func renderStartButton() {
        var config = startButton.configuration ?? Theme.Glass.buttonConfiguration(prominent: true)
        config.buttonSize = .large
        config.titleLineBreakMode = .byTruncatingMiddle
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = Theme.Ramp.font(.control)
            return attributes
        }
        if let choice = browser.choice {
            config.title = Localized.text(verb.format, Self.name(of: choice))
        } else {
            config.title = Localized.text(verb.placeholder)
        }
        startButton.configuration = config
        var usable = browser.choice != nil
        if case .failed = browser.phase { usable = false }
        startButton.isEnabled = usable
    }

    private static func name(of path: String) -> String {
        path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    @objc private func starTapped() {
        run(.favoriteHere)
    }

    private func toggleStar(path: String) {
        guard let server = browser.server else { return }
        Theme.Haptics.selection()
        let starred = FileBrowserFavorites.toggle(path, for: server.profileID)
        AppLogger.ui.info(
            "folder browser \(starred ? "starred" : "unstarred") profile=\(server.profileID) path=\(path)"
        )
        browser = browser.restated(directories: directories())
        onStarred?()
        update()
    }

    private func finish(profileID: String, path: String) {
        guard !finished else { return }
        finished = true
        Theme.Haptics.tap()
        AppLogger.ui.info("folder browser chose profile=\(profileID) path=\(path)")
        onSelect?(profileID, path)
    }

    private func run(_ command: FolderCommand) {
        let answer = browser.handle(command)
        switch command {
        case .up, .down, .top, .bottom, .halfUp, .halfDown: cursorVisible = true
        case .ascend, .back, .home, .root, .descend, .nextServer, .previousServer:
            Theme.Haptics.selection()
        default: break
        }
        update()
        switch answer.outcome {
        case .choose(let profileID, let path): finish(profileID: profileID, path: path)
        case .favorite(_, let path): toggleStar(path: path)
        case .dismiss: navigationController?.popViewController(animated: true)
        case nil: break
        }
    }

    #if DEBUG
        func tourType(_ text: String) {
            browser.type(text)
            update()
        }

        func tourDescend() {
            run(.descend)
        }
    #endif

    private struct Claimed {
        let keyval: UInt32
        let state: UInt32
        let needsEmptyFilter: Bool
    }

    private static let leftArrow: UInt32 = 0xFF51
    private static let rightArrow: UInt32 = 0xFF53
    private static let homeKey: UInt32 = 0xFF50

    /// The chords the browser takes from the filter field. A first-responder field consumes a press
    /// before the controller sees it and only a registered `UIKeyCommand` is consulted first, so
    /// every chord `FolderBrowser.command` can answer is registered. The three that mean something
    /// else while there is text to edit (backspace and the side arrows) are registered too, and
    /// switched off in `validate` the moment the field holds a letter.
    private static var claimed: [Claimed] {
        var chords: [Claimed] = [
            Claimed(keyval: Keymap.up, state: 0, needsEmptyFilter: false),
            Claimed(keyval: Keymap.down, state: 0, needsEmptyFilter: false),
            Claimed(keyval: Keymap.enter, state: 0, needsEmptyFilter: false),
            Claimed(keyval: Keymap.tab, state: 0, needsEmptyFilter: false),
            Claimed(keyval: Keymap.tab, state: KeyChord.shiftMask, needsEmptyFilter: false),
            Claimed(keyval: Keymap.escape, state: 0, needsEmptyFilter: false),
            Claimed(keyval: Keymap.enter, state: KeyChord.controlMask, needsEmptyFilter: false),
            Claimed(keyval: leftArrow, state: KeyChord.controlMask, needsEmptyFilter: false),
            Claimed(keyval: rightArrow, state: KeyChord.controlMask, needsEmptyFilter: false),
            Claimed(keyval: Keymap.up, state: KeyChord.altMask, needsEmptyFilter: false),
            Claimed(keyval: leftArrow, state: KeyChord.altMask, needsEmptyFilter: false),
            Claimed(keyval: homeKey, state: KeyChord.altMask, needsEmptyFilter: false),
            Claimed(keyval: Keymap.backspace, state: 0, needsEmptyFilter: true),
            Claimed(keyval: leftArrow, state: 0, needsEmptyFilter: true),
            Claimed(keyval: rightArrow, state: 0, needsEmptyFilter: true),
        ]
        for letter in "njpkdusbr" {
            chords.append(
                Claimed(
                    keyval: letter.unicodeScalars.first?.value ?? 0, state: KeyChord.controlMask,
                    needsEmptyFilter: false))
        }
        return chords
    }

    override var keyCommands: [UIKeyCommand]? {
        Self.claimed.compactMap { Self.keyCommand(for: $0) }
    }

    private static func keyCommand(for chord: Claimed) -> UIKeyCommand? {
        var flags: UIKeyModifierFlags = []
        if chord.state & KeyChord.controlMask != 0 { flags.insert(.control) }
        if chord.state & KeyChord.shiftMask != 0 { flags.insert(.shift) }
        if chord.state & KeyChord.altMask != 0 { flags.insert(.alternate) }
        let input: String
        switch chord.keyval {
        case Keymap.enter: input = "\r"
        case Keymap.escape: input = UIKeyCommand.inputEscape
        case Keymap.tab: input = "\t"
        case Keymap.up: input = UIKeyCommand.inputUpArrow
        case Keymap.down: input = UIKeyCommand.inputDownArrow
        case Keymap.backspace: input = "\u{8}"
        case leftArrow: input = UIKeyCommand.inputLeftArrow
        case rightArrow: input = UIKeyCommand.inputRightArrow
        case homeKey: input = UIKeyCommand.inputHome
        default:
            guard let scalar = Unicode.Scalar(chord.keyval), chord.keyval >= 0x20,
                chord.keyval < 0xFF00
            else { return nil }
            input = String(Character(scalar))
        }
        let command = UIKeyCommand(
            title: "", action: #selector(handleBrowserKey(_:)), input: input,
            modifierFlags: flags,
            propertyList: "\(chord.state)|\(chord.keyval)|\(chord.needsEmptyFilter ? 1 : 0)")
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    override func validate(_ command: UICommand) {
        super.validate(command)
        guard let key = command as? UIKeyCommand, let token = key.propertyList as? String,
            token.hasSuffix("|1")
        else { return }
        if browser.filter.isEmpty {
            key.attributes.remove(.disabled)
        } else {
            key.attributes.insert(.disabled)
        }
    }

    @objc private func handleBrowserKey(_ command: UIKeyCommand) {
        guard let token = command.propertyList as? String else { return }
        let pieces = token.split(separator: "|")
        guard pieces.count == 3, let state = UInt32(pieces[0]), let keyval = UInt32(pieces[1]),
            let chord = KeyChord.canonical(keyval: keyval, state: state),
            let action = FolderBrowser.command(for: chord, filterIsEmpty: browser.filter.isEmpty)
        else { return }
        run(action)
    }
}

extension FolderBrowserViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let path = dataSource.itemIdentifier(for: indexPath) else { return }
        Theme.Haptics.selection()
        browser.open(path)
        update()
    }
}

extension FolderBrowserViewController: UISearchResultsUpdating, UISearchBarDelegate {
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != browser.filter else { return }
        browser.type(text)
        cursorVisible = false
        update()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        run(.descend)
    }
}

/// A horizontal row of capsule buttons that scrolls sideways: the path being walked, and the
/// places worth jumping to. It rebuilds only when its chips changed, so a redraw that said the
/// same thing neither flickers nor throws away where the person had scrolled it to.
private final class ChipStrip: UIScrollView {
    struct Chip {
        let key: String
        let title: String
        let symbol: String?
        let emphasised: Bool
        let label: String
        let selected: Bool
        let action: @MainActor () -> Void
    }

    enum Edge {
        case start
        case end
    }

    private let stack = UIStackView()
    private var signature: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        alwaysBounceHorizontal = true
        contentInset = UIEdgeInsets(
            top: 0, left: Theme.Spacing.m, bottom: 0, right: Theme.Spacing.m)
        stack.axis = .horizontal
        stack.spacing = Theme.Spacing.s
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            heightAnchor.constraint(equalTo: contentLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func set(_ chips: [Chip], scrollTo edge: Edge) {
        let next = chips.map { "\($0.key)|\($0.title)|\($0.emphasised)" }
        guard next != signature else { return }
        signature = next
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for chip in chips { stack.addArrangedSubview(Self.button(for: chip)) }
        layoutIfNeeded()
        let animated = !UIAccessibility.isReduceMotionEnabled && window != nil
        switch edge {
        case .start:
            setContentOffset(CGPoint(x: -contentInset.left, y: 0), animated: false)
        case .end:
            let x = max(-contentInset.left, contentSize.width - bounds.width + contentInset.right)
            setContentOffset(CGPoint(x: x, y: 0), animated: animated)
        }
    }

    private static func button(for chip: Chip) -> UIButton {
        var config: UIButton.Configuration = chip.emphasised ? .filled() : .tinted()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.title = chip.title
        config.titleLineBreakMode = .byTruncatingMiddle
        if let symbol = chip.symbol {
            config.image = UIImage(systemName: symbol)
            config.imagePadding = Theme.Spacing.xs
        }
        if chip.emphasised {
            config.baseBackgroundColor = Theme.Color.accent
            config.baseForegroundColor = Theme.Color.onAccent
        } else {
            config.baseBackgroundColor = Theme.Color.secondaryLabel
            config.baseForegroundColor = Theme.Color.label
        }
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = Theme.Ramp.font(.panelDetail)
            return attributes
        }
        let button = UIButton(configuration: config)
        button.accessibilityLabel = chip.label
        button.accessibilityTraits = chip.selected ? [.button, .selected] : .button
        button.addAction(UIAction { _ in chip.action() }, for: .touchUpInside)
        return button
    }
}

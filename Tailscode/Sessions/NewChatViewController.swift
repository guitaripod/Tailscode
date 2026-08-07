import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore
import UIKit

/// What the modal does with the folder it is handed: start the conversation itself, or give the
/// server and folder back to a caller that will. Home's docked composer only wants the answer —
/// it creates the session when the message is sent — so the same screen serves both.
enum NewChatPurpose {
    case start
    case choose
}

/// The New Conversation modal: one screen for both halves of the question, decided by the shared
/// `NewChatChooser`.
///
/// Where a chat starts used to be a file browser pushed full-screen or, on a server that cannot
/// list its files, a bare alert with one text field — which meant the folder you wanted was either
/// the one already filled in or something you typed out in full. Here the folders this device
/// already knows for that server are ranked against what is being typed, each row says where it
/// came from, and the typed path is always offered as a row of its own.
///
/// It is the first sheet in this app to answer a hardware keyboard, and it answers it in both of
/// the chooser's modes: while typing the field owns the letters and only chords it can never want
/// are claimed, and in normal mode the letters are the verbs they are everywhere else. Keyboard
/// focus is moved in and out of the field to follow `chooser.mode` — a mode the widgets disagreed
/// with would be worse than no mode at all.
@MainActor
final class NewChatViewController: UIViewController {
    var onStart: (@MainActor (SessionEntry) -> Void)?
    var onChoose: (@MainActor (String, String?) -> Void)?

    private struct RowID: Hashable {
        let origin: Int
        let path: String
    }

    private let viewModel: SessionListViewModel
    private let purpose: NewChatPurpose
    private var chooser: NewChatChooser
    private let serverButton = UIButton(configuration: Theme.Glass.buttonConfiguration())
    private let field = UITextField()
    private let hintLabel = UILabel()
    private let emptyLabel = UILabel()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, RowID>!
    private var startItem: UIBarButtonItem!

    /// Enter can arrive twice — as the key command that claims the field's Return and as the
    /// field's own `textFieldShouldReturn` — and a second arrival would create a second session
    /// on a server that has no idea the first one was a mistake. The answer is taken once.
    private var finished = false

    init(
        viewModel: SessionListViewModel, preferredServer: String? = nil,
        purpose: NewChatPurpose = .start
    ) {
        self.viewModel = viewModel
        self.purpose = purpose
        let servers = Self.servers(from: viewModel)
        self.chooser = NewChatChooser(
            servers: servers,
            directories: Self.directories(for: servers, entries: viewModel.entries),
            entries: viewModel.entries,
            preferredServer: preferredServer ?? AppPreferences.lastComposeTarget?.profileID)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        title = String(localized: "New conversation")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        startItem = UIBarButtonItem(
            title: purpose == .start ? String(localized: "Start") : String(localized: "Use"),
            style: .done, target: self, action: #selector(startTapped))
        navigationItem.rightBarButtonItem = startItem
        configureHeader()
        configureCollectionView()
        configureDataSource()
        reload()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        syncMode()
    }

    override var canBecomeFirstResponder: Bool { true }

    private func configureHeader() {
        var config = serverButton.configuration
        config?.cornerStyle = .capsule
        config?.buttonSize = .small
        serverButton.configuration = config
        serverButton.showsMenuAsPrimaryAction = true
        serverButton.isHidden = chooser.servers.count < 2
        serverButton.translatesAutoresizingMaskIntoConstraints = false
        serverButton.accessibilityHint = String(localized: "Choose which machine the chat runs on")

        field.borderStyle = .none
        field.backgroundColor = Theme.Color.secondaryBackground
        field.placeholder = String(localized: "Search folders, or type a path")
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.keyboardType = .URL
        field.clearButtonMode = .whileEditing
        field.font = Theme.Font.body()
        field.delegate = self
        field.layer.borderWidth = 1.5
        field.layer.borderColor = UIColor.clear.cgColor
        field.layer.cornerRadius = Theme.Radius.control
        field.layer.cornerCurve = .continuous
        field.leftView = UIView(
            frame: CGRect(x: 0, y: 0, width: Theme.Spacing.m, height: 1))
        field.leftViewMode = .always
        field.addTarget(self, action: #selector(fieldChanged), for: .editingChanged)
        field.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .preferredFont(forTextStyle: .caption2)
        hintLabel.adjustsFontForContentSizeCategory = true
        hintLabel.textColor = Theme.Color.tertiaryLabel
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .preferredFont(forTextStyle: .footnote)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = Theme.Color.secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(serverButton)
        view.addSubview(field)
        view.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            serverButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.s),
            serverButton.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            serverButton.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor, constant: -Theme.Spacing.l),

            field.topAnchor.constraint(
                equalTo: chooser.servers.count < 2
                    ? view.safeAreaLayoutGuide.topAnchor : serverButton.bottomAnchor,
                constant: Theme.Spacing.s),
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            hintLabel.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            hintLabel.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
            hintLabel.bottomAnchor.constraint(
                equalTo: view.keyboardLayoutGuide.topAnchor, constant: -Theme.Spacing.s),
        ])
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.showsSeparators = false
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        collectionView.backgroundColor = .clear
        collectionView.keyboardDismissMode = .none
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(
                equalTo: field.bottomAnchor, constant: Theme.Spacing.s),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(
                equalTo: hintLabel.topAnchor, constant: -Theme.Spacing.xs),
            emptyLabel.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Theme.Spacing.xl),
            emptyLabel.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Theme.Spacing.xl),
        ])
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, RowID> {
            [weak self] cell, indexPath, _ in
            guard let self, self.chooser.rows.indices.contains(indexPath.item) else { return }
            self.configure(cell, row: self.chooser.rows[indexPath.item], index: indexPath.item)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
    }

    /// One folder, with the letters it matched shown on the path itself so the ranking explains
    /// itself rather than merely being right. The row under the cursor wears the same tinted
    /// selection this app uses everywhere a set is being picked from; nothing else marks a row.
    private func configure(_ cell: UICollectionViewListCell, row: NewChatRow, index: Int) {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = row.title
        content.textProperties.font = Theme.Font.body()
        content.textProperties.numberOfLines = 1
        if row.origin == .browse {
            content.secondaryText = row.detail
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
            content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
        } else {
            content.secondaryAttributedText = Self.highlighted(row)
        }
        content.secondaryTextProperties.numberOfLines = 1
        content.textToSecondaryTextVerticalPadding = 2
        content.image = UIImage(systemName: Self.symbol(for: row.origin))
        content.imageProperties.tintColor = Self.tint(for: row.origin)
        content.imageProperties.maximumSize = CGSize(width: 20, height: 20)
        content.imageProperties.reservedLayoutSize = CGSize(width: 20, height: 20)
        content.imageToTextPadding = Theme.Spacing.m
        cell.contentConfiguration = content

        var background = UIBackgroundConfiguration.listCell()
        if index == chooser.cursor {
            background.backgroundColor = Theme.Color.accent.withAlphaComponent(0.18)
        }
        cell.backgroundConfiguration = background

        if let badge = badge(for: row, index: index) {
            cell.accessories = [
                .customView(
                    configuration: .init(
                        customView: badge, placement: .trailing(displayed: .always),
                        maintainsFixedSize: true))
            ]
        } else {
            cell.accessories = []
        }
        cell.accessibilityLabel = Self.spoken(row)
    }

    /// What the row is worth knowing besides its name: the digit that would pick it while the
    /// verbs are live, where it came from, and how many chats already work there.
    private func badge(for row: NewChatRow, index: Int) -> UIView? {
        var parts: [String] = []
        if chooser.mode == .normal, index < 9 { parts.append("\(index + 1)") }
        if let label = row.origin.label { parts.append(label) }
        if row.chats > 0 {
            parts.append(
                row.chats == 1
                    ? String(localized: "1 chat") : String(localized: "\(row.chats) chats"))
        }
        guard !parts.isEmpty else { return nil }
        let label = UILabel()
        label.text = parts.joined(separator: " · ")
        label.font = .preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.tertiaryLabel
        label.sizeToFit()
        return label
    }

    private static func spoken(_ row: NewChatRow) -> String {
        var parts = [row.title]
        if let label = row.origin.label { parts.append(label) }
        if row.origin != .browse { parts.append(row.path) }
        return parts.joined(separator: ", ")
    }

    /// The letters the ranking read, drawn on the path in the accent. Offsets from `FuzzyRank` are
    /// per character, so they are walked into UTF-16 ranges rather than used as byte offsets — a
    /// path with one accented folder in it must not shift every highlight after it.
    private static func highlighted(_ row: NewChatRow) -> NSAttributedString {
        let base = UIFont.preferredFont(forTextStyle: .caption1)
        let text = NSMutableAttributedString(
            string: row.path,
            attributes: [.font: base, .foregroundColor: Theme.Color.tertiaryLabel])
        let marks = Set(row.highlight)
        guard !marks.isEmpty else { return text }
        var offset = 0
        for (index, character) in row.path.enumerated() {
            let length = String(character).utf16.count
            if marks.contains(index) {
                text.addAttributes(
                    [
                        .font: base.withTraits(.traitBold),
                        .foregroundColor: Theme.Color.accent,
                    ],
                    range: NSRange(location: offset, length: length))
            }
            offset += length
        }
        return text
    }

    private static func symbol(for origin: NewChatOrigin) -> String {
        switch origin {
        case .favorite: return "star.fill"
        case .recent: return "clock"
        case .project: return "folder.fill"
        case .typed: return "plus.circle"
        case .browse: return "folder.badge.plus"
        }
    }

    private static func tint(for origin: NewChatOrigin) -> UIColor {
        switch origin {
        case .favorite: return Theme.Color.special
        case .recent: return Theme.Color.secondaryLabel
        case .project: return Theme.Color.accent
        case .typed: return Theme.Color.accent
        case .browse: return Theme.Color.accent
        }
    }

    private func reload() {
        if field.text != chooser.query { field.text = chooser.query }
        hintLabel.text = chooser.hint
        startItem.isEnabled = chooser.server != nil
        updateServerButton()

        var snapshot = NSDiffableDataSourceSnapshot<Int, RowID>()
        snapshot.appendSections([0])
        let ids = chooser.rows.map { RowID(origin: $0.origin.rawValue, path: $0.path) }
        snapshot.appendItems(ids)
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let retained = ids.filter { existing.contains($0) }
        if !retained.isEmpty { snapshot.reconfigureItems(retained) }
        dataSource.apply(snapshot, animatingDifferences: false)

        emptyLabel.isHidden = !chooser.rows.isEmpty
        emptyLabel.text =
            chooser.isEmpty
            ? String(localized: "No server is connected yet. Add one in Settings.")
            : String(
                localized: "Nothing here matches. Type a path starting with / or ~ to use it.")
        guard chooser.rows.indices.contains(chooser.cursor) else { return }
        collectionView.selectItem(
            at: IndexPath(item: chooser.cursor, section: 0), animated: false,
            scrollPosition: .centeredVertically)
    }

    private func updateServerButton() {
        serverButton.isHidden = chooser.servers.count < 2
        guard let server = chooser.server else { return }
        var config = serverButton.configuration
        config?.title = server.title
        config?.subtitle =
            server.reachable
            ? server.address : String(localized: "\(server.address) · not answering")
        config?.image = UIImage(systemName: server.backend.symbolName)
        config?.imagePadding = Theme.Spacing.xs
        serverButton.configuration = config
        serverButton.menu = UIMenu(
            title: String(localized: "Start the chat on…"),
            children: chooser.servers.map { candidate in
                UIAction(
                    title: candidate.title,
                    subtitle: candidate.address,
                    image: UIImage(systemName: candidate.backend.symbolName),
                    state: candidate.profileID == server.profileID ? .on : .off
                ) { [weak self] _ in
                    guard let self else { return }
                    Theme.Haptics.selection()
                    self.chooser.chooseServer(candidate.profileID)
                    self.reload()
                }
            })
    }

    /// Moves keyboard focus to follow the chooser's mode. The field owning the letters and the
    /// verbs owning the letters cannot both be true, so the widget is made to agree with the
    /// state rather than the other way round; the field's ring says which one is live.
    private func syncMode() {
        switch chooser.mode {
        case .typing:
            if !field.isFirstResponder { field.becomeFirstResponder() }
        case .normal:
            if field.isFirstResponder { field.resignFirstResponder() }
            if !isFirstResponder { becomeFirstResponder() }
        }
        field.layer.borderColor =
            (chooser.mode == .typing ? Theme.Color.accent : UIColor.clear).cgColor
        hintLabel.text = chooser.hint
    }

    @objc private func fieldChanged() {
        chooser.type(field.text ?? "")
        reload()
    }

    @objc private func startTapped() {
        activate()
    }

    private func activate() {
        apply(chooser.activate())
    }

    private func apply(_ outcome: NewChatOutcome?) {
        guard let outcome else { return }
        switch outcome {
        case .start(let profileID, let directory):
            finish(profileID: profileID, directory: directory)
        case .browse(let profileID):
            pushBrowser(profileID: profileID)
        case .favorite(let profileID, let path):
            Theme.Haptics.selection()
            _ = FileBrowserFavorites.toggle(path, for: profileID)
            regather()
        case .dismiss:
            dismiss(animated: true)
        }
    }

    /// Re-reads the folders after one of them was starred and carries the cursor across, so the
    /// list moving under the person's finger never moves the person.
    private func regather() {
        chooser = chooser.restated(
            directories: Self.directories(for: chooser.servers, entries: viewModel.entries),
            entries: viewModel.entries)
        reload()
    }

    /// The session is created after the sheet is gone, exactly as the old flow created it: the
    /// list's own error alert is the one surface for a server that will not answer, and it cannot
    /// present itself underneath a sheet that is still up.
    private func finish(profileID: String, directory: String?) {
        guard !finished,
            let profile = viewModel.servers.first(where: { $0.id == profileID })
        else { return }
        finished = true
        if let directory { FileBrowserRecents.record(directory, for: profileID) }
        AppPreferences.lastComposeTarget = (profileID, directory)
        Theme.Haptics.tap()
        dismiss(animated: true) { [weak self] in
            guard let self else { return }
            switch self.purpose {
            case .start:
                self.create(on: profile, directory: directory)
            case .choose:
                self.onChoose?(profileID, directory)
            }
        }
    }

    private func create(on profile: ConnectionProfile, directory: String?) {
        Task { [viewModel, onStart] in
            guard let entry = await viewModel.newSession(on: profile, directory: directory) else {
                Theme.Haptics.error()
                return
            }
            Theme.Haptics.success()
            onStart?(entry)
        }
    }

    /// The server's own file tree, pushed inside this sheet rather than replacing it, so browsing
    /// is one of the modal's answers instead of a different screen that forgets what was typed.
    private func pushBrowser(profileID: String) {
        guard
            let backend = viewModel.backend(forProfileID: profileID) as? (any FileBrowsingBackend)
        else { return }
        field.resignFirstResponder()
        sheetPresentationController?.animateChanges {
            sheetPresentationController?.selectedDetentIdentifier = .large
        }
        let browser = FileBrowserViewController(backend: backend, profileID: profileID)
        browser.onSelect = { [weak self] path in
            self?.finish(profileID: profileID, directory: path)
        }
        navigationController?.pushViewController(browser, animated: true)
    }

    private static func servers(from viewModel: SessionListViewModel) -> [NewChatServer] {
        viewModel.servers.map { profile in
            let backend = viewModel.backend(forProfileID: profile.id)
            return NewChatServer(
                profileID: profile.id, name: profile.name, backend: profile.backend,
                address: ServerLabel.address(profile),
                reachable: !viewModel.unreachable.contains(profile.id),
                canBrowse: backend is any FileBrowsingBackend
                    && backend?.capabilities.supportsFileBrowsing == true)
        }
    }

    private static func directories(for servers: [NewChatServer], entries: [SessionEntry])
        -> [String: NewChatDirectories]
    {
        var gathered: [String: NewChatDirectories] = [:]
        for server in servers {
            gathered[server.profileID] = NewChatDirectories.gather(
                profileID: server.profileID, entries: entries)
        }
        return gathered
    }

    private static let leftArrow: UInt32 = 0xFF51
    private static let rightArrow: UInt32 = 0xFF53

    /// The chords the modal takes from the text field. A first-responder field consumes presses
    /// before `pressesBegan` can see them and only a registered `UIKeyCommand` is consulted
    /// first, so every chord the chooser claims while typing is registered here — and nothing
    /// else is, because a plain letter registered here would stop a path being typed at all.
    private static var claimedChords: [(keyval: UInt32, state: UInt32)] {
        var chords: [(UInt32, UInt32)] = [
            (Keymap.up, 0), (Keymap.down, 0), (Keymap.enter, 0), (Keymap.tab, 0),
            (Keymap.tab, KeyChord.shiftMask), (Keymap.escape, 0),
            (leftArrow, KeyChord.controlMask), (rightArrow, KeyChord.controlMask),
        ]
        for letter in "npjkdusb" {
            chords.append((letter.unicodeScalars.first?.value ?? 0, KeyChord.controlMask))
        }
        return chords.map { (keyval: $0.0, state: $0.1) }
    }

    override var keyCommands: [UIKeyCommand]? {
        Self.claimedChords.compactMap {
            Self.keyCommand(
                keyval: $0.keyval, state: $0.state, action: #selector(handleChooserKey(_:)))
        }
    }

    private static func keyCommand(keyval: UInt32, state: UInt32, action: Selector) -> UIKeyCommand?
    {
        var flags: UIKeyModifierFlags = []
        if state & KeyChord.controlMask != 0 { flags.insert(.control) }
        if state & KeyChord.shiftMask != 0 { flags.insert(.shift) }
        if state & KeyChord.altMask != 0 { flags.insert(.alternate) }
        let input: String
        switch keyval {
        case Keymap.enter: input = "\r"
        case Keymap.escape: input = UIKeyCommand.inputEscape
        case Keymap.tab: input = "\t"
        case Keymap.up: input = UIKeyCommand.inputUpArrow
        case Keymap.down: input = UIKeyCommand.inputDownArrow
        case leftArrow: input = UIKeyCommand.inputLeftArrow
        case rightArrow: input = UIKeyCommand.inputRightArrow
        default:
            guard let scalar = Unicode.Scalar(keyval), keyval >= 0x20, keyval < 0xFF00 else {
                return nil
            }
            input = String(Character(scalar))
        }
        let command = UIKeyCommand(
            title: "", action: action, input: input, modifierFlags: flags,
            propertyList: "\(state)|\(keyval)")
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc private func handleChooserKey(_ command: UIKeyCommand) {
        guard let token = command.propertyList as? String else { return }
        let pieces = token.split(separator: "|")
        guard pieces.count == 2, let state = UInt32(pieces[0]), let keyval = UInt32(pieces[1]),
            let chord = KeyChord.canonical(keyval: keyval, state: state)
        else { return }
        _ = handle(chord)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first(where: { $0.key != nil }),
            let chord = UIKeyChords.chord(for: press), handle(chord)
        else {
            super.pressesBegan(presses, with: event)
            return
        }
    }

    /// Translates a press through the shared chooser and lets it answer. A chord the chooser does
    /// not claim belongs to the text field, which is the rule that keeps typing a path from
    /// tripping over the verbs.
    private func handle(_ chord: KeyChord) -> Bool {
        guard let command = NewChatChooser.command(for: chord, mode: chooser.mode) else {
            return false
        }
        let answer = chooser.handle(command)
        syncMode()
        reload()
        apply(answer.outcome)
        return answer.handled
    }

    #if DEBUG
        func tourType(_ text: String) {
            field.text = text
            chooser.type(text)
            syncMode()
            reload()
        }

        func tourLeaveField() {
            _ = chooser.handle(.leaveField)
            _ = chooser.handle(.down)
            syncMode()
            reload()
        }
    #endif
}

extension NewChatViewController: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        guard chooser.mode == .normal else { return }
        _ = chooser.handle(.enterField)
        syncMode()
        reload()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        activate()
        return false
    }
}

extension NewChatViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard chooser.rows.indices.contains(indexPath.item) else { return }
        chooser.focus(indexPath.item)
        reload()
        activate()
    }
}

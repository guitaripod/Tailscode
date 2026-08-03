import TailscodeCore
import UIKit

/// A hardware keyboard resolves through the same `ShortcutSet` as the desktops: `UIPress` is
/// translated into the registry's GDK-numbered `KeyChord` space, the rebinding file is honored,
/// two-key sequences work, and conflicts are reported on the cheatsheet. ⌘ chords are left to
/// the system on purpose, exactly as the Mac leaves them to its menu bar.
enum UIKeyChords {
    static func chord(for press: UIPress) -> KeyChord? {
        guard let key = press.key else { return nil }
        guard !key.modifierFlags.contains(.command) else { return nil }
        var state: UInt32 = 0
        if key.modifierFlags.contains(.control) { state |= KeyChord.controlMask }
        if key.modifierFlags.contains(.shift) { state |= KeyChord.shiftMask }
        if key.modifierFlags.contains(.alternate) { state |= KeyChord.altMask }
        let keyval: UInt32
        switch key.keyCode {
        case .keyboardEscape: keyval = Keymap.escape
        case .keyboardReturnOrEnter, .keypadEnter: keyval = Keymap.enter
        case .keyboardTab: keyval = Keymap.tab
        case .keyboardUpArrow: keyval = Keymap.up
        case .keyboardDownArrow: keyval = Keymap.down
        case .keyboardLeftArrow: keyval = 0xFF51
        case .keyboardRightArrow: keyval = 0xFF53
        case .keyboardDeleteOrBackspace: keyval = Keymap.backspace
        case .keyboardSpacebar: keyval = 0x20
        default:
            guard let scalar = key.charactersIgnoringModifiers.unicodeScalars.first,
                scalar.value >= 0x20
            else { return nil }
            keyval = scalar.value
        }
        return KeyChord.canonical(keyval: keyval, state: state)
    }
}

/// What a screen must answer to take part: which context its keys land in, and what it does
/// about an action. Returning false lets the press fall through to the system untouched.
@MainActor
protocol KeyActionHost: UIViewController {
    var keyContext: KeyContext { get }
    var keyAwaitingApproval: Bool { get }
    func performKeyAction(_ action: KeyAction) -> Bool
}

extension KeyActionHost {
    var keyAwaitingApproval: Bool { false }

    /// The shared entry point every host's `pressesBegan` calls: true when the press was spent
    /// here — as an action or as the first half of a sequence — false when it should continue
    /// up the responder chain.
    func handleKeyPresses(_ presses: Set<UIPress>) -> Bool {
        guard let press = presses.first(where: { $0.key != nil }),
            let chord = UIKeyChords.chord(for: press)
        else { return false }
        return KeyBridge.shared.handle(
            chord, context: keyContext, awaitingApproval: keyAwaitingApproval
        ) { [weak self] action in
            self?.performKeyAction(action) ?? false
        }
    }
}

/// One shortcut set and one pending-sequence state for the whole app, reloadable the same way
/// the desktops reload theirs.
@MainActor
final class KeyBridge {
    static let shared = KeyBridge()

    private(set) var shortcuts = ShortcutSet.load()
    private var pending: [KeyChord] = []

    func reload() {
        shortcuts = ShortcutSet.load()
        pending = []
    }

    func handle(
        _ chord: KeyChord, context: KeyContext, awaitingApproval: Bool,
        perform: (KeyAction) -> Bool
    ) -> Bool {
        switch shortcuts.resolve(
            chord, context: context, pending: pending, awaitingApproval: awaitingApproval)
        {
        case .run(let action):
            pending = []
            return perform(action)
        case .pending(let chords):
            pending = chords
            return true
        case .unbound:
            pending = []
            return false
        }
    }

    /// While a text view is first responder the text system consumes presses before
    /// `pressesBegan` can see them, and only a registered `UIKeyCommand` is consulted first —
    /// so the insert context rides key commands. Plain printable keys are deliberately
    /// excluded: they must keep typing; what remains is the deliberate chords plus Escape.
    func insertKeyCommands(action: Selector) -> [UIKeyCommand] {
        (shortcuts.actions[.insert] ?? [:]).keys.compactMap { token in
            guard !token.contains(",") else { return nil }
            return Self.keyCommand(forToken: token, action: action)
        }
    }

    static func keyCommand(forToken token: String, action: Selector) -> UIKeyCommand? {
        guard let chord = chord(forToken: token) else { return nil }
        var flags: UIKeyModifierFlags = []
        if chord.control { flags.insert(.control) }
        if chord.shift { flags.insert(.shift) }
        if chord.alt { flags.insert(.alternate) }
        let input: String
        switch chord.keyval {
        case Keymap.enter: input = "\r"
        case Keymap.escape: input = UIKeyCommand.inputEscape
        case Keymap.tab: input = "\t"
        case Keymap.up: input = UIKeyCommand.inputUpArrow
        case Keymap.down: input = UIKeyCommand.inputDownArrow
        case 0xFF51: input = UIKeyCommand.inputLeftArrow
        case 0xFF53: input = UIKeyCommand.inputRightArrow
        default:
            guard let scalar = Unicode.Scalar(chord.keyval), chord.keyval >= 0x20,
                chord.keyval < 0xFF00
            else { return nil }
            input = String(Character(scalar))
        }
        if flags.isEmpty, input != UIKeyCommand.inputEscape { return nil }
        let command = UIKeyCommand(
            title: "", action: action, input: input, modifierFlags: flags, propertyList: token)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    static func chord(forToken token: String) -> KeyChord? {
        let pieces = token.split(separator: ":", maxSplits: 1)
        guard pieces.count == 2, let keyval = UInt32(pieces[1]) else { return nil }
        var state: UInt32 = 0
        if pieces[0].contains("c") { state |= KeyChord.controlMask }
        if pieces[0].contains("s") { state |= KeyChord.shiftMask }
        if pieces[0].contains("a") { state |= KeyChord.altMask }
        return KeyChord.canonical(keyval: keyval, state: state)
    }

    /// The actions this platform can mean: panes, zoom and focus cycling belong to windowed
    /// desktops; everything else has an iOS answer somewhere.
    static func handledOnIOS(_ action: KeyAction) -> Bool {
        switch action {
        case .focus, .cycleForward, .cycleBackward, .toggleSidebar, .toggleFiles,
            .toggleTerminal, .zoomIn, .zoomOut, .zoomReset, .splitPane, .closeSplit,
            .focusSplit, .zoomSplit, .equalizeSplits, .exchangeSplit:
            return false
        default:
            return true
        }
    }
}

/// The help overlay, derived from the effective bindings — overrides included — with the config
/// path and any conflicts the rebinding file produced. Reachable from Settings and from `?`.
@MainActor
final class ShortcutCheatsheetViewController: UIViewController {
    private struct Row: Hashable {
        let keys: String
        let what: String
    }

    private enum Section: Hashable {
        case category(String)
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Keyboard shortcuts")
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })

        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        collectionView = UICollectionView(
            frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        configureDataSource()
        applySnapshot()
    }

    private var sections: [(title: String, rows: [Row])] {
        let set = KeyBridge.shared.shortcuts
        var result: [(String, [Row])] = []
        for category in ShortcutCategory.allCases {
            var rows: [Row] = []
            for definition in ShortcutRegistry.all
            where definition.category == category && KeyBridge.handledOnIOS(definition.action) {
                let keys = set.effective[definition.id] ?? []
                guard !keys.isEmpty else { continue }
                rows.append(Row(keys: keys.joined(separator: " / "), what: definition.title))
            }
            if !rows.isEmpty { result.append((category.title, rows)) }
        }
        return result
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Row> {
            cell, _, row in
            var content = UIListContentConfiguration.valueCell()
            content.text = row.what
            content.textProperties.font = .preferredFont(forTextStyle: .body)
            content.secondaryText = row.keys
            content.secondaryTextProperties.font = .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            cell.contentConfiguration = content
        }
        let titles = sections.map(\.title)
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { view, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = indexPath.section < titles.count ? titles[indexPath.section] : nil
            view.contentConfiguration = content
        }
        let sectionCount = sections.count
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { view, _, indexPath in
            var content = UIListContentConfiguration.groupedFooter()
            if indexPath.section == sectionCount - 1 {
                let issues = KeyBridge.shared.shortcuts.issues
                var lines = [
                    String(
                        localized:
                            "Rebind any of these by id in keybindings.json — in this app's folder in Files."
                    )
                ]
                if !issues.isEmpty { lines.append(issues.joined(separator: " · ")) }
                content.text = lines.joined(separator: "\n")
            }
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: row)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(
                    using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(
                    using: footer, for: indexPath)
        }
    }

    private func applySnapshot() {
        ShortcutSet.ensureConfigFile()
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        for section in sections {
            snapshot.appendSections([.category(section.title)])
            snapshot.appendItems(section.rows, toSection: .category(section.title))
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    static func present(from presenter: UIViewController) {
        let nav = UINavigationController(rootViewController: ShortcutCheatsheetViewController())
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large(), .medium()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(nav, animated: true)
    }
}

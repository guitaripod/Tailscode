import CodingAgentKit
import TailscodeCore
import UIKit

/// Which chats the list column is showing, as the side of the window names it.
enum SidebarScope: Hashable {
    case all, live, saved, archived
    case server(String)
}

/// A place that fills the conversation column, or opens over the window, rather than choosing
/// what the list shows.
enum SidebarPlace: Hashable {
    case home, usage, delegate, video, images
}

/// Everything the chat list knows that the side of the window shows beside it, taken from the one
/// listing the list already holds so the sidebar never asks a server a question of its own.
struct ChatListDigest: Equatable {
    struct Server: Equatable {
        let id: String
        let name: String
        let backend: AgentType
        let live: Int
        let unreachable: Bool
    }

    struct Pinned: Equatable {
        let key: String
        let title: String
        let backend: AgentType
        let activity: ActivityKind?
        let unread: Bool
    }

    var servers: [Server] = []
    var live = 0
    var archived = 0
    var pinned: [Pinned] = []
}

/// What the sidebar draws: the listing's digest, and what the two columns beside it are holding.
struct SidebarReading: Equatable {
    var digest = ChatListDigest()
    var scope: SidebarScope?
    var place: SidebarPlace?
    var openChat: String?
}

/// The side of the iPad's window. Two kinds of row live here and they are drawn differently on
/// purpose: a row that chooses what the list shows — every chat, the live ones, one server, the
/// saved or archived ones — holds the selection, and a place that opens beside the list — Home,
/// usage, a delegate board — is marked in the accent while it is the thing on screen. The two
/// facts are true at once, so they never share one highlight.
@MainActor
final class SidebarViewController: UIViewController {
    weak var owner: WorkspaceSplitViewController?

    private enum Section: Hashable, CaseIterable {
        case places, chats, servers, pinned
    }

    private enum Item: Hashable {
        case header(Section)
        case place(SidebarPlace)
        case scope(SidebarScope)
        case pinned(String)
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var reading = SidebarReading()
    private var applied: SidebarReading?
    private let updateChip = UpdateChipButton()
    private static let collapsedKey = "tailscode.sidebar.collapsed"

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Tailscode"
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = .clear
        updateChip.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                Theme.Haptics.tap()
                UpdateCenterViewController.present(from: self)
            }, for: .touchUpInside)
        configureCollectionView()
        configureDataSource()
        configureBars()
        observe()
        apply(force: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: false)
    }

    /// Takes a new reading of the columns and the listing. Rows are reconfigured only when what
    /// they draw changed, so a listing that ticks every few seconds costs the sidebar nothing.
    func render(_ next: SidebarReading) {
        reading = next
        apply()
    }

    private func observe() {
        let center = NotificationCenter.default
        for name: Notification.Name in [
            SavedChatStore.didChange, ForgeRunner.didChange, ImageStudio.didChange,
            ImageGenStore.didChange, ForgeStore.didChange,
        ] {
            center.addObserver(self, selector: #selector(storesDidChange), name: name, object: nil)
        }
        center.addObserver(
            self, selector: #selector(updatesDidChange), name: UpdateMonitor.didChange, object: nil)
    }

    @objc private func storesDidChange() { apply(force: true) }

    @objc private func updatesDidChange() { configureBars() }

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .sidebar)
            config.showsSeparators = false
            let section = self?.dataSource?.sectionIdentifier(for: index)
            config.headerMode = section == .places || section == nil ? .none : .firstItemInSection
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.selectionFollowsFocus = true
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let header = UICollectionView.CellRegistration<UICollectionViewListCell, Section> {
            cell, _, section in
            var content = UIListContentConfiguration.header()
            content.text = Self.title(of: section)
            cell.contentConfiguration = content
            cell.accessories = [.outlineDisclosure(options: .init(style: .header))]
        }
        let row = UICollectionView.CellRegistration<UICollectionViewListCell, Item> {
            [weak self] cell, _, item in
            self?.configure(cell, for: item)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            if case .header(let section) = item {
                return collectionView.dequeueConfiguredReusableCell(
                    using: header, for: indexPath, item: section)
            }
            return collectionView.dequeueConfiguredReusableCell(
                using: row, for: indexPath, item: item)
        }
        dataSource.sectionSnapshotHandlers.willExpandItem = { item in
            guard case .header(let section) = item else { return }
            Self.setCollapsed(section, false)
        }
        dataSource.sectionSnapshotHandlers.willCollapseItem = { item in
            guard case .header(let section) = item else { return }
            Self.setCollapsed(section, true)
        }
    }

    /// The search field lives on the chat list, so the magnifier here brings the list out and
    /// puts the keyboard in it. New Chat and Settings sit at the foot, where a floating sidebar
    /// keeps its controls; the update mark joins them only while there is something to say.
    private func configureBars() {
        let search = UIBarButtonItem(
            image: UIImage(systemName: "magnifyingglass"),
            primaryAction: UIAction { [weak self] _ in self?.owner?.beginSearch() })
        search.accessibilityLabel = String(localized: "Search chats")
        navigationItem.rightBarButtonItem = search

        let newChat = UIBarButtonItem(
            title: String(localized: "New Chat"), image: nil,
            primaryAction: UIAction { [weak self] _ in self?.owner?.startNewChat() }, menu: nil)
        newChat.accessibilityLabel = String(localized: "New chat")
        if #available(iOS 26, *) {
            newChat.style = .prominent
        } else {
            newChat.style = .done
        }
        let settings = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            primaryAction: UIAction { [weak self] _ in self?.owner?.openSettings() })
        settings.accessibilityLabel = String(localized: "Settings")
        var items: [UIBarButtonItem] = [newChat, .flexibleSpace()]
        if let chip = UpdateLedger.rollup().chip {
            updateChip.apply(chip)
            let item = UIBarButtonItem(customView: updateChip)
            if #available(iOS 26, *) { item.hidesSharedBackground = true }
            items.append(item)
        }
        items.append(settings)
        toolbarItems = items
    }

    private func apply(force: Bool = false) {
        guard let dataSource else { return }
        guard force || applied != reading else { return }
        let animated = applied != nil
        applied = reading
        let structure = sectionItems()
        if dataSource.snapshot().sectionIdentifiers != structure.map(\.0) {
            var sections = NSDiffableDataSourceSnapshot<Section, Item>()
            sections.appendSections(structure.map(\.0))
            dataSource.apply(sections, animatingDifferences: false)
        }
        for (section, items) in structure {
            var wanted = NSDiffableDataSourceSectionSnapshot<Item>()
            if section == .places {
                wanted.append(items)
            } else {
                let header = Item.header(section)
                wanted.append([header])
                wanted.append(items, to: header)
                if Self.isCollapsed(section) {
                    wanted.collapse([header])
                } else {
                    wanted.expand([header])
                }
            }
            let current = dataSource.snapshot(for: section)
            guard current.items != wanted.items || current.visibleItems != wanted.visibleItems
            else { continue }
            dataSource.apply(wanted, to: section, animatingDifferences: animated)
        }
        var snapshot = dataSource.snapshot()
        let rows = snapshot.itemIdentifiers.filter {
            if case .header = $0 { return false }
            return true
        }
        snapshot.reconfigureItems(rows)
        dataSource.apply(snapshot, animatingDifferences: false)
        syncSelection()
    }

    private func sectionItems() -> [(Section, [Item])] {
        var places: [Item] = [.place(.home), .place(.usage), .place(.delegate), .place(.video)]
        if ImageGenDoor.current().isOpen { places.append(.place(.images)) }
        var result: [(Section, [Item])] = [(.places, places)]
        var chats: [Item] = [.scope(.all), .scope(.live), .scope(.saved)]
        if reading.digest.archived > 0 || reading.scope == .archived {
            chats.append(.scope(.archived))
        }
        result.append((.chats, chats))
        if !reading.digest.servers.isEmpty {
            result.append((.servers, reading.digest.servers.map { .scope(.server($0.id)) }))
        }
        if !reading.digest.pinned.isEmpty {
            result.append((.pinned, reading.digest.pinned.map { .pinned($0.key) }))
        }
        return result
    }

    /// The selection is the list's scope and nothing else. It is set from the reading, not kept,
    /// so a scope chosen anywhere else — a Home card, the keyboard, the phone's stack before the
    /// window widened — is the one this side of the window shows.
    private func syncSelection() {
        let wanted = reading.scope.flatMap { dataSource.indexPath(for: .scope($0)) }
        for indexPath in collectionView.indexPathsForSelectedItems ?? [] where indexPath != wanted {
            collectionView.deselectItem(at: indexPath, animated: false)
        }
        if let wanted, collectionView.indexPathsForSelectedItems?.contains(wanted) != true {
            collectionView.selectItem(at: wanted, animated: false, scrollPosition: [])
        }
    }

    private func configure(_ cell: UICollectionViewListCell, for item: Item) {
        var content = UIListContentConfiguration.cell()
        var accessories: [UICellAccessory] = []
        content.textProperties.numberOfLines = 1
        content.textProperties.font = Theme.Ramp.font(.rowTitle)
        switch item {
        case .header:
            return
        case .place(let place):
            content.text = Self.title(of: place)
            content.image = UIImage(systemName: Self.symbol(of: place))
            if reading.place == place {
                content.textProperties.font = Theme.Ramp.font(.rowTitleStrong)
                content.textProperties.color = Theme.Color.accent
                content.imageProperties.tintColor = Theme.Color.accent
            }
            if Self.isBusy(place) { accessories.append(.working(spoken: Self.busyWords(of: place))) }
        case .scope(let scope):
            content.text = title(of: scope)
            content.image = image(of: scope)
            accessories += scopeAccessories(scope)
        case .pinned(let key):
            guard let pinned = reading.digest.pinned.first(where: { $0.key == key }) else { break }
            content.text = SessionListViewController.displayTitle(pinned.title)
            content.image = UIImage(systemName: pinned.backend.symbolName)?
                .withTintColor(pinned.backend.brandColor, renderingMode: .alwaysOriginal)
            if pinned.unread { content.textProperties.font = Theme.Ramp.font(.rowTitleStrong) }
            if reading.openChat == key {
                content.textProperties.font = Theme.Ramp.font(.rowTitleStrong)
                content.textProperties.color = Theme.Color.accent
            }
            if let activity = pinned.activity {
                let badge = ActivityBadgeView(pointSize: 11)
                badge.activity = activity
                accessories.append(
                    .customView(
                        configuration: .init(
                            customView: badge, placement: .trailing(displayed: .always),
                            maintainsFixedSize: true)))
            }
        }
        content.imageProperties.maximumSize = CGSize(width: 22, height: 22)
        content.imageProperties.reservedLayoutSize = CGSize(width: 24, height: 22)
        cell.contentConfiguration = content
        cell.accessories = accessories
        cell.answersPointer(cornerRadius: Theme.Radius.control)
    }

    private func scopeAccessories(_ scope: SidebarScope) -> [UICellAccessory] {
        switch scope {
        case .live:
            return reading.digest.live > 0 ? Self.liveCount(reading.digest.live) : []
        case .saved:
            let saved = SavedChatStore.all().count
            return saved > 0 ? [Self.count(saved)] : []
        case .server(let id):
            guard let server = reading.digest.servers.first(where: { $0.id == id }) else { return [] }
            if server.unreachable {
                let mark = UIImageView(image: UIImage(systemName: "wifi.slash"))
                mark.tintColor = Theme.Color.tertiaryLabel
                mark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
                mark.accessibilityLabel = String(localized: "Server unreachable")
                mark.isAccessibilityElement = true
                return [
                    .customView(
                        configuration: .init(
                            customView: mark, placement: .trailing(displayed: .always)))
                ]
            }
            return server.live > 0 ? Self.liveCount(server.live) : []
        case .all, .archived:
            return []
        }
    }

    private static func liveCount(_ count: Int) -> [UICellAccessory] {
        let badge = ActivityBadgeView(pointSize: 10)
        badge.activity = .working
        return [
            .customView(
                configuration: .init(
                    customView: badge, placement: .trailing(displayed: .always),
                    maintainsFixedSize: true)),
            .label(
                text: "\(count)", displayed: .always,
                options: .init(tintColor: Theme.Color.success, font: Theme.Ramp.font(.rowMeta))),
        ]
    }

    private static func count(_ count: Int) -> UICellAccessory {
        .label(
            text: "\(count)", displayed: .always,
            options: .init(tintColor: Theme.Color.tertiaryLabel, font: Theme.Ramp.font(.rowMeta)))
    }

    private func title(of scope: SidebarScope) -> String {
        switch scope {
        case .all: return String(localized: "All Chats")
        case .live: return String(localized: "Live Now")
        case .saved: return String(localized: "Saved")
        case .archived: return String(localized: "Archived")
        case .server(let id):
            return reading.digest.servers.first { $0.id == id }?.name ?? id
        }
    }

    private func image(of scope: SidebarScope) -> UIImage? {
        switch scope {
        case .all: return UIImage(systemName: "bubble.left.and.bubble.right")
        case .live: return UIImage(systemName: "dot.radiowaves.left.and.right")
        case .saved: return UIImage(systemName: "bookmark")
        case .archived: return UIImage(systemName: "archivebox")
        case .server(let id):
            guard let server = reading.digest.servers.first(where: { $0.id == id }) else {
                return UIImage(systemName: "server.rack")
            }
            return UIImage(systemName: server.backend.symbolName)?
                .withTintColor(server.backend.brandColor, renderingMode: .alwaysOriginal)
        }
    }

    private static func title(of section: Section) -> String {
        switch section {
        case .places: return ""
        case .chats: return String(localized: "Chats")
        case .servers: return String(localized: "Servers")
        case .pinned: return String(localized: "Pinned")
        }
    }

    private static func title(of place: SidebarPlace) -> String {
        switch place {
        case .home: return String(localized: "Home")
        case .usage: return String(localized: "Usage")
        case .delegate: return DelegateEntryPoint.title
        case .video: return String(localized: "Video")
        case .images: return String(localized: "Images")
        }
    }

    private static func symbol(of place: SidebarPlace) -> String {
        switch place {
        case .home: return "house"
        case .usage: return "gauge.with.dots.needle.33percent"
        case .delegate: return DelegateEntryPoint.symbol
        case .video: return "film"
        case .images: return "photo.on.rectangle"
        }
    }

    private static func isBusy(_ place: SidebarPlace) -> Bool {
        switch place {
        case .video: return ForgeRunner.shared.isRendering
        case .images: return ImageStudio.shared.isPainting
        default: return false
        }
    }

    private static func busyWords(of place: SidebarPlace) -> String {
        place == .video
            ? String(localized: "A video is rendering") : String(localized: "A picture is being made")
    }

    private static func isCollapsed(_ section: Section) -> Bool {
        (UserDefaults.standard.stringArray(forKey: collapsedKey) ?? []).contains("\(section)")
    }

    private static func setCollapsed(_ section: Section, _ collapsed: Bool) {
        var names = Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])
        if collapsed { names.insert("\(section)") } else { names.remove("\(section)") }
        UserDefaults.standard.set(Array(names).sorted(), forKey: collapsedKey)
    }

    private func perform(_ place: SidebarPlace, from indexPath: IndexPath) {
        guard let workspace = owner else { return }
        Theme.Haptics.selection()
        switch place {
        case .home: workspace.showHome()
        case .usage: workspace.show(place: UsageViewController())
        case .video: workspace.home.presentVideo()
        case .images: workspace.home.presentImage()
        case .delegate: openDelegate(from: indexPath)
        }
    }

    /// One machine opens its board outright; several are asked about first, from the row that
    /// asked, exactly as Home's own delegate button asks.
    private func openDelegate(from indexPath: IndexPath) {
        guard let workspace = owner else { return }
        let servers = ConnectionController.shared.profiles
        guard servers.count > 1 else {
            guard let profile = servers.first else { return }
            workspace.showHome(animated: false)
            DelegateGate.open(from: workspace.home, profile: profile)
            return
        }
        let sheet = UIAlertController(
            title: DelegateEntryPoint.menuTitle, message: nil, preferredStyle: .actionSheet)
        for profile in servers {
            sheet.addAction(
                UIAlertAction(title: profile.name, style: .default) { [weak workspace] _ in
                    guard let workspace else { return }
                    workspace.showHome(animated: false)
                    DelegateGate.open(from: workspace.home, profile: profile)
                })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        if let cell = collectionView.cellForItem(at: indexPath) {
            sheet.popoverPresentationController?.sourceView = cell
            sheet.popoverPresentationController?.sourceRect = cell.bounds
        } else {
            sheet.popoverPresentationController?.sourceView = collectionView
            sheet.popoverPresentationController?.sourceRect = CGRect(
                origin: CGPoint(x: collectionView.bounds.midX, y: collectionView.bounds.midY),
                size: .zero)
        }
        present(sheet, animated: true)
    }

    private func choose(_ scope: SidebarScope) {
        guard let workspace = owner else { return }
        switch scope {
        case .all: workspace.showChats(.all)
        case .live: workspace.showChats(.live)
        case .server(let id): workspace.showChats(.profile(id))
        case .saved: workspace.showSaved()
        case .archived: workspace.showArchived()
        }
    }
}

extension SidebarViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath)
        -> Bool
    {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return false }
        switch item {
        case .scope, .header:
            return true
        case .place(let place):
            perform(place, from: indexPath)
            return false
        case .pinned(let key):
            Theme.Haptics.selection()
            owner?.chatList.open(key: key)
            return false
        }
    }

    /// A header row expands and collapses itself — its disclosure is the header style, which
    /// takes the whole row — so selecting one only has to give the selection back to the scope.
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard case .scope(let scope) = dataSource.itemIdentifier(for: indexPath) else {
            collectionView.deselectItem(at: indexPath, animated: false)
            syncSelection()
            return
        }
        guard scope != reading.scope else { return }
        Theme.Haptics.selection()
        choose(scope)
    }

    func collectionView(
        _ collectionView: UICollectionView, selectionFollowsFocusForItemAt indexPath: IndexPath
    ) -> Bool {
        guard case .scope = dataSource.itemIdentifier(for: indexPath) else { return false }
        return true
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
            case .scope(.server(let id)) = dataSource.itemIdentifier(for: indexPath),
            let profile = ConnectionController.shared.profiles.first(where: { $0.id == id })
        else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [weak self] _ in
            UIMenu(children: [
                UIAction(
                    title: String(localized: "New chat here"),
                    image: UIImage(systemName: "square.and.pencil")
                ) { _ in
                    guard let workspace = self?.owner else { return }
                    workspace.showHome()
                    workspace.home.aimCompose(at: profile.id)
                },
                UIAction(
                    title: DelegateEntryPoint.menuTitle,
                    image: UIImage(systemName: DelegateEntryPoint.symbol)
                ) { _ in
                    guard let workspace = self?.owner else { return }
                    workspace.showHome(animated: false)
                    DelegateGate.open(from: workspace.home, profile: profile)
                },
            ])
        }
    }
}

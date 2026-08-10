import SafariServices
import TailscodeCore
import UIKit

/// The one press, performed. Shared by the Update Center and a server's own screen so a promise
/// printed in two places cannot be kept two different ways — and so the sentence a reader was
/// shown before pressing is the sentence the press honours.
@MainActor
enum UpdatePress {
    static func perform(_ reading: UpdateReading, from presenter: UIViewController) {
        guard let invitation = reading.invitation else { return }
        switch invitation {
        case .installHere:
            confirmInstall(reading, from: presenter)
        case .openStore(let url):
            Theme.Haptics.tap()
            open(url)
        case .copyCommand(let command):
            copy(command, from: presenter)
        case .openPage(let url):
            Theme.Haptics.tap()
            guard let link = URL(string: url), link.scheme?.hasPrefix("http") == true else {
                open(url)
                return
            }
            presenter.present(SFSafariViewController(url: link), animated: true)
        case .recheck:
            Theme.Haptics.tap()
            Task { await UpdateMonitor.check(reading.component, force: true) }
        }
    }

    /// The changes an update would bring, before it is taken: an update restarts the server, and a
    /// person is entitled to know what they are restarting it for.
    private static func confirmInstall(_ reading: UpdateReading, from presenter: UIViewController) {
        let changes = (reading.verdict.offer?.changes ?? []).prefix(8)
            .map { "• \($0)" }.joined(separator: "\n")
        let alert = UIAlertController(
            title: String(localized: "Update \(reading.title)?"),
            message: changes.isEmpty
                ? String(
                    localized:
                        "The server pulls the new code, rebuilds it, and restarts. It stops answering for a moment while it does."
                )
                : String(
                    localized:
                        "\(changes)\n\nThe server rebuilds and restarts, so it stops answering for a moment."
                ),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Update"), style: .default) { _ in
                Theme.Haptics.tap()
                Task { await UpdateMonitor.update(reading.component) }
            })
        presenter.present(alert, animated: true)
    }

    private static func copy(_ command: String, from presenter: UIViewController) {
        UIPasteboard.general.string = command
        Theme.Haptics.success()
        let alert = UIAlertController(
            title: String(localized: "Copied"),
            message: String(
                localized:
                    "Run it on the machine that server runs on. It updates in place and keeps your password."
            ),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        presenter.present(alert, animated: true)
    }

    private static func open(_ url: String) {
        guard let link = URL(string: url) else { return }
        UIApplication.shared.open(link)
    }
}

/// Every machine in the picture, and what it is running.
///
/// One section per machine — this app and each configured server — because the question a person
/// actually has is "is anything here out of date", and answering it one screen at a time hides the
/// server that is three months behind. Every number arrives with the name of whoever said it and
/// the moment it was read; nothing here invents a word, and nothing here decides what a verdict
/// means. The rows are Core's sentences arranged by a phone.
///
/// Nothing dismisses. "Not now" records this exact offer against this exact machine, which stops
/// the standing mark and collapses the card explaining it — and expires by itself the moment a
/// newer release, a different obstacle or an obstacle that cleared gives the person something new
/// to decide.
@MainActor
final class UpdateCenterViewController: UIViewController {
    static func present(from presenter: UIViewController) {
        let center = UpdateCenterViewController()
        guard let nav = presenter.navigationController else {
            presenter.present(UINavigationController(rootViewController: center), animated: true)
            return
        }
        nav.pushViewController(center, animated: true)
    }

    private enum Section: Hashable {
        case everything
        case component(String)
    }

    private enum Item: Hashable {
        case verdict(String)
        case installed(String)
        case available(String)
        case change(String, Int)
        case log(String)
        case invitation(String)
        case notNow(String)
        case updateEverything
    }

    /// Enough of an update's subjects to judge whether to take it; the rest is a changelog, and a
    /// changelog is not what this screen is for.
    private static let changeLimit = 6

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var rollup = UpdateLedger.rollup()
    private let refresher = UIRefreshControl()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Updates")
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            primaryAction: UIAction { [weak self] _ in self?.recheck() })
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "Check again")
        configure()
        applySnapshot()
        NotificationCenter.default.addObserver(
            self, selector: #selector(ledgerChanged), name: UpdateLedger.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sweepChanged), name: UpdateMonitor.didChange, object: nil)
        Task { await UpdateMonitor.checkAll() }
    }

    private func configure() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        config.backgroundColor = .clear
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.refreshControl = refresher
        refresher.addAction(UIAction { [weak self] _ in self?.recheck() }, for: .valueChanged)
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> {
            [weak self] cell, _, item in
            self?.configure(cell, item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self, let section = self.section(at: indexPath),
                case .component(let key) = section, let reading = self.reading(key)
            else {
                view.contentConfiguration = nil
                return
            }
            var content = UIListContentConfiguration.header()
            content.text = reading.title
            content.secondaryText = reading.subtitle
            content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self, let text = self.footerText(at: indexPath) else {
                view.contentConfiguration = nil
                return
            }
            var content = UIListContentConfiguration.footer()
            content.text = text
            view.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            let registration = kind == UICollectionView.elementKindSectionFooter ? footer : header
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: registration, for: indexPath)
        }
    }

    private func section(at indexPath: IndexPath) -> Section? {
        dataSource.snapshot().sectionIdentifiers[safe: indexPath.section]
    }

    private func reading(_ key: String) -> UpdateReading? {
        rollup.readings.first { $0.id == key }
    }

    /// The last section carries the provenance disclaimer, because it is a fact about every number
    /// above it and repeating it under each one would train the reader to skip it.
    private func footerText(at indexPath: IndexPath) -> String? {
        let sections = dataSource.snapshot().sectionIdentifiers
        guard indexPath.section == sections.count - 1 else { return nil }
        return String(
            localized:
                "Every version above is shown with who reported it and when. A machine that could not be reached, or that is too old to answer, says so rather than reading as up to date."
        )
    }

    private func configure(_ cell: UICollectionViewListCell, _ item: Item) {
        var content = cell.defaultContentConfiguration()
        cell.accessories = []
        switch item {
        case .verdict(let key):
            guard let reading = reading(key) else { break }
            content.text = reading.headline
            content.secondaryText = reading.detail()
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.font = Theme.Ramp.font(.panelDetail)
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(
                systemName: reading.icon.symbol,
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .body))
            content.imageProperties.tintColor = reading.tone.color
            cell.accessibilityLabel = reading.accessibilityLine()
            if reading.verdict.isBusy { cell.accessories = [spinner()] }
        case .installed(let key):
            guard let reading = reading(key) else { break }
            content.text = String(localized: "Installed")
            content.secondaryText = reading.installed.line
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.textProperties.font = Theme.Ramp.font(.panelLabel)
        case .available(let key):
            guard let reading = reading(key) else { break }
            content.text = String(localized: "Available")
            content.secondaryText = reading.available.line
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.textProperties.font = Theme.Ramp.font(.panelLabel)
        case .change(let key, let index):
            guard let change = reading(key)?.verdict.offer?.changes[safe: index] else { break }
            content.text = change
            content.textProperties.numberOfLines = 2
            content.textProperties.font = Theme.Ramp.font(.panelDetail)
            content.textProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(
                systemName: "circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 5, weight: .bold))
            content.imageProperties.tintColor = Theme.Color.tertiaryLabel
        case .log:
            content.text = String(localized: "Show what it printed")
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "text.alignleft")
            content.imageProperties.tintColor = Theme.Color.accent
            cell.accessories = [.disclosureIndicator()]
        case .invitation(let key):
            guard let invitation = reading(key)?.invitation else { break }
            content.text = invitation.label
            content.textProperties.color = Theme.Color.accent
            if let promise = invitation.promise {
                content.secondaryText = promise
                content.secondaryTextProperties.numberOfLines = 0
                content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            }
            content.image = UIImage(systemName: Self.symbol(for: invitation))
            content.imageProperties.tintColor = Theme.Color.accent
        case .notNow:
            content.text = String(localized: "Not now")
            content.secondaryText = String(
                localized:
                    "Keeps the row and stops the mark, until this offer changes into a different one."
            )
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "clock.arrow.circlepath")
            content.imageProperties.tintColor = Theme.Color.secondaryLabel
        case .updateEverything:
            content.text = String(localized: "Update everything")
            content.secondaryText = String(
                localized:
                    "\(rollup.installableServers.count) servers, one at a time — each rebuilds and restarts before the next starts."
            )
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "arrow.down.circle.fill")
            content.imageProperties.tintColor = Theme.Color.accent
            if UpdateMonitor.isUpdatingEverything { cell.accessories = [spinner()] }
        }
        cell.contentConfiguration = content
    }

    private static func symbol(for invitation: UpdateInvitation) -> String {
        switch invitation {
        case .installHere: return "arrow.down.circle"
        case .openStore: return "arrow.up.forward.app"
        case .copyCommand: return "doc.on.doc"
        case .openPage: return "safari"
        case .recheck: return "arrow.clockwise"
        }
    }

    private func spinner() -> UICellAccessory {
        let view = UIActivityIndicatorView(style: .medium)
        view.startAnimating()
        return .customView(configuration: .init(customView: view, placement: .trailing()))
    }

    /// What one machine is worth saying about it, in the order a person reads it: the verdict, the
    /// numbers it rests on, what an update would bring, and only then the press. An acknowledged
    /// offer keeps its verdict and its numbers and loses the card — the row never disappears.
    private func items(for reading: UpdateReading) -> [Item] {
        let key = reading.id
        var items: [Item] = [.verdict(key)]
        if reading.installed.isKnown { items.append(.installed(key)) }
        if reading.available.isKnown { items.append(.available(key)) }
        let collapsed = rollup.isAcknowledged(reading)
        if !collapsed, let offer = reading.verdict.offer {
            let count = min(Self.changeLimit, offer.changes.count)
            items += (0..<count).map { Item.change(key, $0) }
        }
        if reading.log != nil, case .failed = reading.verdict { items.append(.log(key)) }
        if !collapsed, reading.invitation != nil { items.append(.invitation(key)) }
        if !collapsed, reading.stands() { items.append(.notNow(key)) }
        return items
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if rollup.canUpdateEverything {
            snapshot.appendSections([.everything])
            snapshot.appendItems([.updateEverything], toSection: .everything)
        }
        for reading in rollup.readings {
            let section = Section.component(reading.id)
            snapshot.appendSections([section])
            snapshot.appendItems(items(for: reading), toSection: section)
        }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let carried = snapshot.itemIdentifiers.filter { existing.contains($0) }
        if !carried.isEmpty { snapshot.reconfigureItems(carried) }
        dataSource.apply(snapshot, animatingDifferences: false)
        updateEmptyState(itemCount: snapshot.numberOfItems)
    }

    private func updateEmptyState(itemCount: Int) {
        guard itemCount == 0 else {
            contentUnavailableConfiguration = nil
            return
        }
        guard !UpdateMonitor.isChecking else {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
            return
        }
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "questionmark.circle")
        config.text = String(localized: "Nothing has answered yet")
        config.secondaryText = String(
            localized: "Pull down to ask this app and every server what they are running.")
        contentUnavailableConfiguration = config
    }

    @objc private func ledgerChanged() {
        rollup = UpdateLedger.rollup()
        applySnapshot()
    }

    @objc private func sweepChanged() {
        if refresher.isRefreshing, !UpdateMonitor.isChecking { refresher.endRefreshing() }
        rollup = UpdateLedger.rollup()
        applySnapshot()
    }

    private func recheck() {
        Theme.Haptics.tap()
        Task { [weak self] in
            await UpdateMonitor.checkAll(force: true)
            self?.refresher.endRefreshing()
        }
    }

    private func showLog(_ reading: UpdateReading) {
        let alert = UIAlertController(
            title: String(localized: "Update failed"),
            message: reading.log ?? reading.detail(), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Copy"), style: .default) { _ in
                UIPasteboard.general.string = reading.log
                Theme.Haptics.tap()
            })
        present(alert, animated: true)
    }
}

extension UpdateCenterViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .invitation(let key):
            guard let reading = reading(key) else { return }
            UpdatePress.perform(reading, from: self)
        case .notNow(let key):
            guard let reading = reading(key) else { return }
            Theme.Haptics.selection()
            UpdateLedger.acknowledge(reading)
        case .log(let key):
            guard let reading = reading(key) else { return }
            showLog(reading)
        case .updateEverything:
            Theme.Haptics.tap()
            Task { await UpdateMonitor.updateEverything() }
        default:
            break
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1 else { return nil }
        let text: String?
        switch dataSource.itemIdentifier(for: indexPaths[0]) {
        case .installed(let key): text = reading(key)?.installed.line
        case .available(let key): text = reading(key)?.available.line
        case .verdict(let key): text = reading(key)?.accessibilityLine()
        default: text = nil
        }
        guard let text else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(
                    title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = text
                    Theme.Haptics.tap()
                }
            ])
        }
    }
}

/// The gear, wearing the one mark the app owes its reader.
///
/// The mark is chrome: it sits in the corner of a button that already existed, covers nothing, and
/// there is no gesture that puts it out — it goes out when the fact it stands for stops being
/// true, or when the person sets that exact offer aside inside the Update Center.
///
/// It holds perfectly still while an update merely *exists*, because a settled fact that pulses
/// reads as work in progress and teaches a reader to ignore it. Only a machine actually being
/// replaced earns motion, and it gets the one motion the vocabulary gives that state: a sweep,
/// drawn as an arc turning on the display's own clock so it is in time with every other badge on
/// screen.
@MainActor
final class UpdateMarkButton: UIButton {
    private let mark = CAShapeLayer()
    private var link: CADisplayLink?
    private var declared: ActivityMotion = .still
    private var tone: ActivityTone = .quiet

    /// What the mark is allowed to do here and now. Reduce Motion is read at the moment of asking
    /// rather than folded into the stored value, or the mark would stay still forever after the
    /// setting was switched back off.
    private var motion: ActivityMotion {
        declared.honoring(reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    private static let diameter: CGFloat = 9
    private static let side: CGFloat = 34

    init() {
        super.init(frame: .zero)
        setImage(
            UIImage(
                systemName: "gearshape",
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)), for: .normal)
        mark.isHidden = true
        mark.fillColor = UIColor.clear.cgColor
        layer.addSublayer(mark)
        accessibilityLabel = String(localized: "Settings")
        NotificationCenter.default.addObserver(
            self, selector: #selector(reapply),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: UpdateMarkButton, _) in view.reapply()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.side, height: Self.side)
    }

    func apply(_ rollup: UpdateRollup) {
        accessibilityValue = rollup.showsMark ? rollup.headline : nil
        mark.isHidden = !rollup.showsMark
        tone = rollup.tone
        declared = rollup.motion
        reapply()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stop() : reapply()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = Self.diameter
        let frame = CGRect(
            x: bounds.maxX - size - 3, y: bounds.minY + 3, width: size, height: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.frame = frame
        mark.path = path(in: CGRect(origin: .zero, size: frame.size))
        CATransaction.commit()
    }

    /// A filled dot when nothing is moving, and an open arc when something is: the arc is what a
    /// sweep looks like at nine points, and a full circle turning would be indistinguishable from
    /// a still one.
    private func path(in rect: CGRect) -> CGPath {
        let inset = rect.insetBy(dx: 1, dy: 1)
        guard motion.isAnimated else { return UIBezierPath(ovalIn: rect).cgPath }
        return UIBezierPath(
            arcCenter: CGPoint(x: inset.midX, y: inset.midY), radius: inset.width / 2,
            startAngle: 0, endAngle: .pi * 1.5, clockwise: true
        ).cgPath
    }

    @objc private func reapply() {
        let moving = motion.isAnimated
        let ink = tone.color.resolvedColor(with: traitCollection).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.strokeColor = ink
        mark.fillColor = moving ? UIColor.clear.cgColor : ink
        mark.lineWidth = moving ? 2 : 0
        mark.transform = CATransform3DIdentity
        CATransaction.commit()
        setNeedsLayout()
        moving && !mark.isHidden ? start() : stop()
    }

    private func start() {
        guard link == nil, window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.transform = CATransform3DMakeRotation(motion.rotation(at: link.timestamp), 0, 0, 1)
        CATransaction.commit()
    }
}

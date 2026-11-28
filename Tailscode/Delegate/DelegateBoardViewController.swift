import CodingAgentKit
import CodingAgentKitApple
import MidgarCore
import TailscodeCore
import UIKit

/// One machine's dispatcher as a screen: New packet first, the ladder it holds as one row of joined
/// rungs with what the table suggests under it, and every run it remembers grouped by what it asks
/// of the reader. Every word is `DelegateBoard`'s; this controller draws rows and forwards taps.
@MainActor
final class DelegateBoardViewController: UIViewController {
    /// The machine a rehearsal was opened in place of, which the price leads on to.
    struct Unlock {
        let host: String
        let serverName: String
    }

    private enum Section: Hashable {
        case rehearsal
        case practice
        case unlock
        case top
        case setup
        case ladder
        case runs(DelegateRunSection.Kind)
    }

    private enum Item: Hashable {
        case compose
        case status
        case password
        case point(Int)
        case practice
        case unlock
        case setupAsk
        case setupRehearse
        case setupLead
        case setup(String)
        case ladder
        case hint(Int)
        case run(String)
        case empty
    }

    private let host: String
    private let serverName: String
    private let desk = DelegateGate.desk
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var board: DelegateBoard { desk.board(host: host, serverName: serverName) }
    private var reach: DelegateReach { desk.reach[host] ?? .unknown }
    private var copiedStep: String?
    private var sections: [DelegateRunSection] = []
    private let ladderView = DelegateBoardLadderView()
    private lazy var composeView = makeComposeView()
    private let composeNote = UILabel()
    private let unlocks: Unlock?
    var isRehearsal: Bool { unlocks != nil }
    private var practicing = false
    private let practiceButton = PrimaryButton(title: DelegateRehearsal.practiceTitle)
    private lazy var practiceView = makePracticeView()

    init(host: String, serverName: String, unlocks: Unlock? = nil) {
        self.host = host
        self.serverName = serverName
        self.unlocks = unlocks
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = board.title
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = Theme.Color.groupedBackground
        let plus = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in self?.compose() })
        plus.accessibilityLabel = DelegateEntryPoint.newPacketTitle
        let beta = BetaBadge(feature: .delegate, reportLines: { [weak self] in self?.betaReportLines ?? [] })
        navigationItem.rightBarButtonItems = [plus, UIBarButtonItem(customView: beta)]
        configure()
        NotificationCenter.default.addObserver(
            self, selector: #selector(deskChanged), name: DelegateDesk.didChange, object: nil)
        applySnapshot()
        if board.phase == .idle { desk.probe(host: host, serverName: serverName) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        MidgarSignals.noteScreen(unlocks == nil ? "delegate" : "delegate-rehearsal", feature: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if board.isReady { Task { await desk.refresh(host: host) } }
    }

    @objc private func deskChanged() {
        applySnapshot()
    }

    private func configure() {
        var config = UICollectionLayoutListConfiguration.themed(.insetGrouped)
        config.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.readableList(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.refreshControl = UIRefreshControl()
        collectionView.refreshControl?.addAction(UIAction { [weak self] _ in self?.pulled() }, for: .valueChanged)
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<SurfaceListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item)
        }
        let runCell = UICollectionView.CellRegistration<DelegateRunRowCell, Item> { [weak self] cell, _, item in
            guard case .run(let runID) = item, let row = self?.row(runID) else { return }
            cell.show(row)
        }
        let hostCell = UICollectionView.CellRegistration<DelegateHostCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            switch item {
            case .compose:
                #if DEBUG
                    let demoNote =
                        ProcessInfo.processInfo.environment["TAILSCODE_HIDE_DEMO_BADGE"] != nil
                        ? nil : self.board.note
                #else
                    let demoNote = self.board.note
                #endif
                self.composeNote.text = demoNote ?? DelegateEntryPoint.subtitle
                cell.place(self.composeView)
                cell.backgroundConfiguration = .clear()
            case .practice:
                self.practiceButton.setLoading(self.practicing)
                cell.place(self.practiceView)
                cell.backgroundConfiguration = .clear()
            case .ladder:
                self.ladderView.show(self.board.ladderRungs)
                cell.place(self.ladderView)
            default:
                break
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.sectionTitle(at: indexPath.section)
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .run: return collectionView.dequeueConfiguredReusableCell(using: runCell, for: indexPath, item: item)
            case .compose, .ladder, .practice: return collectionView.dequeueConfiguredReusableCell(using: hostCell, for: indexPath, item: item)
            default: return collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    /// The primary action and the board's one standing sentence, outside any card.
    private func makeComposeView() -> UIView {
        let button: UIButton = DelegateRehearsal.isRehearsal(host: host)
            ? SecondaryButton(title: DelegateEntryPoint.newPacketTitle) : PrimaryButton(title: DelegateEntryPoint.newPacketTitle)
        button.configuration?.image = UIImage(systemName: "plus")
        button.configuration?.imagePadding = Theme.Spacing.s
        button.addAction(UIAction { [weak self] _ in self?.compose() }, for: .touchUpInside)
        composeNote.font = Theme.Ramp.font(.cardBody)
        composeNote.textColor = Theme.Color.secondaryLabel
        composeNote.numberOfLines = 0
        composeNote.adjustsFontForContentSizeCategory = true
        let column = UIStackView(arrangedSubviews: [button, composeNote])
        column.axis = .vertical
        column.spacing = Theme.Spacing.s
        return column
    }

    /// The rehearsal's one bold action, with what pressing it costs said under it: nothing.
    private func makePracticeView() -> UIView {
        practiceButton.configuration?.image = UIImage(systemName: "play.fill")
        practiceButton.configuration?.imagePadding = Theme.Spacing.s
        practiceButton.addAction(UIAction { [weak self] _ in self?.sendPractice() }, for: .touchUpInside)
        let detail = UILabel()
        detail.text = DelegateRehearsal.practiceDetail
        detail.font = Theme.Ramp.font(.cardBody)
        detail.textColor = Theme.Color.secondaryLabel
        detail.numberOfLines = 0
        detail.textAlignment = .center
        detail.adjustsFontForContentSizeCategory = true
        let column = UIStackView(arrangedSubviews: [practiceButton, detail])
        column.axis = .vertical
        column.spacing = Theme.Spacing.s
        return column
    }

    private func pulled() {
        if board.isReady {
            Task {
                await desk.refresh(host: host)
                collectionView.refreshControl?.endRefreshing()
            }
        } else {
            desk.probe(host: host, serverName: serverName)
            collectionView.refreshControl?.endRefreshing()
        }
    }

    private func row(_ runID: String) -> DelegateRunRow? {
        for section in sections {
            if let row = section.rows.first(where: { $0.runID == runID }) { return row }
        }
        return nil
    }

    private func sectionTitle(at index: Int) -> String? {
        switch dataSource.snapshot().sectionIdentifiers[safe: index] {
        case .top:
            if #available(iOS 26.0, *) { return nil }
            return board.subtitle
        case .rehearsal: return DelegateRehearsal.title
        case .practice, .unlock: return nil
        case .setup: return DelegateSetup.title
        case .ladder: return DelegateComposerWords.ladderLabel
        case .runs(let kind): return sections.first { $0.kind == kind }?.title
        case .none: return nil
        }
    }

    private func applySnapshot() {
        let board = board
        if #available(iOS 26.0, *) { navigationItem.subtitle = board.subtitle }
        sections = board.isReady ? board.sections() : []
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if board.isReady, DelegateRehearsal.isRehearsal(host: host) {
            snapshot.appendSections([.rehearsal])
            snapshot.appendItems(DelegateRehearsal.points.indices.map { .point($0) }, toSection: .rehearsal)
            snapshot.appendSections([.practice])
            snapshot.appendItems([.practice], toSection: .practice)
            if unlocks != nil, !DelegateGate.isOpen {
                snapshot.appendSections([.unlock])
                snapshot.appendItems([.unlock], toSection: .unlock)
            }
        }
        snapshot.appendSections([.top])
        var top: [Item] = board.isReady ? [.compose] : [.status]
        if reach.asksForPassword || (desk.password(host: host) != nil && !desk.isDemo(host: host)) { top.append(.password) }
        snapshot.appendItems(top, toSection: .top)
        if DelegateSetup.isWanted(board: board, known: desk.isKnown(host: host)) {
            snapshot.appendSections([.setup])
            let easy: [Item] = hostProfile == nil ? [.setupRehearse] : [.setupAsk, .setupRehearse]
            snapshot.appendItems(easy + [.setupLead] + DelegateSetup.steps.map { .setup($0.id) }, toSection: .setup)
        }
        if !board.tiers.isEmpty {
            snapshot.appendSections([.ladder])
            snapshot.appendItems([.ladder] + board.promotions.indices.map { .hint($0) }, toSection: .ladder)
        }
        if board.isReady {
            if sections.isEmpty {
                snapshot.appendSections([.runs(.earlier)])
                snapshot.appendItems([.empty], toSection: .runs(.earlier))
            }
            for section in sections {
                snapshot.appendSections([.runs(section.kind)])
                snapshot.appendItems(section.rows.map { .run($0.runID) }, toSection: .runs(section.kind))
            }
        }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { existing.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: false)
        for header in collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader) {
            guard let header = header as? UICollectionViewListCell,
                let indexPath = collectionView.indexPath(forSupplementaryView: header)
            else { continue }
            var content = UIListContentConfiguration.header()
            content.text = sectionTitle(at: indexPath.section)
            header.contentConfiguration = content
        }
    }

    private func configure(_ cell: UICollectionViewListCell, _ item: Item) {
        var content = cell.defaultContentConfiguration()
        cell.accessories = []
        let board = board
        switch item {
        case .status:
            content.text = board.statusLine
            content.secondaryText = reach.isAnswering || board.statusLine == reach.line ? DelegateEntryPoint.subtitle : reach.line
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.secondaryTextProperties.numberOfLines = 0
            content.image = UIImage(systemName: DelegateEntryPoint.symbol)
            content.imageProperties.tintColor = (reach == .unknown ? board.statusTone : reach.tone).color
            if board.phase == .checking { cell.accessories = [.working()] }
        case .point(let index):
            content.text = DelegateRehearsal.points[safe: index]
            content.textProperties.numberOfLines = 0
            content.textProperties.font = Theme.Ramp.font(.cardBody)
            content.image = UIImage(systemName: "\(index + 1).circle.fill")
            content.imageProperties.tintColor = Theme.Color.accent
        case .unlock:
            content.text = DelegateRehearsal.unlockTitle(serverName: unlocks?.serverName ?? serverName)
            content.textProperties.color = Theme.Color.accent
            content.textProperties.font = Theme.Ramp.font(.rowTitle)
            content.secondaryText = DelegateRehearsal.unlockDetail
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.secondaryTextProperties.numberOfLines = 0
            content.image = UIImage(systemName: DelegateEntryPoint.symbol)
            content.imageProperties.tintColor = Theme.Color.accent
            cell.accessories = [.disclosureIndicator()]
        case .setupAsk:
            content.text = DelegateSetup.askTitle(agent: hostProfile?.backend.displayName ?? serverName)
            content.textProperties.color = Theme.Color.accent
            content.secondaryText = DelegateSetup.askDetail
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.secondaryTextProperties.numberOfLines = 0
            content.image = UIImage(systemName: "sparkles")
            content.imageProperties.tintColor = Theme.Color.accent
            cell.accessories = [.disclosureIndicator()]
        case .setupRehearse:
            content.text = DelegateSetup.rehearseTitle
            content.textProperties.color = Theme.Color.accent
            content.secondaryText = DelegateSetup.rehearseDetail
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.secondaryTextProperties.numberOfLines = 0
            content.image = UIImage(systemName: "play.circle")
            content.imageProperties.tintColor = Theme.Color.accent
            cell.accessories = [.disclosureIndicator()]
        case .setupLead:
            content.text = DelegateSetup.lead(serverName: serverName)
            content.textProperties.numberOfLines = 0
            content.textProperties.font = Theme.Ramp.font(.rowNote)
            content.textProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "terminal")
            content.imageProperties.tintColor = Theme.Color.accent
        case .setup(let id):
            guard let step = DelegateSetup.steps.first(where: { $0.id == id }) else { break }
            content.text = step.title
            content.secondaryText = step.command + "\n" + step.detail
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.font = Theme.Ramp.font(.code)
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            let copied = copiedStep == id
            cell.accessories = [
                .label(
                    text: copied ? DelegateSetup.copied : String(localized: "Copy"),
                    options: .init(tintColor: copied ? Theme.Color.success : Theme.Color.accent))
            ]
        case .password:
            content.text = desk.password(host: host) == nil
                ? String(localized: "Enter the dispatcher's password")
                : String(localized: "Change the dispatcher's password")
            content.secondaryText = String(localized: "From serve.env on that machine")
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "key")
            content.imageProperties.tintColor = Theme.Color.accent
        case .hint(let index):
            content.text = board.promotions[safe: index]
            content.textProperties.numberOfLines = 0
            content.textProperties.font = Theme.Ramp.font(.rowNote)
            content.textProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "lightbulb")
            content.imageProperties.tintColor = Theme.Color.special
        case .empty:
            content.text = board.emptyLine
            content.textProperties.color = Theme.Color.secondaryLabel
            content.textProperties.numberOfLines = 0
        case .compose, .ladder, .run, .practice:
            break
        }
        cell.contentConfiguration = content
    }

    /// Why the feature wears its mark, in Core's words, sized to them.
    func explainBeta() {
        BetaCardViewController.present(feature: .delegate, reportLines: { [weak self] in self?.betaReportLines ?? [] }, from: self)
    }

    /// What the daemon on this machine said last, for a report: where it is, what it answered and
    /// which version, and nothing the person typed.
    private var betaReportLines: [String] {
        let address = (DelegateAccessStore.access(host: host) ?? DelegateAccess(host: host)).address
        var lines = ["Daemon: \(address)", "Daemon state: \(betaReportState)"]
        if case .answering(let version) = reach { lines.append("Daemon version: \(version)") }
        return lines
    }

    private var betaReportState: String {
        switch reach {
        case .unknown: return "not checked"
        case .checking: return "checking"
        case .answering: return "answering"
        case .wantsPassword: return "wants a password"
        case .refused: return "password refused"
        case .unreachable(let why): return "not answering (\(why))"
        }
    }

    func compose() {
        Theme.Haptics.tap()
        DelegateGate.presentComposer(from: self, host: host, serverName: serverName, draft: nil)
    }

    /// The saved server on this board's machine, whose agent can be asked to install the dispatcher.
    private var hostProfile: ConnectionProfile? {
        ConnectionController.shared.profiles.first { $0.baseURL.host == host }
    }

    /// One press sends the practice packet and lands on its run, where the lesson is.
    private func sendPractice() {
        guard !practicing else { return }
        practicing = true
        Theme.Haptics.tap()
        applySnapshot()
        Task { [weak self] in
            guard let self else { return }
            do {
                let runID = try await self.desk.start(DelegateRehearsal.practice, host: self.host)
                MidgarSignals.noteScreen("delegate-practice", feature: true)
                DelegateGate.showRun(runID, host: self.host, serverName: self.serverName, from: self, unlocks: self.unlocks)
            } catch {
                MidgarLog.error("delegate practice packet did not start: \(error.localizedDescription)", category: .ui)
            }
            self.practicing = false
            self.applySnapshot()
        }
    }

    /// Hands the setup request to Home's box, aimed at this machine's server and unsent: the
    /// person reads it and sends it, and the agent's every step is theirs to approve.
    private func askAgent() {
        guard let profile = hostProfile else { return }
        Theme.Haptics.tap()
        let brief = DelegateSetup.brief
        let aim = {
            guard let home = MachineRouter.home else {
                UIPasteboard.general.string = brief
                return
            }
            if let workspace = home.workspace {
                workspace.showHome()
            } else {
                home.navigationController?.popToRootViewController(animated: false)
            }
            home.aimCompose(at: profile.id, carry: CarryPlan(brief: nil, draft: brief))
        }
        if let root = view.window?.rootViewController, root.presentedViewController != nil {
            root.dismiss(animated: true, completion: aim)
        } else {
            aim()
        }
    }

    /// One command onto the clipboard, and the row says so for a moment.
    private func copySetupCommand(_ id: String) {
        guard let step = DelegateSetup.steps.first(where: { $0.id == id }) else { return }
        UIPasteboard.general.string = step.command
        Theme.Haptics.tap()
        copiedStep = id
        applySnapshot()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.copiedStep == id else { return }
            self.copiedStep = nil
            self.applySnapshot()
        }
    }

    private func askPassword() {
        let alert = UIAlertController(
            title: String(localized: "Dispatcher password"),
            message: String(localized: "The DELEGATE_PASSWORD line in ~/.config/delegate/serve.env on \(serverName)."),
            preferredStyle: .alert)
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.placeholder = String(localized: "Password")
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Save"), style: .default) { [weak self, weak alert] _ in
                guard let self, let text = alert?.textFields?.first?.text, !text.isEmpty else { return }
                self.desk.remember(password: text, host: self.host, serverName: self.serverName)
            })
        present(alert, animated: true)
    }
}

extension DelegateBoardViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .password:
            askPassword()
        case .status:
            if !board.isReady { desk.probe(host: host, serverName: serverName) }
        case .run(let runID):
            Theme.Haptics.tap()
            navigationController?.pushViewController(
                DelegateRunViewController(host: host, serverName: serverName, runID: runID, unlocks: unlocks), animated: true)
        case .empty:
            compose()
        case .setup(let id):
            copySetupCommand(id)
        case .unlock:
            guard let unlocks else { break }
            DelegateGate.unlock(from: self, host: unlocks.host, serverName: unlocks.serverName)
        case .setupAsk:
            askAgent()
        case .setupRehearse:
            DelegateGate.rehearse(from: self)
        case .compose, .ladder, .hint, .setupLead, .point, .practice:
            break
        }
    }
}

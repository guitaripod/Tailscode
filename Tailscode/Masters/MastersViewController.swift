import CodingAgentKit
import MidgarCore
import TailscodeCore
import UIKit

/// The shelf's rows, drawn the same wherever the shelf is: Home's section, the masters page and
/// the iPad's place beside the list.
@MainActor
enum MasterShelf {
    static func row(_ row: MasterRow, showsMachine: Bool, action: @escaping () -> Void) -> MachineRowView {
        let state = row.state()
        let view = MachineRowView(
            title: showsMachine ? "\(row.master.name) · \(row.machine)" : row.master.name, detail: state.text,
            image: MasterStyle.mark(row), detailColor: MasterStyle.color(state.tone), action: action)
        view.detailLabel.numberOfLines = 2
        if let count = MasterReading.badge(row.master) { view.trail(badge(count)) }
        view.chevron()
        view.isAccessibilityElement = true
        view.accessibilityLabel = [row.master.name, state.text].joined(separator: ", ")
        view.accessibilityHint = Localized.text("Opens the master")
        return view
    }

    static func newMasterRow(action: @escaping () -> Void) -> MachineRowView {
        let plus = UIImage(
            systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        let view = MachineRowView(title: MasterWords.newMaster, image: plus, tint: Theme.Color.accent, action: action)
        view.titleLabel.textColor = Theme.Color.accent
        view.isAccessibilityElement = true
        view.accessibilityLabel = MasterWords.newMaster
        return view
    }

    static func badge(_ count: Int) -> UIView {
        let label = UILabel()
        label.text = "\(count)"
        label.font = Theme.Ramp.font(.badge)
        label.textColor = Theme.Color.onAccent
        label.textAlignment = .center
        label.backgroundColor = Theme.Color.accent
        label.layer.cornerRadius = 10
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.heightAnchor.constraint(equalToConstant: 20),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
        label.accessibilityLabel = MasterWords.toReview(count)
        return label
    }

    /// The shelf's identity is nothing; what it says is everything its rows say.
    nonisolated static func signature(_ board: MasterBoard, now: Date = Date()) -> Int {
        var hasher = Hasher()
        for row in board.rows {
            hasher.combine(row.id)
            hasher.combine(row.master.name)
            hasher.combine(row.master.glyph)
            hasher.combine(row.master.hue)
            let state = row.state(now: now)
            hasher.combine(state.text)
            hasher.combine(state.tone)
            hasher.combine(row.master.pending)
        }
        hasher.combine(board.machines.map(\.profileID))
        hasher.combine(board.unanswered.map(\.profileID))
        return hasher.finalize()
    }
}

/// Every master on every machine, as a page.
@MainActor
final class MastersViewController: UIViewController {
    private var scroll: UIScrollView!
    private var column: UIStackView!
    private let refresher = UIRefreshControl()
    private var isWatching = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = MasterWords.title
        (scroll, column) = MachinePage.install(in: self)
        refresher.addAction(UIAction { [weak self] _ in self?.pulled() }, for: .valueChanged)
        scroll.refreshControl = refresher
        let plus = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                MasterRouter.newMaster(from: self)
            })
        plus.accessibilityLabel = MasterWords.newMaster
        let beta = BetaBadge(feature: .masters, reportLines: { MasterDesk.shared.betaReportLines })
        navigationItem.rightBarButtonItems = [plus, UIBarButtonItem(customView: beta)]
        NotificationCenter.default.addObserver(
            self, selector: #selector(deskChanged), name: MasterDesk.didChange, object: nil)
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        MidgarSignals.noteScreen("masters", feature: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !isWatching else { return }
        isWatching = true
        MasterDesk.shared.watch()
    }

    /// A pull reads every machine again and lets go of the spinner when the read ends, changed or not.
    private func pulled() {
        let read = MasterDesk.shared.refresh(force: true)
        Task { [weak self] in
            await read?.value
            self?.refresher.endRefreshing()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isWatching else { return }
        isWatching = false
        MasterDesk.shared.unwatch()
    }

    @objc private func deskChanged() {
        refresher.endRefreshing()
        render()
    }

    private func render() {
        MachinePage.clear(column)
        let board = MasterDesk.shared.board
        guard !board.isEmpty else {
            column.addArrangedSubview(Self.emptyState(board: board) { [weak self] in
                guard let self else { return }
                MasterRouter.newMaster(from: self)
            })
            return
        }
        let machines = Set(board.rows.map(\.profileID))
        let card = MachineCardView()
        for row in board.rows {
            card.add(MasterShelf.row(row, showsMachine: machines.count > 1) { [weak self] in
                guard let self else { return }
                MasterRouter.open(row, from: self)
            })
        }
        card.add(MasterShelf.newMasterRow { [weak self] in
            guard let self else { return }
            MasterRouter.newMaster(from: self)
        })
        column.addArrangedSubview(card)
        if let silent = MasterDesk.shared.notAnsweringLine {
            let note = MachinePage.footnote(silent)
            note.textColor = Theme.Color.warning
            column.addArrangedSubview(note)
        }
        column.addArrangedSubview(MachinePage.footnote(MasterWords.emptyDetail))
    }

    static func emptyState(board: MasterBoard, action: @escaping () -> Void) -> UIView {
        let canMake = !board.machines.isEmpty
        let empty = UIStackView()
        empty.axis = .vertical
        empty.spacing = Theme.Spacing.s
        empty.alignment = .center
        let icon = UIImageView(
            image: UIImage(systemName: MasterStyle.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 34)))
        icon.tintColor = Theme.Color.tertiaryLabel
        let title = UILabel()
        title.text = MasterWords.empty
        title.font = Theme.Ramp.font(.cardTitle)
        title.textColor = Theme.Color.label
        let detail = MachinePage.footnote(canMake ? MasterWords.emptyDetail : MasterDesk.shared.unreachableWords)
        detail.textAlignment = .center
        [icon, title, detail].forEach(empty.addArrangedSubview)
        if canMake, let silent = MasterDesk.shared.notAnsweringLine {
            let note = MachinePage.footnote(silent)
            note.textAlignment = .center
            note.textColor = Theme.Color.warning
            empty.addArrangedSubview(note)
        }
        if canMake {
            empty.addArrangedSubview(MachinePage.pill(MasterWords.newMaster, prominent: true, action: action))
        }
        empty.isLayoutMarginsRelativeArrangement = true
        empty.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.xxxl, leading: Theme.Spacing.l, bottom: 0, trailing: Theme.Spacing.l)
        return empty
    }
}

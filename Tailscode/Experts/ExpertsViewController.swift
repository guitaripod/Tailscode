import CodingAgentKit
import TailscodeCore
import UIKit

/// The shelf's rows, drawn the same wherever the shelf is: Home's section, the experts page and
/// the iPad's place beside the list.
@MainActor
enum ExpertShelf {
    static func row(_ row: ExpertRow, showsMachine: Bool, action: @escaping () -> Void) -> MachineRowView {
        let state = row.state()
        let view = MachineRowView(
            title: showsMachine ? "\(row.expert.name) · \(row.machine)" : row.expert.name, detail: state.text,
            image: ExpertStyle.mark(row), detailColor: ExpertStyle.color(state.tone), action: action)
        view.detailLabel.numberOfLines = 2
        if let count = ExpertReading.badge(row.expert) {
            view.trail(badge(count))
        } else {
            view.chevron()
        }
        view.isAccessibilityElement = true
        view.accessibilityLabel = [row.expert.name, state.text].joined(separator: ", ")
        view.accessibilityHint = Localized.text("Opens the expert")
        return view
    }

    static func newExpertRow(action: @escaping () -> Void) -> MachineRowView {
        let plus = UIImage(
            systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        let view = MachineRowView(title: ExpertWords.newExpert, image: plus, tint: Theme.Color.accent, action: action)
        view.titleLabel.textColor = Theme.Color.accent
        view.isAccessibilityElement = true
        view.accessibilityLabel = ExpertWords.newExpert
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
        label.accessibilityLabel = ExpertWords.toReview(count)
        return label
    }

    /// The shelf's identity is nothing; what it says is everything its rows say.
    nonisolated static func signature(_ board: ExpertBoard, now: Date = Date()) -> Int {
        var hasher = Hasher()
        for row in board.rows {
            hasher.combine(row.id)
            hasher.combine(row.expert.name)
            hasher.combine(row.expert.glyph)
            hasher.combine(row.expert.hue)
            let state = row.state(now: now)
            hasher.combine(state.text)
            hasher.combine(state.tone)
            hasher.combine(row.expert.pending)
        }
        hasher.combine(board.machines.map(\.profileID))
        hasher.combine(board.unanswered.map(\.profileID))
        return hasher.finalize()
    }
}

/// Every expert on every machine, as a page.
@MainActor
final class ExpertsViewController: UIViewController {
    private var scroll: UIScrollView!
    private var column: UIStackView!
    private let refresher = UIRefreshControl()
    private var isWatching = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ExpertWords.title
        (scroll, column) = MachinePage.install(in: self)
        refresher.addAction(UIAction { [weak self] _ in self?.pulled() }, for: .valueChanged)
        scroll.refreshControl = refresher
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                ExpertRouter.newExpert(from: self)
            })
        navigationItem.rightBarButtonItem?.accessibilityLabel = ExpertWords.newExpert
        NotificationCenter.default.addObserver(
            self, selector: #selector(deskChanged), name: ExpertDesk.didChange, object: nil)
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !isWatching else { return }
        isWatching = true
        ExpertDesk.shared.watch()
    }

    /// A pull reads every machine again and lets go of the spinner when the read ends, changed or not.
    private func pulled() {
        let read = ExpertDesk.shared.refresh(force: true)
        Task { [weak self] in
            await read?.value
            self?.refresher.endRefreshing()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isWatching else { return }
        isWatching = false
        ExpertDesk.shared.unwatch()
    }

    @objc private func deskChanged() {
        refresher.endRefreshing()
        render()
    }

    private func render() {
        MachinePage.clear(column)
        let board = ExpertDesk.shared.board
        guard !board.isEmpty else {
            column.addArrangedSubview(Self.emptyState(board: board) { [weak self] in
                guard let self else { return }
                ExpertRouter.newExpert(from: self)
            })
            return
        }
        let machines = Set(board.rows.map(\.profileID))
        let card = MachineCardView()
        for row in board.rows {
            card.add(ExpertShelf.row(row, showsMachine: machines.count > 1) { [weak self] in
                guard let self else { return }
                ExpertRouter.open(row, from: self)
            })
        }
        card.add(ExpertShelf.newExpertRow { [weak self] in
            guard let self else { return }
            ExpertRouter.newExpert(from: self)
        })
        column.addArrangedSubview(card)
        if let silent = ExpertDesk.shared.notAnsweringLine {
            let note = MachinePage.footnote(silent)
            note.textColor = Theme.Color.warning
            column.addArrangedSubview(note)
        }
        column.addArrangedSubview(MachinePage.footnote(ExpertWords.emptyDetail))
    }

    static func emptyState(board: ExpertBoard, action: @escaping () -> Void) -> UIView {
        let canMake = !board.machines.isEmpty
        let empty = UIStackView()
        empty.axis = .vertical
        empty.spacing = Theme.Spacing.s
        empty.alignment = .center
        let icon = UIImageView(
            image: UIImage(systemName: ExpertStyle.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 34)))
        icon.tintColor = Theme.Color.tertiaryLabel
        let title = UILabel()
        title.text = ExpertWords.empty
        title.font = Theme.Ramp.font(.cardTitle)
        title.textColor = Theme.Color.label
        let detail = MachinePage.footnote(canMake ? ExpertWords.emptyDetail : ExpertDesk.shared.unreachableWords)
        detail.textAlignment = .center
        [icon, title, detail].forEach(empty.addArrangedSubview)
        if canMake, let silent = ExpertDesk.shared.notAnsweringLine {
            let note = MachinePage.footnote(silent)
            note.textAlignment = .center
            note.textColor = Theme.Color.warning
            empty.addArrangedSubview(note)
        }
        if canMake {
            empty.addArrangedSubview(MachinePage.pill(ExpertWords.newExpert, prominent: true, action: action))
        }
        empty.isLayoutMarginsRelativeArrangement = true
        empty.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.xxxl, leading: Theme.Spacing.l, bottom: 0, trailing: Theme.Spacing.l)
        return empty
    }
}

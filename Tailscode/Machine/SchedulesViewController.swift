import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore
import UIKit

/// Every machine's schedules, soonest first — or one machine's, opened from its own screen.
@MainActor
final class SchedulesViewController: UIViewController {
    private let profileID: String?
    private var column: UIStackView!
    private var scroll: UIScrollView!
    private let refresher = UIRefreshControl()

    init(profileID: String? = nil) {
        self.profileID = profileID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = profileID.flatMap { MachineDesk.shared.profile($0)?.name }
            .map { Localized.text("Scheduled on %@", $0) } ?? ScheduleWords.title
        (scroll, column) = MachinePage.install(in: self)
        refresher.addAction(UIAction { _ in MachineDesk.shared.refresh(force: true) }, for: .valueChanged)
        scroll.refreshControl = refresher
        NotificationCenter.default.addObserver(
            self, selector: #selector(deskChanged), name: MachineDesk.didChange, object: nil)
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        MachineDesk.shared.refresh(force: true)
    }

    @objc private func deskChanged() {
        refresher.endRefreshing()
        render()
    }

    private var rows: [ScheduleRow] {
        MachineDesk.shared.board.rows.filter { profileID == nil || $0.profileID == profileID }
    }

    private func render() {
        MachinePage.clear(column)
        let rows = self.rows
        guard !rows.isEmpty else {
            let empty = UIStackView()
            empty.axis = .vertical
            empty.spacing = Theme.Spacing.s
            empty.alignment = .center
            let icon = UIImageView(
                image: UIImage(
                    systemName: "clock", withConfiguration: UIImage.SymbolConfiguration(pointSize: 34)))
            icon.tintColor = Theme.Color.tertiaryLabel
            let title = UILabel()
            title.text = ScheduleWords.empty
            title.font = Theme.Ramp.font(.cardTitle)
            title.textColor = Theme.Color.label
            let detail = MachinePage.footnote(ScheduleWords.emptyDetail)
            detail.textAlignment = .center
            [icon, title, detail].forEach(empty.addArrangedSubview)
            empty.isLayoutMarginsRelativeArrangement = true
            empty.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: Theme.Spacing.xxxl, leading: Theme.Spacing.l, bottom: 0, trailing: Theme.Spacing.l)
            column.addArrangedSubview(empty)
            return
        }
        let card = MachineCardView()
        for row in rows { card.add(Self.row(row) { [weak self] in self?.open(row) }) }
        column.addArrangedSubview(card)
    }

    static func row(_ row: ScheduleRow, action: @escaping () -> Void) -> MachineRowView {
        let dim = row.schedule.paused || row.schedule.isFinished
        let tile = AgentMark.image(
            initial: "", color: dim ? Theme.Color.tertiaryLabel : ScheduleModelWord.tint(row.schedule.model))
        let view = MachineRowView(title: row.title, detail: row.subtitle, image: tile, action: action)
        let clock = UIImageView(
            image: UIImage(
                systemName: "clock", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)))
        clock.tintColor = .white
        clock.translatesAutoresizingMaskIntoConstraints = false
        view.leading.addSubview(clock)
        NSLayoutConstraint.activate([
            clock.centerXAnchor.constraint(equalTo: view.leading.centerXAnchor),
            clock.centerYAnchor.constraint(equalTo: view.leading.centerYAnchor),
        ])
        if dim { view.titleLabel.textColor = Theme.Color.secondaryLabel }
        if let words = row.markWords {
            let mark = UILabel()
            mark.text = "\(row.mark.glyph) \(words)"
            mark.font = Theme.Ramp.font(.rowMeta)
            mark.textColor = row.mark.color
            mark.setContentCompressionResistancePriority(.required, for: .horizontal)
            view.trail(mark)
        }
        view.chevron()
        view.accessibilityLabel = [row.title, row.subtitle, row.markWords].compactMap { $0 }.joined(separator: ", ")
        view.isAccessibilityElement = true
        return view
    }

    private func open(_ row: ScheduleRow) {
        navigationController?.pushViewController(ScheduleDetailViewController(row: row), animated: true)
    }
}

/// How a schedule names the model it asks with, on the machine that keeps it.
@MainActor
enum ScheduleModelWord {
    static func selection(_ raw: String?) -> ModelSelection? {
        guard let raw, !raw.isEmpty else { return nil }
        if let slash = raw.firstIndex(of: "/"), slash != raw.startIndex {
            return ModelSelection(
                providerID: String(raw[..<slash]), modelID: String(raw[raw.index(after: slash)...]))
        }
        return ModelSelection(providerID: "", modelID: raw)
    }

    static func word(_ raw: String?, profileID: String) -> String? {
        guard let selection = selection(raw) else { return nil }
        let catalog = ModelCatalogStore.cached(profileID)
        if !selection.providerID.isEmpty {
            return ModelBadge.word(for: selection, in: catalog)
        }
        return ModelBadge.chip(model: selection.modelID, effort: nil, providerID: nil, catalog: catalog)?.name
            ?? selection.modelID
    }

    static func tint(_ raw: String?) -> UIColor {
        guard let selection = selection(raw) else { return Theme.Color.accent }
        if !selection.providerID.isEmpty, ModelTint.family(selection.modelID) == nil {
            return AgentMark.color(for: selection.providerID, isBuiltIn: false)
        }
        let family = ModelTint.family(selection.modelID)
        return family == nil ? Theme.Color.accent : Theme.Color.modelFamily(family)
    }
}

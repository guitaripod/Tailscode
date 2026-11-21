import CodingAgentKit
import TailscodeCore
import UIKit

/// Home's shelf of masters. There is only ever one, so its identity is nothing at all and every
/// row it draws arrives through reconfigure.
struct MasterShelfCard: Hashable {
    let board: MasterBoard

    static func == (lhs: MasterShelfCard, rhs: MasterShelfCard) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

final class MasterShelfCell: UICollectionViewCell {
    var onOpen: ((MasterRow) -> Void)?
    var onNew: ((UIView) -> Void)?
    var onAll: (() -> Void)?

    private let header = UIStackView()
    private let titleLabel = UILabel()
    private let allButton = UIButton(type: .system)
    private var card = MachineCardView()
    private let column = UIStackView()
    private let silentLabel = MachinePage.footnote("")

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.text = MasterWords.title.uppercased(with: .current)
        titleLabel.font = Theme.Ramp.font(.sectionLabel)
        titleLabel.textColor = Theme.Color.secondaryLabel
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = .header
        var all = UIButton.Configuration.plain()
        all.title = Localized.text("See all")
        all.contentInsets = .zero
        all.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var updated = attributes
            updated.font = Theme.Ramp.font(.rowMeta)
            return updated
        }
        allButton.configuration = all
        allButton.addAction(UIAction { [weak self] _ in self?.onAll?() }, for: .touchUpInside)
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(UIView())
        header.addArrangedSubview(allButton)
        header.alignment = .lastBaseline
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0, leading: Theme.Spacing.xs, bottom: 0, trailing: Theme.Spacing.xs)
        column.axis = .vertical
        column.spacing = Theme.Spacing.s
        column.addArrangedSubview(header)
        column.addArrangedSubview(card)
        silentLabel.textColor = Theme.Color.warning
        silentLabel.isHidden = true
        column.addArrangedSubview(silentLabel)
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: MasterShelfCell, _) in
            cell.rebuild()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var board = MasterBoard.empty

    func configure(_ shelf: MasterShelfCard) {
        board = shelf.board
        rebuild()
    }

    private func rebuild() {
        let fresh = MachineCardView()
        let machines = Set(board.rows.map(\.profileID))
        for row in board.rows {
            fresh.add(MasterShelf.row(row, showsMachine: machines.count > 1) { [weak self] in self?.onOpen?(row) })
        }
        if !board.machines.isEmpty {
            fresh.add(MasterShelf.newMasterRow { [weak self] in
                guard let self else { return }
                self.onNew?(self.card)
            })
        }
        column.removeArrangedSubview(card)
        card.removeFromSuperview()
        column.insertArrangedSubview(fresh, at: 1)
        fresh.isHidden = fresh.isEmpty
        card = fresh
        allButton.isHidden = board.rows.count < 2
        silentLabel.text = MasterDesk.shared.notAnsweringLine
        silentLabel.isHidden = silentLabel.text == nil
    }
}

extension HomeViewController {
    var masterShelf: MasterShelfCard? {
        let board = MasterDesk.shared.board
        return board.isEmpty && board.unanswered.isEmpty ? nil : MasterShelfCard(board: board)
    }

    @objc func masterDeskChanged() {
        applySnapshot()
    }

    func openMaster(_ row: MasterRow) {
        MasterRouter.open(row, from: self)
    }

    func pushMasters() {
        MasterRouter.openShelf(from: self)
    }
}

#if DEBUG
    extension HomeViewController {
        /// `TAILSCODE_OPEN_MASTER=demo-x-ipad[:notebook|:guards|:journal|:task|:edit|:draft|:brief|:debrief|:note]`,
        /// `TAILSCODE_OPEN_MASTER=shelf`, `=new` or `=chooser` puts a screen about a master on screen at
        /// launch, and `TAILSCODE_MASTER_PART=charter|skills|notebook|notes|bench|guards` opens that part of
        /// an editor, so each can be photographed without a hand.
        func openMasterScreensForVerification() {
            guard let wanted = ProcessInfo.processInfo.environment["TAILSCODE_OPEN_MASTER"] else { return }
            let parts = wanted.split(separator: ":").map(String.init)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                MasterDesk.shared.refresh(force: true)
                for _ in 0..<40 where MasterDesk.shared.board.isEmpty {
                    try? await Task.sleep(for: .seconds(0.25))
                }
                guard let self else { return }
                switch parts.first {
                case "shelf":
                    self.pushMasters()
                    return
                case "new":
                    MasterRouter.newMaster(from: self)
                    return
                case "chooser":
                    if !MasterDesk.shared.board.isEmpty {
                        let picker = ModelPickerViewController(sources: [], selected: nil, context: .chat) { _ in }
                        picker.masters = MasterDesk.shared.board.rows
                        picker.expertNote = MasterWords.handOverNote("Bridge restart wording")
                        picker.onMaster = { _ in }
                        let nav = UINavigationController(rootViewController: picker)
                        nav.sheetPresentationController?.detents = [.large()]
                        self.present(nav, animated: false)
                    }
                    return
                default:
                    break
                }
                guard let id = parts.first, let row = MasterDesk.shared.board.rows.first(where: { $0.master.id == id })
                else { return }
                let page = MasterViewController(row: row)
                if let workspace = self.workspace {
                    workspace.show(place: page, animated: false)
                } else {
                    self.navigationController?.pushViewController(page, animated: false)
                }
                guard parts.count > 1 else { return }
                try? await Task.sleep(for: .seconds(1))
                switch parts[1] {
                case "notebook": page.navigationController?.pushViewController(MasterNotebookViewController(row: row), animated: false)
                case "guards": page.navigationController?.pushViewController(MasterGuardsViewController(row: row), animated: false)
                case "journal": page.navigationController?.pushViewController(MasterJournalViewController(row: row), animated: false)
                case "task": MasterRouter.newTask(row, from: page)
                case "edit": MasterEditorViewController.presentEdit(row: row, from: page)
                case "debrief":
                    self.openSession(withID: DemoWorld.demoReviewedTaskID)
                    try? await Task.sleep(for: .seconds(3))
                    let chat = self.navigationController?.topViewController as? ChatViewController
                    for _ in 0..<120 where chat?.masterCard == nil {
                        try? await Task.sleep(for: .seconds(0.5))
                    }
                    try? await Task.sleep(for: .seconds(1))
                    chat?.tourScrollToBottom()
                case "note":
                    let backend = MasterDesk.shared.masters(forProfileID: row.profileID)
                    if let note = try? await backend?.expertNotes(row.master.id, retired: false).first {
                        page.navigationController?.pushViewController(
                            MasterNoteViewController(row: row, note: note), animated: false)
                    }
                case "draft":
                    MasterEditorViewController.presentDraft(profileID: row.profileID, sessionID: "demo-c3", from: page)
                default: break
                }
            }
        }
    }
#endif

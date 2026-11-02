import CodingAgentKit
import TailscodeCore
import UIKit

/// Home's one line while anything is scheduled: what asks next, when and where. Its identity is
/// nothing; what it says arrives through reconfigure.
struct ScheduleLineCard: Hashable {
    let line: String

    static func == (lhs: ScheduleLineCard, rhs: ScheduleLineCard) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

/// Agents a machine has that nobody has been told about, said once.
struct AgentNewsCard: Hashable {
    let title: String
    let detail: String

    static func == (lhs: AgentNewsCard, rhs: AgentNewsCard) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

final class ScheduleLineCell: UICollectionViewCell {
    private let icon = UIImageView()
    private let label = UILabel()
    private let chevron = UIImageView()
    private let capsule = CapsuleView()

    override var isHighlighted: Bool {
        didSet { contentView.alpha = isHighlighted ? 0.6 : 1 }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        capsule.backgroundColor = Theme.Color.groupedSurface
        capsule.layer.cornerCurve = .continuous
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.isUserInteractionEnabled = false
        icon.image = UIImage(
            systemName: "clock", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        icon.tintColor = Theme.Color.accent
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.font = Theme.Ramp.font(.statusLine)
        label.textColor = Theme.Color.label
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [icon, label, chevron])
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.s, leading: Theme.Spacing.m, bottom: Theme.Spacing.s, trailing: Theme.Spacing.m)
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(capsule)
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            capsule.topAnchor.constraint(equalTo: contentView.topAnchor),
            capsule.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            capsule.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = Localized.text("Opens everything scheduled")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ card: ScheduleLineCard) {
        label.text = card.line
        accessibilityLabel = card.line
    }
}

final class AgentNewsCell: ContentCardCell {
    var onAdd: (() -> Void)?
    var onNotNow: (() -> Void)?

    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let addButton = PrimaryButton(title: Localized.text("Add"))
    private let notNowButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        let icon = UIImageView(
            image: UIImage(
                systemName: "person.2.badge.plus",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)))
        icon.tintColor = Theme.Color.accent
        icon.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        bodyLabel.font = Theme.Ramp.font(.panelFootnote)
        bodyLabel.textColor = Theme.Color.secondaryLabel
        bodyLabel.numberOfLines = 0
        var notNow = UIButton.Configuration.gray()
        notNow.title = Localized.text("Not now")
        notNow.baseForegroundColor = Theme.Color.secondaryLabel
        notNow.cornerStyle = .large
        notNow.buttonSize = .large
        notNowButton.configuration = notNow
        addButton.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .touchUpInside)
        notNowButton.addAction(UIAction { [weak self] _ in self?.onNotNow?() }, for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [icon, titleLabel])
        header.alignment = .center
        header.spacing = Theme.Spacing.s
        let buttons = UIStackView(arrangedSubviews: [addButton, notNowButton])
        buttons.spacing = Theme.Spacing.s
        buttons.distribution = .fillEqually
        let column = UIStackView(arrangedSubviews: [header, bodyLabel, buttons])
        column.axis = .vertical
        column.spacing = Theme.Spacing.s
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
        ])
        isAccessibilityElement = false
        accessibilityElements = [titleLabel, bodyLabel, addButton, notNowButton]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ card: AgentNewsCard) {
        titleLabel.text = card.title
        bodyLabel.text = card.detail
    }
}

extension HomeViewController {
    /// Everything scheduled, beside the list on an iPad and pushed on a phone.
    func pushSchedules() {
        Theme.Haptics.tap()
        if let workspace {
            return workspace.show(place: SchedulesViewController())
        }
        navigationController?.pushViewController(SchedulesViewController(), animated: true)
    }

    @objc func machineDeskChanged() {
        applySnapshot()
    }

    var scheduleLine: ScheduleLineCard? {
        MachineDesk.shared.board.homeLine().map(ScheduleLineCard.init(line:))
    }

    /// Holding Send: ask this later on the aimed machine, or sharpen it first where the device can.
    func presentSendHold(text: String, from view: UIView) {
        guard enhancement.isAvailable else { return askLater(text: text) }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: ScheduleWords.askLaterMenu, style: .default) { [weak self] _ in
                self?.askLater(text: text)
            })
        sheet.addAction(
            UIAlertAction(title: Localized.text("Enhance prompt"), style: .default) { [weak self] _ in
                self?.enhanceFromHold(text)
            })
        sheet.addAction(UIAlertAction(title: Localized.text("Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = view.bounds
        present(sheet, animated: true)
    }

    func askLater(text: String) {
        guard let aim = composerAim, let backend = viewModel.backend(forProfileID: aim.profile.id) else { return }
        let choice = modelChoices[aim.memoryKey]
        Theme.Haptics.tap()
        AskLaterViewController.present(
            from: self,
            context: AskLaterViewController.Context(
                profile: aim.profile, backend: backend, text: text, selection: choice?.model,
                effort: choice?.effort, directory: aim.directory, sessionID: nil))
    }

    var agentNews: AgentNewsCard? {
        MachineDesk.shared.headline.map { AgentNewsCard(title: $0.title, detail: $0.detail) }
    }
}

#if DEBUG
    extension HomeViewController {
        /// Puts Scheduled, a schedule's page, or the demo machine's agents on screen at launch, so
        /// each can be photographed without a hand.
        func openMachineScreensForVerification() {
            let environment = ProcessInfo.processInfo.environment
            let agents =
                environment["TAILSCODE_OPEN_MACHINE_AGENTS"] != nil || environment["TAILSCODE_OPEN_AGENT"] != nil
                || environment["TAILSCODE_OPEN_MORE_AGENTS"] != nil
            let scheduleID = environment["TAILSCODE_OPEN_SCHEDULE"]
            guard agents || scheduleID != nil || environment["TAILSCODE_OPEN_SCHEDULED"] != nil else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                if agents {
                    let profile =
                        ConnectionController.shared.profiles.first { $0.id == DemoWorld.claudeProfile.id }
                        ?? ConnectionController.shared.profiles.first { $0.backend == .claudeCode }
                    guard let profile else { return }
                    self.navigationController?.pushViewController(
                        ServerDetailViewController(profile: profile), animated: false)
                    return
                }
                MachineDesk.shared.refresh(force: true)
                for _ in 0..<40 where MachineDesk.shared.board.isEmpty {
                    try? await Task.sleep(for: .seconds(0.25))
                }
                if let scheduleID,
                    let row = MachineDesk.shared.board.rows.first(where: { $0.schedule.id == scheduleID })
                {
                    if let workspace = self.workspace {
                        workspace.show(place: ScheduleDetailViewController(row: row), animated: false)
                    } else {
                        self.navigationController?.pushViewController(
                            ScheduleDetailViewController(row: row), animated: false)
                    }
                    return
                }
                self.pushSchedules()
            }
        }
    }
#endif

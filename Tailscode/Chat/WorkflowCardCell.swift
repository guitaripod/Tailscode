import CodingAgentKit
import TailscodeCore
import UIKit

/// A workflow run as one card in the conversation that started it. The Workflow tool answers the
/// instant it hands the work to the background, so the call itself has nothing left to say while
/// its agents spend minutes on it — the card says it instead: the run's name and description, the
/// phase plan its script declares, every agent that has appeared with what it is running, a meter
/// over the fan-out in hand, elapsed, and the answer folded in when the task reports back.
final class WorkflowCardCell: UICollectionViewCell {
    static let reuseID = "WorkflowCardCell"

    private let container = UIView()
    private let rail = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let headlineLabel = UILabel()
    private let elapsedLabel = UILabel()
    private let summaryLabel = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private let meterLabel = UILabel()
    private let phaseStack = UIStackView()
    private let agentStack = UIStackView()
    private let answerLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let column = UIStackView()
    private var fillWidth: NSLayoutConstraint?
    private var onAgentTap: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.layer.cornerRadius = Theme.Radius.card
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false

        let glass = Theme.Glass.view()
        glass.isUserInteractionEnabled = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)

        rail.backgroundColor = Theme.Color.accent
        rail.translatesAutoresizingMaskIntoConstraints = false

        iconView.image = UIImage(
            systemName: "point.3.connected.trianglepath.dotted",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        iconView.tintColor = Theme.Color.accent
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        titleLabel.textColor = Theme.Color.label
        titleLabel.adjustsFontForContentSizeCategory = true
        headlineLabel.font = .preferredFont(forTextStyle: .caption2)
        headlineLabel.adjustsFontForContentSizeCategory = true
        headlineLabel.setContentHuggingPriority(.required, for: .horizontal)
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.textColor = Theme.Color.tertiaryLabel
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        summaryLabel.font = .preferredFont(forTextStyle: .caption1)
        summaryLabel.textColor = Theme.Color.secondaryLabel
        summaryLabel.numberOfLines = 3
        summaryLabel.adjustsFontForContentSizeCategory = true
        answerLabel.font = .preferredFont(forTextStyle: .footnote)
        answerLabel.textColor = Theme.Color.label
        answerLabel.numberOfLines = 0
        answerLabel.adjustsFontForContentSizeCategory = true
        meterLabel.font = .preferredFont(forTextStyle: .caption2)
        meterLabel.textColor = Theme.Color.tertiaryLabel
        meterLabel.setContentHuggingPriority(.required, for: .horizontal)

        track.backgroundColor = Theme.Color.accent.withAlphaComponent(0.18)
        track.layer.cornerRadius = 2
        track.translatesAutoresizingMaskIntoConstraints = false
        fill.backgroundColor = Theme.Color.accent
        fill.layer.cornerRadius = 2
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)

        spinner.hidesWhenStopped = true
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        phaseStack.axis = .vertical
        phaseStack.spacing = 2
        agentStack.axis = .vertical
        agentStack.spacing = 4

        let header = UIStackView(arrangedSubviews: [
            iconView, titleLabel, UIView(), headlineLabel, spinner, elapsedLabel,
        ])
        header.axis = .horizontal
        header.spacing = 6
        header.alignment = .center

        let meterRow = UIStackView(arrangedSubviews: [track, meterLabel])
        meterRow.axis = .horizontal
        meterRow.spacing = 8
        meterRow.alignment = .center

        column.axis = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, summaryLabel, meterRow, phaseStack, agentStack, answerLabel] {
            column.addArrangedSubview(view)
        }

        container.addSubview(rail)
        container.addSubview(column)
        contentView.addSubview(container)

        let fillWidth = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: 0)
        self.fillWidth = fillWidth
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            container.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rail.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rail.topAnchor.constraint(equalTo: container.topAnchor),
            rail.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: 2),
            column.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            track.heightAnchor.constraint(equalToConstant: 4),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fillWidth,
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ run: WorkflowRun, at now: Date, onAgentTap: @escaping (String) -> Void) {
        self.onAgentTap = onAgentTap
        titleLabel.text = run.name
        headlineLabel.text = run.headline(at: now)
        headlineLabel.textColor = run.isLive ? Theme.Color.accent : Theme.Color.secondaryLabel
        summaryLabel.text = run.summary
        summaryLabel.isHidden = run.summary == nil
        elapsedLabel.text = run.elapsed(at: now).map(WorkflowRun.duration)
        elapsedLabel.isHidden = elapsedLabel.text == nil
        if run.isLive { spinner.startAnimating() } else { spinner.stopAnimating() }
        rail.backgroundColor = run.isLive ? Theme.Color.accent : Theme.Color.success

        fillWidth?.isActive = false
        let fraction = max(0.02, min(1, run.progress))
        let updated = fill.widthAnchor.constraint(
            equalTo: track.widthAnchor, multiplier: fraction)
        updated.isActive = true
        fillWidth = updated
        meterLabel.text =
            run.agents.isEmpty
            ? String(localized: "no agents yet")
            : String(localized: "\(run.doneCount) of \(run.agents.count) agents")

        rebuild(phaseStack) { stack in
            for phase in run.phases { stack.addArrangedSubview(Self.phaseRow(phase, run: run)) }
        }
        rebuild(agentStack) { stack in
            for agent in run.agents {
                stack.addArrangedSubview(self.agentRow(agent, at: now))
            }
        }

        let answer = run.result?.trimmingCharacters(in: .whitespacesAndNewlines)
        answerLabel.text = answer.map { $0.count > 600 ? String($0.prefix(600)) + "…" : $0 }
        answerLabel.isHidden = (answer ?? "").isEmpty
    }

    private func rebuild(_ stack: UIStackView, _ build: (UIStackView) -> Void) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        build(stack)
        stack.isHidden = stack.arrangedSubviews.isEmpty
    }

    /// The phases the script declares, as the plan it is. Which phase an agent belongs to is only
    /// recorded by a finished run, so a live card never points at one — claiming a position the
    /// data cannot support is worse than showing the plan and the agents separately.
    private static func phaseRow(_ phase: WorkflowPhase, run: WorkflowRun) -> UIView {
        let done = !run.isLive
        let dot = UIImageView(
            image: UIImage(
                systemName: done ? "circle.fill" : "circle",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 7, weight: .semibold)))
        dot.tintColor = done ? Theme.Color.accent : Theme.Color.tertiaryLabel
        dot.setContentHuggingPriority(.required, for: .horizontal)

        let title = UILabel()
        title.font = .preferredFont(forTextStyle: .caption1).withTraits(.traitBold)
        title.textColor = Theme.Color.label
        title.text = phase.title
        title.setContentHuggingPriority(.required, for: .horizontal)

        let detail = UILabel()
        detail.font = .preferredFont(forTextStyle: .caption2)
        detail.textColor = Theme.Color.tertiaryLabel
        detail.text = phase.detail
        detail.lineBreakMode = .byTruncatingTail

        let row = UIStackView(arrangedSubviews: [dot, title, detail])
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .firstBaseline
        if let model = phase.model {
            let badge = UILabel()
            badge.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
            badge.textColor = Theme.Color.accent
            badge.text = Self.shortModel(model)
            badge.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(badge)
        }
        return row
    }

    /// One agent, tappable: opening it is opening its own transcript, because a workflow agent is
    /// never its own chat and never gets a screen of its own to be lost behind.
    private func agentRow(_ agent: WorkflowAgent, at now: Date) -> UIView {
        let glyph = UIImageView(
            image: UIImage(
                systemName: agent.isCompleted ? "checkmark.circle.fill" : "circle.dotted",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
        glyph.tintColor = agent.isCompleted ? Theme.Color.success : Theme.Color.accent
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        let title = UILabel()
        title.font = .preferredFont(forTextStyle: .caption1)
        title.textColor = Theme.Color.label
        title.text = agent.title.replacingOccurrences(of: "\n", with: " ")
        title.lineBreakMode = .byTruncatingTail

        let row = UIStackView(arrangedSubviews: [glyph, title])
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .firstBaseline
        if agent.isActive, let tool = agent.currentTool {
            let live = UILabel()
            live.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
            live.textColor = Theme.Color.accent
            live.text = tool
            live.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(live)
        }
        if let elapsed = agent.elapsed(at: now) {
            let time = UILabel()
            time.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            time.textColor = Theme.Color.tertiaryLabel
            time.text = WorkflowRun.duration(elapsed)
            time.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(time)
        }

        let button = UIButton(type: .system)
        button.accessibilityLabel = agent.title
        button.addAction(
            UIAction { [weak self] _ in self?.onAgentTap?(agent.id) }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.topAnchor.constraint(equalTo: row.topAnchor),
            button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    /// A phase's model as a badge: the family, without the vendor prefix or the dated build that
    /// makes every badge the same width and none of them readable.
    private static func shortModel(_ model: String) -> String {
        var name = model
        if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
        let parts = name.split(separator: "-")
        let keep = parts.prefix { Int($0) == nil || $0.count < 3 }
        return keep.isEmpty ? name : keep.joined(separator: "-")
    }
}

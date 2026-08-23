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
    private let mark = ActivityBadgeView(pointSize: 12)
    private let column = UIStackView()
    private var fillWidth: NSLayoutConstraint?
    private var containerTop: NSLayoutConstraint!
    private var onAgentTap: ((String) -> Void)?
    private var phaseSignature: [String] = []
    private var phaseHandles: [PhaseHandle] = []
    private var agentIDs: [String] = []
    private var agentHandles: [AgentHandle] = []

    /// The pieces of one phase row a restate writes into: the marker, and the title it is read out
    /// with. The standing rides on the title rather than on the marker so the rail gains no extra
    /// stop for a reader going through it — one voice per phase, saying which phase and how it
    /// stands, instead of a dot that announces itself and a title that repeats the row.
    private struct PhaseHandle {
        let dot: UIImageView
        let title: UILabel
        let phase: WorkflowPhase
    }

    /// The mutable pieces of one agent row, kept so a reconfigure writes into them instead of
    /// rebuilding the row — a rebuilt row takes the button out from under a finger mid-tap.
    private struct AgentHandle {
        let glyph: ActivityBadgeView
        let title: UILabel
        let live: UILabel
        let time: UILabel
    }

    /// Extra gap above the card when this row opens a new turn.
    var turnInset: CGFloat = 0 {
        didSet { containerTop.constant = 4 + turnInset }
    }

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

        titleLabel.font = Theme.Ramp.font(.workflowName)
        titleLabel.textColor = Theme.Color.label
        titleLabel.adjustsFontForContentSizeCategory = true
        headlineLabel.font = Theme.Ramp.font(.workflowModel)
        headlineLabel.adjustsFontForContentSizeCategory = true
        headlineLabel.setContentHuggingPriority(.required, for: .horizontal)
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.textColor = Theme.Color.tertiaryLabel
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        summaryLabel.font = Theme.Ramp.font(.workflowSummary)
        summaryLabel.textColor = Theme.Color.secondaryLabel
        summaryLabel.numberOfLines = 3
        summaryLabel.adjustsFontForContentSizeCategory = true
        answerLabel.font = Theme.Ramp.font(.cardBody)
        answerLabel.textColor = Theme.Color.label
        answerLabel.numberOfLines = 0
        answerLabel.adjustsFontForContentSizeCategory = true
        meterLabel.font = Theme.Ramp.font(.workflowMeter)
        meterLabel.textColor = Theme.Color.tertiaryLabel
        meterLabel.setContentHuggingPriority(.required, for: .horizontal)

        track.backgroundColor = Theme.Color.accent.withAlphaComponent(0.18)
        track.layer.cornerRadius = 2
        track.translatesAutoresizingMaskIntoConstraints = false
        fill.backgroundColor = Theme.Color.accent
        fill.layer.cornerRadius = 2
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)

        mark.setContentHuggingPriority(.required, for: .horizontal)

        phaseStack.axis = .vertical
        phaseStack.spacing = 2
        agentStack.axis = .vertical
        agentStack.spacing = 4

        let header = UIStackView(arrangedSubviews: [
            iconView, titleLabel, UIView(), headlineLabel, mark, elapsedLabel,
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
        containerTop = container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            container.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            containerTop,
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
        summaryLabel.text = run.summary
        summaryLabel.isHidden = run.summary == nil
        elapsedLabel.text = run.elapsed(at: now).map(WorkflowRun.duration)
        elapsedLabel.isHidden = elapsedLabel.text == nil
        wearEnding(of: run)

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

        let phases = run.phases.map { "\($0.title)|\($0.detail ?? "")|\($0.model ?? "")" }
        if phases != phaseSignature {
            phaseSignature = phases
            phaseHandles = []
            rebuild(phaseStack) { stack in
                for phase in run.phases {
                    stack.addArrangedSubview(self.phaseRow(phase, run: run))
                }
            }
        }
        for handle in phaseHandles { Self.wear(run.phaseStanding, on: handle) }

        let ids = run.agents.map(\.id)
        if ids != agentIDs {
            agentIDs = ids
            agentHandles = []
            rebuild(agentStack) { stack in
                for agent in run.agents {
                    stack.addArrangedSubview(self.agentRow(agent))
                }
            }
        }
        for (handle, agent) in zip(agentHandles, run.agents) {
            update(handle, with: agent, in: run, at: now)
        }

        let answer = run.result?.trimmingCharacters(in: .whitespacesAndNewlines)
        answerLabel.text = answer.map { $0.count > 600 ? String($0.prefix(600)) + "…" : $0 }
        answerLabel.isHidden = (answer ?? "").isEmpty
    }

    /// The one mark this card wears, and the colours that have to agree with it.
    ///
    /// The face comes from the run rather than from a spinner this cell starts and stops itself:
    /// the call that launches a run answers in milliseconds while the work takes minutes, so
    /// nothing about the tool row is its progress, and only the run's own state knows the ending.
    /// Every ending in the vocabulary holds perfectly still, because a record that keeps moving
    /// reads as work that never ended. The rail takes the mark's tone with it — a run that was
    /// stopped no longer wears the green of a success nobody reported — and the headline is
    /// written in the ending's own voice, raised only where the run actually broke.
    private func wearEnding(of run: WorkflowRun) {
        let icon = run.activityIcon
        mark.show(icon, spoken: nil)
        rail.backgroundColor = run.isLive ? Theme.Color.accent : icon.tone.color
        let ended = icon.tone == .danger ? Theme.Color.danger : Theme.Color.secondaryLabel
        headlineLabel.textColor = run.isLive ? Theme.Color.accent : ended
    }

    private func rebuild(_ stack: UIStackView, _ build: (UIStackView) -> Void) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        build(stack)
        stack.isHidden = stack.arrangedSubviews.isEmpty
    }

    /// One phase row, wearing the standing the run's own state earns it.
    ///
    /// A run that was stopped or broke is not a run that got through its plan: nothing anywhere
    /// records which phase was current when it ended, so a rail that fills on any ending claims
    /// four finished phases for a four-phase script killed inside the first. Core decides which of
    /// the three readings applies and what each one looks like, so the three cards cannot disagree
    /// about a plan; a filled dot and a hollow one are the same silence to a screen reader, so the
    /// standing's own word is spoken over the phase it belongs to.
    private static func wear(_ standing: WorkflowPhaseStanding, on handle: PhaseHandle) {
        handle.dot.image = UIImage(
            systemName: standing.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 7, weight: .semibold))
        handle.dot.tintColor = standing.tone.color
        handle.title.accessibilityLabel = "\(handle.phase.title), \(standing.spoken)"
    }

    /// The phases the script declares, as the plan it is. Which phase an agent belongs to is only
    /// recorded by a finished run, so a live card never points at one — claiming a position the
    /// data cannot support is worse than showing the plan and the agents separately.
    private func phaseRow(_ phase: WorkflowPhase, run: WorkflowRun) -> UIView {
        let dot = UIImageView()
        dot.setContentHuggingPriority(.required, for: .horizontal)

        let title = UILabel()
        title.font = Theme.Ramp.font(.workflowStep)
        title.textColor = Theme.Color.label
        title.text = phase.title
        title.setContentHuggingPriority(.required, for: .horizontal)
        let handle = PhaseHandle(dot: dot, title: title, phase: phase)
        phaseHandles.append(handle)
        Self.wear(run.phaseStanding, on: handle)

        let detail = UILabel()
        detail.font = Theme.Ramp.font(.workflowModel)
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
    /// never its own chat and never gets a screen of its own to be lost behind. The live-tool and
    /// elapsed labels exist from the start and hide while empty, so a reconfigure only ever
    /// changes words — the row, and the button under a finger, are never rebuilt for a tick.
    private func agentRow(_ agent: WorkflowAgent) -> UIView {
        let glyph = ActivityBadgeView(pointSize: 11)
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        let title = UILabel()
        title.font = Theme.Ramp.font(.workflowStep)
        title.textColor = Theme.Color.label
        title.lineBreakMode = .byTruncatingTail

        let live = UILabel()
        live.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        live.textColor = Theme.Color.accent
        live.setContentHuggingPriority(.required, for: .horizontal)

        let time = UILabel()
        time.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        time.textColor = Theme.Color.tertiaryLabel
        time.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [glyph, title, live, time])
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .firstBaseline

        let button = UIButton(type: .system)
        button.accessibilityLabel = agent.title
        let agentID = agent.id
        button.addAction(
            UIAction { [weak self] _ in self?.onAgentTap?(agentID) }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.topAnchor.constraint(equalTo: row.topAnchor),
            button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        agentHandles.append(AgentHandle(glyph: glyph, title: title, live: live, time: time))
        return row
    }

    /// One agent row restated. The mark is read against the run rather than against the agent's
    /// own record: a sidecar goes on calling itself active for up to half an hour after the run
    /// around it ended, and the per-second restate that would ever re-ask is itself gated on the
    /// run being live — so a card left to the record alone sweeps its agents forever under a
    /// header that says the work stopped. The sentence and the caption follow the mark for the
    /// same reason: only an agent the mark shows as out is one VoiceOver may call working, or one
    /// this row may name a tool for.
    private func update(
        _ handle: AgentHandle, with agent: WorkflowAgent, in run: WorkflowRun, at now: Date
    ) {
        let icon = ActivityIcon.workflowAgent(agent, in: run)
        handle.glyph.show(
            icon, spoken: icon == .openWork ? String(localized: "Agent working") : nil)
        handle.title.text = agent.title.replacingOccurrences(of: "\n", with: " ")
        let tool = Self.liveTool(agent, wearing: icon)
        handle.live.text = tool
        handle.live.isHidden = tool == nil
        let elapsed = agent.elapsed(at: now)
        handle.time.text = elapsed.map(WorkflowRun.duration)
        handle.time.isHidden = elapsed == nil
    }

    /// The tool an agent is holding right now, which is the mark's answer rather than a second
    /// one this card works out for itself.
    ///
    /// A sidecar goes on naming the tool it was last seen on for as long as its reporting window
    /// lasts, which outlives the run by up to half an hour — so a row read from the agent alone
    /// would keep "WebFetch" lit beside a settled mark under a header that says the run is over.
    /// ``ActivityIcon/workflowAgent(_:in:)`` has already weighed the agent against its run: only
    /// the mark it hands back for an agent genuinely still out names a tool.
    private static func liveTool(_ agent: WorkflowAgent, wearing icon: ActivityIcon) -> String? {
        icon == .openWork ? agent.currentTool : nil
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

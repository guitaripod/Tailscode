import CodingAgentKit
import UIKit

/// What a run of agent steps says about itself on its one line: a lead in the ink of a name, a
/// detail in the quieter mono, and how the run stands. A run of one tool reads as that tool and
/// what it touched; a longer run, or one with thinking in it, reads as a count and the names.
struct ActivityLine: Equatable {
    enum Standing: Equatable {
        case done, working, failed
    }

    let lead: String
    let detail: String?
    let standing: Standing

    static func read(_ steps: [ActivityStep], streaming: Bool) -> ActivityLine {
        let calls = steps.compactMap { step -> ToolCall? in
            if case .tool(let call) = step { return call }
            return nil
        }
        let thoughts = steps.count - calls.count
        let failed = !streaming && calls.contains { $0.status == .error }
        let standing: Standing = streaming ? .working : (failed ? .failed : .done)
        if streaming, let last = steps.last {
            switch last {
            case .reasoning:
                return ActivityLine(lead: String(localized: "Thinking…"), detail: nil, standing: standing)
            case .tool(let call):
                if call.summary.kind == .question {
                    return ActivityLine(lead: stepName(call), detail: nil, standing: standing)
                }
                return ActivityLine(lead: call.name, detail: argument(of: call), standing: standing)
            }
        }
        if thoughts == 0, calls.count == 1, let call = calls.first {
            if call.summary.kind == .question {
                return ActivityLine(lead: stepName(call), detail: nil, standing: standing)
            }
            return ActivityLine(lead: call.name, detail: argument(of: call), standing: standing)
        }
        var lead: [String] = []
        if thoughts > 0 {
            lead.append(
                thoughts == 1
                    ? String(localized: "1 thought") : String(localized: "\(thoughts) thoughts"))
        }
        if calls.count > 1 {
            lead.append(String(localized: "\(calls.count) tools"))
        }
        let names = tally(calls)
        return ActivityLine(
            lead: lead.isEmpty ? String(localized: "\(steps.count) steps") : lead.joined(separator: " · "),
            detail: names.isEmpty ? nil : names, standing: standing)
    }

    /// A question the agent asked is named by the question, which is the point of the row.
    private static func stepName(_ call: ToolCall) -> String {
        guard call.summary.kind == .question, let question = call.summary.title else {
            return call.name
        }
        return String(localized: "Asked · \(question)")
    }

    /// What a call touched, on one line: its title, or the first line of its command.
    private static func argument(of call: ToolCall) -> String? {
        let summary = call.summary
        var text = summary.title ?? call.title ?? ""
        if text == call.name { text = "" }
        if text.hasPrefix(call.name + " ") { text = String(text.dropFirst(call.name.count + 1)) }
        if text.isEmpty, let command = summary.command {
            text = command.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? command
        }
        text = text.replacingOccurrences(of: "\n", with: " ")
        return text.isEmpty ? nil : String(text.prefix(160))
    }

    private static func tally(_ calls: [ToolCall]) -> String {
        var counted: [(name: String, count: Int)] = []
        for call in calls {
            let name = stepName(call)
            if let index = counted.firstIndex(where: { $0.name == name }) {
                counted[index].count += 1
            } else {
                counted.append((name, 1))
            }
        }
        let shown = counted.prefix(4).map { $0.count > 1 ? "\($0.name)×\($0.count)" : $0.name }
        let rest = counted.count - shown.count
        return shown.joined(separator: " ") + (rest > 0 ? " +\(rest)" : "")
    }
}

/// A run of consecutive agent actions (thinking + tool calls) as one flat line, with no plate and
/// no shadow: a mark for how the run stands, the name of what it did, and what it touched. It
/// grows into the roomy card, with the same steps it always held, only when opened.
///
/// The line is a 32-point row so a finger can hit it, with the 24-point visible line inside. A
/// running run breathes on the shared swell, a failed one is danger-toned while folded, and the
/// text grows with Dynamic Type instead of clipping.
final class ActivityGroupCell: UICollectionViewCell {
    static let reuseID = "ActivityGroupCell"

    private let container = UIView()
    private let glass = Theme.Glass.view()
    private let line = UIView()
    private let chevron = UIImageView()
    private let dot = UIView()
    private let failMark = UIImageView()
    private let liveMark = ActivityBadgeView(pointSize: 11)
    private let summaryLabel = UILabel()
    private let stack = UIStackView()
    private let toggle = UIButton(type: .system)
    private let renderer = ToolStepRenderer()
    private var onToggle: (() -> Void)?

    private var topConstraint: NSLayoutConstraint!
    private var foldedBottom: NSLayoutConstraint!
    private var openBottom: NSLayoutConstraint!
    private var stackTop: NSLayoutConstraint!

    private static let markSize: CGFloat = 14

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.layer.cornerRadius = Theme.Radius.card
        container.layer.cornerCurve = .continuous
        container.translatesAutoresizingMaskIntoConstraints = false

        glass.isUserInteractionEnabled = false
        glass.layer.cornerRadius = Theme.Radius.card
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.alpha = 0
        glass.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)

        line.translatesAutoresizingMaskIntoConstraints = false

        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.contentMode = .center
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        failMark.image = UIImage(
            systemName: "exclamationmark.triangle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        failMark.tintColor = Theme.Color.danger
        failMark.contentMode = .center
        failMark.translatesAutoresizingMaskIntoConstraints = false
        liveMark.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.isAccessibilityElement = false
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.addTarget(self, action: #selector(toggleTapped(_:event:)), for: .touchUpInside)
        toggle.answersPointer(cornerRadius: Theme.Radius.control)

        contentView.addSubview(container)
        container.addSubview(line)
        [chevron, dot, failMark, liveMark, summaryLabel].forEach(line.addSubview)
        container.addSubview(stack)
        container.addSubview(toggle)

        topConstraint = container.topAnchor.constraint(equalTo: contentView.topAnchor)
        foldedBottom = line.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        openBottom = stack.bottomAnchor.constraint(
            equalTo: container.bottomAnchor, constant: -Theme.Spacing.m)
        stackTop = stack.topAnchor.constraint(equalTo: line.bottomAnchor)
        let rowHeight = CGFloat(Theme.Chat.metrics.activityRowHeight)
        let mark = Self.markSize

        NSLayoutConstraint.activate([
            topConstraint,
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            container.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.s),
            container.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.s),

            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: rowHeight),
            foldedBottom,

            chevron.leadingAnchor.constraint(equalTo: line.leadingAnchor, constant: Theme.Spacing.s),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.centerYAnchor.constraint(equalTo: line.centerYAnchor),

            dot.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: Theme.Spacing.xs),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            failMark.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
            failMark.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            liveMark.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
            liveMark.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            liveMark.widthAnchor.constraint(equalToConstant: mark),

            summaryLabel.leadingAnchor.constraint(
                equalTo: chevron.trailingAnchor, constant: Theme.Spacing.xs + mark + Theme.Spacing.xs),
            summaryLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: line.trailingAnchor, constant: -Theme.Spacing.s),
            summaryLabel.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            summaryLabel.topAnchor.constraint(greaterThanOrEqualTo: line.topAnchor, constant: 4),
            summaryLabel.bottomAnchor.constraint(lessThanOrEqualTo: line.bottomAnchor, constant: -4),

            stackTop,
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),

            toggle.topAnchor.constraint(equalTo: container.topAnchor),
            toggle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toggle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var gapAbove: CGFloat = 0 {
        didSet { topConstraint.constant = gapAbove }
    }

    func configure(
        steps: [ActivityStep], expanded: Bool, streaming: Bool, compact: Bool,
        onToggle: @escaping () -> Void, onToolTap: ((ToolCall) -> Void)? = nil,
        onToolOpen: ((ToolCall) -> Bool)? = nil, onLinkTap: ((URL) -> Void)? = nil
    ) {
        self.onToggle = onToggle
        renderer.onToolTap = onToolTap
        renderer.onToolOpen = onToolOpen
        renderer.onLinkTap = onLinkTap
        let reading = ActivityLine.read(steps, streaming: streaming)
        show(reading, compact: compact)
        toggle.accessibilityLabel = summaryLabel.text
        toggle.accessibilityValue =
            expanded ? String(localized: "Expanded") : String(localized: "Collapsed")
        toggle.accessibilityHint = expanded
            ? String(localized: "Double tap to hide agent steps")
            : String(localized: "Double tap to show agent steps")
        chevron.transform = expanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        glass.alpha = expanded ? 1 : 0

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.isHidden = !expanded
        renderer.reset()
        foldedBottom.isActive = !expanded
        openBottom.isActive = expanded
        stackTop.constant = expanded ? Theme.Spacing.xs : 0
        if expanded {
            for step in steps { stack.addArrangedSubview(renderer.view(for: step)) }
        }
    }

    /// The line itself. Compact keeps the name in the toolName voice and the argument in the quiet
    /// mono; turning the compact switch off keeps the same flat line but sets the lead in the
    /// card-title voice, which is as much of "individual rows" as a flat line has.
    private func show(_ reading: ActivityLine, compact: Bool) {
        let leadColor = reading.standing == .failed ? Theme.Color.danger : Theme.Color.label
        let text = NSMutableAttributedString(
            string: reading.lead,
            attributes: Theme.Ramp.attributes(compact ? .toolName : .cardTitle, color: leadColor))
        if let detail = reading.detail {
            text.append(
                NSAttributedString(
                    string: "  " + detail,
                    attributes: Theme.Ramp.attributes(
                        .toolDetail, color: Theme.Color.secondaryLabel)))
        }
        summaryLabel.attributedText = text
        summaryLabel.numberOfLines =
            traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 0 : 1
        dot.isHidden = reading.standing != .done
        dot.backgroundColor = Theme.Color.success
        failMark.isHidden = reading.standing != .failed
        liveMark.show(
            reading.standing == .working ? .openWork : nil, spoken: String(localized: "Still working"))
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
        else { return }
        summaryLabel.numberOfLines =
            traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 0 : 1
    }

    /// The whole line is one button — a gesture recognizer here would lose
    /// the recognition race against the chat's keyboard-dismiss tap, so the
    /// step rows stay non-interactive and taps dispatch by touch location:
    /// a subagent-spawn or link row runs its action, anywhere else toggles.
    @objc private func toggleTapped(_ sender: UIButton, event: UIEvent) {
        if let touch = event.allTouches?.first,
            renderer.handleTap(at: touch.location(in: container), in: container)
        {
            Theme.Haptics.tap()
            return
        }
        Theme.Haptics.selection()
        onToggle?()
    }
}

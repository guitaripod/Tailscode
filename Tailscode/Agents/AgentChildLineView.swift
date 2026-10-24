import TailscodeCore
import UIKit

/// One agent hanging under a session: a subagent with the words for what it is doing and how far
/// through its todos it is, or the background task with its age. Never a chat of its own.
@MainActor
final class AgentChildLineView: UIView {
    private let badgeBox = UIView()
    private let badge = ActivityBadgeView(pointSize: 11)
    private let textLabel = UILabel()
    private let todoBar = AgentTodoBarView()
    private let todoLabel = UILabel()
    private let ageLabel = UILabel()
    private let trailing = UIStackView()
    private let row = UIStackView()
    private var startedAt: Date?
    private var todos: (done: Int, total: Int)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeBox.addSubview(badge)
        NSLayoutConstraint.activate([
            badgeBox.widthAnchor.constraint(equalToConstant: 18),
            badge.centerXAnchor.constraint(equalTo: badgeBox.centerXAnchor),
            badge.topAnchor.constraint(equalTo: badgeBox.topAnchor, constant: 1),
        ])

        textLabel.numberOfLines = 2
        textLabel.adjustsFontForContentSizeCategory = true

        todoLabel.font = Theme.Ramp.font(.rowStamp)
        todoLabel.textColor = Theme.Color.secondaryLabel
        todoLabel.adjustsFontForContentSizeCategory = true
        ageLabel.font = Theme.Ramp.font(.rowStamp)
        ageLabel.textColor = Theme.Color.tertiaryLabel
        ageLabel.adjustsFontForContentSizeCategory = true

        trailing.axis = .horizontal
        trailing.alignment = .center
        trailing.spacing = Theme.Spacing.s
        [todoBar, todoLabel, ageLabel].forEach(trailing.addArrangedSubview)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.axis = .horizontal
        row.alignment = .top
        row.spacing = Theme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        [badgeBox, textLabel, trailing].forEach(row.addArrangedSubview)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ child: AgentChild, now: Date) {
        startedAt = child.startedAt
        todos = child.todos
        badge.show(AgentGlyph.icon(for: child), spoken: nil)

        let text = NSMutableAttributedString(
            string: child.title,
            attributes: [
                .font: Theme.Ramp.font(.rowTitleStrong).withSize(Theme.Ramp.font(.rowDetail).pointSize),
                .foregroundColor: Theme.Color.label,
            ])
        text.append(
            NSAttributedString(
                string: " " + child.line,
                attributes: [
                    .font: Theme.Ramp.font(.rowDetail), .foregroundColor: Theme.Color.secondaryLabel,
                ]))
        textLabel.attributedText = text

        if let todos = child.todos {
            todoBar.todos = todos
            todoLabel.text = "\(todos.done)/\(todos.total)"
        }
        todoBar.isHidden = child.todos == nil || AgentsLayout.isLarge(traitCollection)
        todoLabel.isHidden = child.todos == nil
        ageLabel.isHidden = child.todos != nil || child.startedAt == nil
        tick(now: now)
    }

    func tick(now: Date) {
        guard !ageLabel.isHidden else { return }
        ageLabel.text = AgentsWords.elapsed(since: startedAt, now: now)
    }

    func spoken(now: Date) -> String {
        var parts = [textLabel.attributedText?.string ?? ""]
        if let todos { parts.append(AgentsWords.todosSpoken(todos)) }
        if let startedAt, !ageLabel.isHidden {
            parts.append(String(localized: "for \(AgentsWords.spokenAge(startedAt, now: now))"))
        }
        return parts.joined(separator: ", ")
    }
}

import TailscodeCore
import UIKit

/// The face of a turn the machine was pulled out from under. A card at the end of the transcript,
/// not a bubble: nothing was said, and the point of it is the account of what the work had already
/// done. It holds perfectly still — nothing is running — and while it is undecided it offers
/// exactly two things to do.
///
/// It also says what leaving it undecided costs, because it costs something: the server will not
/// carry the session on by itself while the card stands, and nothing else anywhere says so.
final class InterruptedTurnCell: UICollectionViewCell {
    static let reuseID = "InterruptedTurnCell"

    private let card = UIView()
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let promptLabel = UILabel()
    private let progressStack = UIStackView()
    private let queuedLabel = UILabel()
    private let costLabel = UILabel()
    private let resume = UIButton(type: .system)
    private let dismiss = UIButton(type: .system)
    private let actions = UIStackView()
    private var turn: InterruptedTurn?
    private var onResume: (() -> Void)?
    private var onDismiss: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        card.backgroundColor = Theme.Color.secondaryBackground
        card.layer.cornerRadius = Theme.Radius.card
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = InterruptedTurn.tone.color.withAlphaComponent(0.35).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        icon.image = UIImage(
            systemName: InterruptedTurn.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        icon.tintColor = InterruptedTurn.tone.color
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0

        let header = UIStackView(arrangedSubviews: [icon, titleLabel])
        header.axis = .horizontal
        header.alignment = .firstBaseline
        header.spacing = Theme.Spacing.s

        promptLabel.font = Theme.Ramp.font(.prompt)
        promptLabel.adjustsFontForContentSizeCategory = true
        promptLabel.textColor = Theme.Color.label
        promptLabel.numberOfLines = 3

        detailLabel.font = Theme.Ramp.font(.panelDetail)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.numberOfLines = 0

        progressStack.axis = .vertical
        progressStack.alignment = .leading
        progressStack.spacing = 2

        queuedLabel.font = Theme.Ramp.font(.rowNote)
        queuedLabel.adjustsFontForContentSizeCategory = true
        queuedLabel.textColor = Theme.Color.secondaryLabel
        queuedLabel.numberOfLines = 0

        costLabel.font = Theme.Ramp.font(.rowNote)
        costLabel.adjustsFontForContentSizeCategory = true
        costLabel.textColor = InterruptedTurn.tone.color
        costLabel.numberOfLines = 0

        var resumeConfig = Theme.Glass.buttonConfiguration()
        resumeConfig.cornerStyle = .capsule
        resumeConfig.buttonSize = .small
        resume.configuration = resumeConfig
        resume.addAction(UIAction { [weak self] _ in self?.pickUp() }, for: .touchUpInside)

        var dismissConfig = UIButton.Configuration.plain()
        dismissConfig.cornerStyle = .capsule
        dismissConfig.buttonSize = .small
        dismiss.configuration = dismissConfig
        dismiss.tintColor = Theme.Color.secondaryLabel
        dismiss.addAction(UIAction { [weak self] _ in self?.letGo() }, for: .touchUpInside)

        actions.axis = .horizontal
        actions.alignment = .center
        actions.spacing = Theme.Spacing.s
        actions.addArrangedSubview(resume)
        actions.addArrangedSubview(dismiss)

        let stack = UIStackView(arrangedSubviews: [
            header, promptLabel, detailLabel, progressStack, queuedLabel, costLabel, actions,
        ])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.xs
        for last in [progressStack, queuedLabel, costLabel] as [UIView] {
            stack.setCustomSpacing(Theme.Spacing.s, after: last)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            card.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            card.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            card.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Spacing.m),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.Spacing.m),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Spacing.m),
            stack.trailingAnchor.constraint(
                equalTo: card.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        turn = nil
        onResume = nil
        onDismiss = nil
    }

    func configure(_ turn: InterruptedTurn, onResume: (() -> Void)?, onDismiss: (() -> Void)?) {
        self.onResume = onResume
        self.onDismiss = onDismiss
        draw(turn)
    }

    /// The one place the card becomes pixels, so what a press draws and what an answer draws
    /// cannot drift apart. Every word on it is Core's; this decides only what is on screen.
    ///
    /// A card the server has picked back up offers nothing: the work is going again, so "let it
    /// go" would mean forgetting the record rather than stopping anything, and a button that
    /// cannot do what its words say is worse than no button. A press still in flight keeps both,
    /// disabled, because seeing what was asked for is the point of the acknowledgement.
    private func draw(_ turn: InterruptedTurn) {
        self.turn = turn
        titleLabel.text = turn.title
        promptLabel.text = turn.prompt
        promptLabel.isHidden = turn.prompt.isEmpty
        detailLabel.text = turn.detail
        for view in progressStack.arrangedSubviews { view.removeFromSuperview() }
        for line in turn.progress { progressStack.addArrangedSubview(Self.line(line)) }
        queuedLabel.text = turn.queuedLine
        queuedLabel.isHidden = turn.queuedLine == nil
        costLabel.text = turn.cost
        costLabel.isHidden = turn.cost == nil
        resume.configuration?.title = turn.resumeTitle
        resume.isHidden = turn.isResumed || onResume == nil
        resume.isEnabled = turn.acceptsPress
        dismiss.configuration?.title = turn.dismissTitle
        dismiss.isHidden = turn.isResumed || onDismiss == nil
        dismiss.isEnabled = turn.acceptsPress
        actions.isHidden = resume.isHidden && dismiss.isHidden
        card.layer.borderColor = InterruptedTurn.tone.color.withAlphaComponent(0.35).cgColor
        isAccessibilityElement = true
        accessibilityLabel = turn.spoken
        accessibilityTraits = .staticText
    }

    private static func line(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = Theme.Ramp.font(.rowNote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.secondaryLabel
        label.numberOfLines = 0
        label.text = "· \(text)"
        return label
    }

    /// Answers the press on the card itself, before the network can.
    ///
    /// The server's word is a second or two away over a tailnet and may never arrive at all. A
    /// button that looks exactly as it did before that answer lands tells the person their press
    /// did nothing, so the card is redrawn at once in Core's own in-flight state: the button
    /// renames itself, both stop taking a second press, and the server's answer only ever replaces
    /// what is already on screen.
    private func acknowledge(_ press: InterruptedTurnPress) -> Bool {
        guard let turn, turn.acceptsPress else { return false }
        draw(InterruptedTurnReading.pressed(turn, press))
        return true
    }

    private func pickUp() {
        guard acknowledge(.pickUp) else { return }
        Theme.Haptics.send()
        onResume?()
    }

    private func letGo() {
        guard acknowledge(.letGo) else { return }
        Theme.Haptics.selection()
        onDismiss?()
    }
}

import CodingAgentKit
import TailscodeCore
import UIKit

/// What the ask lane says while its box is empty.
///
/// The argument the quick ask has always had to make is that the thing on the other end reads
/// pictures, makes them, searches, drafts and translates — that it is a way into everything the
/// agent can do and not only a place to type. A summoned sheet made that argument in rows down an
/// empty screen. A docked bar has no empty screen to spend, so it makes the same argument sideways:
/// one strip of chips above the box, starters first and the questions already asked on that machine
/// behind them, scrolling out of the way rather than pushing the board off the top.
///
/// Nothing here ever sends. A starter is the first half of a sentence and lands in the box with the
/// caret at its end; a recent reopens the conversation it names. A question the app wrote and sent
/// on somebody's behalf is the one thing this lane must never do.
@MainActor
final class HomeAskSuggestions: UIView {
    var onStarter: ((QuickAskStarter) -> Void)?
    var onRecent: ((SessionEntry) -> Void)?

    private let scrollView = UIScrollView()
    private let row = UIStackView()
    private var applied: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentInset = UIEdgeInsets(
            top: 0, left: Theme.Spacing.l, bottom: 0, right: Theme.Spacing.l)
        addSubview(scrollView)

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.xs
        row.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(row)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            scrollView.heightAnchor.constraint(equalTo: row.heightAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Redrawn only when the offer actually changed: this is rebuilt on every keystroke's worth of
    /// state churn, and rebuilding a scroll view's contents under a finger throws away where the
    /// person had scrolled to.
    func update(starters: [QuickAskStarter], recents: [SessionEntry], note: String?) {
        let identity =
            (note ?? "") + "|" + starters.map(\.id).joined(separator: ",") + "|"
            + recents.map(\.session.id).joined(separator: ",")
        guard identity != applied else { return }
        applied = identity
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let note {
            row.addArrangedSubview(label(note))
            return
        }
        if !starters.isEmpty { row.addArrangedSubview(label(QuickAskWords.offer)) }
        for starter in starters {
            row.addArrangedSubview(
                chip(symbol: starter.symbol, title: starter.title) {
                    [weak self] in self?.onStarter?(starter)
                })
        }
        guard !recents.isEmpty else { return }
        row.addArrangedSubview(label(QuickAskWords.asked))
        for entry in recents {
            row.addArrangedSubview(
                chip(symbol: "clock.arrow.circlepath", title: Self.title(of: entry)) {
                    [weak self] in self?.onRecent?(entry)
                })
        }
    }

    private static func title(of entry: SessionEntry) -> String {
        AgentSession.isPlaceholderTitle(entry.session.title)
            ? QuickAskWords.untitled : entry.session.title
    }

    private func label(_ text: String) -> UILabel {
        let view = UILabel()
        view.text = text
        view.font = Theme.Ramp.font(.sectionLabel)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = Theme.Color.tertiaryLabel
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }

    /// Ink on glass is left to the glass. The system maps a tint through whatever is behind the
    /// pane and picks the ink to match, so a colour chosen here would be a guess about a surface
    /// that does not exist yet — the symbol carries which kind of chip this is.
    private func chip(symbol: String, title: String, action: @escaping () -> Void) -> UIButton {
        var config = Theme.Glass.buttonConfiguration()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.imagePadding = Theme.Spacing.xs
        config.titleLineBreakMode = .byTruncatingTail
        config.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        var name = AttributedString(title)
        name.font = Theme.Ramp.font(.sectionLabel)
        config.attributedTitle = name
        let button = UIButton(configuration: config)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        return button
    }
}

/// The pictures and files waiting to ride with the next message. One removable chip each, read
/// fully at pick time, sitting between the suggestions and the box so what is in hand is never
/// further from the send button than the words are.
@MainActor
final class HomeAttachmentStrip: UIView {
    var onRemove: ((UUID) -> Void)?

    private let scrollView = UIScrollView()
    private let row = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentInset = UIEdgeInsets(
            top: 0, left: Theme.Spacing.l, bottom: 0, right: Theme.Spacing.l)
        addSubview(scrollView)

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(row)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            scrollView.heightAnchor.constraint(equalTo: row.heightAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func update(_ attachments: [PendingAttachment]) {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for attachment in attachments {
            let image =
                attachment.mime.hasPrefix("image/") ? UIImage(data: attachment.data) : nil
            let id = attachment.id
            row.addArrangedSubview(
                AttachmentChip(
                    label:
                        "\(attachment.name) · \(AttachmentIntake.sizeText(attachment.data.count))",
                    image: image
                ) { [weak self] in self?.onRemove?(id) })
        }
    }
}

/// Why the conversation did not start, said where the asking happened.
///
/// A mint that fails on the front door used to be an alert over the board — a modal about a
/// machine, on a screen full of machines, with nothing to do about it but agree. This is the same
/// diagnosis the sheets show, sized for the gap above a docked bar: what happened, what to do, and
/// the one press that does it. The words in the box are never touched, so agreeing costs nothing
/// and disagreeing costs nothing either.
@MainActor
final class HomeComposerFailureCard: UIView {
    var onFix: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let glass = Theme.Glass.view()
    private let symbol = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.layer.cornerRadius = Theme.Radius.card
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        symbol.contentMode = .scaleAspectFit
        symbol.tintColor = Theme.Color.danger
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 17, weight: .semibold)
        symbol.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = Theme.Ramp.font(.rowTitleStrong)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2

        detailLabel.font = Theme.Ramp.font(.panelDetail)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.numberOfLines = 3

        var close = UIButton.Configuration.plain()
        close.contentInsets = .zero
        close.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        close.baseForegroundColor = Theme.Color.tertiaryLabel
        closeButton.configuration = close
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.accessibilityLabel = String(localized: "Dismiss")
        closeButton.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .touchUpInside)

        var action = UIButton.Configuration.borderedProminent()
        action.cornerStyle = .capsule
        action.buttonSize = .small
        action.baseBackgroundColor = Theme.Color.accent
        action.baseForegroundColor = Theme.Color.onAccent
        actionButton.configuration = action
        actionButton.addAction(UIAction { [weak self] _ in self?.onFix?() }, for: .touchUpInside)

        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.spacing = 2

        let head = UIStackView(arrangedSubviews: [symbol, text, closeButton])
        head.axis = .horizontal
        head.alignment = .top
        head.spacing = Theme.Spacing.s

        let actionRow = UIStackView(arrangedSubviews: [actionButton, UIView()])
        actionRow.axis = .horizontal

        let stack = UIStackView(arrangedSubviews: [head, actionRow])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(
                equalTo: glass.contentView.topAnchor, constant: Theme.Spacing.m),
            stack.leadingAnchor.constraint(
                equalTo: glass.contentView.leadingAnchor, constant: Theme.Spacing.m),
            stack.trailingAnchor.constraint(
                equalTo: glass.contentView.trailingAnchor, constant: -Theme.Spacing.m),
            stack.bottomAnchor.constraint(
                equalTo: glass.contentView.bottomAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ failure: NewChatFailure) {
        symbol.image = UIImage(systemName: failure.symbol)
        titleLabel.text = failure.title
        detailLabel.text = failure.detail
        if let title = failure.actionTitle {
            actionButton.isHidden = false
            actionButton.configuration?.title = title
        } else {
            actionButton.isHidden = true
        }
        accessibilityLabel = failure.spoken
        isAccessibilityElement = false
    }
}

/// The video lane's own furniture: every setting the board can walk, worn as chips under the box
/// so a render is composed without leaving the keyboard — and the road into the full surface at
/// the end of the row. The values are the board's own words, and a tap is the same walk the
/// board's rows answer, so the composer and the forge can never disagree about the next render.
@MainActor
final class HomeVideoChips: UIView {
    var onCycle: ((ForgeField) -> Void)?
    var onOpen: (() -> Void)?

    private let scrollView = UIScrollView()
    private let row = UIStackView()
    private var applied: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentInset = UIEdgeInsets(
            top: 0, left: Theme.Spacing.l, bottom: 0, right: Theme.Spacing.l)
        addSubview(scrollView)

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.xs
        row.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(row)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            scrollView.heightAnchor.constraint(equalTo: row.heightAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Redrawn only when a value actually changed, because this is rebuilt on every snapshot off
    /// the render socket and a scroll view rebuilt under a finger forgets where it was.
    func update(board: ForgeBoard) {
        let fields = QuickAskLane.videoChips
        let identity = fields.map { "\($0.rawValue)=\(board.value(of: $0))" }
            .joined(separator: "|") + "|\(board.isBusy)"
        guard identity != applied else { return }
        applied = identity
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for field in fields {
            let chip = chip(symbol: field.symbol, title: board.value(of: field)) {
                [weak self] in self?.onCycle?(field)
            }
            chip.isEnabled = !board.isBusy
            chip.accessibilityLabel = "\(field.label), \(board.value(of: field))"
            row.addArrangedSubview(chip)
        }
        let open = chip(symbol: "slider.horizontal.3", title: ForgeSurface.title) {
            [weak self] in self?.onOpen?()
        }
        open.accessibilityLabel = ForgeSurface.title
        row.addArrangedSubview(open)
    }

    private func chip(
        symbol: String, title: String, action: @escaping () -> Void
    ) -> UIButton {
        var config = Theme.Glass.buttonConfiguration()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.imagePadding = Theme.Spacing.xs
        config.titleLineBreakMode = .byTruncatingTail
        config.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        var name = AttributedString(title)
        name.font = Theme.Ramp.font(.sectionLabel)
        config.attributedTitle = name
        let button = UIButton(configuration: config)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        return button
    }
}

import TailscodeCore
import UIKit

/// The whole account behind the chip's one price: what the conversation cost, which turns were
/// expensive, where the money went between fresh tokens and cache, and which model spent it.
///
/// Every number is `SessionSpend`'s — the same five sections the desks draw, in a sheet, because a
/// phone has no band to hang a popover from. The turn chart carries it: spend is never evenly
/// spread, and the three turns that cost more than the other forty are the ones worth seeing.
final class SpendViewController: UIViewController {
    private let spend: SessionSpend
    private let chatTitle: String
    private let scroll = UIScrollView()
    private let column = UIStackView()

    private static let chartHeight: CGFloat = 84
    private static let barWidth: CGFloat = 8

    init(spend: SessionSpend, title: String) {
        self.spend = spend
        self.chatTitle = title
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        title = String(localized: "What this cost")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })

        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        column.alignment = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.m, leading: Theme.Spacing.m, bottom: Theme.Spacing.xl,
            trailing: Theme.Spacing.m)

        column.addArrangedSubview(header())
        if !spend.turns.isEmpty { column.addArrangedSubview(chart()) }
        if !spend.tiers.isEmpty { column.addArrangedSubview(tiers()) }
        if spend.models.count > 1 { column.addArrangedSubview(models()) }
        column.addArrangedSubview(expensive())
        let source = UILabel()
        source.text = spend.source
        source.font = .preferredFont(forTextStyle: .caption2)
        source.textColor = Theme.Color.tertiaryLabel
        source.numberOfLines = 0
        column.addArrangedSubview(source)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            column.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            column.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
    }

    /// The number, then the facts that make it mean something.
    private func header() -> UIView {
        let name = label(chatTitle, style: .caption1, color: Theme.Color.secondaryLabel)
        name.numberOfLines = 1
        name.lineBreakMode = .byTruncatingTail
        let money = UILabel()
        money.text = spend.badge
        money.font = .systemFont(ofSize: 40, weight: .bold)
        money.textColor = Theme.Color.label
        money.adjustsFontSizeToFitWidth = true
        money.minimumScaleFactor = 0.6

        let facts = UIStackView()
        facts.axis = .horizontal
        facts.distribution = .fillEqually
        facts.spacing = Theme.Spacing.s
        for (caption, value) in spend.headline {
            let cell = UIStackView(arrangedSubviews: [
                label(value, style: .subheadline, color: Theme.Color.label, bold: true),
                label(caption.uppercased(), style: .caption2, color: Theme.Color.tertiaryLabel),
            ])
            cell.axis = .vertical
            cell.spacing = 1
            facts.addArrangedSubview(cell)
        }
        return card([name, money, facts])
    }

    /// One bar per turn, oldest first, each as tall as it cost against the priciest.
    private func chart() -> UIView {
        let bars = UIStackView()
        bars.axis = .horizontal
        bars.alignment = .bottom
        bars.spacing = 2
        for turn in spend.turns {
            let bar = UIView()
            bar.backgroundColor = turn.share > 0.66 ? Theme.Color.accent : Theme.Color.info
            bar.layer.cornerRadius = 2
            bar.isAccessibilityElement = true
            bar.accessibilityLabel = tooltip(for: turn)
            bar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: Self.barWidth),
                bar.heightAnchor.constraint(
                    equalToConstant: max(2, Self.chartHeight * turn.share)),
            ])
            bars.addArrangedSubview(bar)
        }
        let strip = UIScrollView()
        strip.showsHorizontalScrollIndicator = false
        strip.translatesAutoresizingMaskIntoConstraints = false
        bars.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(bars)
        NSLayoutConstraint.activate([
            strip.heightAnchor.constraint(equalToConstant: Self.chartHeight + 4),
            bars.leadingAnchor.constraint(equalTo: strip.contentLayoutGuide.leadingAnchor),
            bars.trailingAnchor.constraint(equalTo: strip.contentLayoutGuide.trailingAnchor),
            bars.bottomAnchor.constraint(equalTo: strip.contentLayoutGuide.bottomAnchor),
            bars.heightAnchor.constraint(equalToConstant: Self.chartHeight),
        ])

        var views: [UIView] = [
            heading(
                String(localized: "Turn by turn"),
                trailing: String(localized: "\(spend.turnCount) turns")),
            strip,
        ]
        if let first = spend.turns.first?.at, let last = spend.turns.last?.at {
            let span = UIStackView(arrangedSubviews: [
                label(
                    first.formatted(.dateTime.hour().minute()), style: .caption2,
                    color: Theme.Color.tertiaryLabel),
                UIView(),
                label(
                    last.formatted(.dateTime.hour().minute()), style: .caption2,
                    color: Theme.Color.tertiaryLabel),
            ])
            span.axis = .horizontal
            views.append(span)
        }
        return card(views)
    }

    private func tiers() -> UIView {
        var views: [UIView] = [
            heading(
                String(localized: "Where it went"),
                trailing: String(localized: "\(StatusFacts.tokens(spend.totalTokens)) tokens"))
        ]
        for tier in spend.tiers {
            views.append(
                meter(
                    label: tier.label, value: SessionSpend.money(tier.costUSD),
                    detail: StatusFacts.tokens(tier.tokens), fraction: tier.share,
                    hot: tier.id == "output"))
        }
        return card(views)
    }

    private func models() -> UIView {
        var views: [UIView] = [heading(String(localized: "Which model"), trailing: nil)]
        for model in spend.models {
            views.append(
                meter(
                    label: model.label, value: SessionSpend.money(model.costUSD),
                    detail: String(localized: "\(model.turns) turns"), fraction: model.share,
                    hot: false))
        }
        return card(views)
    }

    /// The turns worth remembering, with the words that started them.
    private func expensive() -> UIView {
        var views: [UIView] = [heading(String(localized: "The expensive ones"), trailing: nil)]
        let ranked = spend.turns.sorted { $0.costUSD > $1.costUSD }.prefix(5)
        if ranked.isEmpty {
            views.append(
                label(
                    String(localized: "Nothing has been spent yet."), style: .footnote,
                    color: Theme.Color.secondaryLabel))
        }
        for turn in ranked {
            let money = label(
                SessionSpend.money(turn.costUSD), style: .subheadline, color: Theme.Color.label,
                bold: true)
            money.setContentHuggingPriority(.required, for: .horizontal)
            money.setContentCompressionResistancePriority(.required, for: .horizontal)
            let prompt = label(
                turn.prompt ?? String(localized: "a turn with no prompt of its own"),
                style: .footnote, color: Theme.Color.secondaryLabel)
            prompt.numberOfLines = 2
            let row = UIStackView(arrangedSubviews: [money, prompt])
            row.axis = .horizontal
            row.spacing = Theme.Spacing.s
            row.alignment = .firstBaseline
            views.append(row)
        }
        return card(views)
    }

    private func heading(_ text: String, trailing: String?) -> UIView {
        var views: [UIView] = [
            label(text, style: .headline, color: Theme.Color.label), UIView(),
        ]
        if let trailing {
            views.append(label(trailing, style: .caption2, color: Theme.Color.tertiaryLabel))
        }
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.spacing = Theme.Spacing.s
        row.alignment = .firstBaseline
        return row
    }

    private func meter(
        label name: String, value: String, detail: String, fraction: Double, hot: Bool
    ) -> UIView {
        let title = label(name, style: .footnote, color: Theme.Color.label)
        let count = label(detail, style: .caption2, color: Theme.Color.tertiaryLabel)
        count.setContentHuggingPriority(.required, for: .horizontal)
        let money = label(value, style: .subheadline, color: Theme.Color.label, bold: true)
        money.setContentHuggingPriority(.required, for: .horizontal)
        let top = UIStackView(arrangedSubviews: [title, UIView(), count, money])
        top.axis = .horizontal
        top.spacing = Theme.Spacing.s
        top.alignment = .firstBaseline

        let track = UIView()
        track.backgroundColor = Theme.Color.separator
        track.layer.cornerRadius = 3
        track.translatesAutoresizingMaskIntoConstraints = false
        let fill = UIView()
        fill.backgroundColor = hot ? Theme.Color.accent : Theme.Color.info
        fill.layer.cornerRadius = 3
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        NSLayoutConstraint.activate([
            track.heightAnchor.constraint(equalToConstant: 6),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(
                equalTo: track.widthAnchor, multiplier: max(0.01, min(1, fraction))),
        ])

        let block = UIStackView(arrangedSubviews: [top, track])
        block.axis = .vertical
        block.spacing = 4
        block.isAccessibilityElement = true
        block.accessibilityLabel = "\(name), \(value), \(detail)"
        return block
    }

    private func card(_ views: [UIView]) -> UIView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.m, leading: Theme.Spacing.m, bottom: Theme.Spacing.m,
            trailing: Theme.Spacing.m)
        stack.backgroundColor = Theme.Color.secondaryBackground
        stack.layer.cornerRadius = Theme.Radius.card
        stack.layer.cornerCurve = .continuous
        return stack
    }

    private func label(
        _ text: String, style: UIFont.TextStyle, color: UIColor, bold: Bool = false
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = bold
            ? .preferredFont(forTextStyle: style).withTraits(.traitBold)
            : .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func tooltip(for turn: SessionSpend.Turn) -> String {
        var parts = [
            SessionSpend.money(turn.costUSD),
            String(localized: "\(StatusFacts.tokens(turn.tokens)) tokens"),
        ]
        if let seconds = turn.seconds { parts.append(SessionSpend.duration(seconds)) }
        if let prompt = turn.prompt { parts.append(prompt) }
        return parts.joined(separator: ", ")
    }
}

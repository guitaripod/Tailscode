import AppKit
import TailscodeCore

/// The whole account behind the band's one price, in a popover off the price itself: what the
/// conversation cost, which turns were expensive, where the money went between fresh tokens and
/// cache, and which model spent it.
///
/// Every number is `SessionSpend`'s; this decides only how tall a bar is. The turn chart carries
/// the panel — spend is never evenly spread, and the three turns that cost more than the other
/// forty are the ones worth seeing.
@MainActor
final class SpendPanelViewController: NSViewController {
    private let spend: SessionSpend
    private let chatTitle: String

    private static let chartHeight: CGFloat = 76
    private static let barWidth: CGFloat = 7
    private static let trackWidth: CGFloat = 300

    init(spend: SessionSpend, title: String) {
        self.spend = spend
        self.chatTitle = title
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = FillingStack()
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        column.translatesAutoresizingMaskIntoConstraints = false

        column.addArrangedSubview(header())
        if !spend.turns.isEmpty { column.addArrangedSubview(chart()) }
        if !spend.tiers.isEmpty { column.addArrangedSubview(tiers()) }
        if spend.models.count > 1 { column.addArrangedSubview(models()) }
        column.addArrangedSubview(expensive())
        column.addArrangedSubview(
            RowKit.label(spend.source, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel))

        let clip = RowKit.FlippedClip()
        clip.drawsBackground = false
        let scroll = NSScrollView()
        scroll.contentView = clip
        scroll.documentView = column
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            column.topAnchor.constraint(equalTo: clip.topAnchor),
            column.widthAnchor.constraint(equalTo: clip.widthAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 400),
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
        view = container
    }

    /// The number, then the facts that make it mean something. The estimate warning sits under the
    /// money, because it is the money it qualifies.
    private func header() -> NSView {
        let name = RowKit.label(
            chatTitle, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel)
        name.lineBreakMode = .byTruncatingTail
        let money = RowKit.label(
            spend.badge, font: MacTheme.Ramp.font(.metricLarge),
            color: MacTheme.Color.label)

        let facts = NSStackView()
        facts.orientation = .horizontal
        facts.spacing = MacTheme.Spacing.l
        facts.alignment = .top
        for (label, value) in spend.headline {
            let caption = NSTextField(
                labelWithAttributedString: NSAttributedString(
                    string: label.uppercased(),
                    attributes: MacTheme.Ramp.attributes(
                        .metricLabel, color: MacTheme.Color.tertiaryLabel)))
            caption.translatesAutoresizingMaskIntoConstraints = false
            let cell = NSStackView(views: [
                RowKit.label(value, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label),
                caption,
            ])
            cell.orientation = .vertical
            cell.alignment = .leading
            cell.spacing = 1
            facts.addArrangedSubview(cell)
        }

        return card(views: [name, money, facts])
    }

    private func chart() -> NSView {
        let bars = NSStackView()
        bars.orientation = .horizontal
        bars.alignment = .bottom
        bars.spacing = 2
        for turn in spend.turns {
            let bar = BarView(
                fill: turn.share > 0.66 ? MacTheme.Color.accent : MacTheme.Color.info)
            bar.toolTip = tooltip(for: turn)
            bar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: Self.barWidth),
                bar.heightAnchor.constraint(
                    equalToConstant: max(2, Self.chartHeight * turn.share)),
            ])
            bars.addArrangedSubview(bar)
        }
        bars.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.documentView = bars
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: Self.chartHeight + 8),
            scroll.widthAnchor.constraint(equalToConstant: Self.trackWidth + 40),
            bars.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            bars.topAnchor.constraint(equalTo: clip.topAnchor),
            bars.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            bars.trailingAnchor.constraint(greaterThanOrEqualTo: clip.trailingAnchor),
        ])

        var views: [NSView] = [
            heading(
                Localized.text("Turn by turn"),
                trailing: Localized.text("%@ turns", "\(spend.turnCount)")),
            scroll,
        ]
        if let first = spend.turns.first?.at, let last = spend.turns.last?.at {
            let span = NSStackView(views: [
                RowKit.label(
                    Self.clock(first), font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.tertiaryLabel),
                RowKit.spacer(),
                RowKit.label(
                    Self.clock(last), font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.tertiaryLabel),
            ])
            span.orientation = .horizontal
            views.append(span)
        }
        return card(views: views)
    }

    private func tiers() -> NSView {
        var views: [NSView] = [
            heading(
                Localized.text("Where it went"),
                trailing: Localized.text("%@ tokens", StatusFacts.tokens(spend.totalTokens)))
        ]
        for tier in spend.tiers {
            views.append(
                meter(
                    label: tier.label, value: SessionSpend.money(tier.costUSD),
                    detail: StatusFacts.tokens(tier.tokens), fraction: tier.share,
                    hot: tier.id == "output"))
        }
        return card(views: views)
    }

    private func models() -> NSView {
        var views: [NSView] = [heading(Localized.text("Which model"), trailing: nil)]
        for model in spend.models {
            views.append(
                meter(
                    label: model.label, value: SessionSpend.money(model.costUSD),
                    detail: Localized.text("%@ turns", "\(model.turns)"), fraction: model.share,
                    hot: false))
        }
        return card(views: views)
    }

    /// The turns worth remembering, with the words that started them — a chart nobody can read
    /// back to a question is a decoration.
    private func expensive() -> NSView {
        var views: [NSView] = [heading(Localized.text("The expensive ones"), trailing: nil)]
        let ranked = spend.turns.sorted { $0.costUSD > $1.costUSD }.prefix(5)
        if ranked.isEmpty {
            views.append(
                RowKit.label(
                    Localized.text("Nothing has been spent yet."), font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.secondaryLabel))
        }
        for turn in ranked {
            let money = RowKit.label(
                SessionSpend.money(turn.costUSD), font: MacTheme.Ramp.font(.cardTitle),
                color: MacTheme.Color.label)
            money.setContentHuggingPriority(.required, for: .horizontal)
            let prompt = RowKit.label(
                turn.prompt ?? Localized.text("a turn with no prompt of its own"),
                font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel)
            prompt.lineBreakMode = .byTruncatingTail
            prompt.toolTip = tooltip(for: turn)
            let row = NSStackView(views: [money, prompt])
            row.orientation = .horizontal
            row.spacing = MacTheme.Spacing.s
            row.alignment = .firstBaseline
            views.append(row)
        }
        return card(views: views)
    }

    private func heading(_ text: String, trailing: String?) -> NSView {
        let title = RowKit.label(text, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label)
        var views: [NSView] = [title, RowKit.spacer()]
        if let trailing {
            views.append(
                RowKit.label(
                    trailing, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel))
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        return row
    }

    private func meter(
        label: String, value: String, detail: String, fraction: Double, hot: Bool
    ) -> NSView {
        let name = RowKit.label(label, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.label)
        let count = RowKit.label(
            detail, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel)
        count.setContentHuggingPriority(.required, for: .horizontal)
        let money = RowKit.label(
            value, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label)
        money.setContentHuggingPriority(.required, for: .horizontal)
        let top = NSStackView(views: [name, RowKit.spacer(), count, money])
        top.orientation = .horizontal
        top.spacing = MacTheme.Spacing.s
        top.alignment = .firstBaseline

        let track = BarView(fill: MacTheme.Color.separator)
        track.translatesAutoresizingMaskIntoConstraints = false
        let fill = BarView(fill: hot ? MacTheme.Color.accent : MacTheme.Color.info)
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        NSLayoutConstraint.activate([
            track.widthAnchor.constraint(equalToConstant: Self.trackWidth),
            track.heightAnchor.constraint(equalToConstant: 6),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(
                equalToConstant: max(2, Self.trackWidth * min(max(fraction, 0), 1))),
        ])

        let block = NSStackView(views: [top, track])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 3
        return block
    }

    private func card(views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = MacTheme.Spacing.s
        stack.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.s, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.s)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = MacTheme.Radius.control
        stack.layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
        return stack
    }

    private func tooltip(for turn: SessionSpend.Turn) -> String {
        var parts = [
            SessionSpend.money(turn.costUSD),
            Localized.text("%@ tokens", StatusFacts.tokens(turn.tokens)),
        ]
        if let seconds = turn.seconds { parts.append(SessionSpend.duration(seconds)) }
        if let model = turn.model { parts.append(ModelBadge.shortName(model)) }
        if let prompt = turn.prompt { parts.append(prompt) }
        return parts.joined(separator: " · ")
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }
}

/// A plain filled rectangle. AppKit has no bar, and a box with a border drawn by the system is not
/// one — the panel needs a rounded fill whose height is the whole message.
@MainActor
private final class BarView: NSView {
    init(fill: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

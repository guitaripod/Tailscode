import CodingAgentKit
import TailscodeCore
import UIKit

/// What a conversation has left to spend, as a sheet: which tank runs out first, the tanks that
/// govern this chat as pace bars, whether the prompt cache is still held, what is in the window,
/// how the footprint has grown turn by turn, and the one thing to do about it.
///
/// Every number and word is `RangeBoard`'s, read once for all three clients; this decides only how
/// wide a bar is. The sheet stays true while it is open — the clock-driven readings are read again
/// every fifteen seconds and whenever the transcript moves — and it reads and never operates:
/// Compact goes through the chat's own preflight.
@MainActor
final class RangeViewController: UIViewController {
    struct Reading {
        let board: RangeBoard
        let billing: ContextFill?
    }

    private enum Lens: Int {
        case content
        case billing
    }

    private let chatTitle: String
    private let read: () -> Reading?
    private let compact: (() -> Void)?
    private let reveal: ((ContextComposition.Item) -> Void)?
    private let scroll = UIScrollView()
    private var rail: ReadableRail?
    private let column = UIStackView()
    private var shown: Reading?
    private var lens: Lens = .content
    private var clock: Task<Void, Never>?
    private var coalesced: Task<Void, Never>?
    private var lastReadAt = Date.distantPast

    private static let cadence: Duration = .seconds(15)
    private static let quickest: TimeInterval = 1

    init(
        title: String, read: @escaping () -> Reading?, compact: (() -> Void)?,
        reveal: ((ContextComposition.Item) -> Void)?
    ) {
        self.chatTitle = title
        self.read = read
        self.compact = compact
        self.reveal = reveal
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        navigationItem.titleView = titleView()
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
            top: Theme.Spacing.s, leading: Theme.Spacing.m, bottom: Theme.Spacing.xl,
            trailing: Theme.Spacing.m)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            column.centerXAnchor.constraint(equalTo: scroll.contentLayoutGuide.centerXAnchor),
            scroll.contentLayoutGuide.widthAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        rail = ReadableRail(
            host: view,
            compact: [column.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)],
            regular: [column.widthAnchor.constraint(equalTo: view.readableContentGuide.widthAnchor)])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: RangeViewController, _: UITraitCollection) in
            controller.rebuild()
        }
        refresh(force: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_RANGE"] == "bottom" {
                scrollToBottomForVerification()
            }
        #endif
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.cadence)
                guard !Task.isCancelled else { return }
                self?.refresh(force: false)
            }
        }
    }

    #if DEBUG
        private func scrollToBottomForVerification() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let scroll = self?.scroll else { return }
                scroll.layoutIfNeeded()
                let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                scroll.setContentOffset(CGPoint(x: 0, y: max(0, bottom)), animated: false)
            }
        }
    #endif

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        clock?.cancel()
        clock = nil
        coalesced?.cancel()
        coalesced = nil
    }

    /// Reads again. A transcript state arrives for every token of an answer, so a read inside the
    /// last second is deferred to the end of it rather than repeated.
    func refresh(force: Bool = false) {
        let age = Date().timeIntervalSince(lastReadAt)
        guard force || age >= Self.quickest else {
            guard coalesced == nil else { return }
            coalesced = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.quickest - age))
                guard !Task.isCancelled else { return }
                self?.coalesced = nil
                self?.refresh(force: true)
            }
            return
        }
        lastReadAt = Date()
        guard let reading = read() else { return }
        guard shown?.board != reading.board || shown?.billing != reading.billing else { return }
        shown = reading
        rebuild()
    }

    private func titleView() -> UIView {
        let name = UILabel()
        name.text = RangeSheetWords.title(chat: "")
        name.font = Theme.Ramp.font(.panelTitle)
        name.textColor = Theme.Color.label
        let detail = UILabel()
        detail.text = chatTitle
        detail.font = Theme.Ramp.font(.panelFootnote)
        detail.textColor = Theme.Color.secondaryLabel
        detail.lineBreakMode = .byTruncatingTail
        let stack = UIStackView(arrangedSubviews: [name, detail])
        stack.axis = .vertical
        stack.alignment = .center
        return stack
    }

    private func rebuild() {
        guard let shown else { return }
        let board = shown.board
        column.arrangedSubviews.forEach {
            column.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        column.addArrangedSubview(verdict(board.verdict))
        if !board.rows.isEmpty || !board.elsewhere.isEmpty {
            column.addArrangedSubview(
                section(RangeSheetWords.tanks, card: tanks(board)))
        }
        if let cache = board.cache {
            column.addArrangedSubview(section(RangeSheetWords.cache, card: cacheCard(cache)))
        }
        if let window = windowCard(shown) {
            column.addArrangedSubview(
                section(RangeSheetWords.window, card: window))
        }
        if let footprint = board.footprint {
            column.addArrangedSubview(
                section(RangeSheetWords.footprint, card: footprintCard(footprint)))
        }
        if compact != nil { column.addArrangedSubview(compactButton()) }
        column.addArrangedSubview(footer(board))
    }

    private func verdict(_ verdict: RangeBoard.Verdict) -> UIView {
        var views: [UIView] = [
            label(
                verdict.headline, role: .headline,
                color: verdict.tone == .quiet ? Theme.Color.label : PaceBar.color(for: verdict.tone))
        ]
        if let detail = verdict.detail {
            views.append(label(detail, role: .panelDetail, color: Theme.Color.secondaryLabel))
        }
        return card(views, spacing: Theme.Spacing.xs)
    }

    private func tanks(_ board: RangeBoard) -> UIView {
        var views: [UIView] = []
        for row in board.rows + board.elsewhere {
            if !views.isEmpty { views.append(divider()) }
            views.append(paceRow(row))
        }
        return card(views, spacing: Theme.Spacing.s)
    }

    /// The title and what qualifies it on the left, the amount on the right, the bar, and the one
    /// line of words the row owes.
    private func paceRow(_ row: PaceRow) -> UIView {
        let name = NSMutableAttributedString(
            string: row.title,
            attributes: [
                .font: Theme.Ramp.font(.control), .foregroundColor: Theme.Color.label,
            ])
        if !row.detail.isEmpty {
            name.append(
                NSAttributedString(
                    string: "  " + row.detail,
                    attributes: [
                        .font: Theme.Ramp.font(.panelFootnote),
                        .foregroundColor: Theme.Color.secondaryLabel,
                    ]))
        }
        let title = UILabel()
        title.attributedText = name
        title.numberOfLines = 0
        title.adjustsFontForContentSizeCategory = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let amount = label(
            row.amount, role: .metricValue,
            color: row.tone == .danger ? Theme.Color.danger : Theme.Color.label)
        amount.textAlignment = .right
        amount.numberOfLines = 1
        amount.setContentHuggingPriority(.required, for: .horizontal)
        amount.setContentCompressionResistancePriority(.required, for: .horizontal)
        let line = UIStackView(arrangedSubviews: [title, amount])
        line.axis = .horizontal
        line.alignment = .firstBaseline
        line.spacing = Theme.Spacing.s

        var views: [UIView] = [line]
        if row.kind != .balance {
            let bar = PaceBar()
            bar.outline = Theme.Color.secondaryBackground
            bar.speaks = false
            bar.configure(row)
            views.append(bar)
        }
        if let words = PaceWords.line(for: row, opened: true) { views.append(words) }

        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = 7
        stack.alpha = row.dimmed ? 0.55 : 1
        stack.isAccessibilityElement = true
        stack.accessibilityLabel = row.accessibilityLabel
        return stack
    }

    private func cacheCard(_ cache: CacheRow) -> UIView {
        let name = NSMutableAttributedString(
            string: cache.title,
            attributes: [
                .font: Theme.Ramp.font(.control), .foregroundColor: Theme.Color.label,
            ])
        name.append(
            NSAttributedString(
                string: "  " + cache.detail,
                attributes: [
                    .font: Theme.Ramp.font(.panelFootnote),
                    .foregroundColor: Theme.Color.secondaryLabel,
                ]))
        let title = UILabel()
        title.attributedText = name
        title.numberOfLines = 0
        title.adjustsFontForContentSizeCategory = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let trailing = label(cache.trailing, role: .metricValue, color: Theme.Color.label)
        trailing.textAlignment = .right
        trailing.numberOfLines = 1
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        let line = UIStackView(arrangedSubviews: [title, trailing])
        line.axis = .horizontal
        line.alignment = .firstBaseline
        line.spacing = Theme.Spacing.s

        var views: [UIView] = [line]
        if !cache.isCold {
            let bar = UsageStyle.bar(fraction: cache.fractionLeft, color: Theme.Color.info)
            views.append(bar)
        }
        if let sentence = cache.sentence {
            views.append(label(sentence, role: .panelFootnote, color: Theme.Color.secondaryLabel))
        }
        let stack = card(views, spacing: 7)
        stack.isAccessibilityElement = true
        stack.accessibilityLabel = [cache.title, cache.detail, cache.trailing, cache.sentence]
            .compactMap { $0 }.joined(separator: ", ")
        return stack
    }

    private func windowCard(_ reading: Reading) -> UIView? {
        let composition = reading.board.composition
        let billing = reading.billing.flatMap { $0.slices.isEmpty ? nil : $0 }
        guard composition != nil || billing != nil else { return nil }
        var views: [UIView] = []
        if composition != nil, billing != nil {
            let picker = UISegmentedControl(items: [
                RangeSheetWords.content, RangeSheetWords.billing,
            ])
            picker.selectedSegmentIndex = lens.rawValue
            picker.addAction(
                UIAction { [weak self, weak picker] _ in
                    guard let self, let picker, let lens = Lens(rawValue: picker.selectedSegmentIndex)
                    else { return }
                    self.lens = lens
                    self.rebuild()
                }, for: .valueChanged)
            views.append(picker)
        }
        let showsContent = composition != nil && (billing == nil || lens == .content)
        if showsContent, let composition {
            views.append(contentsOf: contentViews(composition))
        } else if let billing {
            views.append(contentsOf: billingViews(billing))
        }
        return card(views, spacing: Theme.Spacing.s)
    }

    private static func sliceColor(_ id: String) -> UIColor {
        switch id {
        case "system": return Theme.Color.tertiaryLabel
        case "you": return Theme.Color.accent
        case "answers": return Theme.Color.info
        case "tools": return Theme.Color.special
        case "images": return Theme.Color.success
        default: return Theme.Color.warning
        }
    }

    private func contentViews(_ composition: ContextComposition) -> [UIView] {
        var views: [UIView] = [
            label(
                RangeSheetWords.compositionTotal(StatusFacts.tokens(composition.total)).uppercased(),
                role: .sectionLabel, color: Theme.Color.tertiaryLabel)
        ]
        let slices = composition.slices.map { (Self.sliceColor($0.id), $0.share) }
        views.append(
            stackedBar(
                slices, spoken: composition.slices.map { "\($0.label) \(StatusFacts.share($0.share))" }))
        for slice in composition.slices {
            views.append(
                legendRow(
                    color: Self.sliceColor(slice.id), name: slice.label,
                    share: StatusFacts.share(slice.share), count: StatusFacts.tokens(slice.tokens)))
        }
        for item in composition.items {
            views.append(divider())
            views.append(itemRow(item))
        }
        return views
    }

    private func billingViews(_ fill: ContextFill) -> [UIView] {
        var views: [UIView] = [
            label(
                [RangeSheetWords.billingHeading, fill.window.map { RangeSheetWords.of(window: StatusFacts.tokens($0)) }]
                    .compactMap { $0 }.joined(separator: " · ").uppercased(),
                role: .sectionLabel, color: Theme.Color.tertiaryLabel)
        ]
        let color: (String) -> UIColor = { id in
            switch id {
            case "cacheRead": return Theme.Color.info
            case "cacheWrite": return Theme.Color.info.withAlphaComponent(0.55)
            case "input": return Theme.Color.accent
            default: return Theme.Color.warning
            }
        }
        views.append(
            stackedBar(
                fill.slices.map { (color($0.id), $0.share) },
                spoken: fill.slices.map { "\($0.label) \(StatusFacts.tokens($0.tokens))" }))
        for slice in fill.slices {
            views.append(
                legendRow(
                    color: color(slice.id), name: slice.label,
                    share: StatusFacts.share(slice.share), count: StatusFacts.tokens(slice.tokens)))
        }
        return views
    }

    private func stackedBar(_ parts: [(UIColor, Double)], spoken: [String]) -> UIView {
        let track = UIView()
        track.backgroundColor = Theme.Color.separator
        track.layer.cornerRadius = 5
        track.layer.masksToBounds = true
        track.translatesAutoresizingMaskIntoConstraints = false
        track.heightAnchor.constraint(equalToConstant: 10).isActive = true
        var leading = track.leadingAnchor
        var offset: CGFloat = 0
        for (color, share) in parts {
            let band = UIView()
            band.backgroundColor = color
            band.translatesAutoresizingMaskIntoConstraints = false
            track.addSubview(band)
            NSLayoutConstraint.activate([
                band.leadingAnchor.constraint(equalTo: leading, constant: offset),
                band.topAnchor.constraint(equalTo: track.topAnchor),
                band.bottomAnchor.constraint(equalTo: track.bottomAnchor),
                band.widthAnchor.constraint(
                    equalTo: track.widthAnchor, multiplier: max(0.005, min(1, share))),
            ])
            leading = band.trailingAnchor
            offset = 1
        }
        track.isAccessibilityElement = true
        track.accessibilityLabel = spoken.joined(separator: ", ")
        return track
    }

    private func legendRow(color: UIColor, name: String, share: String, count: String) -> UIView {
        let swatch = UIView()
        swatch.backgroundColor = color
        swatch.layer.cornerRadius = 2
        swatch.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: 10),
            swatch.heightAnchor.constraint(equalToConstant: 10),
        ])
        let nameLabel = label(name, role: .metricDetail, color: Theme.Color.label)
        let shareLabel = label(share, role: .panelFootnote, color: Theme.Color.tertiaryLabel)
        shareLabel.setContentHuggingPriority(.required, for: .horizontal)
        let countLabel = label(count, role: .metricValue, color: Theme.Color.label)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [swatch, nameLabel, UIView(), shareLabel, countLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        return row
    }

    private func itemRow(_ item: ContextComposition.Item) -> UIView {
        let title = [item.tool, item.detail].compactMap { $0 }.joined(separator: " ")
        let name = label(title, role: .control, color: Theme.Color.label)
        name.numberOfLines = 2
        name.lineBreakMode = .byTruncatingMiddle
        let meta = label(
            RangeSheetWords.turn(item.turn, size: StatusFacts.tokens(item.tokens)),
            role: .panelFootnote, color: Theme.Color.secondaryLabel)
        let words = UIStackView(arrangedSubviews: [name, meta])
        words.axis = .vertical
        words.spacing = 1
        words.isUserInteractionEnabled = false
        let share = label(
            StatusFacts.share(item.share), role: .metricValue, color: Theme.Color.label)
        share.setContentHuggingPriority(.required, for: .horizontal)
        share.isUserInteractionEnabled = false
        let chevron = UIImageView(
            image: UIImage(
                systemName: "chevron.right",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.isHidden = reveal == nil
        let row = UIStackView(arrangedSubviews: [words, share, chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        row.isUserInteractionEnabled = false

        let control = UIControl()
        row.translatesAutoresizingMaskIntoConstraints = false
        control.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: control.topAnchor, constant: Theme.Spacing.xs),
            row.bottomAnchor.constraint(equalTo: control.bottomAnchor, constant: -Theme.Spacing.xs),
            row.leadingAnchor.constraint(equalTo: control.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: control.trailingAnchor),
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        control.isAccessibilityElement = true
        control.accessibilityLabel =
            "\(title), \(String(localized: "turn \(item.turn)")), \(StatusFacts.tokens(item.tokens)), \(StatusFacts.share(item.share))"
        control.accessibilityTraits = reveal == nil ? .staticText : .button
        guard reveal != nil else { return control }
        control.accessibilityHint = String(localized: "Shows it in the conversation.")
        control.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                self?.reveal?(item)
            }, for: .touchUpInside)
        return control
    }

    private func footprintCard(_ footprint: RangeFootprint) -> UIView {
        let chart = FootprintChartView(footprint: footprint)
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 110).isActive = true
        var views: [UIView] = [chart]
        let first = label(RangeSheetWords.firstTurn, role: .panelFootnote, color: Theme.Color.tertiaryLabel)
        var captions: [UIView] = [first, UIView()]
        let projected = footprint.projectedTurns
        if projected > 0 {
            captions.append(
                label(
                    RangeSheetWords.projected(projected), role: .panelFootnote,
                    color: Theme.Color.tertiaryLabel))
        }
        let row = UIStackView(arrangedSubviews: captions)
        row.axis = .horizontal
        views.append(row)
        return card(views, spacing: Theme.Spacing.xs)
    }

    private func compactButton() -> UIView {
        var config = Theme.Glass.buttonConfiguration(prominent: true)
        config.title = String(localized: "Compact…")
        let button = UIButton(configuration: config)
        button.addAction(UIAction { [weak self] _ in self?.compact?() }, for: .touchUpInside)
        return button
    }

    private func footer(_ board: RangeBoard) -> UIView {
        let words = [
            board.source.map { $0.last.map { ".!?".contains($0) } == true ? $0 : $0 + "." },
            String(
                localized:
                    "Shares of the window by content are estimated from the transcript and scaled to the measured total. Projections are at the pace so far and change as you work."
            ),
        ].compactMap { $0 }.joined(separator: " ")
        return label(words, role: .panelFootnote, color: Theme.Color.tertiaryLabel)
    }

    private func section(_ title: String, card: UIView) -> UIView {
        let heading = label(title.uppercased(), role: .sectionLabel, color: Theme.Color.secondaryLabel)
        heading.accessibilityTraits = .header
        let stack = UIStackView(arrangedSubviews: [heading, card])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        stack.setCustomSpacing(Theme.Spacing.s, after: heading)
        return stack
    }

    private func card(_ views: [UIView], spacing: CGFloat) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = spacing
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.m, leading: Theme.Spacing.m, bottom: Theme.Spacing.m,
            trailing: Theme.Spacing.m)
        stack.backgroundColor = Theme.Color.secondaryBackground
        stack.layer.cornerRadius = Theme.Radius.card
        stack.layer.cornerCurve = .continuous
        return stack
    }

    private func divider() -> UIView {
        let line = UIView()
        line.backgroundColor = Theme.Color.separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        return line
    }

    private func label(_ text: String, role: TypeRole, color: UIColor) -> UILabel {
        let label = UILabel()
        label.attributedText = NSAttributedString(
            string: text, attributes: Theme.Ramp.attributes(role, color: color))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }
}

/// The footprint after each turn as small bars on one scale: a turn in the accent, a compaction as
/// a dashed rule where the window emptied, the turns the recent pace would add hatched in the
/// warning colour, and the danger line dashed across them.
@MainActor
final class FootprintChartView: UIView {
    private let footprint: RangeFootprint
    private static let gap: CGFloat = 2
    private static let labelBand: CGFloat = 14

    init(footprint: RangeFootprint) {
        self.footprint = footprint
        super.init(frame: .zero)
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityLabel = String(
            localized: "Footprint per turn, \(footprint.bars.filter { $0.kind == .turn }.count) turns")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), !footprint.bars.isEmpty else { return }
        let traits = traitCollection
        let top = footprint.dangerLine == nil ? 0 : Self.labelBand
        let plot = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        let count = CGFloat(footprint.bars.count)
        let width = max(1, (plot.width - Self.gap * (count - 1)) / count)
        let accent = Theme.Color.accent.resolvedColor(with: traits)
        let warning = Theme.Color.warning.resolvedColor(with: traits)
        let rule = Theme.Color.tertiaryLabel.resolvedColor(with: traits)

        var x: CGFloat = 0
        for bar in footprint.bars {
            switch bar.kind {
            case .turn:
                let height = max(1, plot.height * CGFloat(bar.height))
                let frame = CGRect(x: x, y: plot.maxY - height, width: width, height: height)
                accent.setFill()
                UIBezierPath(roundedRect: frame, cornerRadius: min(1.5, width / 2)).fill()
            case .projected:
                let height = max(1, plot.height * CGFloat(bar.height))
                let frame = CGRect(x: x, y: plot.maxY - height, width: width, height: height)
                HatchView.stripes(in: context, rect: frame, color: warning.withAlphaComponent(0.8))
            case .refill:
                context.saveGState()
                context.setStrokeColor(rule.cgColor)
                context.setLineWidth(1)
                context.setLineDash(phase: 0, lengths: [3, 3])
                let mid = x + width / 2
                context.move(to: CGPoint(x: mid, y: plot.minY))
                context.addLine(to: CGPoint(x: mid, y: plot.maxY))
                context.strokePath()
                context.restoreGState()
            }
            x += width + Self.gap
        }

        guard let danger = footprint.dangerLine else { return }
        let y = plot.maxY - plot.height * CGFloat(danger)
        let red = Theme.Color.danger.resolvedColor(with: traits)
        context.saveGState()
        context.setStrokeColor(red.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.move(to: CGPoint(x: 0, y: y))
        context.addLine(to: CGPoint(x: bounds.width, y: y))
        context.strokePath()
        context.restoreGState()
        let text = NSAttributedString(
            string: StatusFacts.share(danger),
            attributes: [.font: Theme.Ramp.font(.panelFootnote), .foregroundColor: red])
        let size = text.size()
        text.draw(at: CGPoint(x: 0, y: max(0, y - size.height - 1)))
    }
}

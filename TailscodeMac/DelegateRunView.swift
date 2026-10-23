import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// One run read on the right, drawn from its `DelegateRunReading`: the headline and its facts, the
/// one thing that matters now, the ladder, exactly one primary action beside the rest, the patch's
/// files, and one timeline. Each part is rebuilt only when its own slice of the reading changed, so
/// a run streaming its story in grows its timeline without redrawing the screen above it.
@MainActor
final class DelegateRunView: NSView {
    var onAction: ((DelegateRunAction.Kind, String) -> Void)?
    var onFile: ((String, String) -> Void)?
    private let column = NSStackView()
    private let headerSlot = NSStackView()
    private let leadSlot = NSStackView()
    private let ladder = MacLadderView()
    private let actionsSlot = NSStackView()
    private let filesSlot = NSStackView()
    private let timelineSlot = NSStackView()
    private let nothing = NSTextField(wrappingLabelWithString: "")
    private var scroll: NSScrollView!
    private var drawn: Drawn?
    private var replayTiers: [String] = []

    private struct Drawn: Equatable {
        var scale: CGFloat
        var runID: String
        var header: [String?]
        var tone: ActivityTone
        var lead: DelegateRunReading.Lead?
        var ladder: DelegateLadder
        var primary: DelegateRunAction?
        var secondary: [DelegateRunAction]
        var replay: [String]
        var filesTitle: String?
        var files: [DelegateFileRow]
        var timeline: [DelegateStoryLine]
    }

    init() {
        super.init(frame: .zero)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.l
        column.edgeInsets = NSEdgeInsets(top: MacTheme.Spacing.l, left: MacTheme.Spacing.xl, bottom: MacTheme.Spacing.xl, right: MacTheme.Spacing.xl)
        for slot in [headerSlot, leadSlot, actionsSlot, filesSlot, timelineSlot] {
            slot.orientation = .vertical
            slot.alignment = .leading
            slot.spacing = 2
            slot.isHidden = true
        }
        actionsSlot.orientation = .horizontal
        actionsSlot.alignment = .centerY
        actionsSlot.spacing = MacTheme.Spacing.s
        headerSlot.spacing = MacTheme.Spacing.xs
        timelineSlot.spacing = 3
        for view in [headerSlot, leadSlot, ladder, actionsSlot, filesSlot, timelineSlot] {
            column.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * MacTheme.Spacing.xl).isActive = true
        }
        scroll = MacDialogs.scrollColumn(holding: column)
        addSubview(scroll)
        nothing.font = MacTheme.Ramp.font(.panelLabel)
        nothing.textColor = MacTheme.Color.secondaryLabel
        nothing.alignment = .center
        nothing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nothing)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            nothing.centerXAnchor.constraint(equalTo: centerXAnchor),
            nothing.centerYAnchor.constraint(equalTo: centerYAnchor),
            nothing.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Drops what was drawn, so the next reading rebuilds every part in the new theme or scale.
    func forget() { drawn = nil }

    func showNothing(_ text: String) {
        scroll.isHidden = true
        nothing.isHidden = false
        nothing.stringValue = text
        drawn = nil
    }

    func show(_ reading: DelegateRunReading, board: DelegateBoard) {
        scroll.isHidden = false
        nothing.isHidden = true
        let labels = board.tiers.reduce(into: [String: String]()) { $0[$1.tier] = $1.label }
        let next = Drawn(
            scale: MacTheme.UIScale.factor, runID: reading.runID,
            header: [reading.headline, reading.badge, reading.facts], tone: reading.tone,
            lead: reading.lead, ladder: reading.ladder, primary: reading.primary,
            secondary: reading.secondary, replay: reading.replayTiers.map { tier in
                labels[tier].flatMap { $0.isEmpty ? nil : "\(tier) · \($0)" } ?? tier
            },
            filesTitle: reading.filesTitle, files: reading.files, timeline: reading.timeline)
        let last = drawn?.scale == next.scale && drawn?.runID == next.runID ? drawn : nil
        drawn = next
        replayTiers = reading.replayTiers
        func changed<Part: Equatable>(_ part: KeyPath<Drawn, Part>) -> Bool {
            guard let last else { return true }
            return last[keyPath: part] != next[keyPath: part]
        }
        if changed(\.header) || changed(\.tone) { drawHeader(reading) }
        if changed(\.lead) { drawLead(reading.lead) }
        if changed(\.ladder) { ladder.show(reading.ladder) }
        if changed(\.primary) || changed(\.secondary) || changed(\.replay) {
            drawActions(reading, replayTitles: next.replay)
        }
        if changed(\.filesTitle) || changed(\.files) { drawFiles(reading) }
        if changed(\.timeline) { drawTimeline(reading.timeline) }
        if last == nil { scroll.contentView.scroll(to: .zero) }
    }

    private func refill(_ slot: NSStackView, with views: [NSView], fill: Bool = true) {
        slot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for view in views {
            slot.addArrangedSubview(view)
            if fill { view.widthAnchor.constraint(equalTo: slot.widthAnchor).isActive = true }
        }
        slot.isHidden = views.isEmpty
    }

    private func drawHeader(_ reading: DelegateRunReading) {
        let headline = NSTextField(wrappingLabelWithString: reading.headline)
        headline.font = MacTheme.Ramp.font(.paneHeadline)
        headline.textColor = MacTheme.Color.label
        headline.isSelectable = false
        headline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var top: [NSView] = [headline]
        if let badge = reading.badge { top.append(DelegatePill(badge, tone: reading.tone)) }
        let titleRow = NSStackView(views: top)
        titleRow.orientation = .horizontal
        titleRow.distribution = .fill
        titleRow.alignment = .top
        titleRow.spacing = MacTheme.Spacing.m
        var views: [NSView] = [titleRow]
        if !reading.facts.isEmpty {
            views.append(RowKit.wrapping(reading.facts, font: MacTheme.Ramp.font(.rowMeta), color: MacTheme.Color.secondaryLabel))
        }
        refill(headerSlot, with: views)
    }

    private func drawLead(_ lead: DelegateRunReading.Lead?) {
        refill(leadSlot, with: lead.map { [DelegateLeadCard($0)] } ?? [])
    }

    private func drawActions(_ reading: DelegateRunReading, replayTitles: [String]) {
        var views: [NSView] = []
        let runID = reading.runID
        if let primary = reading.primary { views.append(button(primary, runID: runID)) }
        for action in reading.secondary { views.append(button(action, runID: runID)) }
        if !replayTitles.isEmpty {
            let popup = NSPopUpButton(frame: .zero, pullsDown: true)
            popup.addItem(withTitle: DelegateRunReading.replayMenuTitle)
            popup.addItems(withTitles: replayTitles)
            popup.target = self
            popup.action = #selector(replayPicked(_:))
            popup.setContentHuggingPriority(.required, for: .horizontal)
            views.append(popup)
        }
        refill(actionsSlot, with: views, fill: false)
        if !views.isEmpty {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            actionsSlot.addArrangedSubview(spacer)
        }
    }

    private func button(_ action: DelegateRunAction, runID: String) -> NSButton {
        let kind = action.kind
        let button = RowKit.ActionButton(title: action.title) { [weak self] in self?.onAction?(kind, runID) }
        switch action.role {
        case .primary:
            button.bezelColor = MacTheme.Color.accent
        case .normal:
            break
        case .destructive:
            button.hasDestructiveAction = true
            button.contentTintColor = MacTheme.Color.danger
        }
        button.toolTip = action.detail
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    @objc private func replayPicked(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1
        guard let runID = drawn?.runID, let tier = replayTiers.element(at: index) else { return }
        onAction?(.replay(tier: tier), runID)
    }

    private func drawFiles(_ reading: DelegateRunReading) {
        guard let title = reading.filesTitle, !reading.files.isEmpty else {
            refill(filesSlot, with: [])
            return
        }
        let runID = reading.runID
        var views: [NSView] = [MacDialogs.sectionHeader(title.uppercased())]
        for file in reading.files {
            let row = DelegateFileRowView(file)
            let path = file.path
            row.onClick = { [weak self] in self?.onFile?(path, runID) }
            views.append(row)
        }
        refill(filesSlot, with: views)
    }

    private func drawTimeline(_ lines: [DelegateStoryLine]) {
        var views: [NSView] = [MacDialogs.sectionHeader(DelegateRunReading.timelineTitle.uppercased())]
        if lines.isEmpty {
            views.append(RowKit.wrapping(Localized.text("Nothing yet."), font: MacTheme.Ramp.font(.rowNote), color: MacTheme.Color.tertiaryLabel))
        }
        for line in lines {
            let label = RowKit.wrapping(
                line.text, font: MacTheme.Ramp.font(line.isProgress ? .rowMeta : .rowDetail),
                color: line.isProgress || line.tone == .quiet ? MacTheme.Color.secondaryLabel : line.tone.color)
            views.append(line.isProgress ? Self.indented(label, rule: false) : label)
            if let detail = line.detail, !detail.isEmpty {
                let tail = RowKit.wrapping(detail, font: MacTheme.Ramp.font(.code), color: MacTheme.Color.secondaryLabel)
                views.append(Self.indented(tail, rule: true))
            }
        }
        refill(timelineSlot, with: views)
    }

    /// A line set in under the one it belongs to — a worker's progress, or a failed attempt's own
    /// output behind a faint rule.
    private static func indented(_ view: NSView, rule: Bool) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        var constraints = [
            view.topAnchor.constraint(equalTo: box.topAnchor, constant: rule ? 2 : 0),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: rule ? -4 : 0),
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: MacTheme.Spacing.l + (rule ? MacTheme.Spacing.s : 0)),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ]
        if rule {
            let bar = RowKit.Ground(frame: .zero)
            bar.fill = MacTheme.Color.separator
            box.addSubview(bar)
            constraints += [
                bar.topAnchor.constraint(equalTo: view.topAnchor),
                bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                bar.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: MacTheme.Spacing.l),
                bar.widthAnchor.constraint(equalToConstant: 2),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return box
    }
}

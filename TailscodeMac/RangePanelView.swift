import AppKit
import CodingAgentKit
import TailscodeCore

/// A ring filled to a share, as an image: the band wears it small before the words. One painter so
/// the band's ring is always the same picture of the same share.
enum ContextRing {
    static func image(fraction: Double, ink: NSColor, diameter: CGFloat, stroke: CGFloat) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = stroke / 2 + 0.5
            let circle = rect.insetBy(dx: inset, dy: inset)
            let track = NSBezierPath(ovalIn: circle)
            track.lineWidth = stroke
            ink.withAlphaComponent(0.22).setStroke()
            track.stroke()
            let share = min(max(fraction, 0), 1)
            guard share > 0 else { return true }
            let fill = NSBezierPath()
            fill.lineWidth = stroke
            fill.lineCapStyle = .round
            fill.appendArc(
                withCenter: NSPoint(x: circle.midX, y: circle.midY), radius: circle.width / 2,
                startAngle: 90, endAngle: 90 - share * 360, clockwise: true)
            ink.setStroke()
            fill.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// What the Range popover draws: the board Core read and the fill it was read beside, which the
/// billing view still draws tier by tier.
struct RangeSnapshot: Equatable {
    let board: RangeBoard
    let fill: ContextFill?
}

extension TranscriptViewController {
    /// The range of this conversation as it stands: its own window, every window that governs the
    /// model the next send would use, the cache, and what is in the window — all read from what the
    /// pane already holds, so opening the popover asks nobody anything.
    func rangeSnapshot() -> RangeSnapshot? {
        guard let state = currentState else { return nil }
        let board = RangeBoard.read(
            messages: state.messages, fill: contextFill, quotas: quotasForStatus?() ?? [],
            model: composer.activeModelID, selection: composer.activeSelection,
            isRunning: state.status == .running, trail: RangeStore.trail)
        return RangeSnapshot(board: board, fill: contextFill)
    }
}

/// The Range of one conversation in a popover off its band: which tank runs out first, the tanks
/// that govern this chat as pace bars, the cache, what is in the window, how the footprint has
/// grown, and the one thing to do about it. Every number and word is Core's (`RangeBoard`); this
/// decides only how a bar is drawn and where a card sits. It is read again every fifteen seconds
/// and whenever the conversation moves, because a countdown and a cache that stood still while the
/// sheet was open would be wrong.
@MainActor
final class RangePanelViewController: NSViewController {
    private enum Lens: Int {
        case content
        case billing
    }

    private let chatTitle: String
    private let read: () -> RangeSnapshot?
    private let compact: (() -> Void)?
    private let reveal: (RangeItem) -> Void
    private var snapshot: RangeSnapshot
    private var lens = Lens.content
    private let column = FillingStack()
    private var timer: Timer?
    private var debounce: Task<Void, Never>?
    private var refreshedAt = Date()

    typealias RangeItem = ContextComposition.Item

    private static let width: CGFloat = 420
    private static let textWidth: CGFloat = 372
    private static let tick: TimeInterval = 15
    private static let settle: TimeInterval = 2

    /// How many cards the sheet drew on its last build, and how many rows of pace bars: what a
    /// selftest asks without having to find them in a view tree.
    private(set) var drawnCards = 0
    private(set) var drawnTanks = 0

    init(
        title: String, snapshot: RangeSnapshot, read: @escaping () -> RangeSnapshot?,
        compact: (() -> Void)?, reveal: @escaping (RangeItem) -> Void
    ) {
        self.chatTitle = title
        self.snapshot = snapshot
        self.read = read
        self.compact = compact
        self.reveal = reveal
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        column.translatesAutoresizingMaskIntoConstraints = false

        let clip = RowKit.FlippedClip()
        clip.drawsBackground = false
        let scroll = NSScrollView()
        scroll.contentView = clip
        scroll.documentView = column
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = WindowWatchView()
        container.onWindow = { [weak self] window in
            guard let self else { return }
            window == nil ? self.stop() : self.start()
        }
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
            container.widthAnchor.constraint(equalToConstant: Self.width),
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 640),
        ])
        let fit = scroll.heightAnchor.constraint(equalTo: column.heightAnchor)
        fit.priority = .defaultHigh
        fit.isActive = true
        view = container
        rebuild()
    }

    /// The conversation moved. Redrawn at most every couple of seconds however fast it streams,
    /// because the composition is the one reading here that costs the size of the transcript.
    func stateChanged() {
        guard debounce == nil else { return }
        let wait = max(0, Self.settle - Date().timeIntervalSince(refreshedAt))
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.debounce = nil
            self.refresh()
        }
    }

    private func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainThread.call { self?.refresh() }
        }
        refresh()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        debounce?.cancel()
        debounce = nil
    }

    private func refresh() {
        refreshedAt = Date()
        guard let next = read(), next != snapshot else { return }
        snapshot = next
        rebuild()
    }

    private func rebuild() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        drawnCards = 0
        drawnTanks = 0
        let board = snapshot.board
        let title = RowKit.label(
            RangeSheetWords.title(chat: chatTitle), font: MacTheme.Ramp.font(.panelFootnote),
            color: MacTheme.Color.secondaryLabel)
        column.addArrangedSubview(title)
        column.addArrangedSubview(verdictCard(board.verdict))
        column.addArrangedSubview(tanksCard(board))
        if let cache = board.cache { column.addArrangedSubview(cacheCard(cache)) }
        if let window = windowCard(board) { column.addArrangedSubview(window) }
        if let footprint = board.footprint { column.addArrangedSubview(footprintCard(footprint)) }
        if let compact {
            let button = RowKit.ActionButton(title: Localized.text("Compact…"), action: compact)
            button.keyEquivalent = "\r"
            let row = NSStackView(views: [RowKit.spacer(), button])
            row.orientation = .horizontal
            row.alignment = .centerY
            column.addArrangedSubview(row)
        }
        if let source = board.source {
            column.addArrangedSubview(
                Self.words(
                    source, role: .panelFootnote, color: MacTheme.Color.secondaryLabel))
        }
    }

    private func verdictCard(_ verdict: RangeBoard.Verdict) -> NSView {
        var views: [NSView] = [
            Self.words(verdict.headline, role: .metricLarge, color: MacTheme.Color.label)
        ]
        if let detail = verdict.detail {
            views.append(
                Self.words(detail, role: .panelDetail, color: MacTheme.Color.secondaryLabel))
        }
        let card = Self.card(views: views)
        if verdict.tone != .quiet {
            card.layer?.borderWidth = 1
            card.layer?.borderColor =
                PaceWords.ink(verdict.tone).withAlphaComponent(0.4).cgColor
        }
        drawnCards += 1
        return card
    }

    private func tanksCard(_ board: RangeBoard) -> NSView {
        var views: [NSView] = [Self.heading(RangeSheetWords.tanks)]
        for (index, row) in board.rows.enumerated() {
            if index > 0 { views.append(RowKit.hairline()) }
            views.append(tank(row))
        }
        for row in board.elsewhere {
            views.append(RowKit.hairline())
            let block = tank(row)
            block.alphaValue = 0.6
            views.append(block)
        }
        drawnCards += 1
        return Self.card(views: views)
    }

    private func tank(_ row: PaceRow) -> NSView {
        drawnTanks += 1
        let title = RowKit.label(
            row.title, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        var headline: [NSView] = [title]
        if !row.detail.isEmpty {
            let detail = RowKit.label(
                row.detail, font: MacTheme.Ramp.font(.panelFootnote),
                color: MacTheme.Color.secondaryLabel)
            detail.setContentCompressionResistancePriority(.init(100), for: .horizontal)
            headline.append(detail)
        }
        let amount = RowKit.label(
            row.amount, font: MacTheme.Ramp.font(.cardTitle),
            color: UsageFormat.amountInk(row.tone, quiet: MacTheme.Color.label))
        amount.setContentHuggingPriority(.required, for: .horizontal)
        amount.setContentCompressionResistancePriority(.required, for: .horizontal)
        headline += [RowKit.spacer(), amount]
        let top = NSStackView(views: headline)
        top.orientation = .horizontal
        top.alignment = .firstBaseline
        top.spacing = MacTheme.Spacing.s

        var views: [NSView] = [
            top, PaceBarView(row: row, surface: .opened, height: 6, surround: MacTheme.Color.canvasRaised),
        ]
        if let words = PaceWords.line(for: row, opened: true) {
            (words as? NSTextField)?.preferredMaxLayoutWidth = Self.textWidth
            views.append(words)
        }
        let block = FillingStack()
        block.spacing = 4
        for view in views { block.addArrangedSubview(view) }
        block.setAccessibilityElement(true)
        block.setAccessibilityLabel(row.accessibilityLabel)
        return block
    }

    private func cacheCard(_ cache: CacheRow) -> NSView {
        let title = RowKit.label(
            cache.title, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        let detail = RowKit.label(
            cache.detail, font: MacTheme.Ramp.font(.panelFootnote),
            color: MacTheme.Color.secondaryLabel)
        detail.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        let trailing = RowKit.label(
            cache.trailing, font: MacTheme.Ramp.font(.cardTitle),
            color: cache.isCold ? MacTheme.Color.secondaryLabel : MacTheme.Color.label)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        let top = NSStackView(views: [title, detail, RowKit.spacer(), trailing])
        top.orientation = .horizontal
        top.alignment = .firstBaseline
        top.spacing = MacTheme.Spacing.s

        var views: [NSView] = [
            Self.heading(RangeSheetWords.cache), top,
            PaceBarView(
                fraction: cache.fractionLeft, slug: nil, tone: .quiet, height: 3,
                surround: MacTheme.Color.canvasRaised),
        ]
        if let sentence = cache.sentence {
            views.append(
                Self.words(sentence, role: .panelFootnote, color: MacTheme.Color.secondaryLabel))
        }
        drawnCards += 1
        return Self.card(views: views)
    }

    /// What is in the window, by content and, one switch away, by what the tokens cost. Either is
    /// drawn alone when the other has nothing to say.
    private func windowCard(_ board: RangeBoard) -> NSView? {
        let content = board.composition
        let billing = snapshot.fill.flatMap { $0.slices.isEmpty ? nil : $0 }
        guard content != nil || billing != nil else { return nil }
        let showing: Lens = content == nil ? .billing : (billing == nil ? .content : lens)

        var views: [NSView] = []
        if content != nil, billing != nil {
            let control = NSSegmentedControl(
                labels: [RangeSheetWords.content, RangeSheetWords.billing],
                trackingMode: .selectOne, target: self, action: #selector(lensPicked(_:)))
            control.selectedSegment = showing.rawValue
            control.controlSize = .small
            control.segmentStyle = .rounded
            let head = NSStackView(views: [
                Self.heading(RangeSheetWords.window), RowKit.spacer(), control,
            ])
            head.orientation = .horizontal
            head.alignment = .centerY
            views.append(head)
        } else {
            views.append(
                Self.heading(
                    content != nil
                        ? RangeSheetWords.window : RangeSheetWords.billingHeading))
        }
        switch showing {
        case .content:
            if let content { views += contentViews(content) }
        case .billing:
            if let fill = snapshot.fill { views += billingViews(fill) }
        }
        drawnCards += 1
        return Self.card(views: views)
    }

    @objc private func lensPicked(_ sender: NSSegmentedControl) {
        lens = Lens(rawValue: sender.selectedSegment) ?? .content
        rebuild()
    }

    private func contentViews(_ content: ContextComposition) -> [NSView] {
        var views: [NSView] = [
            Self.words(
                RangeSheetWords.compositionTotal(StatusFacts.tokens(content.total)),
                role: .panelFootnote, color: MacTheme.Color.secondaryLabel),
            StackedBarView(
                segments: content.slices.map { ($0.share, Self.sliceInk($0.id)) }),
        ]
        views.append(
            legend(
                content.slices.map {
                    (Self.sliceInk($0.id), $0.label, StatusFacts.share($0.share), nil)
                }))
        for item in content.items {
            views.append(itemRow(item))
        }
        return views
    }

    private func billingViews(_ fill: ContextFill) -> [NSView] {
        var views: [NSView] = []
        if let window = fill.window {
            views.append(
                Self.words(
                    RangeSheetWords.of(window: StatusFacts.tokens(window)), role: .panelFootnote,
                    color: MacTheme.Color.secondaryLabel))
        }
        views.append(
            StackedBarView(segments: fill.slices.map { ($0.share, Self.tierInk($0.id)) }))
        views.append(
            legend(
                fill.slices.map {
                    (
                        Self.tierInk($0.id), $0.label, StatusFacts.share($0.share),
                        StatusFacts.tokens($0.tokens)
                    )
                }))
        let facts = NSStackView()
        facts.orientation = .horizontal
        facts.spacing = MacTheme.Spacing.l
        facts.alignment = .top
        for fact in fill.facts {
            let caption = NSTextField(
                labelWithAttributedString: NSAttributedString(
                    string: fact.label.uppercased(),
                    attributes: MacTheme.Ramp.attributes(
                        .metricLabel, color: MacTheme.Color.secondaryLabel)))
            caption.translatesAutoresizingMaskIntoConstraints = false
            let cell = NSStackView(views: [
                RowKit.label(
                    fact.value, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label),
                caption,
            ])
            cell.orientation = .vertical
            cell.alignment = .leading
            cell.spacing = 1
            facts.addArrangedSubview(cell)
        }
        views.append(facts)
        return views
    }

    /// One swatch, a name and the figures, per band.
    private func legend(_ entries: [(NSColor, String, String, String?)]) -> NSView {
        let stack = FillingStack()
        stack.spacing = 3
        for (ink, name, share, count) in entries {
            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = ink.cgColor
            swatch.layer?.cornerRadius = 2
            swatch.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                swatch.widthAnchor.constraint(equalToConstant: 10),
                swatch.heightAnchor.constraint(equalToConstant: 10),
            ])
            var views: [NSView] = [
                swatch,
                RowKit.label(
                    name, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.label),
                RowKit.spacer(),
                RowKit.label(
                    share, font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.secondaryLabel),
            ]
            if let count {
                views.append(
                    RowKit.label(
                        count, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label))
            }
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.spacing = MacTheme.Spacing.s
            row.alignment = .centerY
            stack.addArrangedSubview(row)
        }
        return stack
    }

    /// A single read that takes a notable part of the window, pressed to be taken to it.
    private func itemRow(_ item: RangeItem) -> NSView {
        let name = [item.tool, item.detail].compactMap { $0 }.joined(separator: " ")
        let title = RowKit.label(
            name, font: MacTheme.Ramp.font(.panelDetail), color: MacTheme.Color.label)
        title.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        let sub = RowKit.label(
            RangeSheetWords.turn(item.turn, size: StatusFacts.tokens(item.tokens)),
            font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel)
        let words = NSStackView(views: [title, sub])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 1
        let share = RowKit.label(
            StatusFacts.share(item.share), font: MacTheme.Ramp.font(.cardTitle),
            color: MacTheme.Color.label)
        share.setContentHuggingPriority(.required, for: .horizontal)
        let chevron = NSImageView(
            image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
        chevron.contentTintColor = MacTheme.Color.tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [words, RowKit.spacer(), share, chevron])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        let surface = PressSurface(content: row, minHeight: 34)
        surface.onPress = { [weak self] in self?.reveal(item) }
        surface.setAccessibilityElement(true)
        surface.setAccessibilityRole(.button)
        surface.setAccessibilityLabel(
            Localized.text(
                "%@, turn %d, %@", name, item.turn, StatusFacts.share(item.share)))
        surface.setAccessibilityHelp(Localized.text("Shows it in the conversation"))
        return surface
    }

    private func footprintCard(_ footprint: RangeFootprint) -> NSView {
        let chart = FootprintChartView(footprint)
        var views: [NSView] = [Self.heading(RangeSheetWords.footprint), chart]
        let projected = footprint.bars.filter { $0.kind == .projected }.count
        let left = RowKit.label(
            RangeSheetWords.firstTurn, font: MacTheme.Ramp.font(.panelFootnote),
            color: MacTheme.Color.tertiaryLabel)
        var captions: [NSView] = [left, RowKit.spacer()]
        if projected > 0 {
            captions.append(
                RowKit.label(
                    RangeSheetWords.projected(projected),
                    font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel))
        }
        let row = NSStackView(views: captions)
        row.orientation = .horizontal
        views.append(row)
        drawnCards += 1
        return Self.card(views: views)
    }

    private static func sliceInk(_ id: String) -> NSColor {
        switch id {
        case "system": return MacTheme.Color.secondaryLabel.withAlphaComponent(0.55)
        case "you": return MacTheme.Color.accent
        case "answers": return MacTheme.Color.info
        case "tools": return MacTheme.Color.mark
        case "images": return MacTheme.Color.success
        default: return MacTheme.Color.tertiaryLabel
        }
    }

    private static func tierInk(_ id: String) -> NSColor {
        switch id {
        case "cacheRead": return MacTheme.Color.info
        case "cacheWrite": return MacTheme.Color.info.withAlphaComponent(0.55)
        case "input": return MacTheme.Color.accent
        default: return MacTheme.Color.warning
        }
    }

    private static func heading(_ text: String) -> NSView {
        NSTextField(
            labelWithAttributedString: NSAttributedString(
                string: text.uppercased(),
                attributes: MacTheme.Ramp.attributes(
                    .metricLabel, color: MacTheme.Color.tertiaryLabel)))
    }

    private static func words(_ text: String, role: TypeRole, color: NSColor) -> NSTextField {
        let label = RowKit.wrapping(text, font: MacTheme.Ramp.font(role), color: color)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = textWidth
        return label
    }

    private static func card(views: [NSView]) -> FillingStack {
        let stack = FillingStack()
        stack.spacing = MacTheme.Spacing.s
        stack.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s + 2, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.s + 2,
            right: MacTheme.Spacing.m)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = MacTheme.Radius.control
        stack.layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
        for view in views { stack.addArrangedSubview(view) }
        return stack
    }
}

/// A view that says when it has a window and when it has lost it, which a popover's content gets
/// through no controller callback of its own.
private final class WindowWatchView: NSView {
    var onWindow: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?(window)
    }
}

/// A bar divided by share, one colour a band, with a hair of track between bands.
@MainActor
private final class StackedBarView: NSView {
    private let segments: [(Double, NSColor)]

    init(segments: [(Double, NSColor)]) {
        self.segments = segments
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 10).isActive = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let clip = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        MacTheme.Color.separator.setFill()
        clip.fill()
        clip.addClip()
        var x: CGFloat = 0
        for (share, ink) in segments {
            let width = max(2, bounds.width * CGFloat(min(max(share, 0), 1)))
            ink.setFill()
            NSRect(x: x, y: 0, width: min(width, bounds.width - x), height: bounds.height).fill()
            x += width + 1
        }
    }
}

/// The footprint after each turn as small bars: the turns in the accent, a dashed rule where a
/// compaction emptied the window, the next few turns at the recent pace hatched in the warning
/// colour, and the line a compaction is advised at.
@MainActor
private final class FootprintChartView: NSView {
    private let footprint: RangeFootprint

    private static let height: CGFloat = 72
    private static let gap: CGFloat = 2

    init(_ footprint: RangeFootprint) {
        self.footprint = footprint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(
            Localized.text(
                "Footprint per turn, %d turns shown", footprint.bars.filter { $0.kind == .turn }.count))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let bars = footprint.bars
        guard !bars.isEmpty else { return }
        let count = CGFloat(bars.count)
        let slot = (bounds.width - Self.gap * (count - 1)) / count
        var x: CGFloat = 0
        for bar in bars {
            let height = max(2, bounds.height * CGFloat(min(max(bar.height, 0), 1)))
            let rect = NSRect(x: x, y: 0, width: slot, height: height)
            switch bar.kind {
            case .turn:
                MacTheme.Color.accent.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            case .refill:
                let rule = NSBezierPath()
                rule.move(to: NSPoint(x: rect.midX, y: 0))
                rule.line(to: NSPoint(x: rect.midX, y: bounds.height))
                rule.lineWidth = 1
                rule.setLineDash([3, 3], count: 2, phase: 0)
                MacTheme.Color.tertiaryLabel.setStroke()
                rule.stroke()
            case .projected:
                hatch(rect)
            }
            x += slot + Self.gap
        }
        if let line = footprint.dangerLine {
            let y = bounds.height * CGFloat(line)
            let rule = NSBezierPath()
            rule.move(to: NSPoint(x: 0, y: y))
            rule.line(to: NSPoint(x: bounds.width, y: y))
            rule.lineWidth = 1
            rule.setLineDash([3, 3], count: 2, phase: 0)
            MacTheme.Color.danger.withAlphaComponent(0.8).setStroke()
            rule.stroke()
        }
    }

    private func hatch(_ rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let lines = NSBezierPath()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            lines.move(to: NSPoint(x: x, y: rect.minY))
            lines.line(to: NSPoint(x: x + rect.height, y: rect.maxY))
            x += 6
        }
        lines.lineWidth = 2
        MacTheme.Color.warning.withAlphaComponent(0.75).setStroke()
        lines.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

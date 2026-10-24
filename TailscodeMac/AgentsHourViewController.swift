import AppKit
import CodingAgentKit
import TailscodeCore

/// The scale over the lanes: a tick every ten minutes labelled in minutes ago, and "now" at the
/// right edge in the colour of the line that runs down the lanes.
@MainActor
final class AgentHourRulerView: NSView {
    var now = Date() {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 26 * MacTheme.UIScale.factor)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        MacTheme.Color.canvas.setFill()
        bounds.fill()
        let geometry = AgentHourGeometry(width: bounds.width)
        let font = MacTheme.Ramp.font(.rowStamp)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: MacTheme.Color.tertiaryLabel,
        ]
        let y = bounds.height - ceil(font.boundingRectForFont.height) - 4
        for step in 0..<6 {
            let minutes = (6 - step) * 10
            let x = geometry.x(now.addingTimeInterval(-Double(minutes) * 60), now: now)
            let text = NSAttributedString(string: "\(minutes)m", attributes: attributes)
            let size = text.size()
            text.draw(at: NSPoint(x: max(geometry.chartLeft, x - size.width / 2), y: y))
        }
        let nowText = NSAttributedString(
            string: Localized.text("now"),
            attributes: [.font: font, .foregroundColor: MacTheme.Color.success])
        let size = nowText.size()
        nowText.draw(at: NSPoint(x: geometry.chartRight - size.width, y: y))
        MacTheme.Color.label.withAlphaComponent(0.1).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// What the picture is made of, said once under it: the bar, the amber bar, the dashed outline and
/// the hatching, each with its words, so no state rests on colour alone.
@MainActor
final class AgentHourLegendView: NSView {
    private enum Swatch { case working, waiting, background, unseen }

    private let entries: [(Swatch, String)] = [
        (.working, Localized.text("Working")), (.waiting, Localized.text("Waiting on you")),
        (.background, Localized.text("In the background")),
        (.unseen, Localized.text("Not seen by this Mac")),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityLabel(entries.map(\.1).joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 30 * MacTheme.UIScale.factor)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        MacTheme.Color.canvas.setFill()
        bounds.fill()
        let font = MacTheme.Ramp.font(.rowMeta)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: MacTheme.Color.secondaryLabel,
        ]
        var x = MacTheme.Spacing.l
        let mid = bounds.midY
        for (swatch, title) in entries {
            let box = NSRect(x: x, y: mid - 5, width: 22, height: 10)
            paint(swatch, in: box)
            x = box.maxX + MacTheme.Spacing.xs + 2
            let text = NSAttributedString(string: title, attributes: attributes)
            let size = text.size()
            text.draw(at: NSPoint(x: x, y: mid - size.height / 2))
            x += size.width + MacTheme.Spacing.l
        }
    }

    private func paint(_ swatch: Swatch, in box: NSRect) {
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        switch swatch {
        case .working:
            MacTheme.Color.success.setFill()
            path.fill()
        case .waiting:
            MacTheme.Color.warning.setFill()
            path.fill()
        case .background:
            let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            outline.setLineDash([3, 2], count: 2, phase: 0)
            outline.lineWidth = 1
            MacTheme.Color.secondaryLabel.setStroke()
            outline.stroke()
        case .unseen:
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let lines = NSBezierPath()
            var offset: CGFloat = -box.height
            while offset < box.width {
                lines.move(to: NSPoint(x: box.minX + offset, y: box.maxY))
                lines.line(to: NSPoint(x: box.minX + offset + box.height, y: box.minY))
                offset += 5
            }
            lines.lineWidth = 1
            MacTheme.Color.secondaryLabel.withAlphaComponent(0.55).setStroke()
            lines.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// The Hour face: a ruler, the lanes in a scroll of their own, and the legend. The lanes are
/// fetched from the feed once in a while and between fetches only slid along by the clock.
@MainActor
final class AgentsHourViewController: NSViewController {
    let lanes = AgentHourView()
    private let ruler = AgentHourRulerView()
    private let legend = AgentHourLegendView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let context: AgentsContext
    private var fetching = false
    private var lastFetch = Date.distantPast
    var fetch: () async -> AgentHour? = { nil }

    init(context: AgentsContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        lanes.autoresizingMask = [.width]
        scroll.documentView = lanes
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = MacTheme.Color.canvas
        scroll.automaticallyAdjustsContentInsets = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        empty.stringValue =
            Localized.text("Nothing in the last hour") + "\n"
            + Localized.text("The hour shows what this Mac saw while the board was open.")
        empty.font = MacTheme.Ramp.font(.cardBody)
        empty.textColor = MacTheme.Color.secondaryLabel
        empty.alignment = .center
        empty.maximumNumberOfLines = 0
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.isHidden = true
        root.addSubview(ruler)
        root.addSubview(scroll)
        root.addSubview(empty)
        root.addSubview(legend)
        NSLayoutConstraint.activate([
            ruler.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ruler.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ruler.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: ruler.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: legend.topAnchor),
            legend.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            legend.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            legend.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: MacTheme.Spacing.xl),
            empty.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -MacTheme.Spacing.xl),
        ])
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scroll.contentSize.width
        if abs(lanes.frame.width - width) > 0.5 {
            lanes.setFrameSize(NSSize(width: width, height: lanes.frame.height))
        }
    }

    func apply(_ hour: AgentHour?, now: Date) {
        lanes.update(hour, now: now)
        ruler.now = now
        empty.isHidden = !(hour?.lanes.isEmpty ?? true)
        let height = hour.map { AgentHourView.height(of: $0.lanes) } ?? 0
        if abs(lanes.frame.height - height) > 0.5 {
            lanes.setFrameSize(NSSize(width: max(scroll.contentSize.width, 1), height: height))
        }
    }

    func tick(now: Date) {
        ruler.now = now
        lanes.advance(to: now)
        guard !fetching, now.timeIntervalSince(lastFetch) >= 5 else { return }
        reload()
    }

    func reload() {
        guard !fetching else { return }
        fetching = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let hour = await self.fetch()
            self.fetching = false
            self.lastFetch = self.context.now()
            self.apply(hour, now: self.context.now())
        }
    }
}

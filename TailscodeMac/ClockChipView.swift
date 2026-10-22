import AppKit
import TailscodeCore

/// The world clock's mark at the foot of the sidebar: the sky at this desk as a sixteen-point glyph
/// and the time beside it. Resting the pointer on it opens the glance, which stays while the pointer is
/// on the chip or on the card and goes a moment after it is on neither; a click, Space or Return
/// opens Meridian, the sheet, instead. It is drawn once a minute from `MeridianFeed`'s one clock and
/// runs no clock of its own, and it is always there: a clock with nothing to say is still a clock.
@MainActor
final class ClockChipView: ChipButton, NSPopoverDelegate {
    private static let lingerBeforeClosing: TimeInterval = 0.35

    private let sky = SkyGlyphView()
    private let timeLabel = NSTextField(labelWithString: "")
    private var reading: WorldClockReading
    private var popover: NSPopover?
    private var glance: ClockGlanceViewController?
    private var closing: DispatchWorkItem?
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            needsDisplay = true
        }
    }

    init() {
        reading = MeridianFeed.shared.reading()
        super.init(kind: .control)
        timeLabel.lineBreakMode = .byClipping
        timeLabel.setAccessibilityElement(false)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [sky, timeLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = CGFloat(metrics.iconGap)
        install(content: row)
        target = self
        action = #selector(pressed)
        setAccessibilityRole(.button)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(refresh), name: MeridianFeed.didTick, object: nil)
        center.addObserver(
            self, selector: #selector(refresh), name: WorldClockStore.didChange, object: nil)
        center.addObserver(
            self, selector: #selector(refresh), name: MacTheme.Chrome.didRepaint, object: nil)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        closing?.cancel()
    }

    var currentReading: WorldClockReading { reading }

    override var acceptsFirstResponder: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        guard let layer, hovering || popover != nil else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = MacTheme.Color.accent.cgColor
            layer.borderWidth = 1
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        closing?.cancel()
        showGlance()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        scheduleClose()
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\r", "\u{3}": pressed()
        case "\u{1b}" where popover != nil: closeGlance()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        pressed()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closeGlance() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        closeGlance()
    }

    /// The glance, opened the way a resting pointer opens it — the road `--open clock-glance` takes
    /// so the popover can be drawn and measured without a pointer.
    func reveal() { showGlance() }

    @objc private func refresh() {
        reading = MeridianFeed.shared.reading()
        render()
        glance?.apply(reading)
    }

    private func render() {
        timeLabel.font = MacTheme.Ramp.font(.statusLine)
        timeLabel.textColor = MacTheme.Color.label
        timeLabel.stringValue = reading.chipTime
        sky.apply(reading.sky)
        toolTip = reading.spoken
        setAccessibilityLabel(reading.spoken)
        invalidateIntrinsicContentSize()
    }

    @objc private func pressed() {
        closeGlance()
        guard let window else { return }
        MeridianSheetController.shared.present(in: window)
    }

    private func showGlance() {
        guard popover == nil, window != nil, !MeridianSheetController.shared.isUp else { return }
        reading = MeridianFeed.shared.reading()
        let controller = ClockGlanceViewController(reading: reading)
        controller.onHover = { [weak self] inside in
            if inside { self?.closing?.cancel() } else { self?.scheduleClose() }
        }
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.delegate = self
        popover.ground(controller)
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        self.popover = popover
        glance = controller
        needsDisplay = true
    }

    private func scheduleClose() {
        closing?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainThread.call { self?.closeGlance() }
        }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lingerBeforeClosing, execute: work)
    }

    private func closeGlance() {
        closing?.cancel()
        closing = nil
        popover?.close()
        popover = nil
        glance = nil
        needsDisplay = true
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        glance = nil
        needsDisplay = true
    }
}

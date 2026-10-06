import AppKit
import CodingAgentKit
import TailscodeCore

/// A pane the governor has no room to keep whole, as a peek at the conversation rather than the
/// conversation: what it is doing, its last words read from the bottom up, and the facts a person
/// checks at a glance — who is answering and how hard, how long the turn has run, what is queued,
/// what the machine is still carrying.
///
/// It is content, drawn in the palette on the canvas, never glass. It has no input field — a
/// field is cost and an accessibility burden for something one press away — and it changes at the
/// shed level's glance rate with no reveal and no animation beyond the activity face's own, which
/// holds perfectly still once the turn settles. A turn waiting on the person shows the question in
/// the tail's place in the attention tone, and the footer asks for the answer.
///
/// Press it and it becomes the whole conversation again; double-click it and it borrows the
/// window. The same verbs sit in its context menu and, under the pointer, as small buttons.
@MainActor
final class GlanceTileView: NSView {
    var onPress: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onOpenFull: (() -> Void)?
    var onKeepLive: (() -> Void)?
    var onPause: (() -> Void)?
    var onClose: (() -> Void)?
    /// The pane's own menu — split, zoom, promote — appended under the glance's verbs.
    var paneMenuItems: (() -> [NSMenuItem])?

    private let badge = ActivityBadgeView(pointSize: 12)
    private let titleLabel = NSTextField(labelWithString: "")
    private let pin = NSImageView()
    private let densityLabel = NSTextField(labelWithString: "")
    private let actions = NSStackView()
    private let tailLabel = NSTextField(wrappingLabelWithString: "")
    private let modelDot = NSView()
    private let meter = EffortMeterView()
    private let modelLabel = NSTextField(labelWithString: "")
    private let clockLabel = NSTextField(labelWithString: "")
    private let queueIcon = NSImageView()
    private let queueLabel = NSTextField(labelWithString: "")
    private let backgroundIcon = NSImageView()
    private let backgroundLabel = NSTextField(labelWithString: "")
    private let footer = NSStackView()
    private var tracking: NSTrackingArea?
    private var clock: Timer?

    private(set) var reading: GlanceReading?
    private var title = ""
    private var pinned = false
    private var position = (index: 1, count: 1)
    private var shownChars = 0
    /// How many times the tile has been drawn from a reading, for the check that proves a glance
    /// refreshes at its rate rather than with every state.
    private(set) var renders = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        build()
        restyle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = MacTheme.Color.canvas.cgColor
        modelDot.layer?.backgroundColor = dotColor.cgColor
    }

    private var dotColor: NSColor = MacTheme.Color.tertiaryLabel

    private func build() {
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        pin.isHidden = true
        pin.setContentHuggingPriority(.required, for: .horizontal)
        densityLabel.stringValue = Localized.text("Glance")
        densityLabel.setContentHuggingPriority(.required, for: .horizontal)
        densityLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)

        for (symbol, words, action) in [
            ("arrow.up.left.and.arrow.down.right", Localized.text("Open full"), #selector(openFull)),
            ("pin", Localized.text("Keep live"), #selector(keepLive)),
            ("pause", Localized.text("Pause this pane"), #selector(pause)),
            ("xmark", Localized.text("Close Split"), #selector(close)),
        ] {
            let button = NSButton(
                image: NSImage(systemSymbolName: symbol, accessibilityDescription: words)
                    ?? NSImage(), target: self, action: action)
            button.isBordered = false
            button.toolTip = words
            button.setAccessibilityLabel(words)
            actions.addArrangedSubview(button)
        }
        actions.spacing = MacTheme.Spacing.xs
        actions.alphaValue = 0
        actions.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [badge, titleLabel, pin, NSView(), actions, densityLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = MacTheme.Spacing.s
        header.setHuggingPriority(.defaultLow, for: .horizontal)

        tailLabel.maximumNumberOfLines = 0
        tailLabel.lineBreakMode = .byWordWrapping
        tailLabel.cell?.truncatesLastVisibleLine = true
        tailLabel.setContentCompressionResistancePriority(.init(100), for: .vertical)
        tailLabel.setContentCompressionResistancePriority(.init(100), for: .horizontal)

        modelDot.wantsLayer = true
        modelDot.layer?.cornerRadius = 3.5
        queueIcon.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
        backgroundIcon.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        for label in [modelLabel, clockLabel, queueLabel, backgroundLabel] {
            label.lineBreakMode = .byTruncatingTail
        }
        modelLabel.setContentCompressionResistancePriority(.init(150), for: .horizontal)
        footer.setViews(
            [modelDot, meter, modelLabel, clockLabel, queueIcon, queueLabel, backgroundIcon,
             backgroundLabel],
            in: .leading)
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = MacTheme.Spacing.s
        footer.setCustomSpacing(MacTheme.Spacing.xs, after: modelDot)
        footer.setCustomSpacing(2, after: queueIcon)
        footer.setCustomSpacing(2, after: backgroundIcon)
        footer.detachesHiddenViews = true

        for view in [header, tailLabel, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        modelDot.translatesAutoresizingMaskIntoConstraints = false
        let inset = MacTheme.Spacing.m
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: MacTheme.Spacing.s),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            header.heightAnchor.constraint(equalToConstant: 24),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.s),
            footer.heightAnchor.constraint(equalToConstant: 18),
            tailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            tailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            tailLabel.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -MacTheme.Spacing.xs),
            tailLabel.topAnchor.constraint(
                greaterThanOrEqualTo: header.bottomAnchor, constant: MacTheme.Spacing.xs),
            modelDot.widthAnchor.constraint(equalToConstant: 7),
            modelDot.heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    @objc private func themeChanged() { restyle() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        titleLabel.font = MacTheme.Ramp.font(.cardTitle)
        titleLabel.textColor = MacTheme.Color.label
        densityLabel.font = MacTheme.Ramp.font(.pill)
        densityLabel.textColor = MacTheme.Color.secondaryLabel
        pin.contentTintColor = MacTheme.Color.secondaryLabel
        tailLabel.font = MacTheme.Ramp.font(.cardBody)
        for label in [modelLabel, clockLabel, queueLabel, backgroundLabel] {
            label.font = MacTheme.Ramp.font(.rowStamp)
            label.textColor = MacTheme.Color.secondaryLabel
        }
        for icon in [queueIcon, backgroundIcon] {
            icon.contentTintColor = MacTheme.Color.secondaryLabel
            icon.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: MacTheme.Ramp.font(.rowStamp).pointSize, weight: .regular)
        }
        for case let button as NSButton in actions.arrangedSubviews {
            button.contentTintColor = MacTheme.Color.secondaryLabel
        }
        if let reading { apply(reading) }
        needsDisplay = true
    }

    /// Draws the tile from a reading. Nil is a conversation nothing has been heard from yet.
    func render(
        title: String, reading: GlanceReading?, pinned: Bool, index: Int, of count: Int
    ) {
        self.title = title
        self.pinned = pinned
        position = (index, count)
        self.reading = reading
        renders += 1
        titleLabel.stringValue = title
        pin.isHidden = !pinned
        if let reading {
            apply(reading)
        } else {
            badge.activity = nil
            tailLabel.stringValue = ""
            footer.isHidden = true
            stopClock()
        }
        speak()
    }

    private func apply(_ reading: GlanceReading) {
        badge.activity = reading.activity
        footer.isHidden = false
        let waiting = reading.question != nil
        if let question = reading.question {
            tailLabel.stringValue = question
            tailLabel.textColor = MacTheme.Color.warning
            shownChars = question.count
        } else {
            let text = reading.tail(maxChars: capacity)
            tailLabel.stringValue = text
            tailLabel.textColor = MacTheme.Color.label
            shownChars = capacity
        }
        let chip = ModelBadge.chip(model: reading.model, effort: reading.effort)
        dotColor = chip.map { MacTheme.Color.modelIdentity($0) } ?? MacTheme.Color.tertiaryLabel
        modelDot.layer?.backgroundColor = dotColor.cgColor
        modelDot.isHidden = chip == nil
        modelLabel.stringValue = chip?.name ?? ""
        modelLabel.isHidden = chip == nil
        applyEffort(reading.effort)
        queueLabel.stringValue = "\(reading.queued)"
        queueIcon.isHidden = reading.queued == 0
        queueLabel.isHidden = reading.queued == 0
        let tasks = reading.background?.tasks ?? 0
        backgroundLabel.stringValue = "\(tasks)"
        backgroundIcon.isHidden = tasks == 0
        backgroundLabel.isHidden = tasks == 0
        if waiting {
            clockLabel.stringValue = Localized.text("Answer…")
            clockLabel.textColor = MacTheme.Color.warning
            stopClock()
        } else {
            clockLabel.textColor = MacTheme.Color.secondaryLabel
            tickClock()
        }
    }

    private func applyEffort(_ effort: String?) {
        guard let effort, !effort.isEmpty else {
            meter.isHidden = true
            return
        }
        meter.isHidden = false
        if EffortVocabulary.entry(effort)?.role == .power {
            meter.set(lit: EffortMeter.bars, tint: nil, rainbow: true, cold: false, glow: 0)
        } else if EffortVocabulary.isAutomatic(effort) {
            meter.set(lit: 0, tint: nil, rainbow: false, cold: true, glow: 0)
        } else {
            meter.set(
                lit: ModelDial.heat(effort, options: []),
                tint: MacTheme.Color.modelEffort(effort) ?? MacTheme.Color.secondaryLabel,
                rainbow: false, cold: false, glow: 0)
        }
    }

    /// How long the running turn has been out, ticking once a second while the tile can be seen
    /// and the shed level allows any clock at all. A settled turn shows nothing and owns no timer.
    private func tickClock() {
        guard let reading, let started = reading.turnStartedAt, reading.activity != nil,
            reading.session.isInFlight
        else {
            clockLabel.isHidden = true
            stopClock()
            return
        }
        clockLabel.isHidden = false
        clockLabel.stringValue = Self.elapsed(since: started)
        guard clock == nil, window != nil, !isHiddenOrHasHiddenAncestor,
            MotionBudget.level < .critical
        else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickClock() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    func stopClock() {
        clock?.invalidate()
        clock = nil
    }

    var ownsClock: Bool { clock != nil }

    static func elapsed(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// The characters the tail has room for: the columns a line of the body face holds times the
    /// lines between the header and the footer.
    private var capacity: Int {
        let font = MacTheme.Ramp.font(.cardBody)
        let width = max(0, bounds.width - MacTheme.Spacing.m * 2)
        let height = max(0, bounds.height - 24 - 18 - MacTheme.Spacing.s * 2 - MacTheme.Spacing.xs * 2 - safeAreaInsets.top)
        let columns = max(8, Int(width / max(1, font.pointSize * 0.52)))
        let lineHeight = font.ascender - font.descender + font.leading + 2
        let lines = max(1, min(8, Int(height / max(1, lineHeight))))
        return columns * lines
    }

    override func layout() {
        super.layout()
        if let reading, reading.question == nil, capacity != shownChars {
            shownChars = capacity
            tailLabel.stringValue = reading.tail(maxChars: capacity)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopClock() }
    }

    private func speak() {
        var parts = [
            Localized.text("Pane %@ of %@", "\(position.index)", "\(position.count)"), title,
        ]
        if let activity = reading?.activity { parts.append(activity.spoken) }
        if let question = reading?.question {
            parts.append(question)
        } else if let line = reading?.tail.split(separator: "\n").last {
            parts.append(String(line))
        }
        setAccessibilityLabel(parts.joined(separator: ", "))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { actions.alphaValue = 1 }

    override func mouseExited(with event: NSEvent) { actions.alphaValue = 0 }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onPress?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(title: Localized.text("Open full")) { [weak self] in self?.openFull() })
        let keep = ClosureMenuItem(title: Localized.text("Keep live")) { [weak self] in self?.keepLive() }
        keep.state = pinned ? .on : .off
        menu.addItem(keep)
        menu.addItem(ClosureMenuItem(title: Localized.text("Pause this pane")) { [weak self] in self?.pause() })
        menu.addItem(ClosureMenuItem(title: Localized.text("Close Split")) { [weak self] in self?.close() })
        let extra = paneMenuItems?() ?? []
        if !extra.isEmpty {
            menu.addItem(.separator())
            extra.forEach(menu.addItem)
        }
        return menu
    }

    @objc private func openFull() { onOpenFull?() }
    @objc private func keepLive() { onKeepLive?() }
    @objc private func pause() { onPause?() }
    @objc private func close() { onClose?() }
}

import AppKit
import TailscodeCore

/// The line under the prompt box that says where the next prompt goes and how: vim mode,
/// destination, the model-and-effort dial, the command palette, attachments, and stop. The
/// CLI's status line, made clickable — every pill opens the surface that changes what it names.
@MainActor
final class PillsRow: NSView {
    struct MenuRow {
        let title: String
        let subtitle: String?
        let checked: Bool
        let handler: @MainActor () -> Void

        init(
            _ title: String, subtitle: String? = nil, checked: Bool = false,
            handler: @escaping @MainActor () -> Void = {}
        ) {
            self.title = title
            self.subtitle = subtitle
            self.checked = checked
            self.handler = handler
        }
    }

    /// A lane was pressed. Chat is the pane this row already sits in, so only the other two leave.
    var onLane: ((QuickAskLane) -> Void)?

    /// The dial was pressed: the composer opens the model-and-effort popover on it.
    var onDial: (() -> Void)?
    /// The wheel turned over the closed dial, one notch: +1 hotter, -1 colder.
    var onDialStep: ((Int) -> Void)?
    var commandRows: (() -> [MenuRow])?
    var attachRows: (() -> [MenuRow])?
    var onStop: (() -> Void)?

    /// The composer's three lanes, worn as the segmented control a Mac walks modes with. On a
    /// desk each lane is a surface — chat is this pane, ask is the summoned question window,
    /// video is the forge sheet — so a press is a door, and the selection springs back to chat
    /// because this row never stops being a conversation's.
    private let laneControl = NSSegmentedControl(
        labels: PillsRow.offeredLanes.map(\.word), trackingMode: .momentary, target: nil,
        action: nil)
    private let vimBadge = NSTextField(labelWithString: "")
    private let vimBadgeWrap = NSView()
    private let destinationLabel = NSTextField(labelWithString: "")
    private let dialPill = DialPill()
    private let commandPill: MenuPill
    private let attachButton: MenuPill
    private let stopButton: RowKit.ActionButton

    init() {
        commandPill = MenuPill(title: "/")
        attachButton = MenuPill(title: "")
        stopButton = RowKit.ActionButton(title: "") {}
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        vimBadge.textColor = MacTheme.Color.onGlass
        vimBadge.translatesAutoresizingMaskIntoConstraints = false
        vimBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        vimBadgeWrap.wantsLayer = true
        vimBadgeWrap.layer?.cornerRadius = 5
        vimBadgeWrap.translatesAutoresizingMaskIntoConstraints = false
        vimBadgeWrap.addSubview(vimBadge)
        NSLayoutConstraint.activate([
            vimBadge.leadingAnchor.constraint(equalTo: vimBadgeWrap.leadingAnchor, constant: 6),
            vimBadge.trailingAnchor.constraint(
                equalTo: vimBadgeWrap.trailingAnchor, constant: -6),
            vimBadge.topAnchor.constraint(equalTo: vimBadgeWrap.topAnchor, constant: 2),
            vimBadge.bottomAnchor.constraint(equalTo: vimBadgeWrap.bottomAnchor, constant: -2),
        ])
        vimBadgeWrap.isHidden = true

        destinationLabel.textColor = MacTheme.Color.onGlassSecondary
        destinationLabel.lineBreakMode = .byTruncatingMiddle
        destinationLabel.translatesAutoresizingMaskIntoConstraints = false
        destinationLabel.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)

        dialPill.onPress = { [weak self] in self?.onDial?() }
        dialPill.onStep = { [weak self] delta in self?.onDialStep?(delta) }
        dialPill.toolTip = Localized.text(
            "The model the next prompt runs on and how hard it thinks — scroll to step the effort")
        commandPill.rows = { [weak self] in self?.commandRows?() ?? [] }
        commandPill.toolTip = Localized.text("Slash commands")

        attachButton.rows = { [weak self] in self?.attachRows?() ?? [] }
        attachButton.image = NSImage(
            systemSymbolName: "paperclip",
            accessibilityDescription: Localized.text("Attach files"))
        attachButton.toolTip = Localized.text("Attach files or a pasted image, up to 8 MB each")

        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.image = NSImage(
            systemSymbolName: "stop.fill",
            accessibilityDescription: Localized.text("Stop the running turn"))
        stopButton.toolTip = Localized.text("Stop the running turn")
        stopButton.isHidden = true
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.translatesAutoresizingMaskIntoConstraints = false

        dialPill.setContentCompressionResistancePriority(.init(251), for: .horizontal)
        commandPill.setContentCompressionResistancePriority(.init(251), for: .horizontal)
        commandPill.cell?.lineBreakMode = .byTruncatingTail
        attachButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        stopButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        laneControl.controlSize = .small
        laneControl.target = self
        laneControl.action = #selector(laneTapped)
        laneControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        laneControl.translatesAutoresizingMaskIntoConstraints = false
        for (index, lane) in PillsRow.offeredLanes.enumerated() {
            laneControl.setToolTip(lane.spoken, forSegment: index)
        }

        let row = NSStackView(views: [
            vimBadgeWrap, destinationLabel, dialPill, commandPill,
            RowKit.spacer(),
            laneControl, attachButton, stopButton,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Every font and every palette colour in this row is asked for again rather than remembered:
    /// a type-scale step changes what a role is worth, and a colour built under one theme answers
    /// that theme forever — a Stop button made before a theme change would keep the old red.
    func restyle() {
        vimBadge.font = MacTheme.Ramp.font(.badge)
        destinationLabel.font = MacTheme.Ramp.font(.panelFootnote)
        for pill in [commandPill, attachButton] {
            pill.font = MacTheme.Ramp.font(.panelFootnote)
        }
        dialPill.restyle()
        stopButton.contentTintColor = MacTheme.Color.danger
    }

    @objc private func themeChanged() {
        restyle()
    }

    /// The lanes this client draws. A picture is a lane wherever a machine can paint and a
    /// client has a surface to make one in; the Mac has no image studio yet, so the control stays
    /// three wide and never offers a door that opens on nothing.
    static var offeredLanes: [QuickAskLane] { QuickAskLane.offered(imaging: false) }

    @objc private func laneTapped() {
        let lanes = PillsRow.offeredLanes
        guard lanes.indices.contains(laneControl.selectedSegment) else { return }
        onLane?(lanes[laneControl.selectedSegment])
    }

    /// Alongside the badge the caret itself says which mode this is, so the badge carries the
    /// mode's color too: quiet in normal, accent in insert, warning in the visual modes.
    func setVim(_ mode: VimMode?) {
        guard let mode else {
            vimBadgeWrap.isHidden = true
            return
        }
        vimBadgeWrap.isHidden = false
        vimBadge.stringValue = mode.label
        let background: NSColor =
            switch mode {
            case .insert: MacTheme.Color.accent.withAlphaComponent(0.25)
            case .normal: MacTheme.Color.tertiaryLabel.withAlphaComponent(0.25)
            case .visual, .visualLine: MacTheme.Color.warning.withAlphaComponent(0.3)
            }
        vimBadgeWrap.layer?.backgroundColor = background.cgColor
    }

    func setDestination(_ text: String) {
        destinationLabel.stringValue = text
    }

    /// The dial wears what the composer already knows — the model's word, the level a send would
    /// carry and its heat — and the family's hue on the dot; nil hands the dot back to the
    /// toolkit's own tint.
    func setFace(_ face: DialFace, modelTint: NSColor?) {
        dialPill.setFace(face, modelTint: modelTint)
    }

    /// The view a popover anchors to.
    var dialAnchor: NSView { dialPill }

    func setAttachShown(_ shown: Bool) {
        attachButton.isHidden = !shown
    }

    func setStopShown(_ shown: Bool) {
        stopButton.isHidden = !shown
    }

    func popUpCommandMenu() {
        commandPill.popUpMenu()
    }

    @objc private func stopTapped() {
        onStop?()
    }
}

/// The one pill for model and effort: a tinted dot, the model's word, the effort word in its
/// tier's colour and the five-bar meter. A wheel over it steps the effort one notch per click,
/// because which machine and how hard are one decision and the second half of it should not
/// need a menu.
@MainActor
final class DialPill: NSButton {
    var onPress: (() -> Void)?
    var onStep: ((Int) -> Void)?

    private let dot = NSTextField(labelWithString: "●")
    private let modelLabel = NSTextField(labelWithString: "")
    private let separator = NSTextField(labelWithString: "·")
    private let effortLabel = NSTextField(labelWithString: "")
    private let meter = EffortMeterView()
    private let content = NSStackView()
    private var face: DialFace?
    private var modelTint: NSColor?
    /// Wheel travel since the last notch. A precise trackpad reports in points and a notched
    /// mouse in lines, so the threshold is one line or eight points, whichever the device sends.
    private var travel: CGFloat = 0
    private static let notch: CGFloat = 8

    init() {
        super.init(frame: .zero)
        title = ""
        bezelStyle = .rounded
        controlSize = .small
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.button)

        for label in [dot, modelLabel, separator, effortLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        modelLabel.setContentCompressionResistancePriority(.init(260), for: .horizontal)
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 4
        content.setViews([dot, modelLabel, separator, effortLabel, meter], in: .center)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let inner = content.fittingSize
        return NSSize(width: inner.width + 18, height: super.intrinsicContentSize.height)
    }

    /// The labels inside are ornament: a press anywhere on the pill is a press on the pill.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    func restyle() {
        let font = MacTheme.Ramp.font(.panelFootnote)
        for label in [dot, modelLabel, separator] { label.font = font }
        effortLabel.font = MacTheme.Ramp.font(.pill)
        separator.textColor = MacTheme.Color.tertiaryLabel
        if let face { setFace(face, modelTint: modelTint) }
    }

    func setFace(_ face: DialFace, modelTint: NSColor?) {
        self.face = face
        self.modelTint = modelTint
        dot.textColor = modelTint ?? MacTheme.Color.secondaryLabel
        modelLabel.stringValue = face.modelWord
        modelLabel.textColor = MacTheme.Color.label
        separator.isHidden = !face.showsMeter
        effortLabel.isHidden = !face.showsMeter
        meter.isHidden = !face.showsMeter
        setAccessibilityLabel(face.spoken)
        guard let word = face.effortWord else {
            invalidateIntrinsicContentSize()
            return
        }
        if face.isPower {
            effortLabel.attributedStringValue = DialPill.rainbow(word, font: effortLabel.font)
            meter.set(lit: face.heat, tint: nil, rainbow: true, cold: false)
        } else if face.isServer {
            effortLabel.attributedStringValue = NSAttributedString(
                string: word,
                attributes: [
                    .font: MacTheme.Ramp.font(.panelFootnote),
                    .foregroundColor: MacTheme.Color.tertiaryLabel,
                ])
            meter.set(lit: 0, tint: nil, rainbow: false, cold: true)
        } else {
            let tint = MacTheme.Color.modelEffort(word) ?? MacTheme.Color.secondaryLabel
            effortLabel.attributedStringValue = NSAttributedString(
                string: word, attributes: [.font: effortLabel.font as Any, .foregroundColor: tint])
            meter.set(lit: face.heat, tint: tint, rainbow: false, cold: false)
        }
        invalidateIntrinsicContentSize()
    }

    /// Ultracode is a power, not a level, so its word takes no heat: it is set letter by letter
    /// from the shared rainbow, the same stops the aura travels.
    static func rainbow(_ word: String, font: NSFont?) -> NSAttributedString {
        let font = font ?? MacTheme.Ramp.font(.pill)
        let text = NSMutableAttributedString()
        for (index, letter) in word.enumerated() {
            text.append(
                NSAttributedString(
                    string: String(letter),
                    attributes: [
                        .font: font,
                        .foregroundColor: MacTheme.Color.modelRainbowLetter(index, of: word.count),
                    ]))
        }
        return text
    }

    /// Up is hotter. The travel is accumulated rather than acted on per event, so a trackpad's
    /// stream of tiny deltas steps once per finger-width and a mouse's notches step once each,
    /// and a pill with no meter leaves the wheel to whatever is behind it.
    override func scrollWheel(with event: NSEvent) {
        guard face?.showsMeter == true else {
            super.scrollWheel(with: event)
            return
        }
        guard event.hasPreciseScrollingDeltas else {
            let delta = event.scrollingDeltaY
            if delta != 0 { onStep?(delta > 0 ? 1 : -1) }
            return
        }
        if event.phase == .began { travel = 0 }
        guard event.momentumPhase == [] else { return }
        travel += event.scrollingDeltaY
        while travel >= DialPill.notch {
            travel -= DialPill.notch
            onStep?(1)
        }
        while travel <= -DialPill.notch {
            travel += DialPill.notch
            onStep?(-1)
        }
    }

    @objc private func pressed() {
        onPress?()
    }
}

/// The five bars every effort surface draws, as bars rather than glyphs so they take a tint
/// and keep their proportions at every type scale: lit bars in the tier's colour, the rest at a
/// fifth of the label's ink, the power in the rainbow, the server's choice all cold.
@MainActor
final class EffortMeterView: NSView {
    private var lit = 0
    private var tint: NSColor?
    private var rainbow = false
    private var cold = false
    private let barWidth: CGFloat = 4
    private let gap: CGFloat = 2
    private let barHeight: CGFloat = 10

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let scale = MacTheme.UIScale.factor
        let bars = CGFloat(EffortMeter.bars)
        return NSSize(
            width: (bars * barWidth + (bars - 1) * gap) * scale, height: barHeight * scale)
    }

    func set(lit: Int, tint: NSColor?, rainbow: Bool, cold: Bool) {
        self.lit = lit
        self.tint = tint
        self.rainbow = rainbow
        self.cold = cold
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let scale = MacTheme.UIScale.factor
        let width = barWidth * scale
        let height = barHeight * scale
        let step = (barWidth + gap) * scale
        let y = (bounds.height - height) / 2
        let base = tint ?? MacTheme.Color.secondaryLabel
        let unlit = MacTheme.Color.label.withAlphaComponent(cold ? 0.16 : 0.2)
        for index in 0..<EffortMeter.bars {
            let rect = NSRect(x: CGFloat(index) * step, y: y, width: width, height: height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1 * scale, yRadius: 1 * scale)
            let colour: NSColor =
                index < lit
                ? (rainbow ? MacTheme.Color.modelRainbowLetter(index, of: EffortMeter.bars) : base)
                : unlit
            colour.setFill()
            path.fill()
        }
    }
}

/// A pill that pops a menu built fresh on every click, so the rows always describe the session
/// as it is now rather than as it was when the pill was made.
@MainActor
final class MenuPill: NSButton {
    var rows: (() -> [PillsRow.MenuRow])?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        font = MacTheme.Ramp.font(.panelFootnote)
        target = self
        action = #selector(popUp)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func popUpMenu() {
        popUp()
    }

    @objc private func popUp() {
        let rows = rows?() ?? []
        guard !rows.isEmpty else { return }
        let menu = NSMenu()
        for row in rows {
            let item = ClosureMenuItem(title: row.title, handler: row.handler)
            if let subtitle = row.subtitle { item.subtitle = subtitle }
            item.state = row.checked ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}

/// A target-action shim so a menu built from data can hand a closure to AppKit.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() {
        handler()
    }
}

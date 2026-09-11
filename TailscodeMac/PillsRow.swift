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
    private let effortWord = EffortWordView()
    private let meter = EffortMeterView()
    private let content = NSStackView()
    private var face: DialFace?
    private var modelTint: NSColor?
    /// Wheel travel since the last notch. A precise trackpad reports in points and a notched
    /// mouse in lines, so the threshold is one line or eight points, whichever the device sends.
    private var travel: CGFloat = 0
    private static let notch: CGFloat = 8
    /// The power's rainbow travels along its word one stop every ninety milliseconds, on a timer
    /// over the main run loop rather than a chained dispatch, and it runs only while the pill wears
    /// the power, is in a window, and the desk has not asked for less motion.
    private var shimmer: Timer?
    private var shimmerPhase = 0
    private static let shimmerStep: TimeInterval = 0.09

    init() {
        super.init(frame: .zero)
        title = ""
        bezelStyle = .rounded
        controlSize = .small
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.button)

        for label in [dot, modelLabel, separator] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        modelLabel.setContentCompressionResistancePriority(.init(260), for: .horizontal)
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 4
        content.setViews([dot, modelLabel, separator, effortWord, meter], in: .center)
        content.setCustomSpacing(0, after: effortWord)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            content.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -(9 - EffortMeterView.glowInset)),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let inner = content.fittingSize
        return NSSize(
            width: inner.width + 18 - EffortMeterView.glowInset,
            height: super.intrinsicContentSize.height)
    }

    /// The labels inside are ornament: a press anywhere on the pill is a press on the pill.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    /// A clock that ticks for a pill nobody can see is a clock for nothing: the shimmer follows
    /// the window in and out.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncShimmer()
    }

    func restyle() {
        let font = MacTheme.Ramp.font(.panelFootnote)
        for label in [dot, modelLabel, separator] { label.font = font }
        effortWord.pointSize = MacTheme.Ramp.font(.pill).pointSize
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
        effortWord.isHidden = !face.showsMeter
        meter.isHidden = !face.showsMeter
        setAccessibilityLabel(face.spoken)
        guard let word = face.effortWord else {
            stopShimmer()
            invalidateIntrinsicContentSize()
            return
        }
        effortWord.slot(face.slotWords.isEmpty ? [word] : face.slotWords)
        if face.isPower {
            shimmerPhase = 0
            effortWord.text = DialPill.rainbow(word, pointSize: effortWord.pointSize)
            meter.set(lit: face.heat, tint: nil, rainbow: true, cold: false, glow: 6)
        } else if face.isServer {
            effortWord.text = NSAttributedString(
                string: word,
                attributes: EffortHeat.attributes(
                    EffortHeat.Style(weight: .regular, glow: 0), pointSize: effortWord.pointSize,
                    colour: MacTheme.Color.tertiaryLabel))
            meter.set(lit: 0, tint: nil, rainbow: false, cold: true, glow: 0)
        } else {
            let tint = MacTheme.Color.modelEffort(word) ?? MacTheme.Color.secondaryLabel
            effortWord.text = NSAttributedString(
                string: word,
                attributes: EffortHeat.attributes(
                    word, pointSize: effortWord.pointSize, colour: tint))
            meter.set(
                lit: face.heat, tint: tint, rainbow: false, cold: false,
                glow: EffortHeat.style(word).glow, ember: face.isEmber)
        }
        syncShimmer()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// Ultracode is a power, not a level, so its word takes no heat: it is set letter by letter
    /// from the shared rainbow, the same stops the aura travels, shifted by `phase` stops so the
    /// rainbow can move along the word without one glyph moving.
    static func rainbow(_ word: String, pointSize: CGFloat, phase: Int = 0) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let count = word.count
        let attributes = EffortHeat.attributes(
            Ultracode.effortLevel, pointSize: pointSize, colour: MacTheme.Color.label)
        for (index, letter) in word.enumerated() {
            var lettered = attributes
            lettered[.foregroundColor] = MacTheme.Color.modelRainbowLetter(
                ((index + phase) % count + count) % count, of: count)
            text.append(NSAttributedString(string: String(letter), attributes: lettered))
        }
        return text
    }

    private func syncShimmer() {
        guard let face, face.isPower, window != nil, EffortHeat.motionAllowed else {
            stopShimmer()
            return
        }
        guard shimmer == nil else { return }
        let timer = Timer(timeInterval: DialPill.shimmerStep, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.shimmerTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        shimmer = timer
    }

    private func stopShimmer() {
        shimmer?.invalidate()
        shimmer = nil
        if let face, face.isPower, let word = face.effortWord, shimmerPhase != 0 {
            shimmerPhase = 0
            effortWord.text = DialPill.rainbow(word, pointSize: effortWord.pointSize)
        }
    }

    /// The phase is read off the clock rather than counted, so a tick the run loop swallowed
    /// costs a step and not the rhythm; the string is rewritten only when the step changes.
    private func shimmerTick() {
        guard let face, face.isPower, let word = face.effortWord, !word.isEmpty else {
            stopShimmer()
            return
        }
        let phase = Int(Date.timeIntervalSinceReferenceDate / DialPill.shimmerStep) % word.count
        guard phase != shimmerPhase else { return }
        shimmerPhase = phase
        effortWord.text = DialPill.rainbow(word, pointSize: effortWord.pointSize, phase: phase)
    }

    @objc private func motionPreferenceChanged() {
        syncShimmer()
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

/// How hot a level is set: the word's weight climbs with the tier, and from high up its bars
/// glow in the tier's own colour — so a tier is told by weight and light and not only by hue.
/// The word itself never glows, because a blur under type smears it. Anything the catalog does
/// not rank reads as low.
enum EffortHeat {
    struct Style {
        let weight: NSFont.Weight
        let glow: CGFloat
    }

    static func style(_ word: String) -> Style {
        if ModelDial.isPower(word) { return Style(weight: .heavy, glow: 6) }
        switch word.lowercased() {
        case "medium", "thinking": return Style(weight: .semibold, glow: 0)
        case "high": return Style(weight: .bold, glow: 2)
        case "xhigh": return Style(weight: .heavy, glow: 4)
        case "max": return Style(weight: .heavy, glow: 6)
        default: return Style(weight: .regular, glow: 0)
        }
    }

    /// The heaviest ink any word in a slot can wear, which is what the slot is measured with.
    static let widest = Style(weight: .heavy, glow: 0)

    static func attributes(
        _ word: String, pointSize: CGFloat, colour: NSColor
    ) -> [NSAttributedString.Key: Any] {
        attributes(style(word), pointSize: pointSize, colour: colour)
    }

    static func attributes(
        _ style: Style, pointSize: CGFloat, colour: NSColor
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: pointSize, weight: style.weight),
            .foregroundColor: colour,
        ]
    }

    static var motionAllowed: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// The effort word's slot: as wide as the widest word the model's levels can put in it, measured
/// once per set of words in the heaviest ink any of them wears, and left-aligned in that width, so
/// the pill and everything right of it hold still while the wheel turns. It draws the string
/// itself rather than through a text field so the width is the string's own measure and not a
/// cell's guess at padding.
@MainActor
final class EffortWordView: NSView {
    var text = NSAttributedString() {
        didSet { needsDisplay = true }
    }

    var pointSize: CGFloat = 11 {
        didSet {
            guard pointSize != oldValue else { return }
            measured = nil
            invalidateIntrinsicContentSize()
        }
    }

    private var words: [String] = []
    private var measured: NSSize?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func slot(_ words: [String]) {
        guard words != self.words else { return }
        self.words = words
        measured = nil
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let size = measured ?? measure()
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    private func measure() -> NSSize {
        let attributes = EffortHeat.attributes(
            EffortHeat.widest, pointSize: pointSize, colour: MacTheme.Color.label)
        let sizes = words.map { NSAttributedString(string: $0, attributes: attributes).size() }
        let font = attributes[.font] as? NSFont
        let lineHeight = font.map { $0.ascender - $0.descender + $0.leading } ?? pointSize * 1.3
        let size = NSSize(
            width: sizes.map(\.width).max() ?? 0,
            height: max(lineHeight, sizes.map(\.height).max() ?? 0))
        measured = size
        return size
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = text.size()
        let origin = NSPoint(x: 0, y: (bounds.height - size.height) / 2)
        text.draw(at: origin)
    }
}

/// The five bars every effort surface draws, as bars rather than glyphs so they take a tint
/// and keep their proportions at every type scale: rising left to right, lit bars in the tier's
/// colour under the tier's own glow, the rest a shadow of the label's ink, the power's each a
/// stop of the rainbow, the server's choice all cold, and a level under low one ember: its one
/// bar hollow, a stroke of the tier's colour around no fill, so minimal reads as less than one
/// bar against low's solid first.
@MainActor
final class EffortMeterView: NSView {
    static let glowInset: CGFloat = 4
    private static let verticalInset: CGFloat = 6
    private var lit = 0
    private var tint: NSColor?
    private var rainbow = false
    private var cold = false
    private var ember = false
    private var glow: CGFloat = 0
    private static let emberAlpha: CGFloat = 0.9
    private static let emberStroke: CGFloat = 1
    private let barWidth: CGFloat = 4
    private let gap: CGFloat = 2
    private static let heights: [CGFloat] = [6, 8, 10, 12, 14]

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
            width: (bars * barWidth + (bars - 1) * gap) * scale + Self.glowInset * 2,
            height: (Self.heights.last ?? 14) * scale + Self.verticalInset * 2)
    }

    /// `glow` is the tier's own blur (`EffortHeat.style`), handed in with the tint rather than
    /// read back from the count, because a level the catalog does not rank lights bars by its
    /// position and not by a name. `ember` hollows every lit bar and drops its glow, which is
    /// how a level below low keeps its one bar without being mistaken for low's.
    func set(
        lit: Int, tint: NSColor?, rainbow: Bool, cold: Bool, glow: CGFloat, ember: Bool = false
    ) {
        self.lit = lit
        self.tint = tint
        self.rainbow = rainbow
        self.cold = cold
        self.ember = ember
        self.glow = ember ? 0 : (rainbow ? 6 : glow)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let scale = MacTheme.UIScale.factor
        let width = barWidth * scale
        let step = (barWidth + gap) * scale
        let floor = Self.verticalInset
        let base = tint ?? MacTheme.Color.secondaryLabel
        let unlit = MacTheme.Color.label.withAlphaComponent(cold ? 0.14 : 0.18)
        for index in 0..<EffortMeter.bars {
            let height = Self.heights[min(index, Self.heights.count - 1)] * scale
            let rect = NSRect(
                x: Self.glowInset + CGFloat(index) * step, y: floor, width: width, height: height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1 * scale, yRadius: 1 * scale)
            guard index < lit else {
                unlit.setFill()
                path.fill()
                continue
            }
            let colour =
                rainbow ? MacTheme.Color.modelRainbowLetter(index, of: EffortMeter.bars) : base
            if ember {
                let inset = Self.emberStroke / 2
                let outline = NSBezierPath(
                    roundedRect: rect.insetBy(dx: inset, dy: inset),
                    xRadius: 1 * scale, yRadius: 1 * scale)
                outline.lineWidth = Self.emberStroke
                colour.withAlphaComponent(Self.emberAlpha).setStroke()
                outline.stroke()
                continue
            }
            NSGraphicsContext.saveGraphicsState()
            if glow > 0 {
                let shadow = NSShadow()
                shadow.shadowBlurRadius = glow
                shadow.shadowOffset = .zero
                shadow.shadowColor = colour.withAlphaComponent(0.55)
                shadow.set()
            }
            colour.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
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

import AppKit
import TailscodeCore

/// The footer's copy buttons: a caption over the value it will put on the pasteboard, which says
/// *Copied* in place of the caption for a moment afterwards. The value follows the line as it moves,
/// and the button is as wide as the whole value, at any type size.
@MainActor
final class MeridianCopyButton: NSView {
    private static let confirmFor: Duration = .milliseconds(1200)

    private let ground = TintView(
        fill: { MacTheme.Color.canvasRaised }, stroke: { MacTheme.Color.separator }, radius: 14)
    private let caption = MeridianLabel.framed(.metricLabel, color: MacTheme.Color.secondaryLabel)
    private let value = MeridianLabel.framed(.rowStamp)
    private let title: String
    private var copiedTicket = 0
    private(set) var isConfirming = false
    private(set) var payload = ""
    private var pressed = false {
        didSet { alphaValue = pressed ? 0.6 : 1 }
    }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        ground.translatesAutoresizingMaskIntoConstraints = true
        addSubview(ground)
        addSubview(caption)
        addSubview(value)
        setAccessibilityRole(.button)
        HoverPlate.attach(to: self, placement: .over, radius: 14)
        NotificationCenter.default.addObserver(
            self, selector: #selector(restyle), name: MacTheme.Chrome.didRepaint, object: nil)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
    }

    override var intrinsicContentSize: NSSize {
        let captionWidth = max(captionSize(title).width, captionSize(Localized.text("Copied")).width)
        let width = max(captionWidth, MeridianMetrics.fit(value).width)
        let height = captionSize(title).height + MeridianMetrics.fit(value).height + 16
        return NSSize(width: ceil(width) + 28, height: max(44, ceil(height)))
    }

    private func captionSize(_ text: String) -> NSSize {
        let size = NSAttributedString(
            string: text.uppercased(), attributes: MacTheme.Ramp.attributes(.metricLabel)
        ).size()
        return NSSize(width: ceil(size.width) + 6, height: ceil(size.height))
    }

    func apply(value text: String) {
        payload = text
        value.stringValue = text
        setAccessibilityLabel("\(title), \(text)")
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let captionHeight = MeridianMetrics.fit(caption).height
        let valueHeight = MeridianMetrics.fit(value).height
        let top = (bounds.height - captionHeight - valueHeight) / 2
        caption.frame = CGRect(x: 14, y: top, width: bounds.width - 28, height: captionHeight)
        value.frame = CGRect(x: 14, y: top + captionHeight, width: bounds.width - 28, height: valueHeight)
    }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { copyValue() }
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\u{3}": copyValue()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        copyValue()
        return true
    }

    func copyValue() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        isConfirming = true
        copiedTicket += 1
        let ticket = copiedTicket
        restyle()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.confirmFor)
            guard let self, ticket == self.copiedTicket else { return }
            self.isConfirming = false
            self.restyle()
        }
    }

    @objc private func restyle() {
        let text = isConfirming ? Localized.text("Copied") : title
        caption.attributedStringValue = NSAttributedString(
            string: text.uppercased(),
            attributes: MacTheme.Ramp.attributes(
                .metricLabel,
                color: isConfirming ? MacTheme.Color.accent : MacTheme.Color.secondaryLabel))
        value.font = MacTheme.Ramp.font(.rowStamp)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}

/// One choice in the time-format control: the name of the style over what it writes right now, so a
/// person picks 24-hour or 12-hour by reading the time it gives rather than by knowing the words.
@MainActor
final class MeridianStyleSegment: NSControl {
    let style: ClockStyle
    var onSelect: ((ClockStyle) -> Void)?
    var isChosen = false {
        didSet {
            guard isChosen != oldValue else { return }
            ground.fill = fillColour
            ground.stroke = strokeColour
            setAccessibilityValue(isChosen ? 1 : 0)
            needsLayout = true
        }
    }

    private let ground: TintView
    private let name = MeridianLabel.framed(.control)
    private let example = MeridianLabel.framed(.rowStamp, color: MacTheme.Color.secondaryLabel)

    override var isFlipped: Bool { true }

    init(style: ClockStyle) {
        self.style = style
        ground = TintView(radius: 12)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        ground.translatesAutoresizingMaskIntoConstraints = true
        ground.fill = fillColour
        ground.stroke = strokeColour
        name.stringValue = style.title
        addSubview(ground)
        addSubview(name)
        addSubview(example)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(style.title)
        HoverPlate.attach(to: self, placement: .over, radius: 12)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var fillColour: (() -> NSColor)? {
        let chosen = isChosen
        return chosen ? { MacTheme.Color.accent.withAlphaComponent(0.2) } : nil
    }

    private var strokeColour: (() -> NSColor)? {
        let chosen = isChosen
        return chosen ? { MacTheme.Color.accent } : nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }

    func apply(example text: String) {
        example.stringValue = text
        name.font = MacTheme.Ramp.font(.control)
        example.font = MacTheme.Ramp.font(.rowStamp)
        setAccessibilityHelp(text)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let width = max(MeridianMetrics.fit(name).width, MeridianMetrics.fit(example).width) + 24
        let height = MeridianMetrics.fit(name).height + MeridianMetrics.fit(example).height + 10
        return NSSize(width: width, height: max(38, height))
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let nameSize = MeridianMetrics.fit(name)
        let exampleSize = MeridianMetrics.fit(example)
        let top = (bounds.height - nameSize.height - exampleSize.height) / 2
        name.frame = CGRect(
            x: (bounds.width - nameSize.width) / 2, y: top, width: nameSize.width, height: nameSize.height)
        example.frame = CGRect(
            x: (bounds.width - exampleSize.width) / 2, y: top + nameSize.height,
            width: exampleSize.width, height: exampleSize.height)
        name.textColor = isChosen ? MacTheme.Color.accent : MacTheme.Color.label
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        onSelect?(style)
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\u{3}": onSelect?(style)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?(style)
        return true
    }
}

/// The time format as a labelled three-way control: Follow system, 24-hour, 12-hour, each showing the
/// time it would write now. Choosing one writes the store and the sheet redraws in place.
@MainActor
final class MeridianStyleControl: NSView {
    var onChoose: ((ClockStyle) -> Void)?

    private let ground = TintView(
        fill: { MacTheme.Color.canvasRaised }, stroke: { MacTheme.Color.separator }, radius: 15)
    private(set) var segments: [MeridianStyleSegment] = ClockStyle.allCases.map {
        MeridianStyleSegment(style: $0)
    }

    private static let inset: CGFloat = 3

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        ground.translatesAutoresizingMaskIntoConstraints = true
        addSubview(ground)
        for segment in segments {
            segment.onSelect = { [weak self] style in self?.onChoose?(style) }
            addSubview(segment)
        }
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(Localized.text("Time style"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(style: ClockStyle, instant: Date, viewer: TimeZone) {
        for segment in segments {
            segment.apply(example: segment.style.example(at: instant, in: viewer))
            segment.isChosen = segment.style == style
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let widths = segments.map { $0.intrinsicContentSize.width }
        let height = (segments.map { $0.intrinsicContentSize.height }.max() ?? 38) + 2 * Self.inset
        return NSSize(width: widths.reduce(0, +) + 2 * Self.inset + CGFloat(widths.count - 1) * 2, height: height)
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        var x = Self.inset
        for segment in segments {
            let width = segment.intrinsicContentSize.width
            segment.frame = CGRect(
                x: x, y: Self.inset, width: width, height: bounds.height - 2 * Self.inset)
            x += width + 2
        }
    }
}

/// The last row under the lanes while it is closed: a ghost lane with a plus where the tile goes,
/// the invitation in its own words and how many of the places are taken. A press, Return or Space
/// opens it in place. When the list is full it says what to do about that and does nothing.
@MainActor
final class MeridianGhostRow: NSControl {
    var onActivate: (() -> Void)?
    var isActive = true {
        didSet {
            alphaValue = isActive ? 1 : 0.6
            setAccessibilityEnabled(isActive)
        }
    }

    private let outline = CAShapeLayer()
    private let tile = TintView(fill: { MacTheme.Color.canvasRaised }, radius: 9)
    private let plus = NSImageView()
    private let invitation = MeridianLabel.framed(.rowTitleStrong, color: MacTheme.Color.secondaryLabel)
    private let summary = MeridianLabel.framed(.panelFootnote, color: MacTheme.Color.secondaryLabel, alignment: .right)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        outline.fillColor = nil
        outline.lineWidth = 1
        outline.lineDashPattern = [4, 4]
        layer?.addSublayer(outline)
        tile.translatesAutoresizingMaskIntoConstraints = true
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        plus.contentTintColor = MacTheme.Color.accent
        plus.imageScaling = .scaleNone
        plus.setAccessibilityElement(false)
        for view in [tile, plus, invitation, summary] { addSubview(view) }
        setAccessibilityRole(.button)
        HoverPlate.attach(to: self, placement: .over, radius: 14)
        NotificationCenter.default.addObserver(
            self, selector: #selector(restyle), name: MacTheme.Chrome.didRepaint, object: nil)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    override var acceptsFirstResponder: Bool { isActive }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: MeridianMetrics.rowHeight)
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
    }

    func apply(status: PlacesStatus) {
        invitation.stringValue = status.invitation
        summary.stringValue = status.summary
        isActive = !status.isFull
        setAccessibilityLabel("\(status.invitation), \(status.summary)")
        restyle()
    }

    @objc private func restyle() {
        invitation.font = MacTheme.Ramp.font(.rowTitleStrong)
        summary.font = MacTheme.Ramp.font(.panelFootnote)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            outline.strokeColor = MacTheme.Color.separator.cgColor
        }
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 14, cornerHeight: 14, transform: nil)
        CATransaction.commit()
        let side = MeridianMetrics.tile
        tile.frame = CGRect(x: 8, y: (bounds.height - side) / 2, width: side, height: side)
        let plusSize = plus.image?.size ?? .zero
        plus.frame = CGRect(
            x: tile.frame.midX - plusSize.width / 2, y: tile.frame.midY - plusSize.height / 2,
            width: plusSize.width, height: plusSize.height)
        let inviteSize = MeridianMetrics.fit(invitation)
        let summarySize = MeridianMetrics.fit(summary)
        let textX = tile.frame.maxX + MeridianMetrics.tileGap
        invitation.frame = CGRect(
            x: textX, y: (bounds.height - inviteSize.height) / 2, width: inviteSize.width,
            height: inviteSize.height)
        let room = bounds.width - 12 - summarySize.width
        summary.isHidden = invitation.frame.maxX + 12 > room
        summary.frame = CGRect(
            x: room, y: (bounds.height - summarySize.height) / 2, width: summarySize.width,
            height: summarySize.height)
    }

    override func mouseUp(with event: NSEvent) {
        guard isActive, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        onActivate?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\u{3}" where isActive: onActivate?()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isActive else { return false }
        onActivate?()
        return true
    }
}

/// One place in the Add-a-place list: its name over where it is, and on the right the time there over
/// how far that is from here. The row under the pointer or the keyboard's cursor wears the accent.
@MainActor
final class MeridianPlaceRowView: NSView {
    let place: PlaceRow
    var onChoose: ((PlaceRow) -> Void)?
    var onHover: ((MeridianPlaceRowView) -> Void)?
    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            ground.fill = isHighlighted ? { MacTheme.Color.accent.withAlphaComponent(0.14) } : nil
        }
    }

    private let ground = TintView(radius: 10)
    private(set) var labels: [NSTextField] = []

    init(place: PlaceRow) {
        self.place = place
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(ground)
        let name = MeridianLabel.make(place.name, role: .rowTitleStrong)
        let detail = MeridianLabel.wrapping(place.detail, role: .panelFootnote, color: MacTheme.Color.secondaryLabel)
        let time = MeridianLabel.make(place.time, role: .statusLine, alignment: .right)
        let offsetText = "\(place.offset) \u{00B7} \(place.dayWord)"
        let offset = MeridianLabel.make(
            offsetText, role: .panelFootnote, color: MacTheme.Color.secondaryLabel, alignment: .right)
        labels = [name, detail, time, offset]
        let right = NSView()
        right.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(time)
        right.addSubview(offset)
        for view in [name, detail, right] { addSubview(view) }
        let rightWidth = max(
            MeridianLabel.width(of: place.time, role: .statusLine),
            MeridianLabel.width(of: offsetText, role: .panelFootnote))
        NSLayoutConstraint.activate([
            right.widthAnchor.constraint(equalToConstant: rightWidth),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            right.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            time.topAnchor.constraint(equalTo: right.topAnchor),
            time.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            offset.topAnchor.constraint(equalTo: time.bottomAnchor),
            offset.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            offset.bottomAnchor.constraint(equalTo: right.bottomAnchor),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -12),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -12),
            bottomAnchor.constraint(greaterThanOrEqualTo: detail.bottomAnchor, constant: 8),
            bottomAnchor.constraint(greaterThanOrEqualTo: right.bottomAnchor, constant: 8),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(place.spoken)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        ground.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { onHover?(self) }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onChoose?(place) }
    }

    override func accessibilityPerformPress() -> Bool {
        onChoose?(place)
        return true
    }
}

/// Where places are added, in the lanes where they are shown. Closed it is the ghost row; opened it
/// is a search field over a list of places read by their clocks — the places most people reach for
/// while the field is empty, the matches while it is not, and a sentence saying so when nothing
/// matches. Up and Down move the highlight, Return pins it, Esc clears the field and then closes the
/// list. With no places pinned it opens by itself, so a first visit shows what to do.
@MainActor
final class MeridianAddPlaceView: NSView, NSSearchFieldDelegate {
    var onPin: ((String) -> Void)?

    private let column = FillingStack(topDown: true)
    private let ghost = MeridianGhostRow()
    private let panel = TintView(stroke: { MacTheme.Color.separator }, radius: 14)
    private let inner = FillingStack(topDown: true)
    let field = NSSearchField()
    private lazy var fieldHeight = field.heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
    private let caption = MeridianLabel.make("", role: .panelDetail, color: MacTheme.Color.secondaryLabel)
    private let empty = MeridianLabel.wrapping("", role: .panelDetail, color: MacTheme.Color.secondaryLabel)
    private let list = FillingStack(topDown: true)
    private(set) var rows: [MeridianPlaceRowView] = []
    private(set) var highlight = 0
    private(set) var isExpanded = false
    private var openedByPerson = false
    private var dismissedByPerson = false
    private var status = MeridianPlaces.status(.default)
    private var preferences = WorldClockPreferences.default
    private var viewer = TimeZone.current
    private var now = Date()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        column.spacing = 0
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        ghost.onActivate = { [weak self] in self?.open(focusing: true) }
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityLabel(Localized.text("Search a city or country"))
        fieldHeight.isActive = true
        list.spacing = 2
        inner.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        inner.spacing = MacTheme.Spacing.s
        inner.translatesAutoresizingMaskIntoConstraints = false
        for view in [field, caption, empty, list] { inner.addArrangedSubview(view) }
        panel.addSubview(inner)
        panel.takesPresses = true
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: panel.topAnchor),
            inner.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
        ])
        column.addArrangedSubview(ghost)
        column.addArrangedSubview(panel)
        panel.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var ghostRow: MeridianGhostRow { ghost }

    var query: String { field.stringValue.trimmingCharacters(in: .whitespaces) }

    var highlightedPlace: PlaceRow? { rows.indices.contains(highlight) ? rows[highlight].place : nil }

    var isEditing: Bool {
        guard let editor = window?.firstResponder as? NSText else { return false }
        return editor.delegate === field
    }

    func apply(preferences: WorldClockPreferences, viewer: TimeZone, now: Date) {
        self.preferences = preferences
        self.viewer = viewer
        self.now = now
        status = MeridianPlaces.status(preferences)
        ghost.apply(status: status)
        field.font = MacTheme.Ramp.font(.control)
        fieldHeight.constant = ceil(MeridianLabel.height(of: .control)) + 12
        field.placeholderString = status.placeholder
        if status.isFull {
            close(returningFocus: false)
        } else if preferences.pins.isEmpty, !dismissedByPerson, !isExpanded {
            open(focusing: false)
        }
        if isExpanded { refresh() }
    }

    func reset() {
        openedByPerson = false
        dismissedByPerson = false
        field.stringValue = ""
        if isExpanded, !preferences.pins.isEmpty { close(returningFocus: false) }
        if isExpanded { refresh() }
    }

    func open(focusing: Bool) {
        guard !status.isFull else { return }
        isExpanded = true
        if focusing { openedByPerson = true }
        ghost.isHidden = true
        panel.isHidden = false
        refresh()
        if focusing { window?.makeFirstResponder(field) }
    }

    func close(returningFocus: Bool) {
        let wasEditing = isEditing
        isExpanded = false
        openedByPerson = false
        field.stringValue = ""
        panel.isHidden = true
        ghost.isHidden = false
        if returningFocus || wasEditing { window?.makeFirstResponder(ghost) }
    }

    func setQuery(_ text: String) {
        field.stringValue = text
        if !isExpanded { open(focusing: false) }
        refresh()
    }

    func handleEscape() -> Bool {
        guard isExpanded else { return false }
        if !field.stringValue.isEmpty {
            field.stringValue = ""
            refresh()
            return true
        }
        guard openedByPerson || isEditing else { return false }
        dismissedByPerson = true
        close(returningFocus: true)
        return true
    }

    func moveHighlight(_ delta: Int) {
        guard !rows.isEmpty else { return }
        highlight = min(max(highlight + delta, 0), rows.count - 1)
        paintHighlight()
    }

    func pinHighlighted() {
        guard let place = highlightedPlace else { return }
        pin(place)
    }

    private func pin(_ place: PlaceRow) {
        onPin?(place.id)
        dismissedByPerson = false
        close(returningFocus: false)
    }

    /// What a press at the middle of `row` reaches, walked through the whole view as the window
    /// would, so a check can prove a place row is not behind a plate that swallows the press.
    func hitTest(row: MeridianPlaceRowView) -> NSView? {
        guard let superview else { return nil }
        let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: superview)
        return hitTest(point)
    }

    private func refresh() {
        let text = query
        let places =
            text.isEmpty
            ? MeridianPlaces.suggestions(preferences: preferences, viewer: viewer, now: now)
            : MeridianPlaces.results(for: text, preferences: preferences, viewer: viewer, now: now)
        list.arrangedSubviews.forEach {
            list.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        rows = places.map { place in
            let row = MeridianPlaceRowView(place: place)
            row.onChoose = { [weak self] chosen in self?.pin(chosen) }
            row.onHover = { [weak self] hovered in
                guard let self, let index = self.rows.firstIndex(where: { $0 === hovered }) else { return }
                self.highlight = index
                self.paintHighlight()
            }
            list.addArrangedSubview(row)
            return row
        }
        highlight = min(highlight, max(0, rows.count - 1))
        paintHighlight()
        caption.stringValue = Localized.text("Popular")
        caption.font = MacTheme.Ramp.font(.panelDetail)
        caption.isHidden = !text.isEmpty || rows.isEmpty
        empty.stringValue = MeridianPlaces.emptyResult(for: text)
        empty.font = MacTheme.Ramp.font(.panelDetail)
        empty.isHidden = text.isEmpty || !rows.isEmpty
    }

    private func paintHighlight() {
        for (index, row) in rows.enumerated() { row.isHighlighted = index == highlight }
    }

    func controlTextDidChange(_ obj: Notification) {
        highlight = 0
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveHighlight(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveHighlight(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            pinHighlighted()
            return true
        default:
            return false
        }
    }
}

/// A section under the lanes: its name in the label column, aligned with the lanes' words, and its
/// content in the bars' column.
@MainActor
final class MeridianSectionRow: NSView {
    var minimumContent: () -> CGFloat = { 0 }

    private let caption = NSTextField(labelWithString: "")
    private let content: NSView
    private var barX: CGFloat = 0
    private var wide: [NSLayoutConstraint] = []
    private var stacked: [NSLayoutConstraint] = []
    private var isStacked = false
    private var wantsStacked = false

    init(title: String, content: NSView) {
        self.content = content
        super.init(frame: .zero)
        caption.attributedStringValue = NSAttributedString(
            string: title,
            attributes: MacTheme.Ramp.attributes(.sectionLabel, color: MacTheme.Color.secondaryLabel))
        caption.lineBreakMode = .byClipping
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.setContentCompressionResistancePriority(.required, for: .horizontal)
        caption.setContentHuggingPriority(.required, for: .horizontal)
        content.translatesAutoresizingMaskIntoConstraints = false
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)
        addSubview(content)
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        wide = [
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            content.topAnchor.constraint(equalTo: topAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: caption.bottomAnchor),
        ]
        stacked = [
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: MacTheme.Spacing.xs + 2),
        ]
        NSLayoutConstraint.activate(wide)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isBelowCaption: Bool { isStacked }

    func align(to column: MeridianColumn) {
        barX = column.barX
        wide.first?.constant = barX
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let room = bounds.width - barX
        let shouldStack = bounds.width > 0 && room < minimumContent()
        if shouldStack != isStacked {
            wantsStacked = shouldStack
            needsUpdateConstraints = true
        }
    }

    override func updateConstraints() {
        if wantsStacked != isStacked {
            isStacked = wantsStacked
            if isStacked {
                NSLayoutConstraint.deactivate(wide)
                NSLayoutConstraint.activate(stacked)
            } else {
                NSLayoutConstraint.deactivate(stacked)
                NSLayoutConstraint.activate(wide)
            }
        }
        super.updateConstraints()
    }
}

/// Meridian, the sheet: one day laid out as a line, a lane for every place the person watches, a
/// moment they can move along it, and everything that moment means. Every figure and word is Core's
/// board; this arranges it, takes the pointer and the keyboard, and writes back only the choices the
/// board names — the pins, the style, an alarm.
///
/// It is sized by its type. Columns are measured from the words in them, nothing ellipsizes, what
/// does not fit on a line wraps or drops to the next row, and what does not fit on the page scrolls
/// with the header and footer held in place, so a larger scale makes a larger sheet and never a
/// shortened word.
@MainActor
final class MeridianSheetContent: NSView {
    private static let confirmFor: Duration = .milliseconds(1500)

    var onClose: (() -> Void)?

    private let feed = MeridianFeed.shared
    private(set) var board: MeridianBoard
    private var scrubbed: Date?

    private let scroll = NSScrollView()
    private let stack = FillingStack(topDown: true)
    private let header = MeridianFlowView()
    private let titleIcon = NSImageView()
    private let titleLabel = MeridianLabel.make("", role: .metricLarge)
    private let dateLabel = MeridianLabel.make("", role: .panelDetail, color: MacTheme.Color.secondaryLabel)
    private let headLabel = MeridianLabel.make("", role: .metricHero)
    private let deltaLabel = MeridianLabel.make("", role: .rowTitleStrong)
    private let nowButton = RowKit.ActionButton(title: Localized.text("Now"), action: {})
    let lanes = MeridianLanesView()
    let addPlace = MeridianAddPlaceView()
    private let insightCard = TintView(fill: { MacTheme.Color.info.withAlphaComponent(0.1) }, radius: 12)
    private let insightIcon = NSImageView()
    private let insightLabel = MeridianLabel.wrapping("", role: .rowTitle)
    private let machinesContent = FillingStack(topDown: true)
    private let machinesFlow = MeridianFlowView()
    private let warningLabel = MeridianLabel.wrapping(
        "", role: .panelDetail, color: ClockGlanceViewController.ink(.warn))
    private let alarmsFlow = MeridianFlowView()
    private var machinesSection: MeridianSectionRow!
    private var alarmsSection: MeridianSectionRow!
    private let footerFlow = MeridianFlowView()
    private let copyISO = MeridianCopyButton(title: Localized.text("COPY ISO"))
    private let copyUTC = MeridianCopyButton(title: Localized.text("COPY UTC"))
    private let copyEpoch = MeridianCopyButton(title: Localized.text("COPY EPOCH"))
    private let styleControl = MeridianStyleControl()
    private let notify = RowKit.ActionButton(title: "", action: {})
    private var shownMachines: [MachineClockReading]?
    private var shownWarning: String?
    private var shownAlarms: [MeridianBoard.AlarmRow]?
    private var confirmTicket = 0
    private var confirmation: String?

    init() {
        board = MeridianFeed.shared.board()
        super.init(frame: .zero)
        build()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(refresh), name: MeridianFeed.didTick, object: nil)
        center.addObserver(self, selector: #selector(refresh), name: WorldClockStore.didChange, object: nil)
        center.addObserver(self, selector: #selector(refresh), name: ClockAlarmStore.didChange, object: nil)
        center.addObserver(self, selector: #selector(refresh), name: MacTheme.Chrome.didRepaint, object: nil)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    override var acceptsFirstResponder: Bool { true }

    override var isFlipped: Bool { true }

    var focusTarget: NSView { self }

    var isFollowingNow: Bool { scrubbed == nil }

    var notifyButton: NSButton { notify }

    var copyButtons: [MeridianCopyButton] { [copyISO, copyUTC, copyEpoch] }

    var styleSegments: [MeridianStyleSegment] { styleControl.segments }

    var footer: MeridianFlowView { footerFlow }

    var isEditingPlace: Bool { addPlace.isEditing }

    func follow() {
        scrubbed = nil
        addPlace.reset()
        render()
    }

    func rerender() { render() }

    @objc private func refresh() {
        guard window != nil else { return }
        render()
    }

    private func build() {
        titleIcon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 24 * MacTheme.UIScale.factor, weight: .regular))
        titleIcon.contentTintColor = MacTheme.Color.accent
        titleIcon.setAccessibilityElement(false)
        titleIcon.translatesAutoresizingMaskIntoConstraints = false
        nowButton.setAction { [weak self] in self?.goToNow() }
        nowButton.bezelStyle = .rounded
        nowButton.controlSize = .large
        notify.setAction { [weak self] in self?.setAlarm() }
        notify.controlSize = .large
        notify.bezelColor = MacTheme.Color.accent
        notify.keyEquivalent = ""
        styleControl.onChoose = { style in WorldClockStore.update { $0.style = style } }

        lanes.onScrub = { [weak self] fraction, animated in
            guard let self else { return }
            self.scrub(to: self.board.minute(atFraction: fraction), animated: animated)
        }
        lanes.onStep = { [weak self] delta in self?.step(delta) }
        lanes.onRemove = { id in WorldClockStore.update { $0.unpin(id) } }
        lanes.onMove = { id, delta in WorldClockStore.update { $0.move(id, by: delta) } }
        lanes.onMark = { [weak self] mark in self?.alarm(for: mark) }
        lanes.onColumn = { [weak self] column in
            self?.machinesSection.align(to: column)
            self?.alarmsSection.align(to: column)
        }
        addPlace.onPin = { id in WorldClockStore.update { $0.pin(id) } }

        insightIcon.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        insightIcon.contentTintColor = MacTheme.Color.info
        insightIcon.setAccessibilityElement(false)
        insightIcon.setContentHuggingPriority(.required, for: .horizontal)
        insightIcon.translatesAutoresizingMaskIntoConstraints = false
        insightCard.addSubview(insightIcon)
        insightCard.addSubview(insightLabel)
        NSLayoutConstraint.activate([
            insightIcon.leadingAnchor.constraint(equalTo: insightCard.leadingAnchor, constant: 14),
            insightIcon.topAnchor.constraint(equalTo: insightCard.topAnchor, constant: 11),
            insightLabel.leadingAnchor.constraint(equalTo: insightIcon.trailingAnchor, constant: 10),
            insightLabel.trailingAnchor.constraint(equalTo: insightCard.trailingAnchor, constant: -14),
            insightLabel.topAnchor.constraint(equalTo: insightCard.topAnchor, constant: 10),
            insightLabel.bottomAnchor.constraint(equalTo: insightCard.bottomAnchor, constant: -10),
        ])

        machinesFlow.spacing = MacTheme.Spacing.m + 4
        machinesContent.spacing = MacTheme.Spacing.s
        machinesContent.addArrangedSubview(machinesFlow)
        machinesContent.addArrangedSubview(warningLabel)
        machinesSection = MeridianSectionRow(title: Localized.text("MACHINES"), content: machinesContent)
        alarmsSection = MeridianSectionRow(title: Localized.text("ALARMS"), content: alarmsFlow)
        machinesSection.minimumContent = { [weak self] in (self?.machinesFlow.widestItem ?? 0) + 8 }
        alarmsSection.minimumContent = { [weak self] in (self?.alarmsFlow.widestItem ?? 0) + 8 }

        header.rowSpacing = MacTheme.Spacing.m
        header.spacing = MacTheme.Spacing.xl
        header.set(leading: [titleBlock()], trailing: [timeBlock()])

        footerFlow.spacing = MacTheme.Spacing.m
        footerFlow.rowSpacing = MacTheme.Spacing.m
        footerFlow.set(leading: copyButtons + [styleControl], trailing: [notify])

        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)
        let blocks: [NSView] = [lanes, addPlace, insightCard, machinesSection, alarmsSection]
        for view in blocks { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(MacTheme.Spacing.m, after: lanes)
        stack.setCustomSpacing(MacTheme.Spacing.l, after: addPlace)
        stack.setCustomSpacing(MacTheme.Spacing.m, after: insightCard)
        stack.setCustomSpacing(MacTheme.Spacing.m, after: machinesSection)

        let doc = FlippedDocument()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        let width = stack.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -64)
        width.priority = .init(750)
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: doc.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -32),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 1120 * MacTheme.UIScale.factor),
            width,
        ])

        let foot = footerHost()
        let head = headerHost()
        addSubview(scroll)
        addSubview(foot)
        addSubview(head)
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: topAnchor),
            head.leadingAnchor.constraint(equalTo: leadingAnchor),
            head.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: head.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: foot.topAnchor),
            foot.leadingAnchor.constraint(equalTo: leadingAnchor),
            foot.trailingAnchor.constraint(equalTo: trailingAnchor),
            foot.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    private func titleBlock() -> NSView {
        let block = NSView()
        for view in [titleIcon, titleLabel, dateLabel] { block.addSubview(view) }
        NSLayoutConstraint.activate([
            titleIcon.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            titleIcon.topAnchor.constraint(equalTo: block.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: titleIcon.trailingAnchor, constant: MacTheme.Spacing.m),
            titleLabel.centerYAnchor.constraint(equalTo: titleIcon.centerYAnchor),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: block.topAnchor),
            dateLabel.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            dateLabel.topAnchor.constraint(equalTo: titleIcon.bottomAnchor, constant: MacTheme.Spacing.s),
            dateLabel.topAnchor.constraint(greaterThanOrEqualTo: titleLabel.bottomAnchor, constant: 4),
            block.trailingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor),
            block.trailingAnchor.constraint(greaterThanOrEqualTo: dateLabel.trailingAnchor),
            block.bottomAnchor.constraint(equalTo: dateLabel.bottomAnchor),
        ])
        return block
    }

    private func timeBlock() -> NSView {
        let block = NSView()
        nowButton.translatesAutoresizingMaskIntoConstraints = false
        for view in [headLabel, deltaLabel, nowButton] { block.addSubview(view) }
        NSLayoutConstraint.activate([
            headLabel.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            headLabel.topAnchor.constraint(equalTo: block.topAnchor),
            deltaLabel.topAnchor.constraint(equalTo: headLabel.bottomAnchor, constant: 4),
            deltaLabel.trailingAnchor.constraint(equalTo: headLabel.trailingAnchor),
            deltaLabel.leadingAnchor.constraint(greaterThanOrEqualTo: block.leadingAnchor),
            nowButton.leadingAnchor.constraint(equalTo: headLabel.trailingAnchor, constant: 22),
            nowButton.centerYAnchor.constraint(equalTo: block.centerYAnchor),
            block.trailingAnchor.constraint(equalTo: nowButton.trailingAnchor),
            block.bottomAnchor.constraint(equalTo: deltaLabel.bottomAnchor),
        ])
        return block
    }

    private func headerHost() -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(header)
        let width = header.widthAnchor.constraint(equalTo: host.widthAnchor, constant: -64)
        width.priority = .init(750)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: host.topAnchor, constant: 28),
            header.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -22),
            header.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            header.widthAnchor.constraint(lessThanOrEqualToConstant: 1120 * MacTheme.UIScale.factor),
            header.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 32),
            header.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -32),
            width,
        ])
        return host
    }

    private func footerHost() -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let rule = TintView(fill: { MacTheme.Color.separator })
        host.addSubview(rule)
        host.addSubview(footerFlow)
        let width = footerFlow.widthAnchor.constraint(equalTo: host.widthAnchor, constant: -64)
        width.priority = .init(750)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: host.topAnchor),
            rule.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            footerFlow.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 14),
            footerFlow.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -18),
            footerFlow.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            footerFlow.widthAnchor.constraint(lessThanOrEqualToConstant: 1120 * MacTheme.UIScale.factor),
            footerFlow.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 32),
            footerFlow.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -32),
            width,
        ])
        return host
    }

    private func render(animateLine: Bool = false) {
        let now = feed.now
        var minute: Int?
        if let scrubbed {
            let axis = DayAxis(zone: feed.viewer, containing: now)
            if axis.contains(scrubbed) { minute = axis.minute(of: scrubbed) } else { self.scrubbed = nil }
        }
        board = feed.board(now: now, scrubMinute: minute)
        restyle()
        titleLabel.stringValue = Localized.text("Meridian")
        dateLabel.stringValue = board.dateLine
        headLabel.stringValue = board.head
        deltaLabel.stringValue = board.delta
        deltaLabel.textColor =
            board.scrubMinute == board.nowMinute
            ? MacTheme.Color.accent : ClockGlanceViewController.ink(.warn)
        lanes.apply(board, animateLine: animateLine)
        addPlace.apply(preferences: feed.preferences, viewer: feed.viewer, now: now)
        renderInsight()
        renderMachines()
        renderAlarms()
        copyISO.apply(value: board.copy.iso)
        copyUTC.apply(value: board.copy.utc)
        copyEpoch.apply(value: board.copy.epoch)
        styleControl.apply(style: board.style, instant: board.scrubInstant, viewer: feed.viewer)
        notify.title = confirmation ?? board.notifyLabel
        notify.isEnabled = board.canNotify
        footerFlow.needsLayout = true
        header.needsLayout = true
    }

    private func restyle() {
        titleLabel.font = MacTheme.Ramp.font(.metricLarge)
        dateLabel.font = MacTheme.Ramp.font(.panelDetail)
        dateLabel.textColor = MacTheme.Color.secondaryLabel
        headLabel.font = MacTheme.Ramp.font(.metricHero)
        headLabel.textColor = MacTheme.Color.label
        deltaLabel.font = MacTheme.Ramp.font(.rowTitleStrong)
        insightLabel.font = MacTheme.Ramp.font(.rowTitle)
        insightLabel.textColor = MacTheme.Color.label
        warningLabel.font = MacTheme.Ramp.font(.panelDetail)
        warningLabel.textColor = ClockGlanceViewController.ink(.warn)
        titleIcon.contentTintColor = MacTheme.Color.accent
        insightIcon.contentTintColor = MacTheme.Color.info
        notify.bezelColor = MacTheme.Color.accent
        notify.font = MacTheme.Ramp.font(.control)
        nowButton.font = MacTheme.Ramp.font(.control)
    }

    private func renderInsight() {
        insightCard.isHidden = board.insight == nil
        insightLabel.stringValue = board.insight ?? ""
    }

    private func renderMachines() {
        machinesSection.isHidden = board.machines.isEmpty
        guard board.machines != shownMachines || board.skewWarning != shownWarning else { return }
        shownMachines = board.machines
        shownWarning = board.skewWarning
        machinesFlow.set(leading: board.machines.map(machineChip))
        warningLabel.stringValue = board.skewWarning ?? ""
        warningLabel.isHidden = board.skewWarning == nil
    }

    private func machineChip(_ machine: MachineClockReading) -> NSView {
        let tone = ClockGlanceViewController.color(machine.tone)
        let dot = TintView(fill: { tone }, radius: 3.5)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
        var views: [NSView] = [
            dot,
            MeridianLabel.make(machine.name, role: .rowTitleStrong),
            MeridianLabel.make(
                machine.status, role: .panelDetail, color: ClockGlanceViewController.ink(machine.tone)),
        ]
        if let time = machine.time {
            views.append(MeridianLabel.make(time, role: .statusLine))
        }
        let chip = NSStackView(views: views)
        chip.orientation = .horizontal
        chip.alignment = .centerY
        chip.spacing = MacTheme.Spacing.s
        chip.setAccessibilityElement(true)
        chip.setAccessibilityLabel("\(machine.name), \(machine.status)")
        return chip
    }

    private func renderAlarms() {
        alarmsSection.isHidden = board.alarms.isEmpty
        guard board.alarms != shownAlarms else { return }
        shownAlarms = board.alarms
        alarmsFlow.set(leading: board.alarms.map(alarmPill))
    }

    private func alarmPill(_ alarm: MeridianBoard.AlarmRow) -> NSView {
        let diamond = NSImageView()
        diamond.image = NSImage(systemSymbolName: "diamond.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .regular))
        diamond.contentTintColor = MacTheme.Color.mark
        diamond.setAccessibilityElement(false)
        let remove = MeridianIconButton(
            symbol: "xmark", label: String(format: Localized.text("Remove alarm at %@"), alarm.title)
        ) { ClockAlarmStore.update { $0.remove(alarm.id) } }
        remove.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            remove.widthAnchor.constraint(equalToConstant: MeridianIconButton.side),
            remove.heightAnchor.constraint(equalToConstant: MeridianIconButton.side),
        ])
        let row = NSStackView(views: [
            diamond, MeridianLabel.make(alarm.title, role: .statusLine),
            MeridianLabel.make(alarm.detail, role: .panelDetail, color: MacTheme.Color.secondaryLabel),
            remove,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        return MeridianPill(content: row)
    }

    func scrub(to minute: Int, animated: Bool) {
        scrubbed = board.instant(atMinute: minute)
        render(animateLine: animated)
    }

    func step(_ delta: Int) {
        scrub(to: min(max(board.scrubMinute + delta, 0), board.minutes - 1), animated: false)
    }

    func goToStartOfDay() { scrub(to: 0, animated: false) }

    func goToEndOfDay() { scrub(to: board.minutes - 1, animated: false) }

    func goToNow() {
        scrubbed = nil
        render(animateLine: true)
    }

    func handleEscape() -> Bool { addPlace.handleEscape() }

    private func setAlarm() {
        confirm(
            ClockAlarmStore.add(at: board.scrubInstant, zoneID: feed.viewer.identifier) == nil
                ? Localized.text("Already set") : Localized.text("Alarm set"))
    }

    private func alarm(for mark: MeridianBoard.Mark) {
        let reset = feed.resets(now: feed.now).first { "reset.\($0.id)" == mark.id }
        let note = reset.map { String(format: Localized.text("%@ window reopens"), $0.provider) }
        confirm(
            ClockAlarmStore.add(at: mark.instant, zoneID: feed.viewer.identifier, note: note) == nil
                ? Localized.text("Already set") : Localized.text("Alarm set"))
    }

    private func confirm(_ text: String) {
        confirmation = text
        confirmTicket += 1
        let ticket = confirmTicket
        notify.title = text
        footerFlow.needsLayout = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.confirmFor)
            guard let self, ticket == self.confirmTicket else { return }
            self.confirmation = nil
            self.notify.title = self.board.notifyLabel
            self.footerFlow.needsLayout = true
        }
    }
}

/// A removable chip that carries its own padding and wraps a row of views in a capsule, for alarms.
@MainActor
final class MeridianPill: NSView {
    private let content: NSView
    private let ground = TintView(
        fill: { MacTheme.Color.canvasRaised }, stroke: { MacTheme.Color.separator })

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        ground.translatesAutoresizingMaskIntoConstraints = true
        addSubview(ground)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let fitting = content.fittingSize
        return NSSize(width: ceil(fitting.width) + 16, height: ceil(fitting.height) + 8)
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
    }
}

/// Meridian's host: the sheet the window raises over its content, with the keys the line answers to.
/// It is the same host the Studio and the picture viewer use, so the scrim, the motion, the focus trap
/// and Esc, ⌘W and Done closing this sheet and nothing beneath it are theirs and are not written twice.
@MainActor
final class MeridianSheetController {
    static let shared = MeridianSheetController()

    let presenter: SheetPresenter
    let content: MeridianSheetContent
    private let toolbar = SheetToolbarView()
    private var keyMonitor: Any?

    init(stack: SheetStack = .shared) {
        content = MeridianSheetContent()
        let sheet = SheetView(
            content: content, toolbar: toolbar, dialogName: Localized.text("Meridian, dialog"),
            closeLabel: Localized.text("Close Meridian"))
        presenter = SheetPresenter(sheet: sheet, stack: stack)
        let done = RowKit.ActionButton(title: Localized.text("Done")) { [weak self] in
            self?.presenter.dismiss()
        }
        done.setAccessibilityLabel(Localized.text("Close Meridian"))
        toolbar.trailing = [done]
        content.onClose = { [weak self] in self?.presenter.dismiss() }
        presenter.onClosed = { [weak self] in self?.sheetClosed() }
    }

    var isUp: Bool { presenter.state != .closed }

    var sheet: SheetView { presenter.sheet }

    func present(in window: NSWindow) {
        guard !isUp else { return }
        content.follow()
        let effect = presenter.show(in: window, ready: { _ = window.makeFirstResponder(content.focusTarget) })
        if case .animateIn = effect { listen() }
    }

    private func listen() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            nonisolated(unsafe) let pressed = event
            let consumed = MainThread.call { self.consumes(pressed) }
            return consumed ? nil : event
        }
    }

    private func sheetClosed() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func consumes(_ event: NSEvent) -> Bool {
        guard presenter.ownsKeys, event.window === sheet.host else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty else { return false }
        if event.keyCode == 53 {
            if !content.handleEscape() { presenter.dismiss() }
            return true
        }
        guard !content.isEditingPlace else { return false }
        return press(keyCode: event.keyCode, shift: event.modifierFlags.contains(.shift))
    }

    /// What a key does to the line: ← → a minute (a quarter hour with Shift), Home and End the start
    /// and end of the day. Anything else is whoever has focus's.
    @discardableResult
    func press(keyCode: UInt16, shift: Bool) -> Bool {
        let amount = shift ? 15 : 1
        switch keyCode {
        case 123: content.step(-amount)
        case 124: content.step(amount)
        case 115: content.goToStartOfDay()
        case 119: content.goToEndOfDay()
        default: return false
        }
        return true
    }
}

import AppKit
import TailscodeCore

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

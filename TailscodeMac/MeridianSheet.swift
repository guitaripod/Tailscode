import AppKit
import TailscodeCore

/// A wrapping label that tells Auto Layout how tall its words are once it knows how wide it is, which
/// a bare text field only learns on a second pass the sheet's stack does not give it.
@MainActor
final class MeridianWrapLabel: NSTextField {
    override func layout() {
        super.layout()
        guard preferredMaxLayoutWidth != bounds.width else { return }
        preferredMaxLayoutWidth = bounds.width
        invalidateIntrinsicContentSize()
    }
}

/// The footer's copy buttons: a caption over the value it will put on the pasteboard, which says
/// *Copied* in place of the caption for a moment afterwards. The value follows the line as it moves.
@MainActor
final class MeridianCopyButton: NSView {
    private static let confirmFor: Duration = .milliseconds(1200)

    private let ground = TintView(
        fill: { MacTheme.Color.canvasRaised }, stroke: { MacTheme.Color.separator }, radius: 14)
    private let caption = StudioTheme.label(.metricLabel, color: MacTheme.Color.secondaryLabel)
    private let value = StudioTheme.label(.rowStamp)
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
        let captionWidth = max(
            captionSize(title).width, captionSize(Localized.text("Copied")).width)
        let width = max(captionWidth, MeridianMetrics.fit(value).width)
        return NSSize(width: ceil(width) + 28, height: 44)
    }

    private func captionSize(_ text: String) -> NSSize {
        let size = NSAttributedString(
            string: text.uppercased(), attributes: MacTheme.Ramp.attributes(.metricLabel)
        ).size()
        return NSSize(width: size.width + 6, height: size.height)
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
        let captionHeight = StudioTheme.height(of: .metricLabel)
        let valueHeight = StudioTheme.height(of: .rowStamp)
        let top = (bounds.height - captionHeight - valueHeight) / 2
        caption.frame = CGRect(
            x: 14, y: bounds.height - top - captionHeight, width: bounds.width - 28,
            height: captionHeight)
        value.frame = CGRect(
            x: 14, y: bounds.height - top - captionHeight - valueHeight, width: bounds.width - 28,
            height: valueHeight)
    }

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

    /// Puts exactly the value on the pasteboard and says so on the button for a moment.
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

/// Meridian, the sheet: one day laid out as a line, a lane for every place the person watches, a
/// moment they can move along it, and everything that moment means. Every figure and word is Core's
/// board; this arranges it, takes the pointer and the keyboard, and writes back only the choices the
/// board names — the pins, the style, an alarm.
///
/// The moment is held as an instant while it is scrubbed and as nothing while the sheet follows the
/// clock, so a day that ends under a scrubbed line hands the sheet back to the clock instead of
/// pointing it at a minute of another day.
@MainActor
final class MeridianSheetContent: NSView {
    private static let confirmFor: Duration = .milliseconds(1500)

    var onClose: (() -> Void)?

    private let feed = MeridianFeed.shared
    private(set) var board: MeridianBoard
    private var scrubbed: Date?

    private let scroll = NSScrollView()
    private let stack = FillingStack(topDown: true)
    private let titleIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let headLabel = NSTextField(labelWithString: "")
    private let deltaLabel = NSTextField(labelWithString: "")
    private let nowButton = RowKit.ActionButton(title: Localized.text("Now"), action: {})
    let lanes = MeridianLanesView()
    private let cityField = NSSearchField()
    private let cityResults = NSStackView()
    private let insightCard = TintView(fill: { MacTheme.Color.info.withAlphaComponent(0.1) }, radius: 12)
    private let insightIcon = NSImageView()
    private let insightLabel = MeridianWrapLabel(wrappingLabelWithString: "")
    private let machinesRow = NSStackView()
    private let alarmsBlock = FillingStack(topDown: true, stretches: false)
    private let copyISO = MeridianCopyButton(title: Localized.text("COPY ISO"))
    private let copyUTC = MeridianCopyButton(title: Localized.text("COPY UTC"))
    private let copyEpoch = MeridianCopyButton(title: Localized.text("COPY EPOCH"))
    private let styleMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let escapeHint = NSTextField(labelWithString: "")
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

    var searchField: NSSearchField { cityField }

    var notifyButton: NSButton { notify }

    var copyButtons: [MeridianCopyButton] { [copyISO, copyUTC, copyEpoch] }

    func follow() {
        scrubbed = nil
        cityField.stringValue = ""
        refreshResults()
        render()
    }

    @objc private func refresh() {
        guard window != nil else { return }
        render()
    }

    private func build() {
        titleIcon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 24, weight: .regular))
        titleIcon.contentTintColor = MacTheme.Color.accent
        titleIcon.setAccessibilityElement(false)
        titleLabel.stringValue = Localized.text("Meridian")
        titleLabel.setAccessibilityRole(.staticText)
        nowButton.setAction { [weak self] in self?.goToNow() }
        nowButton.bezelStyle = .rounded
        nowButton.controlSize = .large
        notify.setAction { [weak self] in self?.setAlarm() }
        notify.controlSize = .large
        notify.bezelColor = MacTheme.Color.accent
        notify.keyEquivalent = ""
        styleMenu.controlSize = .regular
        for style in ClockStyle.allCases { styleMenu.addItem(withTitle: style.title) }
        styleMenu.target = self
        styleMenu.action = #selector(styleChosen)
        styleMenu.setAccessibilityLabel(Localized.text("Time style"))

        lanes.onScrub = { [weak self] fraction, animated in
            guard let self else { return }
            self.scrub(to: self.board.minute(atFraction: fraction), animated: animated)
        }
        lanes.onStep = { [weak self] delta in self?.step(delta) }
        lanes.onRemove = { id in WorldClockStore.update { $0.unpin(id) } }
        lanes.onMove = { id, delta in WorldClockStore.update { $0.move(id, by: delta) } }
        lanes.onMark = { [weak self] mark in self?.alarm(for: mark) }

        cityField.delegate = self
        cityField.sendsSearchStringImmediately = true
        cityField.setAccessibilityLabel(Localized.text("Add a city"))

        cityResults.orientation = .horizontal
        cityResults.alignment = .centerY
        cityResults.spacing = MacTheme.Spacing.s
        cityResults.translatesAutoresizingMaskIntoConstraints = false
        cityResults.isHidden = true

        insightIcon.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        insightIcon.contentTintColor = MacTheme.Color.info
        insightIcon.setAccessibilityElement(false)
        insightIcon.setContentHuggingPriority(.required, for: .horizontal)
        insightLabel.translatesAutoresizingMaskIntoConstraints = false
        insightLabel.isSelectable = false
        insightLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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

        machinesRow.orientation = .horizontal
        machinesRow.alignment = .firstBaseline
        machinesRow.spacing = MacTheme.Spacing.m
        machinesRow.translatesAutoresizingMaskIntoConstraints = false
        alarmsBlock.spacing = MacTheme.Spacing.xs

        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 0, bottom: 20, right: 0)
        stack.addArrangedSubview(header())
        stack.setCustomSpacing(26, after: stack.arrangedSubviews[0])
        for view in [lanes, cityRow(), insightCard, machinesBlock(), alarmsBlock] {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(14, after: lanes)
        stack.setCustomSpacing(16, after: stack.arrangedSubviews[2])
        stack.setCustomSpacing(12, after: insightCard)
        stack.setCustomSpacing(12, after: machinesRow)

        let doc = FlippedDocument()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
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
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 1120),
            width,
        ])

        let foot = footer()
        addSubview(scroll)
        addSubview(foot)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
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

    private func header() -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let views: [NSView] = [titleIcon, titleLabel, dateLabel, headLabel, deltaLabel, nowButton]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleIcon.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            titleIcon.topAnchor.constraint(equalTo: host.topAnchor),
            titleLabel.leadingAnchor.constraint(
                equalTo: titleIcon.trailingAnchor, constant: MacTheme.Spacing.m),
            titleLabel.centerYAnchor.constraint(equalTo: titleIcon.centerYAnchor),
            dateLabel.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            dateLabel.topAnchor.constraint(equalTo: titleIcon.bottomAnchor, constant: 8),
            nowButton.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            nowButton.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            headLabel.trailingAnchor.constraint(equalTo: nowButton.leadingAnchor, constant: -22),
            headLabel.topAnchor.constraint(equalTo: host.topAnchor),
            headLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 24),
            deltaLabel.trailingAnchor.constraint(equalTo: headLabel.trailingAnchor),
            deltaLabel.topAnchor.constraint(equalTo: headLabel.bottomAnchor, constant: 4),
            host.bottomAnchor.constraint(equalTo: deltaLabel.bottomAnchor),
            host.bottomAnchor.constraint(greaterThanOrEqualTo: dateLabel.bottomAnchor),
        ])
        return host
    }

    private func cityRow() -> NSView {
        cityField.translatesAutoresizingMaskIntoConstraints = false
        cityField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let row = NSStackView(views: [cityField, cityResults, RowKit.spacer()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func machinesBlock() -> NSView { machinesRow }

    private func footer() -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let rule = TintView(fill: { MacTheme.Color.separator })
        let row = NSStackView(
            views: copyButtons + [RowKit.spacer(), escapeHint, styleMenu, notify])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(rule)
        host.addSubview(row)
        let width = row.widthAnchor.constraint(equalTo: host.widthAnchor, constant: -64)
        width.priority = .init(750)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: host.topAnchor),
            rule.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            row.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -18),
            row.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            row.widthAnchor.constraint(lessThanOrEqualToConstant: 1120),
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
        let atNow = board.scrubMinute == board.nowMinute
        deltaLabel.textColor = atNow ? MacTheme.Color.accent : MacTheme.Color.warning
        lanes.apply(board, animateLine: animateLine)
        renderInsight()
        renderMachines()
        renderAlarms()
        copyISO.apply(value: board.copy.iso)
        copyUTC.apply(value: board.copy.utc)
        copyEpoch.apply(value: board.copy.epoch)
        notify.title = confirmation ?? board.notifyLabel
        notify.isEnabled = board.canNotify
        if let index = ClockStyle.allCases.firstIndex(of: board.style),
            styleMenu.indexOfSelectedItem != index
        {
            styleMenu.selectItem(at: index)
        }
        renderCityField()
    }

    private func restyle() {
        titleLabel.font = MacTheme.Ramp.font(.metricLarge)
        titleLabel.textColor = MacTheme.Color.label
        dateLabel.font = MacTheme.Ramp.font(.panelDetail)
        dateLabel.textColor = MacTheme.Color.secondaryLabel
        headLabel.font = MacTheme.Ramp.font(.metricHero)
        headLabel.textColor = MacTheme.Color.label
        deltaLabel.font = MacTheme.Ramp.font(.rowTitleStrong)
        escapeHint.font = MacTheme.Ramp.font(.panelDetail)
        escapeHint.textColor = MacTheme.Color.secondaryLabel
        escapeHint.stringValue = Localized.text("Esc closes")
        insightLabel.font = MacTheme.Ramp.font(.rowTitle)
        insightLabel.textColor = MacTheme.Color.label
        cityField.font = MacTheme.Ramp.font(.control)
        styleMenu.font = MacTheme.Ramp.font(.control)
        titleIcon.contentTintColor = MacTheme.Color.accent
        insightIcon.contentTintColor = MacTheme.Color.info
        notify.bezelColor = MacTheme.Color.accent
    }

    private func renderInsight() {
        insightCard.isHidden = board.insight == nil
        insightLabel.stringValue = board.insight ?? ""
    }

    private func renderMachines() {
        guard board.machines != shownMachines || board.skewWarning != shownWarning else { return }
        shownMachines = board.machines
        shownWarning = board.skewWarning
        machinesRow.arrangedSubviews.forEach {
            machinesRow.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        machinesRow.isHidden = board.machines.isEmpty
        guard !board.machines.isEmpty else { return }
        let heading = NSTextField(labelWithString: "")
        heading.attributedStringValue = NSAttributedString(
            string: Localized.text("MACHINES"),
            attributes: MacTheme.Ramp.attributes(.sectionLabel, color: MacTheme.Color.secondaryLabel))
        machinesRow.addArrangedSubview(heading)
        defer { machinesRow.addArrangedSubview(RowKit.spacer()) }
        for machine in board.machines {
            let tone = ClockGlanceViewController.color(machine.tone)
            let name = RowKit.label(
                machine.name, font: MacTheme.Ramp.font(.rowTitleStrong), color: MacTheme.Color.label)
            let status = RowKit.label(
                machine.status, font: MacTheme.Ramp.font(.panelDetail), color: tone)
            let pair = NSStackView(views: [name, status])
            pair.orientation = .horizontal
            pair.alignment = .firstBaseline
            pair.spacing = MacTheme.Spacing.xs + 2
            pair.setAccessibilityElement(true)
            pair.setAccessibilityLabel("\(machine.name), \(machine.status)")
            machinesRow.addArrangedSubview(pair)
        }
        if let warning = board.skewWarning {
            machinesRow.addArrangedSubview(
                RowKit.label(
                    warning, font: MacTheme.Ramp.font(.panelDetail), color: MacTheme.Color.warning))
        }
    }

    private func renderAlarms() {
        guard board.alarms != shownAlarms else { return }
        shownAlarms = board.alarms
        alarmsBlock.arrangedSubviews.forEach {
            alarmsBlock.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        alarmsBlock.isHidden = board.alarms.isEmpty
        guard !board.alarms.isEmpty else { return }
        let heading = NSTextField(labelWithString: "")
        heading.attributedStringValue = NSAttributedString(
            string: Localized.text("ALARMS"),
            attributes: MacTheme.Ramp.attributes(.sectionLabel, color: MacTheme.Color.secondaryLabel))
        alarmsBlock.addArrangedSubview(heading)
        alarmsBlock.setCustomSpacing(MacTheme.Spacing.s, after: heading)
        for alarm in board.alarms {
            alarmsBlock.addArrangedSubview(alarmRow(alarm))
        }
    }

    private func alarmRow(_ alarm: MeridianBoard.AlarmRow) -> NSView {
        let diamond = NSImageView()
        diamond.image = NSImage(systemSymbolName: "diamond.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .regular))
        diamond.contentTintColor = MacTheme.Color.mark
        diamond.setAccessibilityElement(false)
        let time = RowKit.label(
            alarm.title, font: MacTheme.Ramp.font(.statusLine), color: MacTheme.Color.label)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        let detail = RowKit.label(
            alarm.detail, font: MacTheme.Ramp.font(.panelDetail), color: MacTheme.Color.secondaryLabel)
        let remove = RowKit.ActionButton(title: "") {
            ClockAlarmStore.update { $0.remove(alarm.id) }
        }
        remove.image = NSImage(
            systemSymbolName: "xmark.circle.fill", accessibilityDescription: Localized.text("Remove"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        remove.contentTintColor = MacTheme.Color.secondaryLabel
        remove.imagePosition = .imageOnly
        remove.isBordered = false
        remove.setAccessibilityLabel(Localized.text("Remove alarm at %@", alarm.title))
        let row = NSStackView(views: [diamond, time, detail, remove, RowKit.spacer()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        row.setAccessibilityElement(false)
        return row
    }

    private func renderCityField() {
        let full = feed.preferences.pins.count >= WorldClockPreferences.maxPins
        cityField.isEnabled = !full
        cityField.placeholderString =
            full
            ? Localized.text("Up to %d cities", WorldClockPreferences.maxPins)
            : Localized.text("Add a city")
    }

    private func refreshResults() {
        cityResults.arrangedSubviews.forEach {
            cityResults.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let matches = cityMatches()
        cityResults.isHidden = matches.isEmpty
        for city in matches {
            let chip = SymbolChip()
            chip.text = city.country.isEmpty ? city.name : "\(city.name) · \(city.country)"
            chip.onTap = { [weak self] in self?.pin(city) }
            chip.setAccessibilityLabel(Localized.text("Add %@", city.name))
            cityResults.addArrangedSubview(chip)
        }
    }

    private func cityMatches() -> [WorldCity] {
        let query = cityField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return WorldCities.search(query, excluding: Set(feed.preferences.pins), limit: 6)
    }

    private func pin(_ city: WorldCity) {
        cityField.stringValue = ""
        refreshResults()
        WorldClockStore.update { $0.pin(city.id) }
    }

    func pinFirstMatch() {
        guard let first = cityMatches().first else { return }
        pin(first)
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

    private func setAlarm() {
        confirm(
            ClockAlarmStore.add(at: board.scrubInstant, zoneID: feed.viewer.identifier) == nil
                ? Localized.text("Already set") : Localized.text("Alarm set"))
    }

    private func alarm(for mark: MeridianBoard.Mark) {
        let reset = feed.resets(now: feed.now).first { "reset.\($0.id)" == mark.id }
        confirm(
            ClockAlarmStore.add(at: mark.instant, zoneID: feed.viewer.identifier, note: reset?.alarmNote)
                == nil
                ? Localized.text("Already set") : Localized.text("Alarm set"))
    }

    private func confirm(_ text: String) {
        confirmation = text
        confirmTicket += 1
        let ticket = confirmTicket
        notify.title = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.confirmFor)
            guard let self, ticket == self.confirmTicket else { return }
            self.confirmation = nil
            self.notify.title = self.board.notifyLabel
        }
    }

    @objc private func styleChosen() {
        let index = styleMenu.indexOfSelectedItem
        guard ClockStyle.allCases.indices.contains(index) else { return }
        let style = ClockStyle.allCases[index]
        WorldClockStore.update { $0.style = style }
    }

    var isEditingCity: Bool {
        guard let editor = window?.firstResponder as? NSText else { return false }
        return editor.delegate === cityField
    }

    func clearCityField() {
        cityField.stringValue = ""
        refreshResults()
    }
}

extension MeridianSheetContent: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { refreshResults() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        pinFirstMatch()
        return true
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
            let consumed = MainActor.assumeIsolated { self.consumes(pressed) }
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
            if content.isEditingCity, !content.searchField.stringValue.isEmpty {
                content.clearCityField()
            } else {
                presenter.dismiss()
            }
            return true
        }
        guard !content.isEditingCity else { return false }
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

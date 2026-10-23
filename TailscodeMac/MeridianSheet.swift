import AppKit
import TailscodeCore

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

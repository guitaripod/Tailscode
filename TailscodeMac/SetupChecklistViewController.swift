import AppKit
import TailscodeCore

/// One capability's checklist on one machine, drawn from Core's `SetupChecklist` and nothing else: a
/// headline with its state, a card per row (glyph, title, one line of facts, and the row's fix), and
/// the single primary button pinned under the list so it never scrolls out of reach. Content sits on
/// the opaque canvas; glass is for the layer that floats above it.
///
/// A row is redrawn only when its value changed, and a bar that moved is written where it stands, so
/// a download that lands a reading every second moves neither a button nor a selection.
@MainActor
final class SetupChecklistViewController: NSViewController {
    static let width: CGFloat = 560

    var onFinish: (() -> Void)?
    var onClose: (() -> Void)?

    private let target: SetupTarget
    private let reportLines: () -> [String]
    private let lifetime = PaneLifetime()
    private let column = FillingStack()
    private let ground = RowKit.Ground(frame: .zero)
    private let icon = ActivityBadgeView(pointSize: 22)
    private let nameLabel = NSTextField(labelWithString: "")
    private let headline = NSTextField(wrappingLabelWithString: "")
    private let titleLine = NSStackView()
    private let primary = NSButton()
    private let closeButton = NSButton()
    private var badge: BetaBadge?
    private var badgeFeature: BetaFeature?
    private var rowViews: [String: SetupRowCard] = [:]
    private var order: [String] = []
    private var checklist: SetupChecklist?
    private var copied = false
    private var copiedTicket = 0

    init(target: SetupTarget, reportLines: @escaping () -> [String]) {
        self.target = target
        self.reportLines = reportLines
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit { lifetime.cancelAll() }

    override func loadView() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        ground.fill = MacTheme.Color.canvas
        content.addSubview(ground)

        nameLabel.font = MacTheme.Ramp.font(.panelLabel)
        nameLabel.textColor = MacTheme.Color.secondaryLabel
        headline.font = MacTheme.Ramp.font(.panelTitle)
        headline.textColor = MacTheme.Color.label
        headline.setAccessibilityRole(.staticText)
        titleLine.orientation = .horizontal
        titleLine.alignment = .centerY
        titleLine.spacing = MacTheme.Spacing.s
        titleLine.addArrangedSubview(nameLabel)

        let titles = NSStackView(views: [titleLine, headline])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = MacTheme.Spacing.xs
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let header = NSStackView(views: [icon, titles])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = MacTheme.Spacing.m

        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 16, right: 24)
        column.addArrangedSubview(header)

        let scroll = MacDialogs.scrollColumn(holding: column)
        content.addSubview(scroll)

        closeButton.title = Localized.text("Close")
        closeButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.keyEquivalent = "\u{1b}"
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        primary.target = self
        primary.action = #selector(primaryPressed)
        primary.isHidden = true
        let footer = NSStackView(views: [NSView(), closeButton, primary])
        footer.orientation = .horizontal
        footer.spacing = MacTheme.Spacing.s
        footer.edgeInsets = NSEdgeInsets(top: 12, left: 24, bottom: 16, right: 24)
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)

        NSLayoutConstraint.activate([
            ground.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ground.topAnchor.constraint(equalTo: content.topAnchor),
            ground.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.width),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
        view = content
        apply(SetupChecklist(snapshot: SetupSnapshot(target: target)))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        MacSetupGate.desk.follow(target, lifetime: lifetime) { [weak self] snapshot in
            Task { @MainActor in self?.apply(SetupChecklist(snapshot: snapshot)) }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        lifetime.cancelAll()
    }

    func restyle() {
        ground.fill = MacTheme.Color.canvas
        ground.needsDisplay = true
        nameLabel.font = MacTheme.Ramp.font(.panelLabel)
        headline.font = MacTheme.Ramp.font(.panelTitle)
        for card in rowViews.values { card.restyle() }
    }

    private func apply(_ next: SetupChecklist) {
        checklist = next
        nameLabel.stringValue = next.name
        placeBadge(for: next)
        icon.show(next.icon, spoken: next.headline)
        headline.stringValue = next.headline
        renderRows(next.rows)
        renderPrimary(next.primary)
    }

    private func placeBadge(for next: SetupChecklist) {
        guard next.beta != badgeFeature else { return }
        badge?.removeFromSuperview()
        badge = nil
        badgeFeature = next.beta
        guard let feature = next.beta else { return }
        let made = BetaBadge(feature: feature, reportLines: reportLines)
        titleLine.addArrangedSubview(made)
        badge = made
    }

    private func renderRows(_ rows: [SetupRow]) {
        let ids = rows.map(\.id)
        for stale in Set(rowViews.keys).subtracting(ids) {
            rowViews[stale]?.removeFromSuperview()
            rowViews[stale] = nil
        }
        for row in rows {
            if let existing = rowViews[row.id] {
                existing.apply(row)
            } else {
                let made = SetupRowCard(row: row)
                made.onFix = { [weak self] fix in self?.start(fix) }
                made.onCancel = { [weak self] in self?.cancel() }
                rowViews[row.id] = made
            }
        }
        guard ids != order else { return }
        for view in rowViews.values { column.removeArrangedSubview(view) }
        for id in ids {
            if let view = rowViews[id] { column.addArrangedSubview(view) }
        }
        order = ids
    }

    private func renderPrimary(_ action: SetupAction?) {
        guard let action else {
            primary.isHidden = true
            return
        }
        primary.isHidden = false
        if case .copy = action, copied {
            primary.title = DelegateSetup.copied
        } else {
            primary.title = action.label
        }
        primary.setAccessibilityLabel(action.label)
    }

    @objc private func primaryPressed() {
        guard let action = checklist?.primary else { return }
        MacHaptics.shared.play(.tap)
        switch action {
        case .setUp:
            let target = target
            Task { await MacSetupGate.desk.runAll(target) }
        case .copy(let command, _):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            MacHaptics.shared.play(.success)
            flashCopied()
        case .finish:
            onFinish?()
        case .askPassword:
            askPassword()
        }
    }

    @objc private func closePressed() { onClose?() }

    private func flashCopied() {
        copied = true
        renderPrimary(checklist?.primary)
        copiedTicket += 1
        let ticket = copiedTicket
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, self.copiedTicket == ticket else { return }
            self.copied = false
            self.renderPrimary(self.checklist?.primary)
        }
    }

    private func start(_ fix: SetupRowFix) {
        MacHaptics.shared.play(.tap)
        let target = target
        Task { await MacSetupGate.desk.start(fix: fix.id, for: target) }
    }

    private func cancel() {
        MacHaptics.shared.play(.tap)
        let target = target
        Task { await MacSetupGate.desk.cancel(target) }
    }

    private func askPassword() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = checklist?.name ?? ""
        alert.informativeText = VoiceReach.wantsPassword.line
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = Localized.text("Password")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: Localized.text("Save"))
        alert.addButton(withTitle: Localized.text("Cancel"))
        let target = target
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            let text = field.stringValue
            Task { await MacSetupGate.desk.remember(password: text, for: target) }
        }
    }
}

/// The sheet that carries one checklist. It is retained for exactly as long as it is on screen, the
/// way the other sheets are, and it ends the desk's watch when it goes.
@MainActor
final class SetupSheet: NSObject {
    private static var active: SetupSheet?

    private let window: NSWindow
    private let controller: SetupChecklistViewController
    private let target: SetupTarget
    private var finish: (() -> Void)?

    static func present(
        target: SetupTarget, on host: NSWindow?, reportLines: @escaping () -> [String], onFinish: (() -> Void)?
    ) {
        if let open = active, open.target == target {
            open.finish = onFinish ?? open.finish
            return
        }
        guard let host else { return }
        let made = SetupSheet(target: target, reportLines: reportLines, onFinish: onFinish)
        active = made
        host.beginSheet(made.window) { _ in
            made.controller.viewDidDisappear()
            if active === made { active = nil }
        }
    }

    private init(target: SetupTarget, reportLines: @escaping () -> [String], onFinish: (() -> Void)?) {
        self.target = target
        finish = onFinish
        controller = SetupChecklistViewController(target: target, reportLines: reportLines)
        window = NSWindow(contentViewController: controller)
        super.init()
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        window.title = SetupReading.name(of: target.capability)
        controller.onClose = { [weak self] in self?.end() }
        controller.onFinish = { [weak self] in
            guard let self else { return }
            let next = self.finish
            self.end()
            next?()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @objc private func repaint() { controller.restyle() }

    private func end() {
        window.sheetParent?.endSheet(window)
    }
}

/// One row of the checklist as a card: its state on the glyph, the title, one line of facts, and the
/// row's fix as a button for a job, a bar with Cancel while it runs, or a command to copy.
@MainActor
private final class SetupRowCard: NSView {
    var onFix: ((SetupRowFix) -> Void)?
    var onCancel: (() -> Void)?

    private var row: SetupRow
    private let badge = ActivityBadgeView(pointSize: 18)
    private let body = FillingStack(topDown: false, stretches: false)
    private let ground = RowKit.Ground(frame: .zero)
    private var bar: NSProgressIndicator?
    private var jobLabel: NSTextField?
    private var copyTicket = 0

    init(row: SetupRow) {
        self.row = row
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(ground)
        body.spacing = MacTheme.Spacing.xs
        badge.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        addSubview(body)
        NSLayoutConstraint.activate([
            ground.leadingAnchor.constraint(equalTo: leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: trailingAnchor),
            ground.topAnchor.constraint(equalTo: topAnchor),
            ground.bottomAnchor.constraint(equalTo: bottomAnchor),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.m),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.m),
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),
            body.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: MacTheme.Spacing.m),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.m),
            body.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.m),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.m),
        ])
        setAccessibilityElement(false)
        rebuild()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func restyle() { rebuild() }

    func apply(_ next: SetupRow) {
        guard next != row else { return }
        let sameShape = Self.shape(row) == Self.shape(next)
        row = next
        if sameShape, let bar, let jobLabel, let job = next.job {
            if let fraction = job.fraction { bar.doubleValue = min(1, max(0, fraction)) }
            jobLabel.stringValue = job.waiting ? Localized.text("Waiting for its turn") : (job.line ?? job.step ?? "")
            return
        }
        rebuild()
    }

    private static func shape(_ row: SetupRow) -> String {
        "\(row.state)|\(row.fix?.id ?? "")|\(row.fix?.enabled ?? true)|\(row.fix?.command ?? "")|\(row.job != nil)|\(row.job?.fraction != nil)|\(row.failure ?? "")|\(row.line ?? "")|\(row.title)"
    }

    private func rebuild() {
        for view in body.arrangedSubviews {
            body.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        bar = nil
        jobLabel = nil
        let border: NSColor =
            switch row.state {
            case .needsYou: MacTheme.Color.warning
            case .failed: MacTheme.Color.danger
            default: MacTheme.Color.separator
            }
        ground.fill = row.state == .done ? nil : MacTheme.Color.canvasRaised
        ground.stroke = row.state == .done ? nil : border
        ground.radius = MacTheme.Radius.card
        ground.needsDisplay = true
        badge.show(row.icon, spoken: row.word)
        body.addArrangedSubview(RowKit.wrapping(row.title, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label))
        if let line = row.line, !line.isEmpty {
            body.addArrangedSubview(
                RowKit.wrapping(line, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel))
        }
        if let failure = row.failure {
            body.addArrangedSubview(
                RowKit.wrapping(failure, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.danger))
        }
        if let job = row.job {
            addJob(job)
        } else if let fix = row.fix {
            addFix(fix)
        }
    }

    private func addJob(_ job: SetupRowJob) {
        if let fraction = job.fraction {
            let made = NSProgressIndicator()
            made.isIndeterminate = false
            made.minValue = 0
            made.maxValue = 1
            made.doubleValue = min(1, max(0, fraction))
            made.style = .bar
            made.controlSize = .small
            made.translatesAutoresizingMaskIntoConstraints = false
            bar = made
            body.addArrangedSubview(made)
            made.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        let measure = RowKit.wrapping(
            job.waiting ? Localized.text("Waiting for its turn") : (job.line ?? job.step ?? ""),
            font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel)
        jobLabel = measure
        let cancel = SetupButton(title: Localized.text("Cancel")) { [weak self] in self?.onCancel?() }
        cancel.bezelStyle = .inline
        let line = NSStackView(views: [measure, cancel])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = MacTheme.Spacing.m
        body.addArrangedSubview(line)
    }

    private func addFix(_ fix: SetupRowFix) {
        switch fix.kind {
        case .job:
            let title = row.state == .failed ? Localized.text("Try again") : fix.label
            let button = SetupButton(title: title) { [weak self] in self?.onFix?(fix) }
            button.isEnabled = fix.enabled
            var parts: [NSView] = [button]
            if let cost = fix.cost {
                parts.append(MacDialogs.detailLabel(cost))
            }
            let line = NSStackView(views: parts)
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = MacTheme.Spacing.m
            body.addArrangedSubview(line)
        case .command:
            guard let command = fix.command else { return }
            body.addArrangedSubview(commandBlock(command))
            if let reason = fix.reason {
                body.addArrangedSubview(
                    RowKit.wrapping(reason, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel))
            }
        }
    }

    private func commandBlock(_ command: String) -> NSView {
        let text = RowKit.wrapping(command, font: MacTheme.Ramp.font(.code), color: MacTheme.Color.label)
        text.lineBreakMode = .byCharWrapping
        let copy = SetupButton(title: Localized.text("Copy")) { [weak self] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            MacHaptics.shared.play(.success)
            self?.flashCopy()
        }
        copy.bezelStyle = .inline
        copy.setContentHuggingPriority(.required, for: .horizontal)
        let block = NSStackView(views: [text, copy])
        block.orientation = .horizontal
        block.alignment = .top
        block.spacing = MacTheme.Spacing.s
        block.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 6)
        block.translatesAutoresizingMaskIntoConstraints = false
        RowKit.ground(behind: block, fill: MacTheme.Color.canvas, stroke: MacTheme.Color.separator, radius: MacTheme.Radius.control)
        return block
    }

    private func flashCopy() {
        guard let button = findCopyButton() else { return }
        copyTicket += 1
        let ticket = copyTicket
        button.title = DelegateSetup.copied
        Task { [weak self, weak button] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, self.copyTicket == ticket else { return }
            button?.title = Localized.text("Copy")
        }
    }

    private func findCopyButton() -> NSButton? {
        for view in body.arrangedSubviews {
            if let stack = view as? NSStackView, let button = stack.arrangedSubviews.last as? SetupButton { return button }
        }
        return nil
    }
}

/// A button whose action is a closure, for cards built per row where a selector would need a lookup
/// table on the side.
@MainActor
private final class SetupButton: NSButton {
    private let onClick: @MainActor () -> Void

    init(title: String, onClick: @escaping @MainActor () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        self.title = title
        setButtonType(.momentaryPushIn)
        bezelStyle = .rounded
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { onClick() }
}

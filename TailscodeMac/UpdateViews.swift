import AppKit
import TailscodeCore

/// The one place a `UpdateReading` becomes AppKit, so the servers window and the Update Center ask
/// the same question of the same machine and print the same answer. Two hand-written ladders is
/// how the app came to hold two opinions about what a missing field meant.
@MainActor
enum UpdateReadingViews {
    /// Everything under the headline, in the order Core wrote it: what this copy is, what is true
    /// of it, what it runs and what it could run — each number with the source that said it — the
    /// first few things an update would bring in, and then the obstacle's own list.
    ///
    /// "The checkout has uncommitted changes" is a sentence nobody can act on until it says which,
    /// so the named items follow the summary in the same idiom. They are capped exactly as the
    /// commits are, and Core has already spent the last line saying how many it left out.
    static func lines(for reading: UpdateReading, now: Date = Date()) -> [NSView] {
        var views: [NSView] = []
        if let subtitle = reading.subtitle {
            views.append(
                RowKit.wrapping(
                    subtitle, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel))
        }
        views.append(
            RowKit.wrapping(
                reading.detail(now: now), font: MacTheme.Ramp.font(.panelFootnote),
                color: MacTheme.Color.secondaryLabel))
        views.append(versionLine(Localized.text("Running"), reading.installed))
        views.append(versionLine(Localized.text("Newest known"), reading.available))
        if let manager = reading.manager, !manager.isEmpty {
            views.append(
                RowKit.label(
                    Localized.text("Supervised by %@", manager), font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.tertiaryLabel))
        }
        for change in (reading.verdict.offer?.changes ?? []).prefix(5) {
            views.append(
                RowKit.wrapping(
                    "· \(change)", font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.secondaryLabel))
        }
        for detail in (reading.verdict.offer?.detailLines ?? []).prefix(5) {
            views.append(
                RowKit.wrapping(
                    "· \(detail)", font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.tertiaryLabel))
        }
        return views
    }

    /// What the press will actually accomplish, printed before it is pressed. An offer that ends
    /// in another program's hands says so; anything else would be this app taking credit for a job
    /// it cannot finish.
    static func promise(_ invitation: UpdateInvitation) -> NSView? {
        guard let promise = invitation.promise else { return nil }
        return RowKit.wrapping(
            promise, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel)
    }

    /// Every offer is drawn the same way on purpose: nothing here is emphasised into looking
    /// safer than it is, and no button steals the Return key — a window holding two servers'
    /// updates must never install whichever one AppKit last called its default.
    static func button(
        _ title: String, enabled: Bool = true, action: @escaping () -> Void
    ) -> NSButton {
        let button = RowKit.ActionButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.isEnabled = enabled
        return button
    }

    /// Carrying an invitation out, in the one place that knows what each of them promised.
    /// Returns what to tell the person, when there is anything worth telling.
    @discardableResult
    static func perform(_ invitation: UpdateInvitation, on reading: UpdateReading) -> String? {
        switch invitation {
        case .installHere:
            Task { await MacUpdateWatch.shared.install(reading.component) }
            return Localized.text("Asking %@ to fetch and build…", reading.title)
        case .restartHere:
            Task { await MacUpdateWatch.shared.restart(reading.component) }
            return Localized.text("Asking %@ to load the build it already has…", reading.title)
        case .openStore(let url), .openPage(let url):
            guard let target = URL(string: url) else { return nil }
            NSWorkspace.shared.open(target)
            return nil
        case .copyCommand(let command):
            RowKit.copyToClipboard(command)
            return Localized.text("Command copied — run it on that machine.")
        case .recheck:
            Task { await MacUpdateWatch.shared.recheck(reading.component) }
            return Localized.text("Asking %@ again…", reading.title)
        }
    }

    private static func versionLine(_ caption: String, _ fact: VersionFact) -> NSView {
        let label = RowKit.label(
            caption, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel)
        label.setContentHuggingPriority(.required, for: .horizontal)
        let value = RowKit.wrapping(
            fact.line, font: MacTheme.Ramp.font(.panelFootnote),
            color: fact.isKnown ? MacTheme.Color.label : MacTheme.Color.tertiaryLabel)
        let row = NSStackView(views: [label, value])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = MacTheme.Spacing.s
        return row
    }
}

/// A state's symbol with the state's motion attached, which starts its own clock the moment it
/// lands in a window — a mark built before it is added to anything would otherwise never move,
/// and one taken off screen would keep a display link running for nobody.
///
/// A sweep is a rotation here rather than a cycle of glyphs, because this client draws pictures.
/// The symbol turns inside a holder this view frames by hand, the way every other sweeping badge
/// on this desk does: `frameCenterRotation` is about a view's centre and autolayout would undo it
/// on the next pass, so the thing that turns is never the thing autolayout places.
@MainActor
final class UpdateMarkView: NSView {
    private let holder = NSView()
    private let imageView = NSImageView()
    private lazy var pulse = ActivityPulse(view: holder)
    private let pointSize: CGFloat

    init(pointSize: CGFloat) {
        self.pointSize = pointSize
        super.init(frame: .zero)
        imageView.imageScaling = .scaleProportionallyDown
        holder.addSubview(imageView)
        addSubview(holder)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
        pulse.onTurn = { [weak self] degrees in self?.holder.frameCenterRotation = degrees }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A fixed square rather than the symbol's own size: a mark that re-measured when its state
    /// changed would move the title beside it, and a frame may change light, never layout.
    override var intrinsicContentSize: NSSize {
        NSSize(width: pointSize + 5, height: pointSize + 5)
    }

    override func layout() {
        super.layout()
        let rotation = holder.frameCenterRotation
        holder.frameCenterRotation = 0
        holder.frame = bounds
        imageView.frame = holder.bounds
        holder.frameCenterRotation = rotation
    }

    func apply(_ icon: ActivityIcon?) {
        guard let icon else {
            imageView.image = nil
            holder.frameCenterRotation = 0
            pulse.apply(nil)
            return
        }
        imageView.image = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
        imageView.contentTintColor = icon.tone.color
        if !icon.motion.isAnimated { holder.frameCenterRotation = 0 }
        pulse.apply(icon)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pulse.windowChanged()
    }
}

/// One machine's card, which rewrites itself rather than being rebuilt.
///
/// A ledger post lands every three seconds while an install runs, and a board that rebuilt its
/// column on each one would throw away the scroll position and whatever button was under the
/// pointer. So the card owns its labels: an answer that arrives writes their text, their tone and
/// their visibility, and the buttons keep their identity across every step of an update.
@MainActor
final class UpdateCardView: NSView {
    var onAct: ((UpdateInvitation, UpdateReading) -> Void)?
    var onSetAside: ((UpdateReading) -> Void)?

    private let mark = UpdateMarkView(pointSize: 13)
    private let title = NSTextField(labelWithString: "")
    private let headline = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let asideNote = NSTextField(wrappingLabelWithString: "")
    private let running = UpdateVersionLine(caption: Localized.text("Running"))
    private let newest = UpdateVersionLine(caption: Localized.text("Newest known"))
    private let supervisor = NSTextField(labelWithString: "")
    private let changes = (0..<5).map { _ in NSTextField(wrappingLabelWithString: "") }
    private let details = (0..<5).map { _ in NSTextField(wrappingLabelWithString: "") }
    private let promise = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton()
    private let asideButton = NSButton()
    private let buttons = NSStackView()
    private let column = FillingStack()

    private var reading: UpdateReading?
    private var invitation: UpdateInvitation?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.card
        layer?.borderWidth = 1

        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        headline.lineBreakMode = .byTruncatingTail
        headline.setContentHuggingPriority(.required, for: .horizontal)
        for label in [title, headline, supervisor] {
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        for label in [subtitle, detail, asideNote, promise] + changes + details {
            label.isSelectable = true
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let header = NSStackView(views: [mark, title, RowKit.spacer(), headline])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = MacTheme.Spacing.s

        asideButton.title = Localized.text("Not now")
        for (button, action) in [
            (actionButton, #selector(takeOffer)), (asideButton, #selector(setOfferAside)),
        ] {
            button.setButtonType(.momentaryPushIn)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
        }
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = MacTheme.Spacing.s
        for view in [actionButton, asideButton, RowKit.spacer()] {
            buttons.addArrangedSubview(view)
        }

        column.spacing = MacTheme.Spacing.s
        column.translatesAutoresizingMaskIntoConstraints = false
        var rows: [NSView] = [header, subtitle, detail, asideNote, running, newest, supervisor]
        rows.append(contentsOf: changes as [NSView])
        rows.append(contentsOf: details as [NSView])
        rows.append(promise)
        rows.append(buttons)
        for row in rows { column.addArrangedSubview(row) }
        addSubview(column)
        let inset = MacTheme.Spacing.m
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            column.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// One answer painted into the card it belongs to.
    ///
    /// A row set aside keeps its place and its sentence and loses everything that was an offer:
    /// the whole of the collapse contract is that the mark stops standing, not that the machine
    /// stops being listed.
    func write(_ reading: UpdateReading, acknowledged: Bool, busy: Bool) {
        self.reading = reading
        let invitation = acknowledged ? nil : reading.invitation
        self.invitation = invitation

        mark.apply(reading.icon)
        title.stringValue = reading.title
        headline.stringValue = reading.headline
        headline.textColor = reading.tone.color

        write(subtitle, acknowledged ? nil : reading.subtitle)
        detail.stringValue = reading.detail()
        write(
            asideNote,
            acknowledged
                ? Localized.text(
                    "Set aside. It stays on this list, and the mark comes back the moment what is "
                        + "offered changes.")
                : nil)

        running.write(reading.installed, hidden: acknowledged)
        newest.write(reading.available, hidden: acknowledged)
        write(supervisor, acknowledged ? nil : supervisedBy(reading))

        let subjects = acknowledged ? [] : (reading.verdict.offer?.changes ?? [])
        for (index, label) in changes.enumerated() {
            write(label, index < subjects.count ? "· \(subjects[index])" : nil)
        }
        let obstacle = acknowledged ? [] : (reading.verdict.offer?.detailLines ?? [])
        for (index, label) in details.enumerated() {
            write(label, index < obstacle.count ? "· \(obstacle[index])" : nil)
        }

        write(promise, invitation?.promise)
        actionButton.isHidden = invitation == nil
        actionButton.title = invitation?.label ?? ""
        actionButton.isEnabled = !busy
        asideButton.isHidden = acknowledged || reading.acknowledgeableIdentity == nil
        buttons.isHidden = actionButton.isHidden && asideButton.isHidden
    }

    /// The tokens are values rather than dynamic colours and the fonts carry the type scale, so a
    /// theme or scale change has to reach every label of a card that is already on screen.
    func applyTheme() {
        layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
        layer?.borderColor = MacTheme.Color.separator.cgColor
        title.font = MacTheme.Ramp.font(.cardTitle)
        title.textColor = MacTheme.Color.label
        headline.font = MacTheme.Ramp.font(.panelFootnote)
        headline.textColor = reading?.tone.color ?? MacTheme.Color.secondaryLabel
        for label in [subtitle, asideNote, supervisor, promise] {
            label.font = MacTheme.Ramp.font(.panelFootnote)
            label.textColor = MacTheme.Color.tertiaryLabel
        }
        for label in [detail] + changes {
            label.font = MacTheme.Ramp.font(.panelFootnote)
            label.textColor = MacTheme.Color.secondaryLabel
        }
        for label in details {
            label.font = MacTheme.Ramp.font(.panelFootnote)
            label.textColor = MacTheme.Color.tertiaryLabel
        }
        running.applyTheme()
        newest.applyTheme()
    }

    private func supervisedBy(_ reading: UpdateReading) -> String? {
        guard let manager = reading.manager, !manager.isEmpty else { return nil }
        return Localized.text("Supervised by %@", manager)
    }

    private func write(_ label: NSTextField, _ text: String?) {
        label.isHidden = text == nil
        label.stringValue = text ?? ""
    }

    @objc private func takeOffer() {
        guard let invitation, let reading else { return }
        onAct?(invitation, reading)
    }

    @objc private func setOfferAside() {
        guard let reading else { return }
        onSetAside?(reading)
    }
}

/// A number and who said it, on one line — built once and rewritten, for the same reason the card
/// around it is.
@MainActor
final class UpdateVersionLine: NSStackView {
    private let caption = NSTextField(labelWithString: "")
    private let value = NSTextField(wrappingLabelWithString: "")
    private var isKnown = false

    init(caption text: String) {
        super.init(frame: .zero)
        caption.stringValue = text
        caption.setContentHuggingPriority(.required, for: .horizontal)
        caption.translatesAutoresizingMaskIntoConstraints = false
        value.isSelectable = true
        value.translatesAutoresizingMaskIntoConstraints = false
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = MacTheme.Spacing.s
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(caption)
        addArrangedSubview(value)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func write(_ fact: VersionFact, hidden: Bool) {
        isHidden = hidden
        isKnown = fact.isKnown
        value.stringValue = fact.line
        value.textColor = isKnown ? MacTheme.Color.label : MacTheme.Color.tertiaryLabel
    }

    func applyTheme() {
        caption.font = MacTheme.Ramp.font(.panelFootnote)
        caption.textColor = MacTheme.Color.tertiaryLabel
        value.font = MacTheme.Ramp.font(.panelFootnote)
        value.textColor = isKnown ? MacTheme.Color.label : MacTheme.Color.tertiaryLabel
    }
}

/// The one switch on this screen that is not this device's.
///
/// Whether a machine keeps itself current is the machine's own policy, so the row renders what that
/// machine last answered and never what this Mac last asked for — a switch drawn from a request
/// would sit proudly on for a bridge that never received it, and two Macs would disagree about the
/// same server. While the machine is being asked the checkbox is simply unavailable rather than
/// moved: it takes its position from an answer, and a refusal therefore leaves it exactly where the
/// machine put it.
///
/// The sentence under it is Core's whole account — what the machine will do, when it last did it,
/// and what it is holding off for right now — and a machine too old to have a policy at all gets no
/// row, because a switch that does nothing is worse than a question left unasked.
@MainActor
final class AutoUpdateRow: NSView {
    var onSet: ((Bool) -> Void)?

    private let toggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let footnote = NSTextField(wrappingLabelWithString: "")
    private var machineSaid = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toggle.title = Localized.text("Keep this server up to date")
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        footnote.isSelectable = true
        footnote.translatesAutoresizingMaskIntoConstraints = false
        footnote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let column = NSStackView(views: [toggle, footnote])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
        isHidden = true
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func write(_ automation: UpdateAutomation?, now: Date = Date()) {
        guard let automation else {
            isHidden = true
            return
        }
        isHidden = false
        machineSaid = automation.enabled
        toggle.state = automation.enabled ? .on : .off
        toggle.isEnabled = true
        footnote.stringValue = automation.sentence(now: now)
    }

    /// The stretch between the press and the machine's answer. The switch waits where the pointer
    /// left it and takes no further presses, and every way out of that wait writes it from what the
    /// machine said — so a refusal puts it back where the machine had it rather than leaving this
    /// Mac's request standing as though it were an answer.
    func setAsking(_ asking: Bool) {
        toggle.isEnabled = !asking
        guard !asking else { return }
        toggle.state = machineSaid ? .on : .off
    }

    func applyTheme() {
        toggle.font = MacTheme.Ramp.font(.panelLabel)
        footnote.font = MacTheme.Ramp.font(.panelFootnote)
        footnote.textColor = MacTheme.Color.secondaryLabel
    }

    @objc private func repaint() {
        applyTheme()
    }

    @objc private func toggled() {
        let wanted = toggle.state == .on
        toggle.isEnabled = false
        onSet?(wanted)
    }
}

/// The standing mark at the foot of the chat list: what every machine in the picture adds up to,
/// in one line that opens the Update Center.
///
/// It is drawn from `UpdateLedger`, which is why it is on screen before any check of this launch
/// has come back and why it survives a relaunch. It covers nothing, steals no focus, and there is
/// no gesture here that dismisses it: the row goes out when the rollup stops standing, and setting
/// an offer aside is a decision made in the Update Center against that exact offer.
@MainActor
final class UpdateFooterView: NSView {
    var onOpen: (() -> Void)?

    private let mark = UpdateMarkView(pointSize: 12)
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        headline.font = MacTheme.Ramp.font(.panelFootnote)
        headline.lineBreakMode = .byTruncatingTail
        headline.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        headline.translatesAutoresizingMaskIntoConstraints = false
        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detail.textColor = MacTheme.Color.tertiaryLabel
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        detail.translatesAutoresizingMaskIntoConstraints = false

        let lines = NSStackView(views: [headline, detail])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        lines.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [mark, lines])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        NotificationCenter.default.addObserver(
            self, selector: #selector(ledgerChanged), name: UpdateLedger.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(ledgerChanged), name: MacTheme.Chrome.didRepaint, object: nil)
        isHidden = true
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render() {
        detail.textColor = MacTheme.Color.tertiaryLabel
        let rollup = UpdateLedger.rollup()
        isHidden = !rollup.showsMark
        guard rollup.showsMark else {
            mark.apply(nil)
            return
        }
        let icon = rollup.icon
        mark.apply(icon)
        headline.stringValue = rollup.headline
        headline.textColor = icon.tone.color
        detail.stringValue = rollup.detail()
        toolTip = rollup.accessibilityLine()
        setAccessibilityLabel(rollup.accessibilityLine())
    }

    @objc private func ledgerChanged() {
        render()
    }

    @objc private func clicked() {
        onOpen?()
    }
}

/// A toolbar button wearing the standing mark: a small tinted dot in its corner, on the control
/// somebody already reaches for when something needs deciding.
///
/// A dot rather than a count — the toolbar must not re-measure when a number changes — and it
/// holds perfectly still whatever the rollup is doing. Six points of colour have no way to express
/// a sweep, and a display link running for a rotation nobody could see is worse than stillness:
/// what an update in flight looks like is the mark at the foot of the chat list turning, and what
/// it says here is in the tooltip.
@MainActor
final class UpdateMarkButton: NSButton {
    private let dot = NSView()
    private let tip: String

    init(symbol: String, label: String, tip: String, target: AnyObject?, action: Selector) {
        self.tip = tip
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        setButtonType(.momentaryPushIn)
        bezelStyle = .toolbar
        isBordered = true
        self.target = target
        self.action = action
        toolTip = tip
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.isHidden = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            dot.topAnchor.constraint(equalTo: topAnchor, constant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render() {
        let rollup = UpdateLedger.rollup()
        dot.isHidden = !rollup.showsMark
        guard rollup.showsMark else {
            toolTip = tip
            return
        }
        dot.layer?.backgroundColor = rollup.icon.tone.color.cgColor
        toolTip = Localized.text("%@ — %@", tip, rollup.headline)
    }
}

import AppKit
import CodingAgentKit
import TailscodeCore

/// The inspector's ground: it says when it has a window again. A push that arrives while the
/// inspector is folded away or the wall's popover is closed is not built, and coming back into a
/// window is the moment something has to say so.
@MainActor
private final class AgentPeekRootView: NSView {
    var onWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindow?() }
    }
}

/// The inspector: a read-only monitor of one agent. What it is doing in large type, its last steps,
/// the agents it has out, the files it touched and three meters, with the verbs under them: Open
/// chat, Stop (which asks first) and a Nudge. A session nobody watches says so and offers to watch.
@MainActor
final class AgentPeekViewController: NSViewController {
    let context: AgentsContext
    private let scroll = NSScrollView()
    let column = FillingStack(topDown: true, stretches: true)
    private let askBlock = AgentsAskBlockView(frame: .zero)
    private let askHeading = NSTextField(wrappingLabelWithString: "")
    private let nudgeField = NSTextField()
    private let nudgeButton = NSButton(title: "", target: nil, action: nil)
    private let nudgeNote = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton(title: "", target: nil, action: nil)
    private let stopButton = NSButton(title: "", target: nil, action: nil)
    private var elapsed: NSTextField?
    var stepRows: [AgentsStepRow] = []
    var childRows: [AgentsChildLineView] = []
    private var stepIDs: [String] = []
    private var childIDs: [String] = []
    private var headerBadge: ActivityBadgeView?
    private var headerTitle: NSTextField?
    private var headerMeta: NSTextField?
    private var awayLabel: NSTextField?
    private var flow: AgentsChipFlow?
    private var meters: [Meter] = []
    private var pulse: AgentBeatStripView?
    private var built: Shape?
    private var nudging = false
    private var renderWork: DispatchWorkItem?
    private(set) var subject: AgentsSubject?
    private(set) var facts: AgentFacts?
    var onOpenChat: ((String) -> Void)?
    var onWatch: ((String) -> Void)?

    /// One figure under Meters, kept with the row that shows it so a new value is written where it
    /// belongs rather than into a column built again.
    private struct Meter {
        enum Kind: Equatable {
            case context
            case tokens
            case cost
        }

        var kind: Kind
        var row: NSStackView
        var figure: NSTextField?
        var bar: AgentsMeterBar?
        var tint: ContextFill.Tone?
    }

    /// What the built column was built from. A push that leaves all of this as it was — an agent
    /// streaming into its meters and its last steps — writes those where they stand; anything else
    /// takes the column apart and builds it again.
    private struct Shape: Equatable {
        var key: String?
        var facts: Bool
        var isAway: Bool
        var doing: String?
        var object: AgentObject?
        var steps: Bool
        var children: Bool
        var touched: Bool
        var ask: AgentAsk?
        var phase: AgentsActions.Phase
        var fill: Bool
        var tokens: Bool
        var cost: Bool
        var pulse: Bool
    }

    init(context: AgentsContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var nudgeText: String { nudgeField.stringValue }
    var stopEnabled: Bool { stopButton.isEnabled }
    var texts: [String] { Self.texts(in: column) }

    var nudgeEnabled: Bool { nudgeButton.isEnabled }

    override func loadView() {
        let root = AgentPeekRootView()
        root.onWindow = { [weak self] in MainThread.call { self?.renderNow() } }
        column.spacing = MacTheme.Spacing.s
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.l)
        column.translatesAutoresizingMaskIntoConstraints = false
        let clip = RowKit.FlippedClip()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = column
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        askHeading.font = MacTheme.Ramp.font(.cardTitle)
        askHeading.textColor = MacTheme.Color.warning
        askHeading.maximumNumberOfLines = 0
        askHeading.translatesAutoresizingMaskIntoConstraints = false
        askHeading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        nudgeField.placeholderString = Localized.text("Nudge this agent…")
        nudgeField.font = MacTheme.Ramp.font(.control)
        nudgeField.target = self
        nudgeField.action = #selector(nudgeSent)
        nudgeField.delegate = self
        nudgeField.lineBreakMode = .byTruncatingTail
        nudgeField.translatesAutoresizingMaskIntoConstraints = false
        nudgeField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nudgeButton.title = Localized.text("Nudge")
        nudgeButton.bezelStyle = .rounded
        nudgeButton.target = self
        nudgeButton.action = #selector(nudgeSent)
        nudgeButton.isEnabled = false
        nudgeButton.setContentHuggingPriority(.required, for: .horizontal)
        nudgeNote.font = MacTheme.Ramp.font(.panelFootnote)
        nudgeNote.textColor = MacTheme.Color.danger
        nudgeNote.maximumNumberOfLines = 0
        nudgeNote.isHidden = true
        nudgeNote.translatesAutoresizingMaskIntoConstraints = false
        nudgeNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let nudgeRow = NSStackView(views: [nudgeField, nudgeButton])
        nudgeRow.orientation = .horizontal
        nudgeRow.distribution = .fill
        nudgeRow.spacing = MacTheme.Spacing.s
        nudgeRow.translatesAutoresizingMaskIntoConstraints = false

        openButton.title = Localized.text("Open Chat")
        openButton.bezelStyle = .rounded
        openButton.controlSize = .large
        openButton.bezelColor = MacTheme.Color.accent
        openButton.tintProminence = .primary
        openButton.target = self
        openButton.action = #selector(openPressed)
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stopButton.title = Localized.text("Stop…")
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .large
        stopButton.contentTintColor = MacTheme.Color.danger
        stopButton.target = self
        stopButton.action = #selector(stopPressed)
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.setContentHuggingPriority(.required, for: .horizontal)
        let verbs = NSStackView(views: [openButton, stopButton])
        verbs.orientation = .horizontal
        verbs.distribution = .fill
        verbs.spacing = MacTheme.Spacing.s
        verbs.translatesAutoresizingMaskIntoConstraints = false

        let footer = FillingStack(topDown: false, stretches: true)
        footer.spacing = MacTheme.Spacing.s
        footer.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.l,
            right: MacTheme.Spacing.l)
        footer.addArrangedSubview(nudgeRow)
        footer.addArrangedSubview(nudgeNote)
        footer.addArrangedSubview(verbs)
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scroll)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            column.topAnchor.constraint(equalTo: clip.topAnchor),
            column.widthAnchor.constraint(equalTo: clip.widthAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    func show(_ next: AgentsSubject?) {
        guard next != subject else { return }
        let changed = next?.key != subject?.key
        subject = next
        if changed {
            facts = nil
            nudgeField.stringValue = ""
            nudgeNote.isHidden = true
            nudgeButton.isEnabled = false
        }
        render()
    }

    func apply(facts next: AgentFacts?) {
        guard next != facts else { return }
        facts = next
        scheduleRender()
    }

    private func scheduleRender() {
        guard renderWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.renderWork = nil
            self?.render()
        }
        renderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func renderNow() {
        renderWork?.cancel()
        renderWork = nil
        render()
    }

    func tick(now: Date) {
        if let subject, let elapsed {
            let start = facts?.startedAt ?? subject.startedAt
            elapsed.stringValue = start.map { AgentsWords.elapsed(now.timeIntervalSince($0)) } ?? ""
        }
        if let since = askSince {
            askHeading.stringValue = askLead + " · " + AgentsWords.waiting(AgentsWords.elapsed(now.timeIntervalSince(since)))
        }
        for row in stepRows { row.tick(now: now) }
        for row in childRows { row.tick(now: now) }
    }

    private var askSince: Date?
    private var askLead = ""

    /// Whether the column can be seen at all: no window is a popover that is closed or a view not yet
    /// shown, and a collapsed split item is an inspector folded away. Neither needs a column built.
    private var isOnScreen: Bool {
        guard view.window != nil else { return false }
        guard let split = parent as? NSSplitViewController else { return true }
        return split.splitViewItems.first { $0.viewController === self }?.isCollapsed != true
    }

    /// Builds the column for the subject and its facts, or — when only the clock, a step or a meter
    /// moved since it was built — writes those where they stand. An agent streams into its facts four
    /// times a second, and the column is twenty views deep.
    private func render() {
        guard isViewLoaded, isOnScreen else { return }
        guard let subject else {
            clear()
            return
        }
        let now = context.now()
        let facts = self.facts
        let ask = facts?.ask ?? subject.card?.ask
        let shape = Shape(
            key: subject.key, facts: facts != nil, isAway: subject.isAway, doing: facts?.doing,
            object: facts?.object, steps: facts?.steps.isEmpty == false,
            children: facts?.children.isEmpty == false, touched: facts?.touched.isEmpty == false,
            ask: ask, phase: ask.map { context.actions.phase(for: subject.key, askID: $0.id) } ?? .idle,
            fill: facts?.fill != nil, tokens: facts?.tokens != nil, cost: facts?.cost != nil,
            pulse: facts?.isRunning == true)
        if facts != nil, shape == built {
            refreshHeader(subject)
            refreshAway(subject, now: now)
            if let facts {
                updateSteps(facts.steps, now: now)
                updateChildren(facts.children, now: now)
                if flow?.titles != facts.touched { flow?.titles = facts.touched }
                updateMeters(facts)
            }
        } else {
            rebuild(subject: subject, facts: facts, now: now)
            built = shape
        }
        refreshFooter(subject)
        tick(now: now)
    }

    private func clear() {
        for old in column.arrangedSubviews {
            column.removeArrangedSubview(old)
            if old !== askBlock, old !== askHeading { old.removeFromSuperview() }
        }
        askBlock.removeFromSuperview()
        askHeading.removeFromSuperview()
        stepRows = []
        childRows = []
        stepIDs = []
        childIDs = []
        headerBadge = nil
        headerTitle = nil
        headerMeta = nil
        awayLabel = nil
        flow = nil
        meters = []
        pulse = nil
        elapsed = nil
        askSince = nil
        built = nil
    }

    private func rebuild(subject: AgentsSubject, facts: AgentFacts?, now: Date) {
        clear()
        column.addArrangedSubview(header(subject))
        if subject.isAway {
            let away = note(
                AgentsWords.lastSeen(context.lastHeard(subject.profileID), now: now),
                tint: MacTheme.Color.warning)
            awayLabel = away as? NSTextField
            column.addArrangedSubview(away)
        }
        let ask = facts?.ask ?? subject.card?.ask
        if let ask { addAsk(ask, subject: subject, now: now) }
        if let facts {
            let before = column.arrangedSubviews.count
            addFacts(facts, subject: subject, now: now)
            adopt(Array(column.arrangedSubviews.dropFirst(before)), facts: facts)
        } else {
            if let line = subject.line, !line.isEmpty, ask == nil {
                column.addArrangedSubview(note(line, tint: MacTheme.Color.secondaryLabel))
            }
            if subject.isRunning, subject.card == nil {
                column.addArrangedSubview(note(AgentsWords.listedOnly, tint: MacTheme.Color.tertiaryLabel))
                column.addArrangedSubview(watchButton(subject))
            }
        }
    }

    private func refreshFooter(_ subject: AgentsSubject) {
        let phase = context.actions.stopPhase(for: subject.key)
        var live = subject.isRunning && !subject.isAway
        if case .inFlight = phase { live = false }
        stopButton.isEnabled = live
        switch phase {
        case .inFlight: stopButton.title = Localized.text("Stopping…")
        case .sent: stopButton.title = Localized.text("Stop sent")
        default: stopButton.title = Localized.text("Stop…")
        }
        nudgeField.isEnabled = subject.isRunning && !subject.isAway && !nudging
        nudgeButton.isEnabled =
            nudgeField.isEnabled && !nudgeField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        openButton.isEnabled = true
        if case .failed(let why) = phase {
            nudgeNote.stringValue = Localized.text("Could not stop it: %@", why)
            nudgeNote.isHidden = false
        }
    }

    func refreshActions() {
        guard let subject else { return }
        refreshFooter(subject)
        if subject.card != nil || facts?.ask != nil { render() }
    }

    private func header(_ subject: AgentsSubject) -> NSView {
        let badge = ActivityBadgeView(pointSize: 13)
        badge.show(
            AgentsSection.working.icon(tone: subject.tone, motion: subject.motion),
            spoken: AgentsWords.state(word: nil, section: subject.isRunning ? .working : .finished))
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)
        headerBadge = badge
        let title = NSTextField(wrappingLabelWithString: subject.title)
        title.font = MacTheme.Ramp.font(.panelTitle)
        title.maximumNumberOfLines = 0
        title.isSelectable = true
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerTitle = title
        let clock = NSTextField(labelWithString: "")
        clock.font = .monospacedDigitSystemFont(
            ofSize: MacTheme.Ramp.font(.rowStamp).pointSize, weight: .regular)
        clock.textColor = MacTheme.Color.tertiaryLabel
        clock.translatesAutoresizingMaskIntoConstraints = false
        clock.setContentHuggingPriority(.required, for: .horizontal)
        clock.setContentCompressionResistancePriority(.required, for: .horizontal)
        elapsed = clock
        let top = NSStackView(views: [badge, title, clock])
        top.orientation = .horizontal
        top.distribution = .fill
        top.alignment = .top
        top.spacing = MacTheme.Spacing.s
        top.translatesAutoresizingMaskIntoConstraints = false

        let meta = NSTextField(wrappingLabelWithString: "")
        meta.attributedStringValue = Self.metaLine(subject)
        meta.maximumNumberOfLines = 0
        meta.isSelectable = true
        meta.translatesAutoresizingMaskIntoConstraints = false
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerMeta = meta
        let stack = FillingStack(topDown: false, stretches: true)
        stack.spacing = MacTheme.Spacing.xs
        stack.addArrangedSubview(top)
        stack.addArrangedSubview(meta)
        return stack
    }

    /// The machine and the model the agent runs: the one reading the header is built with and set
    /// again from when either changed, so a push that only moved the clock builds nothing.
    private static func metaLine(_ subject: AgentsSubject) -> NSAttributedString {
        let line = NSMutableAttributedString()
        let font = MacTheme.Ramp.font(.rowMeta)
        line.append(
            NSAttributedString(
                string: subject.machine,
                attributes: [.font: font, .foregroundColor: MacTheme.Color.secondaryLabel]))
        if let chip = subject.chip {
            line.append(
                NSAttributedString(
                    string: " · ",
                    attributes: [.font: font, .foregroundColor: MacTheme.Color.tertiaryLabel]))
            line.append(SidebarSessionCell.chipText(chip))
        }
        return line
    }

    private func refreshHeader(_ subject: AgentsSubject) {
        headerBadge?.show(
            AgentsSection.working.icon(tone: subject.tone, motion: subject.motion),
            spoken: AgentsWords.state(word: nil, section: subject.isRunning ? .working : .finished))
        if headerTitle?.stringValue != subject.title { headerTitle?.stringValue = subject.title }
        let meta = Self.metaLine(subject)
        if headerMeta?.attributedStringValue != meta { headerMeta?.attributedStringValue = meta }
    }

    private func refreshAway(_ subject: AgentsSubject, now: Date) {
        guard subject.isAway, let awayLabel else { return }
        let text = AgentsWords.lastSeen(context.lastHeard(subject.profileID), now: now)
        if awayLabel.stringValue != text { awayLabel.stringValue = text }
    }

    private func addAsk(_ ask: AgentAsk, subject: AgentsSubject, now: Date) {
        askLead = ask.lead
        askSince = ask.since
        askHeading.stringValue = ask.lead
        column.addArrangedSubview(askHeading)
        askBlock.configure(
            ask: ask, phase: context.actions.phase(for: subject.key, askID: ask.id),
            away: subject.isAway,
            note: subject.isAway ? AgentsWords.lastSeen(context.lastHeard(subject.profileID), now: now) : nil)
        askBlock.onDecide = { [weak self] allow in
            self?.context.actions.decide(subject.key, ask: ask, allow: allow)
        }
        askBlock.onOption = { [weak self] option in
            self?.context.actions.choose(subject.key, ask: ask, option: option)
        }
        column.addArrangedSubview(askBlock)
    }

    /// Keeps what `addFacts` just made: the rail of files, one row per figure, the pulse, and the ids
    /// the steps and the agents were listed by, so the next push finds the row each one stands in.
    private func adopt(_ appended: [NSView], facts: AgentFacts) {
        stepIDs = facts.steps.map(\.id)
        childIDs = facts.children.map(\.id)
        flow = appended.compactMap { $0 as? AgentsChipFlow }.first
        var rest = appended.suffix(Self.meterKinds(facts).count + (facts.isRunning ? 1 : 0))
        var meters: [Meter] = []
        for kind in Self.meterKinds(facts) {
            guard let row = rest.first as? NSStackView else { break }
            rest = rest.dropFirst()
            meters.append(
                Meter(
                    kind: kind, row: row, figure: row.arrangedSubviews.last as? NSTextField,
                    bar: row.arrangedSubviews.compactMap { $0 as? AgentsMeterBar }.first, tint: nil))
        }
        self.meters = meters
        pulse = rest.first.flatMap { row in
            (row as? NSStackView)?.arrangedSubviews.compactMap { $0 as? AgentBeatStripView }.first
        }
    }

    private static func meterKinds(_ facts: AgentFacts) -> [Meter.Kind] {
        var kinds: [Meter.Kind] = []
        if facts.fill != nil { kinds.append(.context) }
        if facts.tokens != nil { kinds.append(.tokens) }
        if facts.cost != nil { kinds.append(.cost) }
        return kinds
    }

    private static func meter(_ kind: Meter.Kind, facts: AgentFacts) -> (name: String, value: String) {
        switch kind {
        case .context:
            return (Localized.text("Context"), facts.fill?.badge ?? "")
        case .tokens:
            return (Localized.text("Tokens this turn"), facts.tokens.map(StatusFacts.tokens) ?? "")
        case .cost:
            return (
                Localized.text("API estimate"),
                Localized.text("≈ %@", SessionSpend.money(facts.cost ?? 0))
            )
        }
    }

    private static func tint(_ tone: ContextFill.Tone) -> NSColor {
        switch tone {
        case .quiet: return MacTheme.Color.success
        case .attention: return MacTheme.Color.warning
        case .danger: return MacTheme.Color.danger
        }
    }

    /// Writes each figure where it stands, and only when the figure changed.
    private func updateMeters(_ facts: AgentFacts) {
        for index in meters.indices {
            let meter = meters[index]
            let (name, value) = Self.meter(meter.kind, facts: facts)
            if let figure = meter.figure, figure.stringValue != value { figure.stringValue = value }
            let label = name + ", " + value
            if meter.row.accessibilityLabel() != label { meter.row.setAccessibilityLabel(label) }
            guard meter.kind == .context, let fill = facts.fill else { continue }
            let fraction = fill.fraction ?? 0
            if meter.bar?.fraction != fraction { meter.bar?.fraction = fraction }
            if meters[index].tint != fill.tone {
                meters[index].tint = fill.tone
                meters[index].bar?.tint = Self.tint(fill.tone)
            }
        }
        if let pulse, pulse.beat != facts.beat { pulse.beat = facts.beat }
    }

    /// The step rows by id: the ones that stayed are set again where they stand, one that arrived
    /// takes its place in front of the others and one that left goes.
    private func updateSteps(_ steps: [AgentStep], now: Date) {
        guard let anchor = stepRows.first else { return }
        var carried: [String: AgentsStepRow] = [:]
        for (index, id) in stepIDs.enumerated() where stepRows.indices.contains(index) {
            carried[id] = stepRows[index]
        }
        var rows: [AgentsStepRow] = []
        var ids: [String] = []
        for step in steps {
            let row = carried.removeValue(forKey: step.id) ?? AgentsStepRow()
            row.configure(step, now: now)
            rows.append(row)
            ids.append(step.id)
        }
        place(rows, from: anchor, dropping: Array(carried.values))
        stepRows = rows
        stepIDs = ids
    }

    private func updateChildren(_ children: [AgentChild], now: Date) {
        guard let anchor = childRows.first else { return }
        var carried: [String: AgentsChildLineView] = [:]
        for (index, id) in childIDs.enumerated() where childRows.indices.contains(index) {
            carried[id] = childRows[index]
        }
        var rows: [AgentsChildLineView] = []
        var ids: [String] = []
        for child in children {
            let row = carried.removeValue(forKey: child.id) ?? AgentsChildLineView()
            row.configure(child, now: now)
            rows.append(row)
            ids.append(child.id)
        }
        place(rows, from: anchor, dropping: Array(carried.values))
        childRows = rows
        childIDs = ids
    }

    /// Puts the rows in the column in their order from where the section starts now, and takes away
    /// the ones that left: the rest of the column is not touched.
    private func place<Row: NSView>(_ rows: [Row], from anchor: NSView, dropping stale: [Row]) {
        guard let start = column.arrangedSubviews.firstIndex(where: { $0 === anchor }) else { return }
        for (offset, row) in rows.enumerated() {
            let target = start + offset
            if column.arrangedSubviews.indices.contains(target), column.arrangedSubviews[target] === row {
                continue
            }
            if row.superview != nil {
                column.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
            column.insertArrangedSubview(row, at: min(target, column.arrangedSubviews.count))
        }
        for row in stale {
            column.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
    }

    @objc private func openPressed() {
        guard let subject else { return }
        onOpenChat?(subject.key)
    }

    @objc private func stopPressed() {
        guard let subject else { return }
        context.actions.requestStop(subject.key, title: subject.title)
    }

    @objc private func nudgeSent() {
        let text = nudgeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let subject, !text.isEmpty, !nudging else { return }
        nudging = true
        nudgeField.isEnabled = false
        nudgeButton.isEnabled = false
        nudgeNote.isHidden = true
        let key = subject.key
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reply = await self.context.actions.nudge(key, text: text)
            self.nudging = false
            switch reply {
            case .sent:
                self.nudgeField.stringValue = ""
            case .failed(let why):
                self.nudgeNote.stringValue = Localized.text("Could not send it: %@", why)
                self.nudgeNote.isHidden = false
            case .needsChat:
                self.nudgeField.stringValue = ""
            }
            if let current = self.subject { self.refreshFooter(current) }
        }
    }

    private static func texts(in view: NSView) -> [String] {
        if let field = view as? NSTextField, !field.isHidden { return [field.stringValue] }
        if let button = view as? NSButton, !button.isHidden { return [button.title] }
        return view.subviews.flatMap { texts(in: $0) }
    }
}

extension AgentPeekViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        if let subject { refreshFooter(subject) }
    }
}

import AppKit
import CodingAgentKit
import TailscodeCore

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
    private var nudging = false
    private var renderWork: DispatchWorkItem?
    private(set) var subject: AgentsSubject?
    private(set) var facts: AgentFacts?
    var onOpenChat: ((String) -> Void)?
    var onWatch: ((String) -> Void)?

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
        let root = NSView()
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

    private func render() {
        guard isViewLoaded else { return }
        for old in column.arrangedSubviews {
            column.removeArrangedSubview(old)
            if old !== askBlock, old !== askHeading { old.removeFromSuperview() }
        }
        askBlock.removeFromSuperview()
        askHeading.removeFromSuperview()
        stepRows = []
        childRows = []
        elapsed = nil
        askSince = nil
        guard let subject else { return }
        let now = context.now()
        let facts = self.facts
        column.addArrangedSubview(header(subject, facts: facts, now: now))
        if subject.isAway {
            column.addArrangedSubview(
                note(AgentsWords.lastSeen(context.lastHeard(subject.profileID), now: now), tint: MacTheme.Color.warning))
        }
        let ask = facts?.ask ?? subject.card?.ask
        if let ask { addAsk(ask, subject: subject, now: now) }
        if let facts {
            addFacts(facts, subject: subject, now: now)
        } else {
            if let line = subject.line, !line.isEmpty, ask == nil {
                column.addArrangedSubview(note(line, tint: MacTheme.Color.secondaryLabel))
            }
            if subject.isRunning, subject.card == nil {
                column.addArrangedSubview(note(AgentsWords.listedOnly, tint: MacTheme.Color.tertiaryLabel))
                column.addArrangedSubview(watchButton(subject))
            }
        }
        refreshFooter(subject)
        tick(now: now)
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

    private func header(_ subject: AgentsSubject, facts: AgentFacts?, now: Date) -> NSView {
        let badge = ActivityBadgeView(pointSize: 13)
        badge.show(
            AgentsSection.working.icon(tone: subject.tone, motion: subject.motion),
            spoken: AgentsWords.state(word: nil, section: subject.isRunning ? .working : .finished))
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)
        let title = NSTextField(wrappingLabelWithString: subject.title)
        title.font = MacTheme.Ramp.font(.panelTitle)
        title.maximumNumberOfLines = 0
        title.isSelectable = true
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        let line = NSMutableAttributedString()
        let font = MacTheme.Ramp.font(.rowMeta)
        line.append(
            NSAttributedString(
                string: subject.machine,
                attributes: [.font: font, .foregroundColor: MacTheme.Color.secondaryLabel]))
        if let chip = subject.chip {
            line.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: MacTheme.Color.tertiaryLabel]))
            line.append(SidebarSessionCell.chipText(chip))
        }
        meta.attributedStringValue = line
        meta.maximumNumberOfLines = 0
        meta.isSelectable = true
        meta.translatesAutoresizingMaskIntoConstraints = false
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = FillingStack(topDown: false, stretches: true)
        stack.spacing = MacTheme.Spacing.xs
        stack.addArrangedSubview(top)
        stack.addArrangedSubview(meta)
        return stack
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

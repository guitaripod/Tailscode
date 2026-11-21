import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// The end of an expert's task, under the transcript: while the task is at rest and nobody has
/// finished it, one line naming the expert with Finish task; once it is finished, the debrief —
/// what the expert learned, corrected and wants to retire, each with its own press beside Skip,
/// the journal entry above them, Later and one filled Accept all. Content on the canvas, never on
/// glass, because it is read like the conversation above it.
@MainActor
final class ExpertDebriefSlot: NSView {
    private let column = FillingStack(topDown: false)
    private var entry: SessionEntry?
    private var backend: (any CodingAgentBackend)?
    private var running = false
    private(set) var debrief: ExpertDebrief?
    private var row: ExpertRow?
    private var poll: Task<Void, Never>?
    private var loaded: String?
    /// The task a press is out for, so a reply lands only on the task it was pressed in and a
    /// press in one task never holds up the next.
    private var pressing: String?
    /// The debrief was followed for as long as the slot follows one and was still being written.
    private var stalled = false
    private var deskObserver: NSObjectProtocol?
    var onToast: ((String) -> Void)?

    /// What the slot shows, for a harness.
    var headlineText: String { (column.arrangedSubviews.first as? ExpertDebriefHeader)?.headline ?? "" }
    var proposalTitles: [String] {
        column.arrangedSubviews.compactMap { $0 as? ExpertProposalRow }.map(\.titleText)
    }
    var actionTitles: [String] {
        column.arrangedSubviews.compactMap { $0 as? ExpertProposalRow }.map(\.acceptTitle)
    }
    var proposalTextWidths: [CGFloat] {
        column.arrangedSubviews.compactMap { $0 as? ExpertProposalRow }.map(\.textWidth)
    }
    var footerPressHeight: CGFloat {
        column.arrangedSubviews.compactMap { $0 as? ExpertDebriefFooter }.first?.pressHeight ?? 0
    }
    var offersFinish: Bool { column.arrangedSubviews.contains { $0 is ExpertFinishStrip } }
    var debriefSession: String? { debrief?.sessionID }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.card
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        expertHug(column)
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
        paint()
        deskObserver = NotificationCenter.default.addObserver(
            forName: ExpertDesk.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deskChanged() }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        poll?.cancel()
        if let deskObserver { NotificationCenter.default.removeObserver(deskObserver) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
            layer?.borderColor = MacTheme.Color.separator.withAlphaComponent(0.6).cgColor
        }
        layer?.borderWidth = 0.5
    }

    /// The pane is parked or going: nothing is followed for it any more.
    func stop() {
        poll?.cancel()
        poll = nil
    }

    /// The pane is back: a debrief that was being written when it parked is looked at again.
    func resume() {
        guard poll == nil, debrief?.state == .drafting, !stalled else { return }
        load()
    }

    var isFollowing: Bool { poll != nil }

    /// The pane opened a conversation. Only a task of an expert on a machine that keeps experts
    /// has an end to show.
    func bind(_ entry: SessionEntry?, backend: (any CodingAgentBackend)?) {
        poll?.cancel()
        poll = nil
        debrief = nil
        loaded = nil
        self.entry = entry?.session.expertID == nil ? nil : entry
        self.backend = backend
        running = true
        stalled = false
        row = entry.flatMap { ExpertDesk.shared.row(for: $0) }
        render()
        load()
    }

    /// The conversation moved; a turn ending is when a task can be finished.
    func noteState(running isRunning: Bool) {
        guard entry != nil, isRunning != running else { return }
        running = isRunning
        if !isRunning { load() }
        render()
    }

    private func deskChanged() {
        guard let entry else { return }
        let fresh = ExpertDesk.shared.row(for: entry)
        guard fresh?.expert != row?.expert else { return }
        row = fresh
        render()
    }

    private var keeping: (any MachineExperts)? { backend as? any MachineExperts }

    private func load() {
        guard let entry, let keeping else { return }
        let session = entry.session.id
        loaded = session
        stalled = false
        Task { [weak self] in
            let found = try? await keeping.expertDebrief(sessionID: session)
            guard let self, self.entry?.session.id == session else { return }
            self.debrief = found
            self.render()
            if found?.state == .drafting { self.follow() }
        }
    }

    /// Finish task: the machine drafts the debrief on a fork of the task, and the slot follows it
    /// until it is written or could not be.
    func finish() {
        guard let entry, let keeping, pressing == nil else { return }
        let session = entry.session.id
        pressing = session
        stalled = false
        Task { [weak self] in
            do {
                let started = try await keeping.finishExpertTask(sessionID: session)
                ExpertDesk.shared.refreshSoon()
                guard let self else { return }
                if self.pressing == session { self.pressing = nil }
                guard self.entry?.session.id == session else { return }
                self.debrief = started
                self.render()
                if started.state == .drafting { self.follow() }
            } catch {
                guard let self else { return }
                if self.pressing == session { self.pressing = nil }
                guard self.entry?.session.id == session else { return }
                self.onToast?(AgentErrorText.readable(error))
            }
        }
    }

    private func follow() {
        poll?.cancel()
        stalled = false
        guard let entry, let keeping else { return }
        let session = entry.session.id
        poll = Task { [weak self] in
            for _ in 0..<200 {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, self?.entry?.session.id == session else { return }
                guard let found = try? await keeping.expertDebrief(sessionID: session) else { continue }
                guard let self, self.entry?.session.id == session else { return }
                self.debrief = found
                self.render()
                if found.state != .drafting {
                    ExpertDesk.shared.refreshSoon()
                    return
                }
            }
            guard let self, !Task.isCancelled, self.entry?.session.id == session else { return }
            self.stalled = true
            self.render()
        }
    }

    private func decide(_ decision: ExpertDebriefDecision) {
        guard let entry, let keeping, pressing == nil else { return }
        let session = entry.session.id
        pressing = session
        Task { [weak self] in
            do {
                let settled = try await keeping.decideExpertDebrief(sessionID: session, decision)
                ExpertDesk.shared.refreshSoon()
                guard let self else { return }
                if self.pressing == session { self.pressing = nil }
                guard self.entry?.session.id == session else { return }
                self.debrief = settled
                self.render()
            } catch {
                guard let self else { return }
                if self.pressing == session { self.pressing = nil }
                guard self.entry?.session.id == session else { return }
                self.onToast?(AgentErrorText.readable(error))
            }
        }
    }

    func acceptAll() {
        guard let debrief else { return }
        decide(ExpertDebriefDecision(accepted: debrief.pending.map(\.id)))
    }

    func accept(_ id: String) { decide(ExpertDebriefDecision(accepted: [id], skipped: [])) }
    func skip(_ id: String) { decide(ExpertDebriefDecision(accepted: [], skipped: [id])) }

    /// Shows a debrief that came from somewhere other than this pane's machine, for a harness.
    func stage(_ debrief: ExpertDebrief, row: ExpertRow) {
        self.debrief = debrief
        self.row = row
        render(force: true)
    }

    private func render(force: Bool = false) {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard force || (entry != nil && !running) else {
            isHidden = true
            return
        }
        let name = row?.expert.name ?? Localized.text("The expert")
        guard let debrief else {
            guard loaded != nil, keeping != nil else {
                isHidden = true
                return
            }
            let strip = ExpertFinishStrip(row: row, name: name)
            strip.onFinish = { [weak self] in self?.finish() }
            column.addArrangedSubview(strip)
            isHidden = false
            return
        }
        isHidden = false
        let header = ExpertDebriefHeader(debrief: debrief, row: row, name: name, stalled: stalled)
        header.onRetry = { [weak self] in self?.finish() }
        column.addArrangedSubview(header)
        if let journal = debrief.journal {
            column.addArrangedSubview(ExpertJournalPreview(entry: journal))
        }
        for proposal in debrief.proposals {
            column.addArrangedSubview(ExpertHairline())
            let view = ExpertProposalRow(proposal: proposal, open: debrief.state == .open)
            view.onAccept = { [weak self] in self?.accept(proposal.id) }
            view.onSkip = { [weak self] in self?.skip(proposal.id) }
            column.addArrangedSubview(view)
        }
        if debrief.state == .open, !debrief.pending.isEmpty {
            let footer = ExpertDebriefFooter()
            footer.onLater = { [weak self] in self?.laterTapped() }
            footer.onAcceptAll = { [weak self] in self?.acceptAll() }
            column.addArrangedSubview(ExpertHairline())
            column.addArrangedSubview(footer)
        }
    }

    /// Later leaves every proposal waiting; the shelf says how many, and the card stays here.
    private func laterTapped() {
        onToast?(Localized.text("%@ keeps them for later", row?.expert.name ?? Localized.text("The expert")))
    }
}

/// The card's foot: Later, and the one filled press, Accept all, at the trailing edge. Placed by
/// constraints of its own, because a stack told to hug its rows let both buttons go to no height
/// and they hung over the card's edge.
@MainActor
final class ExpertDebriefFooter: NSView {
    var onLater: (() -> Void)?
    var onAcceptAll: (() -> Void)?
    var pressHeight: CGFloat { subviews.map(\.frame.height).min() ?? 0 }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let later = NSButton(title: ExpertWords.later, target: self, action: #selector(laterTapped))
        later.bezelStyle = .push
        later.toolTip = Localized.text("The notes wait on the expert's shelf")
        let all = NSButton(title: ExpertWords.acceptAll, target: self, action: #selector(acceptAllTapped))
        all.bezelStyle = .push
        all.bezelColor = MacTheme.Color.accent
        all.keyEquivalent = ""
        for button in [later, all] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentCompressionResistancePriority(.required, for: .vertical)
            addSubview(button)
        }
        NSLayoutConstraint.activate([
            all.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.m),
            all.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.s),
            bottomAnchor.constraint(equalTo: all.bottomAnchor, constant: MacTheme.Spacing.m),
            later.trailingAnchor.constraint(equalTo: all.leadingAnchor, constant: -MacTheme.Spacing.s),
            later.firstBaselineAnchor.constraint(equalTo: all.firstBaselineAnchor),
            later.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: MacTheme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func laterTapped() { onLater?() }
    @objc private func acceptAllTapped() { onAcceptAll?() }
}

/// A task at rest that nobody has finished: the expert's mark and name, and Finish task.
@MainActor
final class ExpertFinishStrip: NSView {
    var onFinish: (() -> Void)?

    init(row: ExpertRow?, name: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        var views: [NSView] = []
        if let row { views.append(ExpertMarkView(row: row, side: 22)) }
        let title = NSTextField(labelWithString: Localized.text("A task of %@", name))
        title.font = MacTheme.Ramp.font(.rowTitleStrong)
        let detail = NSTextField(wrappingLabelWithString: ExpertWords.finishTaskDetail)
        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let words = NSStackView(views: [title, detail])
        words.orientation = .vertical
        words.alignment = .width
        words.spacing = 1
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        expertHug(words)
        let finish = NSButton(title: ExpertWords.finishTask, target: self, action: #selector(finishTapped))
        finish.bezelStyle = .push
        finish.setContentHuggingPriority(.required, for: .horizontal)
        views += [words, finish]
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = MacTheme.Spacing.m
        expertHug(row)
        row.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m, right: MacTheme.Spacing.m)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func finishTapped() { onFinish?() }
}

/// The card's head: the mark, the headline in its tone, the line under it, and — while the
/// debrief is written — a spinner; after a failure, Try again. Placed by constraints of its own,
/// because two wrapping lines in a stack had no width anybody had told them.
@MainActor
final class ExpertDebriefHeader: NSView {
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    var onRetry: (() -> Void)?
    var headline: String { title.stringValue }

    init(debrief: ExpertDebrief, row: ExpertRow?, name: String, stalled: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let line = ExpertReading.debriefHeadline(debrief, name: name)
        title.stringValue = line.text
        title.font = MacTheme.Ramp.font(.cardTitle)
        title.textColor = line.tone == .failing ? MacTheme.Color.danger : MacTheme.Color.label
        detail.stringValue = ExpertReading.debriefDetail(debrief)
        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.isHidden = detail.stringValue.isEmpty
        var accessory: NSView?
        if debrief.state == .drafting, !stalled {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            accessory = spinner
        }
        if debrief.state == .failed || stalled {
            let retry = NSButton(title: ExpertWords.tryAgain, target: self, action: #selector(retryTapped))
            retry.bezelStyle = .push
            accessory = retry
        }
        let mark = row.map { ExpertMarkView(row: $0, side: 26) }
        for view in [mark, title, detail, accessory].compactMap({ $0 }) {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let inset = MacTheme.Spacing.m
        let textLeading = mark.map { $0.trailingAnchor } ?? leadingAnchor
        var constraints = [
            title.leadingAnchor.constraint(equalTo: textLeading, constant: inset),
            title.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            bottomAnchor.constraint(
                equalTo: (detail.isHidden ? title : detail).bottomAnchor, constant: MacTheme.Spacing.s),
        ]
        if let mark {
            constraints += [
                mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
                mark.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            ]
        }
        if let accessory {
            constraints += [
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                accessory.centerYAnchor.constraint(equalTo: title.centerYAnchor),
                title.trailingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: -MacTheme.Spacing.s),
            ]
        } else {
            constraints.append(title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func retryTapped() { onRetry?() }

    /// The two lines wrap at the width they were given, said to them before they are measured.
    override func layout() {
        super.layout()
        for label in [title, detail] where label.preferredMaxLayoutWidth != label.bounds.width {
            label.preferredMaxLayoutWidth = label.bounds.width
        }
    }
}

/// The journal entry the debrief wrote, kept as written, in a tinted box above the proposals.
@MainActor
final class ExpertJournalPreview: NSView {
    init(entry: ExpertJournalEntry) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let box = ExpertPlate(fill: MacTheme.Color.label.withAlphaComponent(0.05), radius: 8)
        box.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: ExpertWords.journalEntry + " · " + entry.title)
        title.font = MacTheme.Ramp.font(.rowTitleStrong)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let body = NSTextField(wrappingLabelWithString: ExpertReading.journalPreview(entry))
        body.font = MacTheme.Ramp.font(.panelFootnote)
        body.textColor = MacTheme.Color.secondaryLabel
        body.isSelectable = true
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let column = FillingStack(topDown: false)
        column.spacing = 2
        column.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        expertHug(column)
        column.addArrangedSubview(title)
        column.addArrangedSubview(body)
        box.addSubview(column)
        addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.m),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.m),
            box.topAnchor.constraint(equalTo: topAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.s),
            column.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            column.topAnchor.constraint(equalTo: box.topAnchor),
            column.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        if !entry.commits.isEmpty { toolTip = entry.commits.joined(separator: "\n") }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// One proposal: what it does to the notebook in a tag (New, Changed, Retire), its title, line and
/// reason, and two plain presses — its own action and Skip. A decided proposal says what came of it.
@MainActor
final class ExpertProposalRow: NSView {
    private let title = NSTextField(labelWithString: "")
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let reason = NSTextField(wrappingLabelWithString: "")
    private let accept = NSButton()
    var onAccept: (() -> Void)?
    var onSkip: (() -> Void)?
    var titleText: String { title.stringValue }
    var acceptTitle: String { accept.title }
    var textWidth: CGFloat { title.frame.width }

    init(proposal: ExpertProposal, open: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let tone: ExpertTone = proposal.op == .add ? .good : proposal.op == .change ? .active : .quiet
        let ink = tone == .quiet ? MacTheme.Color.secondaryLabel : ExpertInk.color(tone)
        let tag = ExpertTagLabel(weight: .bold)
        tag.stringValue = " " + ExpertWords.opLabel(proposal.op).uppercased(with: .current) + " "
        tag.ink = ink
        tag.lineBreakMode = .byClipping
        tag.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.stringValue = proposal.title
        title.font = MacTheme.Ramp.font(.rowTitleStrong)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.init(1), for: .horizontal)
        summary.stringValue = proposal.summary
        summary.font = MacTheme.Ramp.font(.panelFootnote)
        summary.textColor = MacTheme.Color.secondaryLabel
        summary.isHidden = proposal.summary.isEmpty
        reason.stringValue = proposal.reason
        reason.font = NSFontManager.shared.convert(MacTheme.Ramp.font(.panelFootnote), toHaveTrait: .italicFontMask)
        reason.textColor = MacTheme.Color.tertiaryLabel
        reason.isHidden = proposal.reason.isEmpty
        accept.title = ExpertWords.accept(proposal.op)
        var trailingView: NSView?
        if open, proposal.state == .pending {
            accept.bezelStyle = .push
            accept.controlSize = .small
            accept.target = self
            accept.action = #selector(acceptTapped)
            let skip = NSButton(title: ExpertWords.skip, target: self, action: #selector(skipTapped))
            skip.bezelStyle = .push
            skip.controlSize = .small
            let presses = NSView()
            for button in [accept, skip] {
                button.translatesAutoresizingMaskIntoConstraints = false
                button.setContentHuggingPriority(.required, for: .horizontal)
                button.setContentCompressionResistancePriority(.required, for: .horizontal)
                presses.addSubview(button)
            }
            NSLayoutConstraint.activate([
                accept.leadingAnchor.constraint(equalTo: presses.leadingAnchor),
                skip.leadingAnchor.constraint(equalTo: accept.trailingAnchor, constant: 6),
                skip.trailingAnchor.constraint(equalTo: presses.trailingAnchor),
                accept.topAnchor.constraint(equalTo: presses.topAnchor),
                accept.bottomAnchor.constraint(equalTo: presses.bottomAnchor),
                skip.firstBaselineAnchor.constraint(equalTo: accept.firstBaselineAnchor),
            ])
            trailingView = presses
        } else if let said = ExpertWords.proposalState(proposal.state, op: proposal.op) {
            let state = NSTextField(labelWithString: said)
            state.font = MacTheme.Ramp.font(.rowMeta)
            state.textColor = proposal.state == .accepted ? MacTheme.Color.success : MacTheme.Color.tertiaryLabel
            trailingView = state
        }
        for view in [tag, title, summary, reason, trailingView].compactMap({ $0 }) {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let inset = MacTheme.Spacing.m
        var last: NSView = title
        var constraints = [
            tag.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            tag.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            title.leadingAnchor.constraint(equalTo: tag.trailingAnchor, constant: MacTheme.Spacing.m),
            title.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.s + 2),
        ]
        for line in [summary, reason] where !line.isHidden {
            constraints += [
                line.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                line.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                line.topAnchor.constraint(equalTo: last.bottomAnchor, constant: 2),
            ]
            last = line
        }
        constraints.append(bottomAnchor.constraint(equalTo: last.bottomAnchor, constant: MacTheme.Spacing.s + 2))
        if let trailingView {
            trailingView.setContentHuggingPriority(.required, for: .horizontal)
            trailingView.setContentCompressionResistancePriority(.required, for: .horizontal)
            constraints += [
                trailingView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                trailingView.centerYAnchor.constraint(equalTo: title.centerYAnchor),
                title.trailingAnchor.constraint(equalTo: trailingView.leadingAnchor, constant: -MacTheme.Spacing.m),
            ]
        } else {
            constraints.append(title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset))
        }
        NSLayoutConstraint.activate(constraints)
        if !proposal.body.isEmpty { toolTip = proposal.body }
        setAccessibilityElement(true)
        setAccessibilityLabel(
            [ExpertWords.opLabel(proposal.op), proposal.title, proposal.summary, proposal.reason]
                .filter { !$0.isEmpty }.joined(separator: ", "))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func acceptTapped() { onAccept?() }
    @objc private func skipTapped() { onSkip?() }

    override func layout() {
        super.layout()
        for label in [summary, reason] where label.preferredMaxLayoutWidth != label.bounds.width {
            label.preferredMaxLayoutWidth = label.bounds.width
        }
    }
}

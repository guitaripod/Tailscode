import AppKit
import CodingAgentKit
import TailscodeCore

/// One schedule, opened: what it asks (editable), when (the same phrase field the Ask later sheet
/// reads, with what was understood said as a date before anything changes), its two switches, the
/// presses — Run now, Pause or Resume, its conversation, Delete — and its history in
/// `ScheduleWords`: answered, quiet, failed in the machine's words, caught up after the machine
/// was off, missed. Every press is the machine's to carry out; the view redraws from its answer.
@MainActor
final class ScheduleDetailView: NSView, NSTextFieldDelegate {
    private let column = FillingStack(topDown: true)
    private var scroll: NSScrollView?
    private let headline = NSTextField(wrappingLabelWithString: "")
    private let meta = NSTextField(wrappingLabelWithString: "")
    private let words = NSTextField()
    private let saveWords = NSButton()
    private let whenNow = NSTextField(labelWithString: "")
    private let phrase = NSTextField()
    private let understood = NSTextField(wrappingLabelWithString: "")
    private let changeWhen = NSButton()
    private let threadSwitch = NSSwitch()
    private let quietSwitch = NSSwitch()
    private let quietRow = NSStackView()
    private let runNow = NSButton()
    private let pause = NSButton()
    private let openChat = NSButton()
    private let delete = NSButton()
    private let history = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private(set) var row: ScheduleRow?
    private var busy = false
    var onOpenChat: ((String, String) -> Void)?
    var onToast: ((String) -> Void)?
    var onDeleted: (() -> Void)?

    /// The history rows' titles as drawn, for a harness.
    var historyTitles: [String] {
        history.arrangedSubviews.compactMap { ($0 as? HistoryRow)?.titleText }
    }
    var understoodText: String { understood.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        headline.font = MacTheme.Ramp.font(.headline)
        meta.font = MacTheme.Ramp.font(.panelDetail)
        meta.textColor = MacTheme.Color.secondaryLabel

        words.font = MacTheme.Ramp.font(.cardBody)
        words.usesSingleLineMode = false
        words.cell?.wraps = true
        words.cell?.isScrollable = false
        words.lineBreakMode = .byWordWrapping
        words.delegate = self
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        words.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        saveWords.title = Localized.text("Save words")
        saveWords.bezelStyle = .push
        saveWords.controlSize = .small
        saveWords.target = self
        saveWords.action = #selector(saveWordsTapped)
        saveWords.isEnabled = false

        whenNow.font = MacTheme.Ramp.font(.panelLabel)
        phrase.placeholderString = ScheduleWords.sayWhen
        phrase.font = MacTheme.Ramp.font(.cardBody)
        phrase.delegate = self
        phrase.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        understood.font = MacTheme.Ramp.font(.panelFootnote)
        understood.textColor = MacTheme.Color.secondaryLabel
        changeWhen.title = Localized.text("Change time")
        changeWhen.bezelStyle = .push
        changeWhen.controlSize = .small
        changeWhen.target = self
        changeWhen.action = #selector(changeWhenTapped)
        changeWhen.isEnabled = false
        let phraseRow = NSStackView(views: [phrase, changeWhen])
        phraseRow.orientation = .horizontal
        phraseRow.spacing = MacTheme.Spacing.s

        threadSwitch.target = self
        threadSwitch.action = #selector(threadChanged)
        quietSwitch.target = self
        quietSwitch.action = #selector(quietChanged)
        let threadRow = Self.switchRow(
            threadSwitch, ScheduleWords.oneConversation, ScheduleWords.oneConversationDetail)
        let quiet = Self.switchRow(quietSwitch, ScheduleWords.quiet, ScheduleWords.quietDetail)
        quietRow.orientation = .vertical
        quietRow.alignment = .leading
        quietRow.addArrangedSubview(quiet)
        let saveRow = NSStackView(views: [saveWords, Self.spacer()])
        saveRow.orientation = .horizontal

        for (button, title, action) in [
            (runNow, ScheduleWords.runNow, #selector(runNowTapped)),
            (pause, ScheduleWords.pause, #selector(pauseTapped)),
            (openChat, ScheduleWords.openConversation, #selector(openChatTapped)),
            (delete, ScheduleWords.delete, #selector(deleteTapped)),
        ] {
            button.title = title
            button.bezelStyle = .push
            button.target = self
            button.action = action
        }
        runNow.keyEquivalent = "\r"
        delete.contentTintColor = MacTheme.Color.danger
        let presses = NSStackView(views: [runNow, pause, openChat, Self.spacer(), delete])
        presses.orientation = .horizontal
        presses.spacing = MacTheme.Spacing.s

        history.orientation = .vertical
        history.alignment = .leading
        history.spacing = 2
        status.font = MacTheme.Ramp.font(.panelFootnote)
        status.textColor = MacTheme.Color.secondaryLabel
        status.isHidden = true

        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        for view in [
            headline, meta, MacDialogs.sectionHeader(Localized.text("ASKS")), words, saveRow,
            MacDialogs.sectionHeader(Localized.text("WHEN")), whenNow, phraseRow, understood,
            threadRow, quietRow, presses, status,
            MacDialogs.sectionHeader(ScheduleWords.history.uppercased()), history,
        ] {
            column.addArrangedSubview(view)
        }
        column.setCustomSpacing(MacTheme.Spacing.xs, after: headline)
        column.setCustomSpacing(MacTheme.Spacing.xs, after: words)
        column.setCustomSpacing(MacTheme.Spacing.l, after: saveRow)
        column.setCustomSpacing(MacTheme.Spacing.xs, after: whenNow)
        column.setCustomSpacing(MacTheme.Spacing.xs, after: phraseRow)
        let scroll = MacDialogs.scrollColumn(holding: column)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.scroll = scroll
    }

    private static func switchRow(_ control: NSSwitch, _ title: String, _ detail: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = MacTheme.Ramp.font(.panelLabel)
        let note = NSTextField(labelWithString: detail)
        note.font = MacTheme.Ramp.font(.panelFootnote)
        note.textColor = MacTheme.Color.secondaryLabel
        let lines = NSStackView(views: [label, note])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        control.controlSize = .small
        let row = NSStackView(views: [control, lines])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        return row
    }

    private static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    func show(_ row: ScheduleRow) {
        let same = self.row?.id == row.id
        self.row = row
        let schedule = row.schedule
        var zoned = Calendar.current
        zoned.timeZone = TimeZone(identifier: schedule.timeZone) ?? .current
        headline.stringValue = row.title
        var facts = [row.machine]
        if let model = Self.modelWord(schedule, profileID: row.profileID) { facts.append(model) }
        facts.append(schedule.thread == .continue ? ScheduleWords.oneConversation : Localized.text("A new conversation each time"))
        if schedule.rule.isRepeating, schedule.quiet { facts.append(Localized.text("quiet")) }
        meta.stringValue = facts.joined(separator: " · ")
        if !same || !saveWords.isEnabled { words.stringValue = schedule.text }
        saveWords.isEnabled = words.stringValue != schedule.text
        var when = schedule.isFinished
            ? ScheduleWords.done
            : (schedule.paused ? ScheduleWords.paused : ScheduleWords.when(schedule.rule, calendar: zoned))
        if let next = schedule.next, !schedule.paused {
            when += " · " + ScheduleWords.next(next, calendar: zoned)
        }
        whenNow.stringValue = when
        if !same {
            phrase.stringValue = ""
            readPhrase()
        }
        threadSwitch.state = schedule.thread == .continue ? .on : .off
        quietSwitch.state = schedule.quiet ? .on : .off
        quietRow.isHidden = !schedule.rule.isRepeating
        pause.title = schedule.paused ? ScheduleWords.resume : ScheduleWords.pause
        pause.isHidden = schedule.isFinished
        openChat.isHidden = (schedule.sessionID ?? schedule.runs.first?.sessionID) == nil
        renderHistory(row, calendar: zoned)
        setBusy(busy)
    }

    /// The model as the pill would say it, read from the machine's catalog: an agent's model
    /// wears its agent first.
    static func modelWord(_ schedule: MachineSchedule, profileID: String) -> String? {
        guard let raw = schedule.model, !raw.isEmpty else { return nil }
        let catalog = ModelCatalogStore.cached(profileID)
        let selection =
            raw.contains("/")
            ? (ModelSelection(string: raw) ?? ModelSelection(providerID: "", modelID: raw))
            : (catalog.first { $0.id == raw }?.selection ?? ModelSelection(providerID: "", modelID: raw))
        return ModelBadge.word(for: selection, in: catalog)
    }

    private func renderHistory(_ row: ScheduleRow, calendar: Calendar) {
        history.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !row.schedule.runs.isEmpty else {
            history.addArrangedSubview(MacDialogs.detailLabel(ScheduleWords.noHistory))
            return
        }
        for run in row.schedule.runs {
            let reading = ScheduleWords.run(run, machine: row.machine, calendar: calendar)
            let line = HistoryRow(
                title: reading.title, detail: reading.detail, mark: reading.mark,
                opens: run.sessionID != nil
            ) { [weak self] in
                guard let session = run.sessionID else { return }
                self?.onOpenChat?(row.profileID, session)
            }
            history.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: history.widthAnchor).isActive = true
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === words, let row {
            saveWords.isEnabled = words.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                != row.schedule.text && !words.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if field === phrase { readPhrase() }
    }

    /// Typed text in the field, `phrase`, and what it was understood as. Set by a harness to stage
    /// the field the way a person would type it.
    func type(phrase text: String) {
        phrase.stringValue = text
        readPhrase()
    }

    private func readPhrase() {
        guard let row else { return }
        var sheet = AskLaterSheet(text: row.schedule.text, machine: row.machine)
        sheet.type(phrase.stringValue)
        var zoned = Calendar.current
        zoned.timeZone = TimeZone(identifier: row.schedule.timeZone) ?? .current
        if let line = sheet.understoodLine(calendar: zoned) {
            understood.stringValue = line.detail.isEmpty ? line.headline : line.headline + " — " + line.detail
            understood.textColor =
                sheet.understanding(calendar: zoned) == nil ? MacTheme.Color.warning : MacTheme.Color.secondaryLabel
            understood.isHidden = false
        } else {
            understood.stringValue = ""
            understood.isHidden = true
        }
        changeWhen.isEnabled = sheet.understanding(calendar: zoned) != nil
    }

    private func setBusy(_ value: Bool) {
        busy = value
        for button in [runNow, pause, delete, changeWhen, saveWords] { button.isEnabled = !value && button.isEnabled }
        if !value {
            runNow.isEnabled = true
            pause.isEnabled = true
            delete.isEnabled = true
            if let row { saveWords.isEnabled = words.stringValue != row.schedule.text }
            readPhrase()
        }
        threadSwitch.isEnabled = !value
        quietSwitch.isEnabled = !value
    }

    /// One press, sent to the machine; the list and this view redraw from its answer.
    private func change(
        _ toast: String?, then: (@MainActor () -> Void)? = nil,
        _ work: @escaping @MainActor (any MachineScheduling, MachineSchedule) async throws -> Void
    ) {
        guard let row, !busy, let scheduling = MachineDesk.shared.scheduling(for: row.profileID) else { return }
        setBusy(true)
        status.isHidden = true
        Task { [weak self] in
            do {
                try await work(scheduling, row.schedule)
                then?()
                await MachineDesk.shared.refreshSchedules()
                if let toast { self?.onToast?(toast) }
            } catch {
                self?.status.stringValue = AgentErrorText.readable(error)
                self?.status.isHidden = false
            }
            self?.setBusy(false)
        }
    }

    @objc private func saveWordsTapped() {
        let text = words.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        change(Localized.text("Saved")) { scheduling, schedule in
            _ = try await scheduling.updateSchedule(schedule.id, ScheduleChange(text: text))
        }
    }

    @objc private func changeWhenTapped() {
        guard let row else { return }
        var sheet = AskLaterSheet(text: row.schedule.text, machine: row.machine)
        sheet.type(phrase.stringValue)
        var zoned = Calendar.current
        zoned.timeZone = TimeZone(identifier: row.schedule.timeZone) ?? .current
        guard let understanding = sheet.understanding(calendar: zoned) else { return }
        let words = ScheduleWords.confirm(understanding, calendar: zoned)
        change(words) { scheduling, schedule in
            _ = try await scheduling.updateSchedule(
                schedule.id,
                ScheduleChange(rule: understanding.rule, timeZone: TimeZone.current.identifier))
        }
        phrase.stringValue = ""
    }

    @objc private func threadChanged() {
        let thread: MachineSchedule.Thread = threadSwitch.state == .on ? .continue : .fresh
        change(nil) { scheduling, schedule in
            _ = try await scheduling.updateSchedule(schedule.id, ScheduleChange(thread: thread))
        }
    }

    @objc private func quietChanged() {
        let quiet = quietSwitch.state == .on
        change(nil) { scheduling, schedule in
            _ = try await scheduling.updateSchedule(schedule.id, ScheduleChange(quiet: quiet))
        }
    }

    @objc private func runNowTapped() {
        guard let row else { return }
        change(Localized.text("Asking %@ now", row.machine)) { scheduling, schedule in
            _ = try await scheduling.runSchedule(schedule.id)
        }
    }

    @objc private func pauseTapped() {
        guard let row else { return }
        let paused = !row.schedule.paused
        change(paused ? ScheduleWords.paused : nil) { scheduling, schedule in
            _ = try await scheduling.updateSchedule(schedule.id, ScheduleChange(paused: paused))
        }
    }

    @objc private func openChatTapped() {
        guard let row, let session = row.schedule.sessionID ?? row.schedule.runs.first?.sessionID else {
            return
        }
        onOpenChat?(row.profileID, session)
    }

    @objc private func deleteTapped() {
        guard row != nil else { return }
        MacDialogs.confirm(
            on: window, title: ScheduleWords.delete + "?", body: ScheduleWords.deleteDetail,
            confirmLabel: Localized.text("Delete")
        ) { [weak self] in
            self?.change(Localized.text("Deleted"), then: { self?.onDeleted?() }) { scheduling, schedule in
                try await scheduling.deleteSchedule(schedule.id)
            }
        }
    }
}

/// One run in a schedule's history: its mark, what happened, and its conversation one press away.
@MainActor
final class HistoryRow: NSView {
    private let title = NSTextField(labelWithString: "")
    private let action: () -> Void

    var titleText: String { title.stringValue }

    init(title text: String, detail: String?, mark: ScheduleMark, opens: Bool, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let glyph = NSTextField(labelWithString: mark.glyph)
        glyph.font = MacTheme.Ramp.font(.panelLabel)
        glyph.textColor = ScheduledWindow.color(mark)
        glyph.alignment = .center
        glyph.widthAnchor.constraint(equalToConstant: 16).isActive = true
        title.stringValue = text
        title.font = MacTheme.Ramp.font(.panelLabel)
        let note = NSTextField(labelWithString: detail ?? "")
        note.font = MacTheme.Ramp.font(.panelFootnote)
        note.textColor = MacTheme.Color.secondaryLabel
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.isHidden = (detail ?? "").isEmpty
        let lines = NSStackView(views: [title, note])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 0
        lines.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [glyph, lines]
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        views.append(spacer)
        if opens {
            let open = RowKit.ActionButton(title: Localized.text("Open")) { [weak self] in self?.action() }
            open.bezelStyle = .inline
            open.controlSize = .small
            views.append(open)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        row.edgeInsets = NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel([text, detail ?? ""].joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

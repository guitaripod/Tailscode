import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// Making or changing an expert: who it is (name, mark, hue, what it is for), where and with what
/// it works (folder, model, effort, notebook), its charter and skills, its bench and its guards, and
/// when the guards run. Saved to the machine in one press; what the machine refuses is said under
/// the form in the machine's own words, and nothing is lost by it.
@MainActor
final class ExpertEditorSheet: NSObject, NSTextViewDelegate {
    private static var active: [ExpertEditorSheet] = []

    let sheet: NSWindow
    private let profile: ConnectionProfile
    private let editing: MachineExpert?
    private let name = NSTextField()
    private let glyph = NSTextField()
    private var hue: ExpertHue
    private let swatches = NSStackView()
    private let preview: ExpertMarkView
    private let purpose = NSTextField()
    private let folder = NSTextField()
    private let model = NSPopUpButton()
    private let effort = NSPopUpButton()
    private let notebookChoice = NSPopUpButton()
    private let notebookPath = NSTextField()
    private let charter = NSTextView()
    private let charterCount = NSTextField(labelWithString: "")
    private let skillsBox = NSStackView()
    private var skillChecks: [NSButton] = []
    private let notesBox = NSStackView()
    private var noteChecks: [(note: ExpertDraftNote, check: NSButton)] = []
    private let seed: ExpertDraft?
    private let benchList = NSStackView()
    private var benchRows: [ExpertBenchEditorRow] = []
    private let guardList = NSStackView()
    private var guardRows: [ExpertGuardEditorRow] = []
    private let ruleKind = NSPopUpButton()
    private let ruleTime = NSDatePicker()
    private let failure = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let onSaved: @MainActor (MachineExpert) -> Void
    private var saving = false

    /// What the form holds, for a harness.
    var nameValue: String { name.stringValue }
    var benchCount: Int { benchRows.count }
    var guardCount: Int { guardRows.count }
    var chosenHue: ExpertHue { hue }
    var swatchViews: [ExpertSwatch] { swatches.arrangedSubviews.compactMap { $0 as? ExpertSwatch } }
    var unnamedControls: [String] {
        let fields: [NSView] = [name, glyph, purpose, folder, model, effort, notebookChoice, notebookPath, charter, ruleKind, ruleTime]
        return fields.filter { ($0.accessibilityLabel() ?? "").isEmpty }.map { String(describing: type(of: $0)) }
    }

    @discardableResult
    static func present(
        on host: NSWindow, profile: ConnectionProfile, editing: MachineExpert?, seed: ExpertDraft? = nil,
        onSaved: @escaping @MainActor (MachineExpert) -> Void
    ) -> ExpertEditorSheet {
        let controller = ExpertEditorSheet(profile: profile, editing: editing, seed: seed, onSaved: onSaved)
        active.append(controller)
        host.beginSheet(controller.sheet) { _ in active.removeAll { $0 === controller } }
        controller.sheet.makeFirstResponder(controller.name)
        return controller
    }

    private init(
        profile: ConnectionProfile, editing: MachineExpert?, seed: ExpertDraft?,
        onSaved: @escaping @MainActor (MachineExpert) -> Void
    ) {
        self.profile = profile
        self.editing = editing
        self.seed = seed
        self.onSaved = onSaved
        hue = ExpertHue(editing?.hue ?? seed?.hue ?? "blue")
        preview = ExpertMarkView(glyph: editing?.glyph ?? seed?.glyph ?? "Ex", hue: hue, side: 40)
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 760), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        sheet.contentMinSize = NSSize(width: 620, height: 520)
        super.init()
        sheet.title = editing == nil ? ExpertWords.newExpert : Localized.text("Edit %@", editing?.name ?? "")
        build()
        fill(editing: editing, seed: seed)
        loadSkills(chosen: editing?.skills ?? seed?.skills ?? [])
    }

    private func build() {
        name.placeholderString = Localized.text("iPadOS, Releases, Server…")
        glyph.placeholderString = "Ex"
        glyph.widthAnchor.constraint(equalToConstant: 48).isActive = true
        glyph.target = self
        glyph.action = #selector(glyphChanged)
        glyph.delegate = self
        purpose.placeholderString = Localized.text("One sentence on what it is for")
        folder.placeholderString = Localized.text("Where its tasks run on %@", profile.name)
        notebookPath.placeholderString = Localized.text("A memory folder on %@", profile.name)
        notebookChoice.addItems(withTitles: [ExpertWords.notebookOwn, Localized.text("Adopt a folder")])
        notebookChoice.target = self
        notebookChoice.action = #selector(notebookChanged)
        model.addItem(withTitle: Localized.text("Machine default"))
        model.lastItem?.representedObject = ""
        for info in ModelCatalogStore.cached(profile.id) where !info.id.contains("/") {
            model.addItem(withTitle: info.name.isEmpty ? info.id : info.name)
            model.lastItem?.representedObject = info.id
        }
        effort.setAccessibilityLabel(Localized.text("Effort"))
        effort.addItem(withTitle: Localized.text("Machine default"))
        effort.lastItem?.representedObject = ""
        for level in ["low", "medium", "high", "xhigh", "max"] {
            effort.addItem(withTitle: level)
            effort.lastItem?.representedObject = level
        }
        for option in ExpertHue.allCases {
            let swatch = ExpertSwatch(hue: option)
            swatch.target = self
            swatch.action = #selector(hueChosen(_:))
            swatches.addArrangedSubview(swatch)
        }
        swatches.orientation = .horizontal
        swatches.spacing = 6
        swatches.setAccessibilityElement(true)
        swatches.setAccessibilityRole(.radioGroup)
        swatches.setAccessibilityLabel(Localized.text("Colour"))
        let markLine = NSStackView(views: [preview, glyph, swatches])
        markLine.orientation = .horizontal
        markLine.alignment = .centerY
        markLine.spacing = MacTheme.Spacing.m

        charter.delegate = self
        charter.setAccessibilityLabel(ExpertWords.charter)
        charter.font = MacTheme.Ramp.font(.cardBody)
        charter.isRichText = false
        charter.allowsUndo = true
        charter.textContainerInset = NSSize(width: 6, height: 6)
        charter.isVerticallyResizable = true
        charter.autoresizingMask = [.width]
        charter.textContainer?.widthTracksTextView = true
        let charterScroll = NSScrollView()
        charterScroll.documentView = charter
        charterScroll.hasVerticalScroller = true
        charterScroll.borderType = .bezelBorder
        charterScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        charterCount.font = MacTheme.Ramp.font(.panelFootnote)
        charterCount.textColor = MacTheme.Color.tertiaryLabel

        skillsBox.orientation = .vertical
        skillsBox.alignment = .leading
        skillsBox.spacing = 4
        benchList.orientation = .vertical
        benchList.alignment = .width
        benchList.spacing = MacTheme.Spacing.s
        guardList.orientation = .vertical
        guardList.alignment = .width
        guardList.spacing = MacTheme.Spacing.s
        let addBench = NSButton(title: ExpertWords.addBenchItem, target: self, action: #selector(addBenchRow))
        addBench.bezelStyle = .accessoryBarAction
        addBench.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addBench.imagePosition = .imageLeading
        let addGuard = NSButton(title: ExpertWords.addGuard, target: self, action: #selector(addGuardRow))
        addGuard.bezelStyle = .accessoryBarAction
        addGuard.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addGuard.imagePosition = .imageLeading

        ruleKind.addItems(withTitles: [ExpertWords.guardsOnDemand, Localized.text("Every day at"), Localized.text("Weekdays at")])
        ruleKind.target = self
        ruleKind.action = #selector(ruleChanged)
        ruleKind.setAccessibilityLabel(Localized.text("When"))
        ruleTime.setAccessibilityLabel(Localized.text("Time"))
        ruleTime.datePickerStyle = .textFieldAndStepper
        ruleTime.datePickerElements = .hourMinute
        var calendar = Calendar.current
        calendar.timeZone = .current
        ruleTime.dateValue = calendar.date(bySettingHour: 3, minute: 0, second: 0, of: Date()) ?? Date()
        let ruleLine = NSStackView(views: [ruleKind, ruleTime, expertSpacer()])
        ruleLine.orientation = .horizontal
        ruleLine.distribution = .fill
        ruleKind.setContentHuggingPriority(.required, for: .horizontal)
        ruleTime.setContentHuggingPriority(.required, for: .horizontal)
        ruleLine.spacing = MacTheme.Spacing.s

        let modelLine = NSStackView(views: [model, effort])
        modelLine.orientation = .horizontal
        modelLine.spacing = MacTheme.Spacing.s
        let notebookLine = NSStackView(views: [notebookChoice, notebookPath])
        notebookLine.orientation = .horizontal
        notebookLine.spacing = MacTheme.Spacing.s
        notebookLine.distribution = .fill
        notebookPath.setContentHuggingPriority(.init(1), for: .horizontal)
        expertHug(markLine, modelLine, notebookLine)
        let form = [
            ExpertFormRow(label: label(ExpertWords.name), content: name),
            ExpertFormRow(label: label(Localized.text("Mark")), content: markLine, hugs: true),
            ExpertFormRow(label: label(ExpertWords.purpose), content: purpose),
            ExpertFormRow(label: label(ExpertWords.folder), content: folder),
            ExpertFormRow(label: label(ExpertWords.model), content: modelLine, hugs: true),
            ExpertFormRow(label: label(ExpertWords.notebookFolder), content: notebookLine),
        ]

        failure.font = MacTheme.Ramp.font(.panelFootnote)
        failure.textColor = MacTheme.Color.danger
        failure.isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        saveButton.title = editing == nil ? ExpertWords.create : ExpertWords.save
        saveButton.bezelStyle = .push
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = [.command]
        saveButton.target = self
        saveButton.action = #selector(save)
        let cancel = NSButton(title: ExpertWords.cancel, target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .push
        cancel.keyEquivalent = "\u{1B}"
        let spacer = expertSpacer()
        let footer = NSStackView(views: [spinner, failure, spacer, cancel, saveButton])
        footer.orientation = .horizontal
        footer.spacing = MacTheme.Spacing.s
        failure.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let column = FillingStack(topDown: true)
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        expertHug(benchList, guardList, skillsBox, notesBox, ruleLine, footer)
        for row in form { column.addArrangedSubview(row) }
        column.addArrangedSubview(MacDialogs.sectionHeader(ExpertWords.charter))
        column.addArrangedSubview(charterScroll)
        column.addArrangedSubview(charterCount)
        if let notes = seed?.notes, !notes.isEmpty, editing == nil {
            notesBox.orientation = .vertical
            notesBox.alignment = .leading
            notesBox.spacing = 4
            let ticks = ExpertMaking.defaultTicks(seed ?? ExpertDraft(name: ""))
            for note in notes {
                let check = NSButton(checkboxWithTitle: note.title, target: nil, action: nil)
                check.state = ticks.contains(note.title) ? .on : .off
                check.toolTip = note.summary
                let words = NSTextField(labelWithString: note.lasting == false ? ExpertWords.lastingUnticked : note.summary)
                words.font = MacTheme.Ramp.font(.panelFootnote)
                words.textColor = note.lasting == false ? MacTheme.Color.warning : MacTheme.Color.secondaryLabel
                words.lineBreakMode = .byTruncatingTail
                words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let line = NSStackView(views: [check, words])
                line.orientation = .horizontal
                line.spacing = MacTheme.Spacing.s
                noteChecks.append((note, check))
                notesBox.addArrangedSubview(line)
            }
            column.addArrangedSubview(
                MacDialogs.sectionHeader(Localized.text("First notes · %d drafted", notes.count)))
            column.addArrangedSubview(notesBox)
        }
        column.addArrangedSubview(MacDialogs.sectionHeader(ExpertWords.skills))
        column.addArrangedSubview(skillsBox)
        column.addArrangedSubview(MacDialogs.sectionHeader(ExpertWords.bench))
        column.addArrangedSubview(benchList)
        column.addArrangedSubview(addBench)
        column.addArrangedSubview(MacDialogs.sectionHeader(ExpertWords.guards))
        column.addArrangedSubview(guardList)
        column.addArrangedSubview(addGuard)
        column.addArrangedSubview(ruleLine)
        let scroll = NSScrollView()
        let clip = ExpertFlippedClip()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = column
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            column.topAnchor.constraint(equalTo: clip.topAnchor),
            column.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
        let root = NSView()
        let footerHolder = NSStackView(views: [footer])
        expertHug(footerHolder)
        footerHolder.edgeInsets = NSEdgeInsets(top: 10, left: 22, bottom: 16, right: 22)
        footerHolder.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        root.addSubview(footerHolder)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerHolder.topAnchor),
            footerHolder.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerHolder.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerHolder.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.widthAnchor.constraint(equalTo: footerHolder.widthAnchor, constant: -44),
            notebookPath.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        sheet.contentView = root
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = MacTheme.Ramp.font(.panelLabel)
        field.textColor = MacTheme.Color.secondaryLabel
        return field
    }

    private func fill(editing: MachineExpert?, seed: ExpertDraft?) {
        name.stringValue = editing?.name ?? seed?.name ?? ""
        glyph.stringValue = editing?.glyph ?? seed?.glyph ?? ""
        purpose.stringValue = editing?.purpose ?? seed?.purpose ?? ""
        folder.stringValue = editing?.directory ?? seed?.directory ?? ""
        charter.string = editing?.charter ?? seed?.charter ?? ""
        let chosenModel = editing?.model ?? seed?.model ?? ""
        if let index = model.itemArray.firstIndex(where: { ($0.representedObject as? String) == chosenModel }) {
            model.selectItem(at: index)
        } else if !chosenModel.isEmpty {
            model.addItem(withTitle: chosenModel)
            model.lastItem?.representedObject = chosenModel
            model.select(model.lastItem)
        }
        let chosenEffort = editing?.effort ?? seed?.effort ?? ""
        if let index = effort.itemArray.firstIndex(where: { ($0.representedObject as? String) == chosenEffort }) {
            effort.selectItem(at: index)
        }
        let adopted = editing?.notebookPath ?? seed?.notebookPath
        notebookChoice.selectItem(at: adopted == nil ? 0 : 1)
        notebookPath.stringValue = adopted ?? ""
        notebookPath.isEnabled = adopted != nil
        for item in editing?.bench ?? seed?.bench ?? [] { appendBench(item) }
        for item in editing?.guards ?? seed?.guards ?? [] { appendGuard(item) }
        let rule = editing?.guardRule ?? seed?.guardRule
        switch rule?.kind {
        case .daily: ruleKind.selectItem(at: 1)
        case .weekdays: ruleKind.selectItem(at: 2)
        default: ruleKind.selectItem(at: 0)
        }
        if let rule, let hour = rule.hour {
            ruleTime.dateValue =
                Calendar.current.date(bySettingHour: hour, minute: rule.minute ?? 0, second: 0, of: Date()) ?? Date()
        }
        ruleChanged()
        refreshMark()
        refreshCount()
        for swatch in swatches.arrangedSubviews.compactMap({ $0 as? ExpertSwatch }) {
            swatch.chosen = swatch.hue == hue
        }
    }

    private func loadSkills(chosen: [String]) {
        guard let keeping = ExpertDesk.shared.keeping(for: profile.id) else {
            showSkills([], chosen: chosen)
            return
        }
        let reading = NSTextField(labelWithString: Localized.text("Reading the machine's skills…"))
        reading.font = MacTheme.Ramp.font(.panelFootnote)
        reading.textColor = MacTheme.Color.tertiaryLabel
        skillsBox.addArrangedSubview(reading)
        Task { [weak self] in
            let found = (try? await keeping.expertSkills()) ?? []
            self?.showSkills(found, chosen: chosen)
        }
    }

    private func showSkills(_ found: [ExpertSkill], chosen: [String]) {
        skillsBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        skillChecks = []
        var names = found.map(\.name)
        for name in chosen where !names.contains(name) { names.append(name) }
        if names.isEmpty {
            let none = NSTextField(labelWithString: Localized.text("No skills on %@", profile.name))
            none.font = MacTheme.Ramp.font(.panelFootnote)
            none.textColor = MacTheme.Color.tertiaryLabel
            skillsBox.addArrangedSubview(none)
            return
        }
        for name in names {
            let check = NSButton(checkboxWithTitle: name, target: nil, action: nil)
            check.state = chosen.contains(name) ? .on : .off
            check.toolTip = found.first { $0.name == name }?.description
            skillChecks.append(check)
            skillsBox.addArrangedSubview(check)
        }
    }

    @objc private func glyphChanged() { refreshMark() }

    @objc private func hueChosen(_ sender: ExpertSwatch) {
        hue = sender.hue
        for swatch in swatches.arrangedSubviews.compactMap({ $0 as? ExpertSwatch }) {
            swatch.chosen = swatch.hue == hue
        }
        refreshMark()
    }

    private func refreshMark() {
        let typed = glyph.stringValue.trimmingCharacters(in: .whitespaces)
        preview.glyph = typed.isEmpty ? ExpertMaking.glyph(for: name.stringValue) : String(typed.prefix(2))
        preview.hue = hue
    }

    @objc private func notebookChanged() {
        notebookPath.isEnabled = notebookChoice.indexOfSelectedItem == 1
        if notebookPath.isEnabled { sheet.makeFirstResponder(notebookPath) }
    }

    @objc private func ruleChanged() {
        ruleTime.isEnabled = ruleKind.indexOfSelectedItem != 0
    }

    func textDidChange(_ notification: Notification) { refreshCount() }

    private func refreshCount() {
        let count = charter.string.count
        charterCount.stringValue = Localized.text("%d of 6000 characters: a map, not a manual", count)
        charterCount.textColor = count > 6_000 ? MacTheme.Color.danger : MacTheme.Color.tertiaryLabel
    }

    @objc private func addBenchRow() {
        appendBench(ExpertBenchItem(name: "", kind: .appleDevice))
        sheet.makeFirstResponder(benchRows.last?.nameField)
    }

    private func appendBench(_ item: ExpertBenchItem) {
        let row = ExpertBenchEditorRow(item: item, machine: profile.name)
        row.onRemove = { [weak self, weak row] in
            guard let self, let row else { return }
            self.benchRows.removeAll { $0 === row }
            row.removeFromSuperview()
        }
        benchRows.append(row)
        benchList.addArrangedSubview(row)
    }

    @objc private func addGuardRow() {
        appendGuard(ExpertGuard(name: "", command: ""))
        sheet.makeFirstResponder(guardRows.last?.nameField)
    }

    private func appendGuard(_ item: ExpertGuard) {
        let row = ExpertGuardEditorRow(item: item)
        row.onRemove = { [weak self, weak row] in
            guard let self, let row else { return }
            self.guardRows.removeAll { $0 === row }
            row.removeFromSuperview()
        }
        guardRows.append(row)
        guardList.addArrangedSubview(row)
    }

    @objc private func cancelTapped() {
        guard !saving else { return }
        sheet.sheetParent?.endSheet(sheet)
    }

    private var rule: ScheduleRule? {
        guard ruleKind.indexOfSelectedItem != 0 else { return nil }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: ruleTime.dateValue)
        return ScheduleRule(
            kind: ruleKind.indexOfSelectedItem == 1 ? .daily : .weekdays, hour: parts.hour ?? 3,
            minute: parts.minute ?? 0)
    }

    /// Everything the form holds, sent to the machine in one press.
    @objc func save() {
        guard !saving, let keeping = ExpertDesk.shared.keeping(for: profile.id) else { return }
        let trimmedName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            show(Localized.text("An expert needs a name."))
            return
        }
        let skills = skillChecks.filter { $0.state == .on }.map(\.title)
        let bench = benchRows.compactMap(\.item)
        let guards = guardRows.compactMap(\.item)
        let modelID = (model.selectedItem?.representedObject as? String) ?? ""
        let effortLevel = (effort.selectedItem?.representedObject as? String) ?? ""
        let adopted = notebookChoice.indexOfSelectedItem == 1 ? notebookPath.stringValue.trimmingCharacters(in: .whitespaces) : ""
        let typedGlyph = glyph.stringValue.trimmingCharacters(in: .whitespaces)
        saving = true
        spinner.startAnimation(nil)
        saveButton.isEnabled = false
        failure.isHidden = true
        let profileID = profile.id
        let editing = self.editing
        let rule = self.rule
        let ticked = Set(noteChecks.filter { $0.check.state == .on }.map(\.note.title))
        var draft = ExpertDraft(
            name: trimmedName, glyph: typedGlyph.isEmpty ? nil : typedGlyph, hue: hue.rawValue,
            purpose: purpose.stringValue, directory: folder.stringValue.isEmpty ? nil : folder.stringValue,
            model: modelID.isEmpty ? nil : modelID, effort: effortLevel.isEmpty ? nil : effortLevel,
            charter: charter.string, skills: skills, notebookPath: adopted.isEmpty ? nil : adopted, bench: bench,
            guards: guards, guardRule: rule, timeZone: TimeZone.current.identifier,
            notes: seed?.notes)
        draft = ExpertMaking.finalized(draft, keeping: ticked)
        Task { [weak self] in
            do {
                let saved: MachineExpert
                if let editing {
                    saved = try await keeping.updateExpert(
                        editing.id,
                        ExpertChange(
                            name: trimmedName, glyph: typedGlyph.isEmpty ? ExpertMaking.glyph(for: trimmedName) : typedGlyph,
                            hue: draft.hue, purpose: draft.purpose ?? "", directory: draft.directory ?? "",
                            model: modelID, effort: effortLevel, charter: draft.charter ?? "", skills: skills,
                            notebookPath: adopted, bench: bench, guards: guards, guardRule: rule,
                            guardsOnDemand: rule == nil ? true : nil, timeZone: TimeZone.current.identifier))
                } else {
                    saved = try await keeping.createExpert(draft)
                }
                ExpertDesk.shared.adopt(saved, profileID: profileID)
                guard let self else { return }
                self.spinner.stopAnimation(nil)
                self.sheet.sheetParent?.endSheet(self.sheet)
                self.onSaved(saved)
            } catch {
                self?.saving = false
                self?.spinner.stopAnimation(nil)
                self?.saveButton.isEnabled = true
                self?.show(AgentErrorText.readable(error))
            }
        }
    }

    private func show(_ text: String) {
        failure.stringValue = text
        failure.isHidden = false
    }

    /// Fills the form, for a harness.
    func stage(name text: String, charter words: String) {
        name.stringValue = text
        charter.string = words
        refreshMark()
        refreshCount()
    }
}

extension ExpertEditorSheet: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { refreshMark() }
}

/// One hue to choose: a dot of the colour, ringed while chosen.
@MainActor
final class ExpertSwatch: NSControl {
    let hue: ExpertHue
    var chosen = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(NSNumber(value: chosen))
        }
    }

    init(hue: ExpertHue) {
        self.hue = hue
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20), heightAnchor.constraint(equalToConstant: 20),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(hue.name)
        setAccessibilityValue(NSNumber(value: false))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }

    override func mouseDown(with event: NSEvent) { sendAction(action, to: target) }

    /// With Full Keyboard Access on, each colour is a stop in the Tab loop and Space or Return
    /// chooses it, as the system's own radio buttons are.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: bounds).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard event.characters == " " || event.characters == "\r" else {
            super.keyDown(with: event)
            return
        }
        sendAction(action, to: target)
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        ExpertInk.hue(hue).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).fill()
        guard chosen else { return }
        MacTheme.Color.label.setStroke()
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        ring.stroke()
    }
}

/// One device or service on the bench, as the form edits it: what kind, its name, how the machine
/// finds it, the lock held around it, and a press that takes it off. Placed by constraints, one line.
@MainActor
final class ExpertBenchEditorRow: NSView {
    private let id: String
    let nameField = NSTextField()
    private let kind = NSPopUpButton()
    private let target = NSTextField()
    private let lock = NSTextField()
    private let remove = NSButton()
    private let machine: String
    var onRemove: (() -> Void)?

    init(item: ExpertBenchItem, machine: String) {
        id = item.id
        self.machine = machine
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        kind.addItems(withTitles: [Localized.text("Apple device"), Localized.text("Command"), Localized.text("Port")])
        kind.selectItem(at: ExpertBenchItem.Kind.allCases.firstIndex(of: item.kind) ?? 0)
        kind.target = self
        kind.action = #selector(kindChanged)
        nameField.placeholderString = ExpertWords.name
        nameField.stringValue = item.name
        switch item.kind {
        case .appleDevice: target.stringValue = item.identifier ?? ""
        case .command: target.stringValue = item.command ?? ""
        case .port: target.stringValue = [item.host, item.port.map(String.init)].compactMap { $0 }.joined(separator: ":")
        }
        lock.placeholderString = Localized.text("Lock file (optional)")
        lock.stringValue = item.lock ?? ""
        remove.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: Localized.text("Remove"))
        remove.isBordered = false
        remove.target = self
        remove.action = #selector(removeTapped)
        for view in [kind, nameField, target, lock, remove] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let gap = MacTheme.Spacing.s
        NSLayoutConstraint.activate([
            kind.leadingAnchor.constraint(equalTo: leadingAnchor),
            kind.widthAnchor.constraint(equalToConstant: 128),
            kind.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: kind.trailingAnchor, constant: gap),
            nameField.widthAnchor.constraint(equalToConstant: 130),
            nameField.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            nameField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            target.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: gap),
            target.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            target.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            lock.leadingAnchor.constraint(equalTo: target.trailingAnchor, constant: gap),
            lock.widthAnchor.constraint(equalToConstant: 150),
            lock.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            remove.leadingAnchor.constraint(equalTo: lock.trailingAnchor, constant: gap),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor),
            remove.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 20),
        ])
        kindChanged()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func kindChanged() {
        switch kind.indexOfSelectedItem {
        case 1: target.placeholderString = Localized.text("A command that exits 0 when it is there")
        case 2: target.placeholderString = "host:port"
        default: target.placeholderString = Localized.text("UDID or device name on %@", machine)
        }
    }

    @objc private func removeTapped() { onRemove?() }

    /// The item as the form says it, or nil for a row left empty.
    var item: ExpertBenchItem? {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let value = target.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty || !value.isEmpty else { return nil }
        let kinds = ExpertBenchItem.Kind.allCases
        let chosen = kinds.indices.contains(kind.indexOfSelectedItem) ? kinds[kind.indexOfSelectedItem] : .appleDevice
        let lockPath = lock.stringValue.trimmingCharacters(in: .whitespaces)
        var item = ExpertBenchItem(
            id: id, name: name.isEmpty ? value : name, kind: chosen, lock: lockPath.isEmpty ? nil : lockPath)
        switch chosen {
        case .appleDevice: item.identifier = value.isEmpty ? nil : value
        case .command: item.command = value
        case .port:
            let parts = value.split(separator: ":")
            if parts.count == 2 {
                item.host = String(parts[0])
                item.port = Int(parts[1])
            } else {
                item.port = Int(value)
            }
        }
        return item
    }
}

/// One guard, as the form edits it: its name and command, and — when it measures a number — the
/// pattern that finds the number and the line it is held to. Placed by constraints; the metric
/// line folds away when the guard measures nothing.
@MainActor
final class ExpertGuardEditorRow: NSView {
    private let id: String
    let nameField = NSTextField()
    private let command = NSTextField()
    private let measures = NSButton(checkboxWithTitle: Localized.text("Measures a number"), target: nil, action: nil)
    private let pattern = NSTextField()
    private let bound = NSPopUpButton()
    private let limit = NSTextField()
    private let unit = NSTextField()
    private let remove = NSButton()
    private var withMetric: NSLayoutConstraint!
    private var withoutMetric: NSLayoutConstraint!
    var onRemove: (() -> Void)?

    init(item: ExpertGuard) {
        id = item.id
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholderString = ExpertWords.name
        nameField.stringValue = item.name
        command.placeholderString = Localized.text("The command, run in the expert's folder")
        command.stringValue = item.command
        command.font = MacTheme.Ramp.font(.code)
        remove.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: Localized.text("Remove"))
        remove.isBordered = false
        remove.target = self
        remove.action = #selector(removeTapped)
        measures.target = self
        measures.action = #selector(measuresChanged)
        measures.state = item.metric == nil ? .off : .on
        pattern.placeholderString = "first frame ([0-9.]+) ms"
        pattern.stringValue = item.metric?.pattern ?? ""
        pattern.font = MacTheme.Ramp.font(.code)
        bound.addItems(withTitles: [Localized.text("at most"), Localized.text("at least")])
        bound.selectItem(at: item.metric?.atLeast != nil && item.metric?.atMost == nil ? 1 : 0)
        limit.placeholderString = "100"
        limit.stringValue = (item.metric?.atMost ?? item.metric?.atLeast).map { String(format: "%g", $0) } ?? ""
        unit.placeholderString = "ms"
        unit.stringValue = item.metric?.unit ?? ""
        for view in [nameField, command, remove, measures, pattern, bound, limit, unit] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let gap = MacTheme.Spacing.s
        withMetric = bottomAnchor.constraint(equalTo: pattern.bottomAnchor, constant: 2)
        withoutMetric = bottomAnchor.constraint(equalTo: measures.bottomAnchor, constant: 2)
        NSLayoutConstraint.activate([
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameField.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            nameField.widthAnchor.constraint(equalToConstant: 170),
            command.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: gap),
            command.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            command.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -gap),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor),
            remove.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 20),
            measures.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            measures.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 6),
            pattern.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            pattern.topAnchor.constraint(equalTo: measures.bottomAnchor, constant: 6),
            pattern.widthAnchor.constraint(equalToConstant: 220),
            bound.leadingAnchor.constraint(equalTo: pattern.trailingAnchor, constant: gap),
            bound.centerYAnchor.constraint(equalTo: pattern.centerYAnchor),
            limit.leadingAnchor.constraint(equalTo: bound.trailingAnchor, constant: gap),
            limit.centerYAnchor.constraint(equalTo: pattern.centerYAnchor),
            limit.widthAnchor.constraint(equalToConstant: 64),
            unit.leadingAnchor.constraint(equalTo: limit.trailingAnchor, constant: gap),
            unit.centerYAnchor.constraint(equalTo: pattern.centerYAnchor),
            unit.widthAnchor.constraint(equalToConstant: 48),
            unit.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        measuresChanged()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func measuresChanged() {
        let shows = measures.state == .on
        for view in [pattern, bound, limit, unit] as [NSView] { view.isHidden = !shows }
        withMetric.isActive = shows
        withoutMetric.isActive = !shows
    }

    @objc private func removeTapped() { onRemove?() }

    var item: ExpertGuard? {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let line = command.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || !line.isEmpty else { return nil }
        var metric: ExpertGuardMetric?
        if measures.state == .on, !pattern.stringValue.isEmpty {
            let value = Double(limit.stringValue.replacingOccurrences(of: ",", with: "."))
            metric = ExpertGuardMetric(
                pattern: pattern.stringValue, atMost: bound.indexOfSelectedItem == 0 ? value : nil,
                atLeast: bound.indexOfSelectedItem == 1 ? value : nil, unit: unit.stringValue.isEmpty ? nil : unit.stringValue)
        }
        return ExpertGuard(id: id, name: name.isEmpty ? line : name, command: line, metric: metric)
    }
}

/// One line of the form: its label at a fixed width, right-aligned, and the control beside it,
/// centred on each other; a control that hugs its width keeps it, any other runs to the edge.
@MainActor
final class ExpertFormRow: NSView {
    init(label: NSTextField, content: NSView, hugs: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .right
        for view in [label, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: 128),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            content.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: MacTheme.Spacing.m),
            hugs
                ? content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
                : content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        name(content, label.stringValue)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The words beside the row name every field and menu in it that has no name of its own, so
    /// VoiceOver says what a sighted person reads next to it.
    private func name(_ view: NSView, _ words: String) {
        if let stack = view as? NSStackView {
            for child in stack.arrangedSubviews { name(child, words) }
            return
        }
        let names = (view as? NSTextField)?.isEditable == true || view is NSPopUpButton || view is NSDatePicker
        guard names, (view.accessibilityLabel() ?? "").isEmpty else { return }
        view.setAccessibilityLabel(words)
    }
}

import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// Making or changing an expert on one short page: its mark, name and what it is for, the folder
/// it works in, and under them every other part as one line that says what it holds. The part
/// picked in that list is edited beside it: the charter, the skills, the notebook, a draft's first
/// notes, the bench, the guards and when they run, the model. A new expert that holds nothing yet
/// can be drafted from one of the machine's skills, over whatever was already typed. Saved to the
/// machine in one press; what the machine refuses is said under the form in the machine's own
/// words, and nothing is lost by it.
@MainActor
final class ExpertEditorSheet: NSObject, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var active: [ExpertEditorSheet] = []
    private static let rowHeight: CGFloat = 40

    let sheet: NSWindow
    private var profile: ConnectionProfile
    private let editing: MachineExpert?
    private let name = NSTextField()
    private let glyph = NSTextField()
    private var hue: ExpertHue
    private var hueIsChosen: Bool
    private let swatches = NSStackView()
    private let markButton: ExpertMarkButton
    private let markPopover = NSPopover()
    private let purpose = NSTextField()
    private let folder = NSTextField()
    private let machine = NSPopUpButton()
    private let outline = NSTableView()
    private var outlineHeight: NSLayoutConstraint!
    private var rows: [ExpertOutline.Row] = []
    private var chosenPart = ExpertOutline.Part.charter
    private var pages: [ExpertOutline.Part: NSView] = [:]
    private let model = NSPopUpButton()
    private let effort = NSPopUpButton()
    private let notebookChoice = NSPopUpButton()
    private let notebookPath = NSTextField()
    private let charter = NSTextView()
    private let charterCount = NSTextField(labelWithString: "")
    private let skillsBox = NSStackView()
    private var skillChecks: [NSButton] = []
    private var foundSkills: [ExpertSkill]?
    private let notesBox = NSStackView()
    private var noteChecks: [(note: ExpertDraftNote, check: NSButton)] = []
    private var notes: [ExpertDraftNote]
    private let benchList = NSStackView()
    private var benchRows: [ExpertBenchEditorRow] = []
    private let guardList = NSStackView()
    private var guardRows: [ExpertGuardEditorRow] = []
    private let ruleKind = NSPopUpButton()
    private let guardsNote = MacDialogs.detailLabel("", wraps: true)
    private let ruleTime = NSDatePicker()
    private let draftPull = NSPopUpButton(frame: .zero, pullsDown: true)
    private let draftSpinner = NSProgressIndicator()
    private let draftBlock = NSView()
    private let leftColumn = FillingStack(topDown: false)
    private var drafting = false
    private var reloading = false
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
    var outlineRows: [ExpertOutline.Row] { rows }
    var selectedPart: ExpertOutline.Part { chosenPart }
    var shownParts: [ExpertOutline.Part] { pages.filter { !$0.value.isHidden }.map(\.key) }
    var offersDraft: Bool { draftBlock.superview != nil }
    var draftChoices: [String] { draftPull.itemTitles.dropFirst().map { $0 } }
    var markView: ExpertMarkButton { markButton }
    var unnamedControls: [String] {
        let fields: [NSView] = [
            name, glyph, purpose, folder, machine, outline, model, effort, notebookChoice, notebookPath, charter, ruleKind,
            ruleTime, draftPull, markButton,
        ]
        return fields.filter { ($0.accessibilityLabel() ?? "").isEmpty }.map { String(describing: type(of: $0)) }
    }
    /// Whether the list of parts is all in view, with nothing of it to scroll to.
    var outlineFits: Bool {
        sheet.contentView?.layoutSubtreeIfNeeded()
        guard let scroll = outline.enclosingScrollView else { return false }
        return outline.frame.height <= scroll.contentView.bounds.height + 0.5
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
        self.onSaved = onSaved
        notes = editing == nil ? seed?.notes ?? [] : []
        hue = ExpertHue(editing?.hue ?? seed?.hue ?? "blue")
        hueIsChosen = editing != nil
        markButton = ExpertMarkButton(glyph: editing?.glyph ?? seed?.glyph ?? "Ex", hue: hue, side: 52)
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        sheet.contentMinSize = NSSize(width: 900, height: 540)
        super.init()
        sheet.title = editing == nil ? ExpertWords.newExpert : Localized.text("Edit %@", editing?.name ?? "")
        build()
        fill(editing.map(Self.draft(of:)) ?? seed ?? ExpertDraft(name: ""))
        loadSkills()
    }

    /// An expert as the form holds one, so an expert being changed and a draft fill it the same way.
    private static func draft(of expert: MachineExpert) -> ExpertDraft {
        ExpertDraft(
            name: expert.name, glyph: expert.glyph, hue: expert.hue, purpose: expert.purpose, directory: expert.directory,
            model: expert.model, effort: expert.effort, charter: expert.charter, skills: expert.skills,
            notebookPath: expert.notebookPath, bench: expert.bench, guards: expert.guards, guardRule: expert.guardRule)
    }

    private func build() {
        buildIdentity()
        buildParts()
        let left = buildLeft()
        let detail = NSView()
        detail.translatesAutoresizingMaskIntoConstraints = false
        for part in ExpertOutline.Part.allCases {
            guard let page = pages[part] else { continue }
            page.translatesAutoresizingMaskIntoConstraints = false
            page.isHidden = true
            detail.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
                page.topAnchor.constraint(equalTo: detail.topAnchor),
                page.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
            ])
        }
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

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
        var footerViews: [NSView] = []
        if editing != nil {
            let delete = NSButton(title: ExpertWords.delete, target: self, action: #selector(deleteTapped))
            delete.bezelStyle = .push
            delete.hasDestructiveAction = true
            footerViews.append(delete)
        }
        footerViews += [spinner, failure, expertSpacer(), cancel, saveButton]
        let footer = NSStackView(views: footerViews)
        footer.orientation = .horizontal
        footer.spacing = MacTheme.Spacing.s
        failure.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        expertHug(footer)
        footer.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        for view in [left, divider, detail, footer] as [NSView] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            left.topAnchor.constraint(equalTo: root.topAnchor),
            left.widthAnchor.constraint(equalToConstant: 310),
            left.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            divider.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            divider.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),
            detail.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detail.topAnchor.constraint(equalTo: root.topAnchor),
            detail.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        sheet.contentView = root
    }

    private func buildIdentity() {
        name.placeholderString = ExpertWords.name
        name.font = MacTheme.Ramp.font(.panelTitle)
        name.setAccessibilityLabel(ExpertWords.name)
        name.delegate = self
        purpose.placeholderString = ExpertWords.purpose
        purpose.setAccessibilityLabel(ExpertWords.purpose)
        purpose.delegate = self
        folder.placeholderString = ExpertWords.folderPlaceholder
        folder.setAccessibilityLabel(ExpertWords.folder)
        folder.font = MacTheme.Ramp.font(.code)
        folder.delegate = self
        machine.setAccessibilityLabel(Localized.text("Machine"))
        machine.target = self
        machine.action = #selector(machineChanged)
        glyph.placeholderString = "Ex"
        glyph.setAccessibilityLabel(ExpertWords.letters)
        glyph.widthAnchor.constraint(equalToConstant: 56).isActive = true
        glyph.delegate = self
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
        let lettersLabel = NSTextField(labelWithString: ExpertWords.letters)
        lettersLabel.font = MacTheme.Ramp.font(.panelLabel)
        lettersLabel.textColor = MacTheme.Color.secondaryLabel
        let lettersLine = NSStackView(views: [lettersLabel, glyph])
        lettersLine.orientation = .horizontal
        lettersLine.spacing = MacTheme.Spacing.s
        let column = NSStackView(views: [swatches, lettersLine])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        let content = NSViewController()
        content.view = column
        markPopover.contentViewController = content
        markPopover.behavior = .transient
        markButton.setAccessibilityLabel(ExpertWords.markAndColour)
        markButton.toolTip = ExpertWords.markAndColour
        markButton.target = self
        markButton.action = #selector(markPressed)
    }

    private func buildLeft() -> NSView {
        let identity = NSView()
        identity.translatesAutoresizingMaskIntoConstraints = false
        for view in [markButton, name, purpose] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            identity.addSubview(view)
        }
        NSLayoutConstraint.activate([
            markButton.leadingAnchor.constraint(equalTo: identity.leadingAnchor),
            markButton.centerYAnchor.constraint(equalTo: identity.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: markButton.trailingAnchor, constant: MacTheme.Spacing.m),
            name.trailingAnchor.constraint(equalTo: identity.trailingAnchor),
            name.topAnchor.constraint(equalTo: identity.topAnchor),
            purpose.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            purpose.trailingAnchor.constraint(equalTo: identity.trailingAnchor),
            purpose.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 6),
            purpose.bottomAnchor.constraint(equalTo: identity.bottomAnchor),
        ])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("part"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.headerView = nil
        outline.style = .inset
        outline.rowHeight = Self.rowHeight
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.backgroundColor = .clear
        outline.allowsEmptySelection = false
        outline.allowsMultipleSelection = false
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel(Localized.text("Details"))
        let outlineScroll = NSScrollView()
        outlineScroll.documentView = outline
        outlineScroll.drawsBackground = false
        outlineScroll.hasVerticalScroller = false
        outlineScroll.verticalScrollElasticity = .none
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        outlineHeight = outlineScroll.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        outlineHeight.isActive = true

        draftPull.setAccessibilityLabel(ExpertWords.draftFromSkill)
        draftPull.bezelStyle = .push
        draftPull.target = self
        draftPull.action = #selector(draftChosen(_:))
        draftSpinner.style = .spinning
        draftSpinner.controlSize = .small
        draftSpinner.isDisplayedWhenStopped = false
        let draftWords = MacDialogs.detailLabel(ExpertWords.draftFromSkillDetail, wraps: true)
        draftWords.preferredMaxLayoutWidth = 266
        draftBlock.translatesAutoresizingMaskIntoConstraints = false
        for view in [draftPull, draftSpinner, draftWords] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            draftBlock.addSubview(view)
        }
        draftPull.setContentHuggingPriority(.required, for: .horizontal)
        draftWords.setContentHuggingPriority(.required, for: .vertical)
        draftWords.setContentCompressionResistancePriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            draftPull.leadingAnchor.constraint(equalTo: draftBlock.leadingAnchor),
            draftPull.topAnchor.constraint(equalTo: draftBlock.topAnchor),
            draftSpinner.leadingAnchor.constraint(equalTo: draftPull.trailingAnchor, constant: MacTheme.Spacing.s),
            draftSpinner.centerYAnchor.constraint(equalTo: draftPull.centerYAnchor),
            draftSpinner.trailingAnchor.constraint(lessThanOrEqualTo: draftBlock.trailingAnchor),
            draftWords.leadingAnchor.constraint(equalTo: draftBlock.leadingAnchor),
            draftWords.trailingAnchor.constraint(equalTo: draftBlock.trailingAnchor),
            draftWords.topAnchor.constraint(equalTo: draftPull.bottomAnchor, constant: 6),
            draftWords.bottomAnchor.constraint(equalTo: draftBlock.bottomAnchor),
        ])

        let gap = NSView()
        gap.translatesAutoresizingMaskIntoConstraints = false
        gap.setContentHuggingPriority(.init(1), for: .vertical)
        gap.setContentCompressionResistancePriority(.init(1), for: .vertical)
        let left = leftColumn
        left.distribution = .fill
        left.spacing = MacTheme.Spacing.m
        left.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 4, right: 22)
        for view in [identity, folder, machine, outlineScroll, gap] as [NSView] { left.addArrangedSubview(view) }
        left.setCustomSpacing(MacTheme.Spacing.s, after: folder)
        fillMachines()
        return left
    }

    private func fillMachines() {
        let makers = ExpertDesk.shared.makers
        machine.removeAllItems()
        for maker in makers {
            machine.addItem(withTitle: maker.name)
            machine.lastItem?.representedObject = maker.id
        }
        if let index = makers.firstIndex(where: { $0.id == profile.id }) { machine.selectItem(at: index) }
        machine.isHidden = editing != nil || makers.count < 2 || !makers.contains { $0.id == profile.id }
    }

    private func buildParts() {
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
        charterScroll.translatesAutoresizingMaskIntoConstraints = false
        charterScroll.setContentHuggingPriority(.init(1), for: .vertical)
        charterScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        charterCount.font = MacTheme.Ramp.font(.panelFootnote)
        charterCount.textColor = MacTheme.Color.tertiaryLabel
        let charterNote = MacDialogs.detailLabel(
            Localized.text("Standing instructions for this kind of work: a map, not a manual."))
        charterNote.lineBreakMode = .byTruncatingTail
        charterNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        charterCount.setContentHuggingPriority(.required, for: .horizontal)
        charterCount.setContentCompressionResistancePriority(.required, for: .horizontal)
        let charterFoot = line([charterNote], trailing: [charterCount])
        pages[.charter] = page(ExpertWords.charter, [charterScroll, charterFoot], note: nil)

        for list in [skillsBox, notesBox] {
            list.orientation = .vertical
            list.alignment = list === notesBox ? .width : .leading
            list.spacing = 6
        }
        pages[.skills] = page(
            ExpertWords.skills, [scrolled(skillsBox)], note: Localized.text("Every task loads these first."))
        pages[.notes] = page(ExpertWords.firstNotes, [scrolled(notesBox)], note: nil)

        notebookPath.placeholderString = Localized.text("A memory folder on %@", profile.name)
        notebookPath.setAccessibilityLabel(ExpertWords.notebookFolder)
        notebookPath.font = MacTheme.Ramp.font(.code)
        notebookPath.delegate = self
        notebookChoice.addItems(withTitles: [ExpertWords.notebookOwn, Localized.text("Adopt a folder")])
        notebookChoice.setAccessibilityLabel(ExpertWords.notebook)
        notebookChoice.target = self
        notebookChoice.action = #selector(notebookChanged)
        pages[.notebook] = page(
            ExpertWords.notebook, [leading(notebookChoice), notebookPath, filler()],
            note: Localized.text(
                "A folder you already keep is adopted as it is: one fact per file, indexed in MEMORY.md. Notes are only written when you accept them."))

        for list in [benchList, guardList] {
            list.orientation = .vertical
            list.alignment = .width
            list.spacing = MacTheme.Spacing.s
        }
        let addBench = NSButton(title: ExpertWords.addBenchItem, target: self, action: #selector(addBenchRow))
        let addGuard = NSButton(title: ExpertWords.addGuard, target: self, action: #selector(addGuardRow))
        for button in [addBench, addGuard] {
            button.bezelStyle = .accessoryBarAction
            button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
        }
        pages[.bench] = page(
            ExpertWords.bench, [scrolled(benchList), leading(addBench)],
            note: Localized.text(
                "The machine proves it whenever the expert's page opens and when a task starts. A task holds the lock around anything it installs or runs there, so two tasks never share a device."))

        ruleKind.addItems(withTitles: [ExpertWords.guardsOnDemand, Localized.text("Every day at"), Localized.text("Weekdays at")])
        ruleKind.target = self
        ruleKind.action = #selector(ruleChanged)
        ruleKind.setAccessibilityLabel(Localized.text("When"))
        ruleTime.setAccessibilityLabel(Localized.text("Time"))
        ruleTime.datePickerStyle = .textFieldAndStepper
        ruleTime.datePickerElements = .hourMinute
        ruleTime.target = self
        ruleTime.action = #selector(ruleChanged)
        ruleTime.dateValue = Calendar.current.date(bySettingHour: 3, minute: 0, second: 0, of: Date()) ?? Date()
        ruleKind.setContentHuggingPriority(.required, for: .horizontal)
        ruleTime.setContentHuggingPriority(.required, for: .horizontal)
        let ruleLine = line([addGuard], trailing: [ruleKind, ruleTime])
        guardsNote.stringValue = ExpertWords.noGuards
        guardsNote.preferredMaxLayoutWidth = 520
        pages[.guards] = page(ExpertWords.guards, [scrolled(guardList), ruleLine, guardsNote], note: nil)

        model.setAccessibilityLabel(ExpertWords.model)
        model.target = self
        model.action = #selector(partChanged)
        effort.setAccessibilityLabel(Localized.text("Effort"))
        effort.target = self
        effort.action = #selector(partChanged)
        effort.addItem(withTitle: Localized.text("Machine default"))
        effort.lastItem?.representedObject = ""
        for level in ["low", "medium", "high", "xhigh", "max"] {
            effort.addItem(withTitle: level)
            effort.lastItem?.representedObject = level
        }
        fillModels()
        pages[.model] = page(ExpertWords.model, [line([model, effort], trailing: []), filler()], note: nil)
    }

    private func fillModels() {
        model.removeAllItems()
        model.addItem(withTitle: Localized.text("Machine default"))
        model.lastItem?.representedObject = ""
        for info in ModelCatalogStore.cached(profile.id) where !info.id.contains("/") {
            model.addItem(withTitle: info.name.isEmpty ? info.id : info.name)
            model.lastItem?.representedObject = info.id
        }
    }

    /// One part's editor: its name, what edits it, and a line on what it is for.
    private func page(_ title: String, _ views: [NSView], note: String?) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = MacTheme.Ramp.font(.cardTitle)
        let column = FillingStack(topDown: false)
        column.distribution = .fill
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 10, right: 22)
        column.addArrangedSubview(heading)
        for view in views { column.addArrangedSubview(view) }
        if let note {
            let words = MacDialogs.detailLabel(note, wraps: true)
            words.preferredMaxLayoutWidth = 520
            column.addArrangedSubview(words)
        }
        return column
    }

    /// A list that scrolls inside its part once it is longer than the sheet, so the sheet itself
    /// never has to.
    private func scrolled(_ list: NSStackView) -> NSScrollView {
        let scroll = NSScrollView()
        let clip = ExpertFlippedClip()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        list.translatesAutoresizingMaskIntoConstraints = false
        expertHug(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            list.topAnchor.constraint(equalTo: clip.topAnchor),
            list.widthAnchor.constraint(equalTo: clip.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        return scroll
    }

    private func leading(_ view: NSView) -> NSView { line([view], trailing: []) }

    /// One line of a part, as tall as the first thing on it: some of it from the leading edge,
    /// the rest from the trailing one, and whatever room is left between the two.
    private func line(_ leading: [NSView], trailing: [NSView]) -> NSView {
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        let gap = MacTheme.Spacing.s
        var constraints: [NSLayoutConstraint] = []
        for view in leading + trailing {
            view.translatesAutoresizingMaskIntoConstraints = false
            line.addSubview(view)
            constraints.append(view.centerYAnchor.constraint(equalTo: line.centerYAnchor))
        }
        if let first = (leading + trailing).first {
            constraints.append(first.topAnchor.constraint(equalTo: line.topAnchor))
            constraints.append(first.bottomAnchor.constraint(equalTo: line.bottomAnchor))
        }
        var edge = line.leadingAnchor
        for (index, view) in leading.enumerated() {
            constraints.append(view.leadingAnchor.constraint(equalTo: edge, constant: index == 0 ? 0 : gap))
            edge = view.trailingAnchor
        }
        var far = line.trailingAnchor
        for (index, view) in trailing.reversed().enumerated() {
            constraints.append(view.trailingAnchor.constraint(equalTo: far, constant: index == 0 ? 0 : -gap))
            far = view.leadingAnchor
        }
        constraints.append(edge.constraint(lessThanOrEqualTo: far, constant: leading.isEmpty || trailing.isEmpty ? 0 : -gap))
        NSLayoutConstraint.activate(constraints)
        return line
    }

    private func filler() -> NSView {
        let gap = NSView()
        gap.translatesAutoresizingMaskIntoConstraints = false
        gap.setContentHuggingPriority(.init(1), for: .vertical)
        gap.setContentCompressionResistancePriority(.init(1), for: .vertical)
        return gap
    }

    private func fill(_ draft: ExpertDraft) {
        name.stringValue = draft.name
        glyph.stringValue = draft.glyph ?? ""
        purpose.stringValue = draft.purpose ?? ""
        folder.stringValue = draft.directory ?? ""
        charter.string = draft.charter ?? ""
        if let chosen = draft.hue { hue = ExpertHue(chosen) }
        let chosenModel = draft.model ?? ""
        if let index = model.itemArray.firstIndex(where: { ($0.representedObject as? String) == chosenModel }) {
            model.selectItem(at: index)
        } else if !chosenModel.isEmpty {
            model.addItem(withTitle: chosenModel)
            model.lastItem?.representedObject = chosenModel
            model.select(model.lastItem)
        }
        let chosenEffort = draft.effort ?? ""
        effort.selectItem(at: effort.itemArray.firstIndex { ($0.representedObject as? String) == chosenEffort } ?? 0)
        notebookChoice.selectItem(at: draft.notebookPath == nil ? 0 : 1)
        notebookPath.stringValue = draft.notebookPath ?? ""
        notebookPath.isEnabled = draft.notebookPath != nil
        for row in benchRows { row.removeFromSuperview() }
        benchRows = []
        for item in draft.bench ?? [] { appendBench(item) }
        for row in guardRows { row.removeFromSuperview() }
        guardRows = []
        for item in draft.guards ?? [] { appendGuard(item) }
        switch draft.guardRule?.kind {
        case .daily: ruleKind.selectItem(at: 1)
        case .weekdays: ruleKind.selectItem(at: 2)
        default: ruleKind.selectItem(at: 0)
        }
        if let rule = draft.guardRule, let hour = rule.hour {
            ruleTime.dateValue =
                Calendar.current.date(bySettingHour: hour, minute: rule.minute ?? 0, second: 0, of: Date()) ?? Date()
        }
        ruleTime.isEnabled = ruleKind.indexOfSelectedItem != 0
        showNotes(ticked: ExpertMaking.defaultTicks(draft))
        showSkills(chosen: draft.skills ?? [])
        refreshMark()
        refreshCount()
        for swatch in swatchViews { swatch.chosen = swatch.hue == hue }
        refreshOutline()
    }

    private func showNotes(ticked: Set<String>) {
        notesBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        noteChecks = []
        for note in notes {
            let check = NSButton(checkboxWithTitle: note.title, target: self, action: #selector(partChanged))
            check.state = ticked.contains(note.title) ? .on : .off
            check.toolTip = note.summary
            let words = NSTextField(labelWithString: note.lasting == false ? ExpertWords.lastingUnticked : note.summary)
            words.font = MacTheme.Ramp.font(.panelFootnote)
            words.textColor = note.lasting == false ? MacTheme.Color.warning : MacTheme.Color.secondaryLabel
            words.lineBreakMode = .byTruncatingTail
            words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let line = NSView()
            for view in [check, words] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                line.addSubview(view)
            }
            check.setContentHuggingPriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                check.leadingAnchor.constraint(equalTo: line.leadingAnchor),
                check.topAnchor.constraint(equalTo: line.topAnchor),
                check.bottomAnchor.constraint(equalTo: line.bottomAnchor),
                words.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: MacTheme.Spacing.s),
                words.firstBaselineAnchor.constraint(equalTo: check.firstBaselineAnchor),
                words.trailingAnchor.constraint(lessThanOrEqualTo: line.trailingAnchor),
            ])
            noteChecks.append((note, check))
            notesBox.addArrangedSubview(line)
        }
    }

    private func loadSkills() {
        foundSkills = nil
        showSkills(chosen: chosenSkills)
        guard let keeping = ExpertDesk.shared.keeping(for: profile.id) else {
            foundSkills = []
            showSkills(chosen: chosenSkills)
            return
        }
        let asked = profile.id
        Task { [weak self] in
            let found = (try? await keeping.expertSkills()) ?? []
            guard let self, self.profile.id == asked else { return }
            self.foundSkills = found
            self.showSkills(chosen: self.chosenSkills)
        }
    }

    private var chosenSkills: [String] { skillChecks.filter { $0.state == .on }.map(\.title) }

    /// The machine's skills as ticks, with any the expert already loads that the machine no longer
    /// lists, and the same skills as what a new expert can be drafted from.
    private func showSkills(chosen: [String]) {
        skillsBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        skillChecks = []
        var names = foundSkills?.map(\.name) ?? []
        for name in chosen where !names.contains(name) { names.append(name) }
        for name in names {
            let check = NSButton(checkboxWithTitle: name, target: self, action: #selector(partChanged))
            check.state = chosen.contains(name) ? .on : .off
            check.toolTip = foundSkills?.first { $0.name == name }?.description
            skillChecks.append(check)
            skillsBox.addArrangedSubview(check)
        }
        if foundSkills == nil || names.isEmpty {
            let words = foundSkills == nil
                ? Localized.text("Reading the machine's skills…") : Localized.text("No skills on %@", profile.name)
            let line = NSTextField(labelWithString: words)
            line.font = MacTheme.Ramp.font(.panelFootnote)
            line.textColor = MacTheme.Color.tertiaryLabel
            skillsBox.addArrangedSubview(line)
        }
        draftPull.removeAllItems()
        draftPull.addItem(withTitle: ExpertWords.draftFromSkill)
        for skill in foundSkills ?? [] {
            draftPull.addItem(withTitle: skill.name)
            draftPull.lastItem?.toolTip = skill.description
        }
        refreshOutline()
    }

    /// What the form holds now, as the draft it would send.
    private func current() -> ExpertDraft {
        let typedGlyph = glyph.stringValue.trimmingCharacters(in: .whitespaces)
        let modelID = (model.selectedItem?.representedObject as? String) ?? ""
        let effortLevel = (effort.selectedItem?.representedObject as? String) ?? ""
        let adopted = notebookChoice.indexOfSelectedItem == 1 ? notebookPath.stringValue.trimmingCharacters(in: .whitespaces) : ""
        return ExpertDraft(
            name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            glyph: typedGlyph.isEmpty ? nil : String(typedGlyph.prefix(2)), hue: hue.rawValue, purpose: purpose.stringValue,
            directory: folder.stringValue.isEmpty ? nil : folder.stringValue, model: modelID.isEmpty ? nil : modelID,
            effort: effortLevel.isEmpty ? nil : effortLevel, charter: charter.string, skills: chosenSkills,
            notebookPath: adopted.isEmpty ? nil : adopted, bench: benchRows.compactMap(\.item),
            guards: guardRows.compactMap(\.item), guardRule: rule, timeZone: TimeZone.current.identifier, notes: notes)
    }

    private var tickedNotes: Set<String> { Set(noteChecks.filter { $0.check.state == .on }.map(\.note.title)) }

    /// The list of parts said again from what the form holds, the part being edited kept chosen,
    /// and the offer to draft withdrawn once there is something a draft would write over.
    private func refreshOutline() {
        guard outlineHeight != nil else { return }
        let draft = current()
        let modelID = (model.selectedItem?.representedObject as? String) ?? ""
        rows = ExpertOutline.rows(draft, kept: tickedNotes.count, modelName: modelID.isEmpty ? nil : model.titleOfSelectedItem)
        if !rows.contains(where: { $0.part == chosenPart }) { chosenPart = .charter }
        guardsNote.isHidden = !guardRows.isEmpty
        reloading = true
        defer { reloading = false }
        outline.reloadData()
        outlineHeight.constant = rows.isEmpty ? Self.rowHeight : outline.rect(ofRow: rows.count - 1).maxY + 10
        if let index = rows.firstIndex(where: { $0.part == chosenPart }) {
            outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        for (part, page) in pages { page.isHidden = part != chosenPart }
        let offers = editing == nil && (drafting || ExpertOutline.canDraft(draft))
        if offers, draftBlock.superview == nil {
            leftColumn.addArrangedSubview(draftBlock)
        } else if !offers, draftBlock.superview != nil {
            leftColumn.removeArrangedSubview(draftBlock)
            draftBlock.removeFromSuperview()
        }
        draftPull.isEnabled = !drafting && draftPull.numberOfItems > 1
    }

    /// Shows one part's editor, for a press in the list or a harness.
    func select(_ part: ExpertOutline.Part) {
        guard rows.contains(where: { $0.part == part }) else { return }
        chosenPart = part
        refreshOutline()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("part")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ExpertOutlineCell ?? ExpertOutlineCell()
        cell.identifier = id
        cell.show(rows[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, rows.indices.contains(outline.selectedRow), rows[outline.selectedRow].part != chosenPart
        else { return }
        chosenPart = rows[outline.selectedRow].part
        for (part, page) in pages { page.isHidden = part != chosenPart }
    }

    @objc private func partChanged() { refreshOutline() }

    @objc private func markPressed() {
        markPopover.show(relativeTo: markButton.bounds, of: markButton, preferredEdge: .maxY)
        markPopover.contentViewController?.view.window?.makeFirstResponder(glyph)
    }

    @objc private func hueChosen(_ sender: ExpertSwatch) {
        hue = sender.hue
        hueIsChosen = true
        for swatch in swatchViews { swatch.chosen = swatch.hue == hue }
        refreshMark()
    }

    private func refreshMark() {
        let typed = glyph.stringValue.trimmingCharacters(in: .whitespaces)
        markButton.mark.glyph = typed.isEmpty ? ExpertMaking.glyph(for: name.stringValue) : String(typed.prefix(2))
        markButton.mark.hue = hue
    }

    @objc private func notebookChanged() {
        notebookPath.isEnabled = notebookChoice.indexOfSelectedItem == 1
        if notebookPath.isEnabled { sheet.makeFirstResponder(notebookPath) }
        refreshOutline()
    }

    @objc private func ruleChanged() {
        ruleTime.isEnabled = ruleKind.indexOfSelectedItem != 0
        refreshOutline()
    }

    /// Another machine for a new expert: what was the old machine's (its folder, notebook, skills,
    /// bench, guards and model) is let go, and what is the expert's own stays.
    @objc private func machineChanged() {
        guard let id = machine.selectedItem?.representedObject as? String, id != profile.id,
            let chosen = ExpertDesk.shared.profile(id)
        else { return }
        profile = chosen
        var kept = current()
        kept.directory = nil
        kept.notebookPath = nil
        kept.skills = []
        kept.bench = []
        kept.guards = []
        kept.guardRule = nil
        kept.model = nil
        notebookPath.placeholderString = Localized.text("A memory folder on %@", profile.name)
        fillModels()
        let ticked = tickedNotes
        fill(kept)
        showNotes(ticked: ticked)
        loadSkills()
    }

    @objc private func draftChosen(_ sender: NSPopUpButton) {
        guard !drafting, sender.indexOfSelectedItem > 0, let skill = sender.titleOfSelectedItem,
            let keeping = ExpertDesk.shared.keeping(for: profile.id)
        else { return }
        draft(from: skill, keeping: keeping)
    }

    /// Asks the machine to draft the expert from one of its skills and lays the draft over what
    /// was typed. A harness awaits the task it returns.
    @discardableResult
    func draft(from skill: String, keeping: any MachineExperts) -> Task<Void, Never> {
        drafting = true
        draftSpinner.startAnimation(nil)
        failure.isHidden = true
        refreshOutline()
        let asked = profile.id
        return Task { [weak self] in
            let outcome: Result<ExpertDraft, Error>
            do { outcome = .success(try await keeping.draftExpert(session: nil, skill: skill)) } catch { outcome = .failure(error) }
            guard let self else { return }
            self.drafting = false
            self.draftSpinner.stopAnimation(nil)
            switch outcome {
            case .success(let drafted) where self.profile.id == asked:
                var typed = self.current()
                if !self.hueIsChosen { typed.hue = nil }
                let merged = ExpertOutline.merged(drafted, over: typed)
                self.notes = merged.notes ?? []
                self.fill(merged)
            case .success:
                self.refreshOutline()
            case .failure(let error):
                self.show(AgentErrorText.readable(error))
                self.refreshOutline()
            }
        }
    }

    func textDidChange(_ notification: Notification) {
        refreshCount()
        refreshOutline()
    }

    private func refreshCount() {
        let count = charter.string.count
        charterCount.stringValue =
            count > 6_000
            ? Localized.text("%d of 6000 characters: a map, not a manual", count)
            : ExpertOutline.wordCount(ExpertOutline.words(charter.string))
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
            self.refreshOutline()
        }
        row.onChange = { [weak self] in self?.refreshOutline() }
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
            self.refreshOutline()
        }
        row.onChange = { [weak self] in self?.refreshOutline() }
        guardRows.append(row)
        guardList.addArrangedSubview(row)
    }

    @objc private func cancelTapped() {
        guard !saving else { return }
        sheet.sheetParent?.endSheet(sheet)
    }

    @objc private func deleteTapped() {
        guard !saving, let editing, let keeping = ExpertDesk.shared.keeping(for: profile.id) else { return }
        let profileID = profile.id
        MacDialogs.confirm(
            on: sheet, title: Localized.text("Delete %@?", editing.name), body: ExpertWords.deleteDetail,
            confirmLabel: ExpertWords.delete
        ) { [weak self] in
            Task { [weak self] in
                do {
                    try await keeping.deleteExpert(editing.id)
                    ExpertDesk.shared.forget(profileID: profileID, expertID: editing.id)
                    guard let self else { return }
                    self.sheet.sheetParent?.endSheet(self.sheet)
                    await ExpertDesk.shared.refresh()
                } catch {
                    self?.show(AgentErrorText.readable(error))
                }
            }
        }
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
        guard !saving, !drafting, let keeping = ExpertDesk.shared.keeping(for: profile.id) else { return }
        let held = current()
        guard !held.name.isEmpty else {
            show(Localized.text("An expert needs a name."))
            sheet.makeFirstResponder(name)
            return
        }
        saving = true
        spinner.startAnimation(nil)
        saveButton.isEnabled = false
        failure.isHidden = true
        let profileID = profile.id
        let editing = self.editing
        let draft = ExpertMaking.finalized(held, keeping: tickedNotes)
        Task { [weak self] in
            do {
                let saved: MachineExpert
                if let editing {
                    saved = try await keeping.updateExpert(
                        editing.id,
                        ExpertChange(
                            name: held.name, glyph: held.glyph ?? ExpertMaking.glyph(for: held.name),
                            hue: held.hue, purpose: held.purpose ?? "", directory: held.directory ?? "",
                            model: held.model ?? "", effort: held.effort ?? "", charter: held.charter ?? "",
                            skills: held.skills ?? [], notebookPath: held.notebookPath ?? "", bench: held.bench ?? [],
                            guards: held.guards ?? [], guardRule: held.guardRule,
                            guardsOnDemand: held.guardRule == nil ? true : nil, timeZone: TimeZone.current.identifier))
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
        refreshOutline()
    }
}

extension ExpertEditorSheet: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        refreshMark()
        refreshOutline()
    }
}

/// The expert's mark as the press that changes it: its colour and its two letters open beside it.
@MainActor
final class ExpertMarkButton: NSControl {
    let mark: ExpertMarkView
    private let side: CGFloat

    init(glyph: String, hue: ExpertHue, side: CGFloat) {
        mark = ExpertMarkView(glyph: glyph, hue: hue, side: side)
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(mark)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side), heightAnchor.constraint(equalToConstant: side),
            mark.centerXAnchor.constraint(equalTo: centerXAnchor), mark.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: side * 0.24, yRadius: side * 0.24).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) { sendAction(action, to: target) }

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
}

/// One part of an expert in the editor's list: its name over the line that says what it holds,
/// quieter while it holds nothing of the person's own.
@MainActor
final class ExpertOutlineCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        title.font = MacTheme.Ramp.font(.rowTitle)
        title.textColor = .labelColor
        value.font = MacTheme.Ramp.font(.panelFootnote)
        value.lineBreakMode = .byTruncatingMiddle
        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        for view in [title, value, chevron] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -6),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            value.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            value.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -6),
            value.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = title
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ row: ExpertOutline.Row) {
        title.stringValue = row.title
        value.stringValue = row.value
        value.textColor = row.isSet ? .secondaryLabelColor : .tertiaryLabelColor
        setAccessibilityLabel("\(row.title), \(row.value)")
    }
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
final class ExpertBenchEditorRow: NSView, NSTextFieldDelegate {
    private let id: String
    let nameField = NSTextField()
    private let kind = NSPopUpButton()
    private let target = NSTextField()
    private let lock = NSTextField()
    private let remove = NSButton()
    private let machine: String
    var onRemove: (() -> Void)?
    var onChange: (() -> Void)?

    func controlTextDidChange(_ obj: Notification) { onChange?() }

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
        nameField.setAccessibilityLabel(ExpertWords.name)
        lock.setAccessibilityLabel(Localized.text("Lock file (optional)"))
        nameField.delegate = self
        target.delegate = self
        for view in [kind, nameField, target, lock, remove] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let gap = MacTheme.Spacing.s
        NSLayoutConstraint.activate([
            kind.leadingAnchor.constraint(equalTo: leadingAnchor),
            kind.widthAnchor.constraint(equalToConstant: 118),
            kind.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: kind.trailingAnchor, constant: gap),
            nameField.widthAnchor.constraint(equalToConstant: 112),
            nameField.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            nameField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            target.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: gap),
            target.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            target.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            lock.leadingAnchor.constraint(equalTo: target.trailingAnchor, constant: gap),
            lock.widthAnchor.constraint(equalToConstant: 128),
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
        target.setAccessibilityLabel(target.placeholderString)
        onChange?()
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
final class ExpertGuardEditorRow: NSView, NSTextFieldDelegate {
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
    var onChange: (() -> Void)?

    func controlTextDidChange(_ obj: Notification) { onChange?() }

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
        nameField.setAccessibilityLabel(ExpertWords.name)
        command.setAccessibilityLabel(Localized.text("Command"))
        pattern.setAccessibilityLabel(Localized.text("Pattern"))
        limit.setAccessibilityLabel(Localized.text("At most"))
        unit.setAccessibilityLabel(Localized.text("Unit"))
        nameField.delegate = self
        command.delegate = self
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
            nameField.widthAnchor.constraint(equalToConstant: 150),
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

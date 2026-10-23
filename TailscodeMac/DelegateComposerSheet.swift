import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// The packet form as a sheet over the delegate window. It asks first for what only the person
/// knows — the goal, the repository (one click from where this machine's chats and runs work), the
/// paths, and whether the patch waits to be read — and folds everything the class already decides
/// into one Plan line that opens on demand. `DelegateDraft` decides every word and every rule.
@MainActor
final class DelegateComposerSheet: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
    /// Every composer on screen, each kept alive by this list until its sheet ends. One slot held
    /// only the newest, so a second composer queued behind the first left the first one with
    /// nothing keeping it.
    private static var active: [DelegateComposerSheet] = []

    private let sheet: NSWindow
    private let host: String
    private let serverName: String
    private let desk = MacDelegateGate.desk
    private var draft: DelegateDraft
    private let repoChoices: [DelegateRepoChoice]
    private let onStarted: (String) -> Void
    private let classPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let repoField = NSTextField()
    private let repoPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let goalView = NSTextView.scrollableTextView()
    private let pathsView = NSTextView.scrollableTextView()
    private let reviewSwitch = NSSwitch()
    private let planToggle = NSButton()
    private let planSummary = NSTextField(labelWithString: "")
    private let planBody = NSStackView()
    private let verifyField = NSTextField()
    private let suggestionRow = NSStackView()
    private let readField = NSTextField()
    private let notesView = NSTextView.scrollableTextView()
    private let ladder = MacLadderView()
    private let legendLabel = NSTextField(wrappingLabelWithString: "")
    private let modeControl = NSSegmentedControl(labels: DelegateMode.allCases.map(DelegateWords.mode), trackingMode: .selectOne, target: nil, action: nil)
    private let effortControl = NSSegmentedControl(labels: [DelegateComposerWords.effortDefault] + DelegateEffort.allCases.map(DelegateWords.effort), trackingMode: .selectOne, target: nil, action: nil)
    private let problems = NSTextField(wrappingLabelWithString: "")
    private let cautions = NSTextField(wrappingLabelWithString: "")
    private let sendButton = RowKit.ActionButton(title: DelegateComposerWords.sendTitle, action: {})
    private var sending = false

    static func present(
        on window: NSWindow, host: String, serverName: String, draft: DelegateDraft? = nil,
        repoChoices: [DelegateRepoChoice] = [], onStarted: @escaping (String) -> Void
    ) {
        let made = DelegateComposerSheet(host: host, serverName: serverName, draft: draft, repoChoices: repoChoices, onStarted: onStarted)
        active.append(made)
        window.beginSheet(made.sheet) { _ in Self.active.removeAll { $0 === made } }
        made.sheet.makeFirstResponder(made.goalView.documentView)
    }

    private var board: DelegateBoard { desk.board(host: host, serverName: serverName) }

    private init(host: String, serverName: String, draft: DelegateDraft?, repoChoices: [DelegateRepoChoice], onStarted: @escaping (String) -> Void) {
        self.host = host
        self.serverName = serverName
        self.onStarted = onStarted
        self.repoChoices = repoChoices
        let board = MacDelegateGate.desk.board(host: host, serverName: serverName)
        self.draft = draft ?? DelegateDraft(capabilities: board.capabilities, repo: repoChoices.first?.path ?? "")
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 680),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sheet.title = DelegateComposerWords.title
        sheet.isReleasedWhenClosed = false
        sheet.contentMinSize = NSSize(width: 540, height: 520)
        MacTheme.Chrome.adopt(sheet)
        super.init()
        sheet.contentView = makeContent(board: board)
        render()
    }

    private func textView(_ scroll: NSScrollView, height: CGFloat, mono: Bool = false) -> NSScrollView {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        scroll.borderType = .bezelBorder
        if let view = scroll.documentView as? NSTextView {
            view.font = MacTheme.Ramp.font(mono ? .code : .answer)
            view.delegate = self
            view.isRichText = false
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.textContainerInset = NSSize(width: 6, height: 6)
        }
        return scroll
    }

    private func labelled(_ title: String, _ view: NSView, help: String? = nil) -> NSStackView {
        let label = RowKit.label(title, font: MacTheme.Ramp.font(.rowTitleStrong), color: MacTheme.Color.label)
        var views: [NSView] = [label, view]
        if let help { views.append(MacDialogs.detailLabel(help, wraps: true)) }
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.xs
        for view in views.dropFirst() {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return column
    }

    private func makeContent(board: DelegateBoard) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.l
        column.edgeInsets = NSEdgeInsets(top: MacTheme.Spacing.l, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.l, right: MacTheme.Spacing.l)

        let heading = RowKit.label(DelegateComposerWords.title, font: MacTheme.Ramp.font(.panelTitle), color: MacTheme.Color.label)
        let machine = RowKit.label(serverName, font: MacTheme.Ramp.font(.panelDetail), color: MacTheme.Color.secondaryLabel)
        let titleRow = NSStackView(views: [heading, machine])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(titleRow)

        (goalView.documentView as? NSTextView)?.string = draft.goal
        column.addArrangedSubview(labelled(DelegateComposerWords.goalLabel, textView(goalView, height: 120), help: DelegateComposerWords.goalPlaceholder))

        repoField.stringValue = draft.repo
        repoField.placeholderString = DelegateComposerWords.repoPlaceholder
        repoField.font = MacTheme.Ramp.font(.code)
        repoField.delegate = self
        repoField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        repoField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var repoViews: [NSView] = [repoField]
        if !repoChoices.isEmpty {
            repoPopup.addItem(withTitle: DelegateComposerWords.repoChoicesLabel)
            for choice in repoChoices {
                let item = NSMenuItem(title: choice.name, action: nil, keyEquivalent: "")
                item.subtitle = choice.detail
                item.toolTip = choice.path
                item.representedObject = choice.path
                repoPopup.menu?.addItem(item)
            }
            repoPopup.target = self
            repoPopup.action = #selector(repoPicked)
            repoPopup.setContentHuggingPriority(.required, for: .horizontal)
            repoPopup.setContentCompressionResistancePriority(.required, for: .horizontal)
            repoViews.append(repoPopup)
        }
        let repoRow = NSStackView(views: repoViews)
        repoRow.orientation = .horizontal
        repoRow.distribution = .fill
        repoRow.alignment = .centerY
        repoRow.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(labelled(DelegateComposerWords.repoLabel, repoRow))

        (pathsView.documentView as? NSTextView)?.string = draft.paths
        column.addArrangedSubview(
            labelled(
                DelegateComposerWords.pathsLabel, textView(pathsView, height: 60, mono: true),
                help: DelegateComposerWords.pathsHelp + " " + DelegateComposerWords.pathsOptional))

        column.addArrangedSubview(reviewRow(board: board))
        column.addArrangedSubview(planHeader())
        buildPlanBody(board: board)
        column.addArrangedSubview(planBody)

        for view in column.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * MacTheme.Spacing.l).isActive = true
        }
        let scroll = MacDialogs.scrollColumn(holding: column)

        cautions.font = MacTheme.Ramp.font(.rowNote)
        cautions.textColor = MacTheme.Color.warning
        problems.font = MacTheme.Ramp.font(.rowNote)
        problems.textColor = MacTheme.Color.danger
        let cancel = RowKit.ActionButton(title: Localized.text("Cancel")) { [weak self] in self?.close() }
        cancel.keyEquivalent = "\u{1b}"
        sendButton.setAction { [weak self] in self?.send() }
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = .command
        sendButton.bezelColor = MacTheme.Color.accent
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        cancel.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, sendButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.distribution = .fill
        buttons.spacing = MacTheme.Spacing.s
        let footer = NSStackView(views: [cautions, problems, buttons])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = MacTheme.Spacing.xs
        footer.edgeInsets = NSEdgeInsets(top: MacTheme.Spacing.s, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.l, right: MacTheme.Spacing.l)
        footer.translatesAutoresizingMaskIntoConstraints = false
        for view in footer.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: footer.widthAnchor, constant: -2 * MacTheme.Spacing.l).isActive = true
        }
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scroll)
        root.addSubview(rule)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rule.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: rule.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    /// Whether the patch waits to be read: on by default wherever the dispatcher can hold one, and
    /// saying plainly where it cannot.
    private func reviewRow(board: DelegateBoard) -> NSView {
        let supported = board.supportsReview
        let title = RowKit.label(DelegateComposerWords.reviewLabel, font: MacTheme.Ramp.font(.rowTitleStrong), color: MacTheme.Color.label)
        let help = MacDialogs.detailLabel(
            supported ? DelegateComposerWords.reviewHelp : DelegateComposerWords.reviewUnsupported, wraps: true)
        let words = NSStackView(views: [title, help])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        help.widthAnchor.constraint(equalTo: words.widthAnchor).isActive = true
        words.setContentHuggingPriority(.defaultLow, for: .horizontal)
        reviewSwitch.state = supported && draft.review ? .on : .off
        reviewSwitch.isEnabled = supported
        reviewSwitch.target = self
        reviewSwitch.action = #selector(reviewChanged)
        reviewSwitch.setAccessibilityLabel(DelegateComposerWords.reviewLabel)
        reviewSwitch.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [words, reviewSwitch])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = MacTheme.Spacing.m
        return row
    }

    /// The Plan line: everything the class already decides, summed up in one line and opened on
    /// demand.
    private func planHeader() -> NSView {
        planToggle.bezelStyle = .disclosure
        planToggle.setButtonType(.pushOnPushOff)
        planToggle.title = ""
        planToggle.state = .off
        planToggle.target = self
        planToggle.action = #selector(planToggled)
        planToggle.setAccessibilityLabel(DelegateComposerWords.planLabel)
        planToggle.setContentHuggingPriority(.required, for: .horizontal)
        let title = RowKit.label(DelegateComposerWords.planLabel, font: MacTheme.Ramp.font(.rowTitleStrong), color: MacTheme.Color.label)
        planSummary.font = MacTheme.Ramp.font(.rowMeta)
        planSummary.textColor = MacTheme.Color.secondaryLabel
        planSummary.lineBreakMode = .byTruncatingTail
        planSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let words = NSStackView(views: [title, planSummary])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        words.setContentHuggingPriority(.defaultLow, for: .horizontal)
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [planToggle, words])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .top
        row.spacing = MacTheme.Spacing.xs
        row.toolTip = DelegateComposerWords.planHelp
        words.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(planHeaderClicked)))
        return row
    }

    private func buildPlanBody(board: DelegateBoard) {
        planBody.orientation = .vertical
        planBody.alignment = .leading
        planBody.spacing = MacTheme.Spacing.l
        planBody.edgeInsets = NSEdgeInsets(top: 0, left: MacTheme.Spacing.l, bottom: 0, right: 0)
        planBody.isHidden = true

        classPopup.addItems(withTitles: board.classes.isEmpty ? [draft.taskClass] : board.classes)
        classPopup.selectItem(withTitle: draft.taskClass)
        classPopup.target = self
        classPopup.action = #selector(classChanged)
        planBody.addArrangedSubview(labelled(DelegateComposerWords.classLabel, classPopup, help: DelegateComposerWords.classHelp))

        verifyField.stringValue = draft.verify
        verifyField.placeholderString = DelegateComposerWords.verifyPlaceholder
        verifyField.font = MacTheme.Ramp.font(.code)
        verifyField.delegate = self
        suggestionRow.orientation = .horizontal
        suggestionRow.spacing = MacTheme.Spacing.xs
        let verifyColumn = NSStackView(views: [verifyField, suggestionRow])
        verifyColumn.orientation = .vertical
        verifyColumn.alignment = .leading
        verifyColumn.spacing = MacTheme.Spacing.xs
        verifyField.widthAnchor.constraint(equalTo: verifyColumn.widthAnchor).isActive = true
        planBody.addArrangedSubview(labelled(DelegateComposerWords.verifyLabel, verifyColumn, help: DelegateComposerWords.verifyHelp))

        ladder.compose = true
        ladder.rungs = board.composerRungs(taskClass: draft.taskClass)
        ladder.set(start: draft.tier, ceiling: draft.ceiling)
        ladder.onChange = { [weak self] start, ceiling in
            self?.draft.tier = start
            self?.draft.ceiling = ceiling
            self?.render()
        }
        legendLabel.font = MacTheme.Ramp.font(.rowNote)
        legendLabel.textColor = MacTheme.Color.success
        let ladderBlock = labelled(DelegateComposerWords.ladderLabel, ladder, help: Localized.text("Click a rung to start there; shift-click sets how far the run may climb. Unset means the class decides."))
        ladderBlock.insertArrangedSubview(legendLabel, at: 2)
        legendLabel.widthAnchor.constraint(equalTo: ladderBlock.widthAnchor).isActive = true
        planBody.addArrangedSubview(ladderBlock)

        modeControl.selectedSegment = DelegateMode.allCases.firstIndex(of: draft.mode) ?? 0
        modeControl.target = self
        modeControl.action = #selector(fieldChanged)
        planBody.addArrangedSubview(labelled(DelegateComposerWords.modeLabel, modeControl))
        effortControl.selectedSegment = draft.effort.flatMap { DelegateEffort.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        effortControl.target = self
        effortControl.action = #selector(fieldChanged)
        planBody.addArrangedSubview(labelled(DelegateComposerWords.effortLabel, effortControl))

        readField.stringValue = draft.read
        readField.placeholderString = "README.md"
        readField.font = MacTheme.Ramp.font(.code)
        readField.delegate = self
        planBody.addArrangedSubview(labelled(DelegateComposerWords.readLabel, readField))
        (notesView.documentView as? NSTextView)?.string = draft.notes
        planBody.addArrangedSubview(labelled(DelegateComposerWords.notesLabel, textView(notesView, height: 50)))
        for view in planBody.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: planBody.widthAnchor, constant: -MacTheme.Spacing.l).isActive = true
        }
    }

    @objc private func planHeaderClicked() {
        planToggle.state = planToggle.state == .on ? .off : .on
        planToggled()
    }

    @objc private func planToggled() {
        planBody.isHidden = planToggle.state != .on
    }

    @objc private func reviewChanged() {
        draft.review = reviewSwitch.state == .on
    }

    @objc private func repoPicked() {
        guard let path = repoPopup.selectedItem?.representedObject as? String else { return }
        repoField.stringValue = path
        fieldChanged()
    }

    func textDidChange(_ notification: Notification) { fieldChanged() }

    @objc private func classChanged() {
        guard let name = classPopup.titleOfSelectedItem else { return }
        draft.choose(taskClass: name, capabilities: board.capabilities)
        verifyField.stringValue = draft.verify
        ladder.rungs = board.composerRungs(taskClass: name)
        ladder.set(start: draft.tier, ceiling: draft.ceiling)
        fieldChanged()
    }

    func controlTextDidChange(_ obj: Notification) { fieldChanged() }

    @objc private func fieldChanged() {
        draft.taskClass = classPopup.titleOfSelectedItem ?? draft.taskClass
        draft.repo = repoField.stringValue
        draft.goal = (goalView.documentView as? NSTextView)?.string ?? ""
        draft.paths = (pathsView.documentView as? NSTextView)?.string ?? ""
        draft.verify = verifyField.stringValue
        draft.read = readField.stringValue
        draft.notes = (notesView.documentView as? NSTextView)?.string ?? ""
        draft.mode = DelegateMode.allCases.element(at: modeControl.selectedSegment) ?? .normal
        draft.effort = effortControl.selectedSegment == 0 ? nil : DelegateEffort.allCases.element(at: effortControl.selectedSegment - 1)
        render()
    }

    private func render() {
        let problems = draft.problems
        self.problems.stringValue = problems.joined(separator: "\n")
        self.problems.isHidden = problems.isEmpty
        let cautions = draft.cautions
        self.cautions.stringValue = cautions.joined(separator: "\n")
        self.cautions.isHidden = cautions.isEmpty
        sendButton.isEnabled = draft.canSend && !sending
        sendButton.title = sending ? DelegateComposerWords.sendingTitle : DelegateComposerWords.sendTitle
        renderLegend()
        suggestionRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for suggestion in DelegateDraft.verifySuggestions(paths: draft.pathList, repo: draft.repo) where suggestion != draft.verify {
            suggestionRow.addArrangedSubview(RowKit.ActionButton(title: suggestion) { [weak self] in
                self?.verifyField.stringValue = suggestion
                self?.fieldChanged()
            })
        }
        suggestionRow.isHidden = suggestionRow.arrangedSubviews.isEmpty
    }

    /// The one sentence that resolves the ladder the way the daemon will, the implied range drawn
    /// on the rungs so an unset ladder is still a picture, and the Plan line that sums it all up.
    private func renderLegend() {
        let plan = draft.plan(capabilities: board.capabilities, tierOrder: board.tierOrder)
        legendLabel.stringValue = plan.legend
        ladder.setImplied(start: plan.start, ceiling: plan.ceiling)
        planSummary.stringValue = draft.planSummary(capabilities: board.capabilities, tierOrder: board.tierOrder)
    }

    private func send() {
        guard draft.canSend, !sending else { return }
        sending = true
        render()
        let draft = draft
        Task { [weak self] in
            guard let self else { return }
            do {
                let runID = try await self.desk.start(draft, host: self.host)
                self.close()
                self.onStarted(runID)
            } catch {
                self.sending = false
                self.render()
                self.problems.stringValue = error.localizedDescription
                self.problems.isHidden = false
            }
        }
    }

    private func close() {
        sheet.sheetParent?.endSheet(sheet)
    }
}

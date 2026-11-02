import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// Ask later: the question, five chips said the way people say them, a field that reads a typed
/// phrase, and what that was understood as — always a date — before anything is saved. One state
/// for three clients (`AskLaterSheet`); this sheet only lays it out and sends the schedule to the
/// machine, which asks it whether or not this Mac is on. A machine that keeps no schedules is said
/// to be one, and the sheet cannot save.
@MainActor
final class AskLaterSheetController: NSObject, NSTextFieldDelegate {
    struct Aim {
        var profile: ConnectionProfile
        var model: ModelSelection?
        var effort: String?
        var directory: String?
        var sessionID: String?
    }

    private static var active: [AskLaterSheetController] = []

    let sheet: NSWindow
    private var state: AskLaterSheet
    private let aim: Aim
    private let question = NSTextField()
    private var chips: [AskLaterSheet.Chip: NSButton] = [:]
    private let phrase = NSTextField()
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let understoodBox = NSView()
    private let threadSwitch = NSSwitch()
    private let quietSwitch = NSSwitch()
    private let switches = NSStackView()
    private let reach = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let confirm = NSButton()
    private var saving = false
    private let onScheduled: @MainActor (MachineSchedule) -> Void

    /// What the sheet says right now, for a harness.
    var headlineText: String { understoodBox.isHidden ? "" : headline.stringValue }
    var detailText: String { detail.stringValue }
    var confirmTitle: String { confirm.title }
    var canSave: Bool { confirm.isEnabled }
    var switchesShown: Bool { !switches.isHidden }

    @discardableResult
    static func present(
        on host: NSWindow, text: String, aim: Aim, modelWord: String?, keepsSchedules: Bool,
        phrase: String = "", onScheduled: @escaping @MainActor (MachineSchedule) -> Void
    ) -> AskLaterSheetController {
        let controller = AskLaterSheetController(
            text: text, aim: aim, modelWord: modelWord, keepsSchedules: keepsSchedules,
            onScheduled: onScheduled)
        active.append(controller)
        host.beginSheet(controller.sheet) { _ in
            active.removeAll { $0 === controller }
        }
        if !phrase.isEmpty { controller.type(phrase) }
        controller.sheet.makeFirstResponder(
            text.trimmingCharacters(in: .whitespaces).isEmpty ? controller.question : controller.phrase)
        return controller
    }

    private init(
        text: String, aim: Aim, modelWord: String?, keepsSchedules: Bool,
        onScheduled: @escaping @MainActor (MachineSchedule) -> Void
    ) {
        self.aim = aim
        self.onScheduled = onScheduled
        state = AskLaterSheet(
            text: text, machine: aim.profile.name, modelWord: modelWord, machineKeepsSchedules: keepsSchedules)
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled],
            backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.title = ScheduleWords.askLater
        super.init()
        sheet.contentView = makeContent(text: text)
        render()
    }

    private func makeContent(text: String) -> NSView {
        let title = NSTextField(labelWithString: ScheduleWords.askLater)
        title.font = MacTheme.Ramp.font(.cardTitle)

        question.stringValue = text
        question.placeholderString = Localized.text("What should be asked?")
        question.font = MacTheme.Ramp.font(.cardBody)
        question.usesSingleLineMode = false
        question.cell?.wraps = true
        question.lineBreakMode = .byWordWrapping
        question.delegate = self
        question.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        question.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let chipRow = NSStackView()
        chipRow.orientation = .horizontal
        chipRow.spacing = MacTheme.Spacing.xs
        for chip in AskLaterSheet.Chip.allCases {
            let words = AskLaterSheet.words(chip)
            let button = NSButton(
                title: words.time.map { "\(words.title) \($0)" } ?? words.title, target: self,
                action: #selector(chipTapped(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .push
            button.controlSize = .small
            button.identifier = NSUserInterfaceItemIdentifier(chip.rawValue)
            chips[chip] = button
            chipRow.addArrangedSubview(button)
        }

        phrase.placeholderString = ScheduleWords.sayWhen
        phrase.font = MacTheme.Ramp.font(.cardBody)
        phrase.delegate = self

        headline.font = MacTheme.Ramp.font(.panelLabel)
        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detail.textColor = MacTheme.Color.secondaryLabel
        let glyph = NSImageView(
            image: NSImage(systemSymbolName: "clock", accessibilityDescription: nil) ?? NSImage())
        glyph.contentTintColor = MacTheme.Color.accent
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        let lines = NSStackView(views: [headline, detail])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        lines.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let understoodRow = NSStackView(views: [glyph, lines])
        understoodRow.orientation = .horizontal
        understoodRow.alignment = .top
        understoodRow.spacing = MacTheme.Spacing.s
        understoodRow.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        understoodRow.translatesAutoresizingMaskIntoConstraints = false
        understoodBox.wantsLayer = true
        understoodBox.layer?.cornerRadius = MacTheme.Radius.control
        understoodBox.layer?.backgroundColor = MacTheme.Color.accent.withAlphaComponent(0.12).cgColor
        understoodBox.addSubview(understoodRow)
        NSLayoutConstraint.activate([
            understoodRow.leadingAnchor.constraint(equalTo: understoodBox.leadingAnchor),
            understoodRow.trailingAnchor.constraint(equalTo: understoodBox.trailingAnchor),
            understoodRow.topAnchor.constraint(equalTo: understoodBox.topAnchor),
            understoodRow.bottomAnchor.constraint(equalTo: understoodBox.bottomAnchor),
        ])

        threadSwitch.state = .on
        threadSwitch.target = self
        threadSwitch.action = #selector(switchesChanged)
        quietSwitch.state = .on
        quietSwitch.target = self
        quietSwitch.action = #selector(switchesChanged)
        switches.orientation = .vertical
        switches.alignment = .leading
        switches.spacing = MacTheme.Spacing.s
        switches.addArrangedSubview(
            Self.switchRow(threadSwitch, ScheduleWords.oneConversation, ScheduleWords.oneConversationDetail))
        switches.addArrangedSubview(Self.switchRow(quietSwitch, ScheduleWords.quiet, ScheduleWords.quietDetail))

        reach.font = MacTheme.Ramp.font(.panelFootnote)
        reach.textColor = MacTheme.Color.secondaryLabel
        status.font = MacTheme.Ramp.font(.panelFootnote)
        status.textColor = MacTheme.Color.danger
        status.isHidden = true

        let cancel = NSButton(title: Localized.text("Cancel"), target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1B}"
        confirm.target = self
        confirm.action = #selector(confirmTapped)
        confirm.bezelStyle = .push
        confirm.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, confirm])
        buttons.orientation = .horizontal
        buttons.spacing = MacTheme.Spacing.s

        let column = FillingStack(views: [
            title, question, chipRow, phrase, understoodBox, switches, reach, status, buttons,
        ])
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: 560).isActive = true
        return column
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

    /// Types a phrase as a person would, for `--open ask-later` and the selftest.
    func type(_ text: String) {
        phrase.stringValue = text
        state.type(text)
        render()
    }

    func pick(_ chip: AskLaterSheet.Chip) {
        state.pick(chip)
        phrase.stringValue = ""
        render()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === phrase { state.type(phrase.stringValue) }
        if field === question { state.text = question.stringValue }
        render()
    }

    @objc private func chipTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let chip = AskLaterSheet.Chip(rawValue: raw) else { return }
        pick(chip)
    }

    @objc private func switchesChanged() {
        state.oneConversation = threadSwitch.state == .on
        state.quiet = quietSwitch.state == .on
        render()
    }

    private func render() {
        for (chip, button) in chips { button.state = state.chip == chip ? .on : .off }
        if let line = state.understoodLine() {
            headline.stringValue = line.headline
            detail.stringValue = line.detail
            detail.isHidden = line.detail.isEmpty
            headline.textColor =
                state.understanding() == nil ? MacTheme.Color.warning : MacTheme.Color.label
            understoodBox.isHidden = false
        } else {
            understoodBox.isHidden = true
        }
        switches.isHidden = !state.showsRepeatSwitches()
        reach.stringValue =
            state.machineKeepsSchedules
            ? ScheduleWords.reach(state.machine) : ScheduleWords.cannotKeep(state.machine)
        reach.textColor = state.machineKeepsSchedules ? MacTheme.Color.secondaryLabel : MacTheme.Color.warning
        confirm.title = state.confirmTitle()
        confirm.isEnabled = !saving && state.canSave && state.understanding() != nil
        sheet.setContentSize(sheet.contentView?.fittingSize ?? sheet.frame.size)
    }

    @objc private func cancelTapped() {
        sheet.sheetParent?.endSheet(sheet)
    }

    @objc private func confirmTapped() {
        guard !saving, let scheduling = MachineDesk.shared.scheduling(for: aim.profile.id) else { return }
        let wire = aim.model.flatMap { model in
            MachineDesk.shared.backend(for: aim.profile.id).map {
                QuickAskLaterHandoff.wireModel(model, backend: $0)
            }
        }
        guard
            let draft = state.draft(
                model: aim.model, wireModel: wire, effort: aim.effort, directory: aim.directory,
                sessionID: aim.sessionID, device: Host.current().localizedName)
        else { return }
        saving = true
        status.isHidden = true
        render()
        Task { [weak self] in
            do {
                let made = try await scheduling.createSchedule(draft)
                await MachineDesk.shared.refreshSchedules()
                guard let self else { return }
                self.onScheduled(made)
                self.sheet.sheetParent?.endSheet(self.sheet)
            } catch {
                guard let self else { return }
                self.saving = false
                self.status.stringValue = AgentErrorText.readable(error)
                self.status.isHidden = false
                self.render()
            }
        }
    }
}

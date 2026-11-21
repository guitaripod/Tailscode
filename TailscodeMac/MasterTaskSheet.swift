import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// A new task for a master: always a fresh conversation. Above the box, what the task starts with
/// is said as facts — its charter, its skills, how many notes, the last tasks, which devices are
/// free, whether the guards pass, and the brief's size — never as settings; a conversation handed
/// over rides along as a chip. ⌘↩ starts it, Esc closes it, and the conversation opens once the
/// machine has it.
@MainActor
final class MasterTaskSheet: NSObject, NSTextViewDelegate {
    private static var active: [MasterTaskSheet] = []

    let sheet: NSWindow
    private let row: MasterRow
    private let carry: ConversationBrief?
    private let textView = MasterTaskTextView()
    private let placeholder = NSTextField(labelWithString: "")
    private let startButton = NSButton()
    private let cancelButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let failure = NSTextField(wrappingLabelWithString: "")
    private let onStarted: @MainActor (MasterRow, ExpertTaskStarted) -> Void
    private var starting = false

    /// What the sheet says, for a harness.
    private(set) var chipTexts: [String] = []
    var typed: String { textView.string }
    var canStart: Bool { startButton.isEnabled }

    @discardableResult
    static func present(
        on host: NSWindow, row: MasterRow, carry: ConversationBrief? = nil, prefill: String = "",
        onStarted: @escaping @MainActor (MasterRow, ExpertTaskStarted) -> Void
    ) -> MasterTaskSheet {
        let controller = MasterTaskSheet(row: row, carry: carry, prefill: prefill, onStarted: onStarted)
        active.append(controller)
        host.beginSheet(controller.sheet) { _ in active.removeAll { $0 === controller } }
        controller.sheet.makeFirstResponder(controller.textView)
        return controller
    }

    private init(
        row: MasterRow, carry: ConversationBrief?, prefill: String,
        onStarted: @escaping @MainActor (MasterRow, ExpertTaskStarted) -> Void
    ) {
        self.row = row
        self.carry = carry
        self.onStarted = onStarted
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        sheet.contentMinSize = NSSize(width: 520, height: 380)
        super.init()
        sheet.title = MasterWords.newTask
        build(prefill: prefill)
    }

    private func build(prefill: String) {
        let master = row.master
        let mark = MasterMarkView(row: row, side: 44)
        let heading = NSTextField(labelWithString: MasterWords.startsWith(master.name))
        heading.font = MacTheme.Ramp.font(.cardTitle)
        let machine = NSTextField(labelWithString: "")
        machine.font = MacTheme.Ramp.font(.panelFootnote)
        machine.textColor = MacTheme.Color.secondaryLabel
        let model = MasterDesk.shared.modelWord(master.model, profileID: row.profileID)
        machine.stringValue = [row.machine, model, master.effort].compactMap { $0 }.joined(separator: " · ")
        let top = NSView()
        top.translatesAutoresizingMaskIntoConstraints = false
        for view in [mark, heading, machine] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            top.addSubview(view)
        }
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        machine.lineBreakMode = .byTruncatingTail
        machine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            mark.topAnchor.constraint(equalTo: top.topAnchor),
            mark.bottomAnchor.constraint(equalTo: top.bottomAnchor),
            heading.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: MacTheme.Spacing.m),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: top.trailingAnchor),
            heading.bottomAnchor.constraint(equalTo: mark.centerYAnchor, constant: 1),
            machine.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            machine.trailingAnchor.constraint(lessThanOrEqualTo: top.trailingAnchor),
            machine.topAnchor.constraint(equalTo: mark.centerYAnchor, constant: 2),
        ])

        let chips = MasterReading.startsWith(master)
        chipTexts = chips.map(\.text)
        let flow = ChipFlow()
        flow.setChips(chips.map { MasterChip($0, lamp: true) })
        let tokens = NSTextField(labelWithString: MasterWords.tokens(master.briefTokens))
        tokens.font = MacTheme.Ramp.font(.panelFootnote)
        tokens.textColor = MacTheme.Color.tertiaryLabel
        tokens.isHidden = master.briefTokens == 0

        var carried: [NSView] = []
        if let carry {
            let chip = MasterChip(MasterLine("↪ " + carry.chip, .active), lamp: false)
            let note = NSTextField(wrappingLabelWithString: MasterWords.handOverNote(carry.source))
            note.font = MacTheme.Ramp.font(.panelFootnote)
            note.textColor = MacTheme.Color.secondaryLabel
            note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let holder = NSStackView(views: [chip])
            carried = [holder, note]
        }

        textView.delegate = self
        textView.font = MacTheme.Ramp.font(.composer)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.string = prefill
        textView.onSubmit = { [weak self] in self?.start() }
        textView.onCancel = { [weak self] in self?.cancel() }
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        placeholder.stringValue =
            carry == nil ? MasterWords.newTaskFor(master.name) : Localized.text("What should %@ do with it?", master.name)
        placeholder.font = MacTheme.Ramp.font(.composer)
        placeholder.textColor = MacTheme.Color.tertiaryLabel
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(placeholder)

        failure.font = MacTheme.Ramp.font(.panelFootnote)
        failure.textColor = MacTheme.Color.danger
        failure.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        startButton.title = Localized.text("Start Task")
        startButton.bezelStyle = .push
        startButton.keyEquivalent = "\r"
        startButton.keyEquivalentModifierMask = [.command]
        startButton.target = self
        startButton.action = #selector(startTapped)
        startButton.toolTip = "⌘↩"
        cancelButton.title = MasterWords.cancel
        cancelButton.bezelStyle = .push
        cancelButton.keyEquivalent = "\u{1B}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        let spacer = masterSpacer()
        let footer = NSStackView(views: [spinner, spacer, cancelButton, startButton])
        footer.orientation = .horizontal
        footer.spacing = MacTheme.Spacing.s

        let column = FillingStack(topDown: false)
        column.spacing = MacTheme.Spacing.m
        for view in [top, flow, tokens] + carried { column.addArrangedSubview(view) }
        column.setCustomSpacing(MacTheme.Spacing.xs, after: flow)
        column.setHuggingPriority(.required, for: .vertical)
        footer.translatesAutoresizingMaskIntoConstraints = false
        failure.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        for view in [column, scroll, failure, footer] as [NSView] { root.addSubview(view) }
        sheet.contentView = root
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: column.bottomAnchor, constant: MacTheme.Spacing.m),
            scroll.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            failure.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: MacTheme.Spacing.s),
            failure.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            failure.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            footer.topAnchor.constraint(equalTo: failure.bottomAnchor, constant: MacTheme.Spacing.s),
            footer.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            placeholder.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 13),
            placeholder.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 9),
        ])
        refresh()
    }

    func textDidChange(_ notification: Notification) { refresh() }

    private func refresh() {
        let typed = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        placeholder.isHidden = !textView.string.isEmpty
        startButton.isEnabled = !starting && (!typed.isEmpty || carry != nil)
    }

    /// Types into the box, for a harness.
    func type(_ text: String) {
        textView.string = text
        refresh()
    }

    @objc private func startTapped() { start() }
    @objc private func cancelTapped() { cancel() }

    private func cancel() {
        guard !starting else { return }
        sheet.sheetParent?.endSheet(sheet)
    }

    /// The machine makes the conversation and sends the first words; the sheet goes once it has,
    /// and says why when it could not.
    func start() {
        guard canStart, let keeping = MasterDesk.shared.keeping(for: row.profileID) else { return }
        let typed = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = carry.map { $0.wrapped(with: typed) } ?? typed
        let title = typed.isEmpty ? carry?.source : nil
        starting = true
        spinner.startAnimation(nil)
        failure.isHidden = true
        refresh()
        let row = self.row
        Task { [weak self] in
            do {
                let started = try await keeping.startExpertTask(
                    row.master.id, ExpertTaskRequest(text: text, title: title))
                guard let self else { return }
                self.spinner.stopAnimation(nil)
                self.sheet.sheetParent?.endSheet(self.sheet)
                self.onStarted(row, started)
            } catch {
                guard let self else { return }
                self.starting = false
                self.spinner.stopAnimation(nil)
                self.failure.stringValue = AgentErrorText.readable(error)
                self.failure.isHidden = false
                self.refresh()
            }
        }
    }
}

/// The task box: ⌘↩ starts, Esc closes, and Return is a new line, as in any composer here.
@MainActor
final class MasterTaskTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            onSubmit?()
            return
        }
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

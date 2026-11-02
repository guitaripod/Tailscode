import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// One agent on one machine, as a checklist the machine proves (`MachineAgentReading.steps`): on
/// the machine, a brain when it needs one — the model servers the machine already runs first — a
/// key when it asks, a sign-in relayed from the machine, and Answered, which turns green only once
/// the machine opened a real session in it. Each step that is not yet true carries its one press;
/// the card leads with the press that matters now. Nothing is decided here: every press is the
/// machine's, and the card redraws from what the machine says next.
@MainActor
final class AgentCardSheet: NSObject {
    private static var active: [AgentCardSheet] = []

    let sheet: NSWindow
    let profile: ConnectionProfile
    let agentID: String
    private(set) var agent: MachineAgent?
    private let header = NSTextField(labelWithString: "")
    private let stateLine = NSTextField(labelWithString: "")
    private let about = NSTextField(wrappingLabelWithString: "")
    private let steps = NSStackView()
    private let brainArea = NSStackView()
    private let brainPopup = NSPopUpButton()
    private let brainKey = NSSecureTextField()
    private let brainUse = NSButton()
    private let keyArea = NSStackView()
    private let keyCaption = NSTextField(labelWithString: "")
    private let keyField = NSSecureTextField()
    private let keyLink = NSButton()
    private let keySave = NSButton()
    private var keyEnv: String?
    private let console = NSStackView()
    private let consoleText = NSTextView()
    private let consoleState = NSTextField(labelWithString: "")
    private let consoleLinks = NSStackView()
    private let consoleInput = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let primary = NSButton()
    private let remove = NSButton()
    private var brainOptions: [BrainOption] = []
    private var busy: String?
    private var relay: AgentSignInRelay?
    private var watching: Task<Void, Never>?
    var onStartChat: ((ConnectionProfile, MachineAgent) -> Void)?
    var onToast: ((String) -> Void)?

    /// The checklist as drawn, for a harness: each step's title and state.
    var stepStates: [(String, AgentSetupStep.State)] {
        steps.arrangedSubviews.compactMap { ($0 as? StepLine).map { ($0.titleText, $0.state) } }
    }
    var primaryTitle: String { primary.isHidden ? "" : primary.title }
    var showsBrainPicker: Bool { !brainArea.isHidden }
    var brainTitles: [String] { brainPopup.itemTitles }

    @discardableResult
    static func present(on host: NSWindow, profile: ConnectionProfile, agentID: String) -> AgentCardSheet {
        let card = AgentCardSheet(profile: profile, agentID: agentID)
        active.append(card)
        host.beginSheet(card.sheet) { _ in
            card.watching?.cancel()
            active.removeAll { $0 === card }
        }
        card.watch()
        return card
    }

    private init(profile: ConnectionProfile, agentID: String) {
        self.profile = profile
        self.agentID = agentID
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 480), styleMask: [.titled],
            backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        super.init()
        sheet.contentView = makeContent()
        render()
    }

    private func makeContent() -> NSView {
        header.font = MacTheme.Ramp.font(.cardTitle)
        stateLine.font = MacTheme.Ramp.font(.panelDetail)
        about.font = MacTheme.Ramp.font(.panelFootnote)
        about.textColor = MacTheme.Color.secondaryLabel
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = MacTheme.Spacing.s

        brainPopup.target = self
        brainPopup.action = #selector(brainChosen)
        brainKey.placeholderString = MachineAgentReading.keyPlaceholder
        brainKey.isHidden = true
        brainUse.title = Localized.text("Use")
        brainUse.bezelStyle = .push
        brainUse.target = self
        brainUse.action = #selector(brainUseTapped)
        let brainRow = NSStackView(views: [brainPopup, brainUse])
        brainRow.orientation = .horizontal
        brainRow.spacing = MacTheme.Spacing.s
        brainArea.orientation = .vertical
        brainArea.alignment = .leading
        brainArea.spacing = MacTheme.Spacing.xs
        brainArea.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("A BRAIN")))
        brainArea.addArrangedSubview(brainRow)
        brainArea.addArrangedSubview(brainKey)
        brainArea.addArrangedSubview(MacDialogs.detailLabel(MachineAgentReading.keyNote, wraps: true))
        brainKey.widthAnchor.constraint(equalToConstant: 320).isActive = true
        brainArea.isHidden = true

        keyCaption.font = MacTheme.Ramp.font(.panelLabel)
        keyField.placeholderString = MachineAgentReading.keyPlaceholder
        keyField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        keyLink.title = Localized.text("Get a key")
        keyLink.bezelStyle = .inline
        keyLink.target = self
        keyLink.action = #selector(keyLinkTapped)
        keySave.title = Localized.text("Save")
        keySave.bezelStyle = .push
        keySave.target = self
        keySave.action = #selector(keySaveTapped)
        let keyRow = NSStackView(views: [keyField, keySave, keyLink])
        keyRow.orientation = .horizontal
        keyRow.spacing = MacTheme.Spacing.s
        keyArea.orientation = .vertical
        keyArea.alignment = .leading
        keyArea.spacing = MacTheme.Spacing.xs
        keyArea.addArrangedSubview(keyCaption)
        keyArea.addArrangedSubview(keyRow)
        keyArea.addArrangedSubview(MacDialogs.detailLabel(MachineAgentReading.keyNote, wraps: true))
        keyArea.isHidden = true

        consoleText.isEditable = false
        consoleText.font = MacTheme.Ramp.font(.code)
        consoleText.drawsBackground = true
        consoleText.backgroundColor = MacTheme.Color.codeBackground
        consoleText.textContainerInset = NSSize(width: 6, height: 6)
        let consoleScroll = NSScrollView()
        consoleScroll.documentView = consoleText
        consoleScroll.hasVerticalScroller = true
        consoleScroll.translatesAutoresizingMaskIntoConstraints = false
        consoleScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        consoleText.autoresizingMask = [.width]
        consoleState.font = MacTheme.Ramp.font(.panelLabel)
        consoleLinks.orientation = .horizontal
        consoleLinks.spacing = MacTheme.Spacing.s
        consoleInput.placeholderString = MachineAgentReading.signInInputPlaceholder
        consoleInput.target = self
        consoleInput.action = #selector(consoleSend)
        let send = NSButton(title: Localized.text("Send"), target: self, action: #selector(consoleSend))
        send.bezelStyle = .push
        let stop = NSButton(title: Localized.text("Cancel"), target: self, action: #selector(consoleCancel))
        stop.bezelStyle = .push
        let inputRow = NSStackView(views: [consoleInput, send, stop])
        inputRow.orientation = .horizontal
        inputRow.spacing = MacTheme.Spacing.s
        consoleInput.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        console.orientation = .vertical
        console.alignment = .leading
        console.spacing = MacTheme.Spacing.xs
        console.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("SIGN-IN")))
        console.addArrangedSubview(consoleState)
        console.addArrangedSubview(consoleScroll)
        console.addArrangedSubview(consoleLinks)
        console.addArrangedSubview(inputRow)
        consoleScroll.widthAnchor.constraint(equalTo: console.widthAnchor).isActive = true
        inputRow.widthAnchor.constraint(equalTo: console.widthAnchor).isActive = true
        console.isHidden = true

        status.font = MacTheme.Ramp.font(.panelFootnote)
        status.textColor = MacTheme.Color.secondaryLabel
        status.isHidden = true

        primary.bezelStyle = .push
        primary.keyEquivalent = "\r"
        primary.target = self
        primary.action = #selector(primaryTapped)
        remove.title = MachineAgentReading.removeTitle
        remove.bezelStyle = .push
        remove.contentTintColor = MacTheme.Color.danger
        remove.target = self
        remove.action = #selector(removeTapped)
        let close = NSButton(title: Localized.text("Close"), target: self, action: #selector(closeTapped))
        close.bezelStyle = .push
        close.keyEquivalent = "\u{1B}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [remove, spacer, close, primary])
        buttons.orientation = .horizontal
        buttons.spacing = MacTheme.Spacing.s

        let column = FillingStack(views: [
            header, stateLine, about, steps, brainArea, keyArea, console, status, buttons,
        ])
        column.spacing = MacTheme.Spacing.m
        column.setCustomSpacing(2, after: header)
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: 560).isActive = true
        return column
    }

    /// The card reads the machine again on a short beat while something is moving — a proof, an
    /// install, a sign-in — and the sign-in's own relay every second while it runs.
    private func watch() {
        watching?.cancel()
        watching = Task { [weak self] in
            await MachineDesk.shared.refreshAgents(profileID: self?.profile.id ?? "", refreshBrains: true)
            self?.render()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if let relay = self.relay, relay.state == .running,
                    let hosting = MachineDesk.shared.hosting(for: self.profile.id)
                {
                    self.relay = (try? await hosting.agentSignIn(self.agentID)) ?? relay
                    self.renderConsole()
                    if self.relay?.state != .running {
                        await MachineDesk.shared.refreshAgents(profileID: self.profile.id)
                        self.render()
                    }
                }
                let moving = [MachineAgent.State.checking, .installing].contains(self.agent?.state)
                if moving || self.busy != nil {
                    await MachineDesk.shared.refreshAgents(profileID: self.profile.id)
                    self.render()
                }
            }
        }
    }

    func render() {
        let report = MachineDesk.shared.reports[profile.id]
        agent = report?.agents.first { $0.id == agentID }
        guard let agent else {
            header.stringValue = agentID
            stateLine.stringValue = Localized.text("Checking…")
            steps.arrangedSubviews.forEach { $0.removeFromSuperview() }
            primary.isHidden = true
            remove.isHidden = true
            fit()
            return
        }
        sheet.title = agent.name
        header.stringValue = agent.name
        let state = MachineAgentReading.state(agent, machine: profile.name)
        stateLine.stringValue = state.0
        stateLine.textColor = AgentLineView.toneColor(state.1)
        about.stringValue = agent.description ?? ""
        about.isHidden = (agent.description ?? "").isEmpty
        steps.arrangedSubviews.forEach { $0.removeFromSuperview() }
        brainOptions = MachineAgentReading.brains(report, for: agent, machine: profile.name)
        let lead = MachineAgentReading.primary(agent, brains: brainOptions, machine: profile.name)?.0
        for step in MachineAgentReading.steps(agent, machine: profile.name) {
            let line = StepLine(step: step, offersPress: step.press != lead) { [weak self] press in
                self?.perform(press)
            }
            steps.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: steps.widthAnchor).isActive = true
        }
        let selected = brainPopup.indexOfSelectedItem
        brainPopup.removeAllItems()
        for option in brainOptions { brainPopup.addItem(withTitle: "\(option.title) — \(option.detail)") }
        if brainOptions.indices.contains(selected) { brainPopup.selectItem(at: selected) }
        brainChosen()
        if agent.state == .needsBrain, brainArea.isHidden, !brainOptions.isEmpty { brainArea.isHidden = false }
        if agent.state == .ready { brainArea.isHidden = true }
        if let primaryPress = MachineAgentReading.primary(agent, brains: brainOptions, machine: profile.name) {
            primary.title = primaryPress.1
            primary.isHidden = false
            primary.isEnabled = busy == nil
        } else {
            primary.isHidden = true
        }
        remove.isHidden = !agent.added
        remove.isEnabled = busy == nil
        if let busy {
            status.stringValue = busy
            status.textColor = MacTheme.Color.secondaryLabel
            status.isHidden = false
        }
        renderConsole()
        fit()
    }

    private func fit() {
        sheet.setContentSize(sheet.contentView?.fittingSize ?? sheet.frame.size)
    }

    /// One press, worded by Core, carried out by the machine.
    func perform(_ press: AgentPress) {
        guard let hosting = MachineDesk.shared.hosting(for: profile.id) else { return }
        let id = agentID
        switch press {
        case .add:
            run(Localized.text("%@ is opening a real chat with it…", profile.name)) { try await hosting.addAgent(id) }
        case .check:
            run(Localized.text("%@ is opening a real chat with it…", profile.name)) { try await hosting.checkAgent(id) }
        case .install:
            run(Localized.text("Installing…")) { try await hosting.installAgent(id) }
        case .giveBrain:
            brainArea.isHidden = false
            fit()
        case .enterKey(let env):
            keyEnv = env
            let key = agent?.keys.first { $0.env == env }
            keyCaption.stringValue = key?.name ?? env
            keyLink.isHidden = key?.url == nil
            keyArea.isHidden = false
            sheet.makeFirstResponder(keyField)
            fit()
        case .signIn(let method):
            startSignIn(method, hosting: hosting)
        case .startChat:
            guard let agent else { return }
            sheet.sheetParent?.endSheet(sheet)
            onStartChat?(profile, agent)
        case .remove:
            removeTapped()
        case .open:
            break
        }
    }

    private func run(_ waiting: String, _ work: @escaping @MainActor () async throws -> MachineAgent) {
        busy = waiting
        render()
        Task { [weak self] in
            do {
                _ = try await work()
                self?.busy = nil
                self?.status.isHidden = true
            } catch {
                self?.busy = nil
                self?.status.stringValue = AgentErrorText.readable(error)
                self?.status.textColor = MacTheme.Color.danger
                self?.status.isHidden = false
            }
            await MachineDesk.shared.refreshAgents(profileID: self?.profile.id ?? "")
            self?.render()
        }
    }

    @objc private func primaryTapped() {
        guard let agent,
            let press = MachineAgentReading.primary(agent, brains: brainOptions, machine: profile.name)?.0
        else { return }
        if press == .giveBrain, let first = brainOptions.first(where: { $0.choice != nil })?.choice {
            useBrain(first)
            return
        }
        perform(press)
    }

    @objc private func brainChosen() {
        let index = brainPopup.indexOfSelectedItem
        guard brainOptions.indices.contains(index) else { return }
        brainKey.isHidden = brainOptions[index].keyProvider == nil
        fit()
    }

    @objc private func brainUseTapped() {
        let index = brainPopup.indexOfSelectedItem
        guard brainOptions.indices.contains(index) else { return }
        let option = brainOptions[index]
        if let provider = option.keyProvider {
            let key = brainKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                sheet.makeFirstResponder(brainKey)
                return
            }
            brainKey.stringValue = ""
            useBrain(.key(provider: provider, key: key))
        } else if let choice = option.choice {
            useBrain(choice)
        }
    }

    private func useBrain(_ choice: AgentBrainChoice) {
        guard let hosting = MachineDesk.shared.hosting(for: profile.id) else { return }
        let id = agentID
        brainArea.isHidden = true
        run(Localized.text("%@ is opening a real chat with it…", profile.name)) {
            try await hosting.setAgentBrain(id, choice)
        }
    }

    @objc private func keyLinkTapped() {
        guard let env = keyEnv, let raw = agent?.keys.first(where: { $0.env == env })?.url,
            let url = URL(string: raw)
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func keySaveTapped() {
        guard let env = keyEnv, let hosting = MachineDesk.shared.hosting(for: profile.id) else { return }
        let value = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        keyField.stringValue = ""
        keyArea.isHidden = true
        let id = agentID
        run(Localized.text("%@ is opening a real chat with it…", profile.name)) {
            try await hosting.setAgentKey(id, env: env, value: value)
        }
    }

    private func startSignIn(_ method: String, hosting: any MachineAgentHosting) {
        let id = agentID
        console.isHidden = false
        consoleState.stringValue = Localized.text("Asking %@ to start the sign-in…", profile.name)
        fit()
        Task { [weak self] in
            do {
                self?.relay = try await hosting.startAgentSignIn(id, method: method)
            } catch {
                self?.consoleState.stringValue = AgentErrorText.readable(error)
            }
            self?.renderConsole()
        }
    }

    private func renderConsole() {
        guard let relay else { return }
        console.isHidden = false
        consoleState.stringValue = MachineAgentReading.signInState(relay)
        consoleText.string = relay.lines.joined(separator: "\n")
        consoleText.scrollToEndOfDocument(nil)
        consoleLinks.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for link in relay.links.prefix(3) {
            let button = RowKit.ActionButton(title: Localized.text("Open link")) {
                if let url = URL(string: link) { NSWorkspace.shared.open(url) }
            }
            button.bezelStyle = .push
            button.toolTip = link
            consoleLinks.addArrangedSubview(button)
        }
        for code in relay.codes.prefix(2) {
            let button = RowKit.ActionButton(title: Localized.text("Copy %@", code)) { [weak self] in
                RowKit.copyToClipboard(code)
                self?.onToast?(Localized.text("Copied"))
            }
            button.bezelStyle = .push
            consoleLinks.addArrangedSubview(button)
        }
        consoleInput.isEnabled = relay.state == .running
        fit()
    }

    @objc private func consoleSend() {
        guard let hosting = MachineDesk.shared.hosting(for: profile.id) else { return }
        let text = consoleInput.stringValue
        consoleInput.stringValue = ""
        let id = agentID
        Task { try? await hosting.sendAgentSignIn(id, text: text) }
    }

    @objc private func consoleCancel() {
        guard let hosting = MachineDesk.shared.hosting(for: profile.id) else { return }
        let id = agentID
        Task { [weak self] in
            try? await hosting.cancelAgentSignIn(id)
            self?.relay = try? await hosting.agentSignIn(id)
            self?.renderConsole()
        }
    }

    @objc private func removeTapped() {
        guard let agent else { return }
        MacDialogs.confirm(
            on: sheet, title: MachineAgentReading.removeTitle + "?",
            body: Localized.text("%@ leaves the model pill on %@. Its conversations stay.", agent.name, profile.name),
            confirmLabel: Localized.text("Remove")
        ) { [weak self] in
            guard let self, let hosting = MachineDesk.shared.hosting(for: self.profile.id) else { return }
            let id = self.agentID
            Task { [weak self] in
                try? await hosting.removeAgent(id)
                await MachineDesk.shared.refreshAgents(profileID: self?.profile.id ?? "")
                self?.render()
            }
        }
    }

    @objc private func closeTapped() {
        sheet.sheetParent?.endSheet(sheet)
    }
}

/// One step of the card: a mark for its state, what it is, the machine's account of it, and the
/// press that makes it true.
@MainActor
final class StepLine: NSView {
    let state: AgentSetupStep.State
    private let title = NSTextField(labelWithString: "")

    var titleText: String { title.stringValue }

    /// - Parameter offersPress: false when the card's own leading button already makes the same
    ///   press, so one action is never offered twice on one card.
    init(step: AgentSetupStep, offersPress: Bool = true, onPress: @escaping (AgentPress) -> Void) {
        state = step.state
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let mark: NSView
        if step.state == .working {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            mark = spinner
        } else {
            let glyph = NSTextField(labelWithString: Self.glyph(step.state))
            glyph.font = .systemFont(ofSize: 13 * MacTheme.UIScale.factor, weight: .bold)
            glyph.textColor = Self.color(step.state)
            glyph.alignment = .center
            mark = glyph
        }
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.widthAnchor.constraint(equalToConstant: 18).isActive = true
        title.stringValue = step.title
        title.font = MacTheme.Ramp.font(.panelLabel)
        let detail = NSTextField(wrappingLabelWithString: step.detail)
        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detail.textColor = step.state == .failed ? MacTheme.Color.danger : MacTheme.Color.secondaryLabel
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let lines = NSStackView(views: [title, detail])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        lines.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        var views: [NSView] = [mark, lines, spacer]
        if offersPress, let press = step.press, let pressTitle = step.pressTitle {
            let button = RowKit.ActionButton(title: pressTitle) { onPress(press) }
            button.bezelStyle = .push
            button.controlSize = .small
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(button)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel(step.title + ", " + step.detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func glyph(_ state: AgentSetupStep.State) -> String {
        switch state {
        case .done: return "✓"
        case .next: return "○"
        case .waiting: return "○"
        case .failed: return "!"
        case .working: return "…"
        }
    }

    static func color(_ state: AgentSetupStep.State) -> NSColor {
        switch state {
        case .done: return MacTheme.Color.success
        case .next: return MacTheme.Color.accent
        case .waiting: return MacTheme.Color.tertiaryLabel
        case .failed: return MacTheme.Color.danger
        case .working: return MacTheme.Color.accent
        }
    }
}

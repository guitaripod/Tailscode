import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// More agents: the ACP registry as the machine can run it, searchable, each row Install on that
/// machine — downloaded there and checked against the registry's checksum, or run through npx or
/// uvx — then proved like any other agent. An agent the machine already has says so instead.
@MainActor
final class AgentRegistrySheet: NSObject, NSSearchFieldDelegate {
    private static var active: [AgentRegistrySheet] = []

    let sheet: NSWindow
    let profile: ConnectionProfile
    private let search = NSSearchField()
    private let list = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var agents: [RegistryAgent] = []
    private var installing: Set<String> = []
    var onInstalled: ((ConnectionProfile, MachineAgent) -> Void)?
    var onToast: ((String) -> Void)?

    /// The rows drawn, for a harness.
    var rowTitles: [String] { list.arrangedSubviews.compactMap { ($0 as? RegistryLine)?.titleText } }

    @discardableResult
    static func present(on host: NSWindow, profile: ConnectionProfile) -> AgentRegistrySheet {
        let controller = AgentRegistrySheet(profile: profile)
        active.append(controller)
        host.beginSheet(controller.sheet) { _ in active.removeAll { $0 === controller } }
        controller.load()
        return controller
    }

    private init(profile: ConnectionProfile) {
        self.profile = profile
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 560), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.title = MachineAgentReading.moreAgents
        super.init()
        sheet.contentView = makeContent()
    }

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: Localized.text("More agents on %@", profile.name))
        title.font = MacTheme.Ramp.font(.cardTitle)
        search.placeholderString = MachineAgentReading.searchRegistry
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        let column = FillingStack(views: [])
        column.addArrangedSubview(list)
        let scroll = MacDialogs.scrollColumn(holding: column)
        scroll.heightAnchor.constraint(equalToConstant: 360).isActive = true
        let note = MacDialogs.detailLabel(MachineAgentReading.registryNote, wraps: true)
        status.font = MacTheme.Ramp.font(.panelFootnote)
        status.textColor = MacTheme.Color.secondaryLabel
        status.stringValue = Localized.text("Reading the registry on %@…", profile.name)
        let done = NSButton(title: Localized.text("Done"), target: self, action: #selector(doneTapped))
        done.bezelStyle = .push
        done.keyEquivalent = "\u{1B}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, done])
        buttons.orientation = .horizontal
        let outer = FillingStack(views: [title, search, scroll, note, status, buttons])
        outer.spacing = MacTheme.Spacing.m
        outer.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.widthAnchor.constraint(equalToConstant: 540).isActive = true
        return outer
    }

    private func load() {
        guard let hosting = MachineDesk.shared.hosting(for: profile.id) else { return }
        Task { [weak self] in
            do {
                self?.agents = try await hosting.agentRegistry()
                self?.status.stringValue = MachineAgentReading.moreAgentsDetail(self?.agents.count ?? 0)
            } catch {
                self?.status.stringValue = AgentErrorText.readable(error)
            }
            self?.render()
        }
    }

    /// Typed words filter the list, in the name and the authors both.
    func filter(_ text: String) {
        search.stringValue = text
        render()
    }

    @objc private func searchChanged() { render() }

    func controlTextDidChange(_ obj: Notification) { render() }

    private func render() {
        let needle = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for agent in agents {
            let haystack = ([agent.name, agent.id] + (agent.authors ?? [])).joined(separator: " ").lowercased()
            guard needle.isEmpty || haystack.contains(needle) else { continue }
            let reading = MachineAgentReading.registryRow(agent, machine: profile.name)
            let line = RegistryLine(
                title: reading.title, subtitle: reading.subtitle,
                press: installing.contains(agent.id) ? Localized.text("Installing…") : reading.press,
                enabled: reading.enabled && !installing.contains(agent.id)
            ) { [weak self] in self?.install(agent) }
            list.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    private func install(_ agent: RegistryAgent) {
        guard let hosting = MachineDesk.shared.hosting(for: profile.id) else { return }
        installing.insert(agent.id)
        render()
        let profile = self.profile
        Task { [weak self] in
            do {
                let installed = try await hosting.installAgent(agent.id)
                await MachineDesk.shared.refreshAgents(profileID: profile.id)
                self?.agents = (try? await hosting.agentRegistry()) ?? self?.agents ?? []
                let state = MachineAgentReading.state(installed, machine: profile.name)
                self?.onToast?("\(installed.name): \(state.0)")
                self?.onInstalled?(profile, installed)
            } catch {
                self?.onToast?(AgentErrorText.readable(error))
            }
            self?.installing.remove(agent.id)
            self?.render()
        }
    }

    @objc private func doneTapped() { sheet.sheetParent?.endSheet(sheet) }
}

/// One registry agent: its name, who makes it, how it runs and its version, and Install.
@MainActor
final class RegistryLine: NSView {
    private let title = NSTextField(labelWithString: "")
    var titleText: String { title.stringValue }

    init(title text: String, subtitle: String, press: String?, enabled: Bool, action: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        title.stringValue = text
        title.font = MacTheme.Ramp.font(.rowTitle)
        let detail = NSTextField(labelWithString: subtitle)
        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let lines = NSStackView(views: [title, detail])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 0
        lines.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        var views: [NSView] = [lines, spacer]
        if let press {
            let button = RowKit.ActionButton(title: press, action: action)
            button.bezelStyle = .push
            button.controlSize = .small
            button.isEnabled = enabled
            views.append(button)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        row.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 4)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

import CodingAgentKit
import CodingAgentKitApple
import MidgarCore
import SafariServices
import TailscodeCore
import UIKit

/// One agent on one machine: the checklist the machine proves, the press that takes it to the next
/// step, the brains it could think with, a key, a sign-in relayed from the machine, and — once it
/// has answered — the chat that starts with it.
@MainActor
final class AgentCardViewController: UIViewController {
    private let profile: ConnectionProfile
    private let hosting: any MachineAgentHosting
    private var agent: MachineAgent
    private var report: MachineAgentsReport?
    private var column: UIStackView!
    private var scroll: UIScrollView!
    private var busy = false
    private var showsBrains = false
    private var signIn: AgentSignInRelay?
    private var pollTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private let signInField = UITextField()
    var onChange: (() -> Void)?

    init(
        profile: ConnectionProfile, hosting: any MachineAgentHosting, agent: MachineAgent,
        report: MachineAgentsReport?
    ) {
        self.profile = profile
        self.hosting = hosting
        self.agent = agent
        self.report = report
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = agent.name
        navigationItem.largeTitleDisplayMode = .never
        (scroll, column) = MachinePage.install(in: self)
        showsBrains = agent.state == .needsBrain
        render()
        pollIfWorking()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true else {
            return
        }
        pollTask?.cancel()
        signInTask?.cancel()
    }

    private var brains: [BrainOption] {
        MachineAgentReading.brains(report, for: agent, machine: profile.name)
    }

    private func render() {
        MachinePage.clear(column)
        let steps = MachineAgentReading.steps(agent, machine: profile.name)
        let card = MachineCardView()
        for step in steps { card.add(stepRow(step)) }
        column.addArrangedSubview(card)

        if let relay = signIn { column.addArrangedSubview(console(relay)) }

        if let primary = MachineAgentReading.primary(agent, brains: brains, machine: profile.name),
            signIn?.state != .running
        {
            let button = PrimaryButton(title: primary.1)
            button.isEnabled = !busy
            button.addAction(UIAction { [weak self] _ in self?.perform(primary.0, primary: true) }, for: .touchUpInside)
            column.addArrangedSubview(button)
        } else if busy || agent.state == .checking || agent.state == .installing {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            column.addArrangedSubview(spinner)
        }

        if agent.state == .ready, !agent.models.isEmpty {
            column.addArrangedSubview(MachinePage.header(Localized.text("Models")))
            let models = MachineCardView()
            for model in agent.models {
                let row = MachineRowView(title: model.name, detail: model.description)
                if model.id == agent.currentModel {
                    let check = UIImageView(image: UIImage(systemName: "checkmark"))
                    check.tintColor = Theme.Color.accent
                    row.trail(check)
                }
                models.add(row)
            }
            column.addArrangedSubview(models)
        }

        var notes: [String] = []
        if let description = agent.description { notes.append(description) }
        if agent.brainStyle == "hermes" {
            notes.append(Localized.text("Hermes keeps its memory, skills and settings on %@. Tailscode sets only its model.", profile.name))
        }
        notes.append(MachineAgentReading.permissionNote)
        column.addArrangedSubview(MachinePage.footnote(notes.joined(separator: "\n\n")))

        if agent.added {
            var remove = UIButton.Configuration.plain()
            remove.title = MachineAgentReading.removeTitle
            remove.baseForegroundColor = Theme.Color.danger
            let button = UIButton(configuration: remove)
            button.addAction(UIAction { [weak self] _ in self?.confirmRemove() }, for: .touchUpInside)
            column.addArrangedSubview(button)
        }
    }

    private func stepRow(_ step: AgentSetupStep) -> MachineRowView {
        let row = MachineRowView(
            title: step.title, detail: step.detail, image: StepMark.image(step.state),
            detailColor: step.state == .failed ? Theme.Color.danger : Theme.Color.secondaryLabel)
        if step.state == .working {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            row.trail(spinner)
        }
        if step.id == "brain", showsBrains || step.state == .next {
            row.attach(brainOptions())
        } else if let press = step.press, let title = step.pressTitle, step.id != "answered" || agent.state != .ready {
            let pill = MachinePage.pill(title) { [weak self] in self?.perform(press, primary: false) }
            pill.isEnabled = !busy
            row.trail(pill)
        }
        if case .enterKey(let env)? = step.press, let key = agent.keys.first(where: { $0.env == env }),
            let raw = key.url, let url = URL(string: raw)
        {
            var link = UIButton.Configuration.plain()
            link.title = Localized.text("Get a %@", key.name)
            link.image = UIImage(systemName: "arrow.up.right.square")
            link.imagePlacement = .trailing
            link.imagePadding = 4
            link.contentInsets = .zero
            link.baseForegroundColor = Theme.Color.accent
            let button = UIButton(configuration: link)
            button.contentHorizontalAlignment = .leading
            button.addAction(UIAction { [weak self] _ in self?.openLink(url) }, for: .touchUpInside)
            row.attach(button)
        }
        return row
    }

    private func brainOptions() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        let current = agent.brain?.model
        for option in brains {
            let button = OptionButton(
                title: option.title, detail: option.detail,
                selected: option.choice?.model == current && current != nil)
            button.isEnabled = !busy
            button.addAction(UIAction { [weak self] _ in self?.choose(option) }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        if brains.isEmpty {
            stack.addArrangedSubview(MachinePage.footnote(Localized.text("No model server answered on %@.", profile.name)))
        }
        return stack
    }

    private func perform(_ press: AgentPress, primary: Bool) {
        switch press {
        case .add: run { try await $0.addAgent($1) }
        case .check: run { try await $0.checkAgent($1) }
        case .install: run { try await $0.installAgent($1) }
        case .giveBrain:
            if primary, let first = brains.first(where: { $0.choice != nil }) {
                choose(first)
            } else {
                showsBrains = true
                render()
            }
        case .enterKey(let env): askForKey(env: env)
        case .signIn(let method): startSignIn(method)
        case .startChat: startChat()
        case .remove: confirmRemove()
        case .open: break
        }
    }

    private func choose(_ option: BrainOption) {
        if let choice = option.choice {
            run { try await $0.setAgentBrain($1, choice) }
            return
        }
        guard let provider = option.keyProvider else { return }
        let alert = UIAlertController(
            title: option.title.replacingOccurrences(of: "…", with: ""), message: MachineAgentReading.keyNote,
            preferredStyle: .alert)
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.placeholder = MachineAgentReading.keyPlaceholder
            field.textContentType = .password
        }
        alert.addAction(UIAlertAction(title: Localized.text("Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: Localized.text("Use"), style: .default) { [weak self, weak alert] _ in
                guard let key = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !key.isEmpty
                else { return }
                self?.run { try await $0.setAgentBrain($1, .key(provider: provider, key: key)) }
            })
        present(alert, animated: true)
    }

    private func askForKey(env: String) {
        let name = agent.keys.first { $0.env == env }?.name ?? env
        let alert = UIAlertController(title: name, message: MachineAgentReading.keyNote, preferredStyle: .alert)
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.placeholder = MachineAgentReading.keyPlaceholder
            field.textContentType = .password
        }
        alert.addAction(UIAlertAction(title: Localized.text("Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: Localized.text("Keep on %@", profile.name), style: .default) {
                [weak self, weak alert] _ in
                guard let value = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !value.isEmpty
                else { return }
                self?.run { try await $0.setAgentKey($1, env: env, value: value) }
            })
        present(alert, animated: true)
    }

    /// A press that changes the agent: the card says the machine is working while it does, and
    /// draws whatever the machine says back.
    private func run(_ change: @escaping (any MachineAgentHosting, String) async throws -> MachineAgent) {
        busy = true
        agent.state = agent.state == .notAdded ? .checking : agent.state
        render()
        let id = agent.id
        let hosting = self.hosting
        Task { [weak self] in
            do {
                let updated = try await change(hosting, id)
                guard let self else { return }
                self.busy = false
                self.adopt(updated)
                Theme.Haptics.success()
            } catch {
                guard let self else { return }
                self.busy = false
                MidgarLog.error("agent \(id) press failed: \(error)", category: .connection)
                await self.reload()
                self.say(Self.words(error))
            }
        }
    }

    private func adopt(_ updated: MachineAgent) {
        agent = updated
        title = updated.name
        if updated.state != .needsBrain { showsBrains = false }
        render()
        onChange?()
        MachineDesk.shared.refresh(force: true)
        pollIfWorking()
    }

    private func reload() async {
        guard let fresh = try? await hosting.machineAgents(refreshBrains: false) else { return }
        report = fresh
        if let updated = fresh.agents.first(where: { $0.id == agent.id }) { adopt(updated) }
    }

    private func pollIfWorking() {
        guard pollTask == nil, agent.state == .checking || agent.state == .installing else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                await self.reload()
                if self.agent.state != .checking, self.agent.state != .installing { break }
            }
            self?.pollTask = nil
        }
    }

    private func startSignIn(_ method: String) {
        busy = true
        render()
        let id = agent.id
        let hosting = self.hosting
        Task { [weak self] in
            do {
                let relay = try await hosting.startAgentSignIn(id, method: method)
                guard let self else { return }
                self.busy = false
                self.signIn = relay
                self.render()
                self.followSignIn()
            } catch {
                guard let self else { return }
                self.busy = false
                self.render()
                self.say(Self.words(error))
            }
        }
    }

    private func followSignIn() {
        signInTask?.cancel()
        let id = agent.id
        let hosting = self.hosting
        signInTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let relay = try? await hosting.agentSignIn(id), let self else { continue }
                let changed = relay != self.signIn
                self.signIn = relay
                if changed, !self.signInField.isFirstResponder { self.render() }
                if relay.state != .running {
                    self.render()
                    await self.reload()
                    break
                }
            }
        }
    }

    private func console(_ relay: AgentSignInRelay) -> UIView {
        let card = MachineCardView()
        let head = MachineRowView(
            title: Localized.text("Signing in on %@", profile.name),
            detail: MachineAgentReading.signInState(relay),
            image: UIImage(systemName: "terminal"), tint: Theme.Color.secondaryLabel)
        if relay.state == .running {
            head.trail(
                MachinePage.pill(Localized.text("Cancel")) { [weak self] in self?.cancelSignIn() })
        }
        card.add(head)
        let lines = UILabel()
        lines.text = relay.lines.suffix(12).joined(separator: "\n")
        lines.font = Theme.Ramp.font(.toolOutput)
        lines.textColor = Theme.Color.secondaryLabel
        lines.numberOfLines = 0
        let body = UIView()
        lines.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(lines)
        NSLayoutConstraint.activate([
            lines.topAnchor.constraint(equalTo: body.topAnchor, constant: Theme.Spacing.s),
            lines.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -Theme.Spacing.s),
            lines.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: Theme.Spacing.m),
            lines.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -Theme.Spacing.m),
        ])
        if !relay.lines.isEmpty { card.add(body) }
        for link in relay.links {
            guard let url = URL(string: link) else { continue }
            let row = MachineRowView(
                title: Localized.text("Open the sign-in page"), detail: url.host ?? link,
                image: UIImage(systemName: "safari")) { [weak self] in self?.openLink(url) }
            row.chevron()
            card.add(row)
        }
        for code in relay.codes {
            let row = MachineRowView(
                title: code, detail: Localized.text("Code to enter — tap to copy"),
                image: UIImage(systemName: "doc.on.doc")) { [weak self] in
                UIPasteboard.general.string = code
                Theme.Haptics.success()
                self?.say(Localized.text("Copied"))
            }
            row.titleLabel.font = Theme.Ramp.font(.pairingCode)
            card.add(row)
        }
        if relay.state == .running {
            signInField.placeholder = MachineAgentReading.signInInputPlaceholder
            signInField.borderStyle = .roundedRect
            signInField.autocapitalizationType = .none
            signInField.autocorrectionType = .no
            signInField.returnKeyType = .send
            signInField.removeTarget(nil, action: nil, for: .allEvents)
            signInField.addTarget(self, action: #selector(sendSignInInput), for: .editingDidEndOnExit)
            let holder = UIView()
            signInField.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(signInField)
            NSLayoutConstraint.activate([
                signInField.topAnchor.constraint(equalTo: holder.topAnchor, constant: Theme.Spacing.s),
                signInField.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -Theme.Spacing.s),
                signInField.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: Theme.Spacing.m),
                signInField.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -Theme.Spacing.m),
            ])
            card.add(holder)
        }
        return card
    }

    @objc private func sendSignInInput() {
        guard let text = signInField.text, !text.isEmpty else { return }
        signInField.text = nil
        let id = agent.id
        let hosting = self.hosting
        Task { try? await hosting.sendAgentSignIn(id, text: text) }
    }

    private func cancelSignIn() {
        signInTask?.cancel()
        let id = agent.id
        let hosting = self.hosting
        signIn = nil
        render()
        Task { try? await hosting.cancelAgentSignIn(id) }
    }

    private func startChat() {
        let model = agent.currentModel ?? agent.models.first?.id ?? "default"
        let name = agent.models.first { $0.id == model }?.name ?? agent.name
        MachineRouter.compose(
            profile: profile, selection: ModelSelection(providerID: agent.id, modelID: model),
            modelName: Localized.text("%@ · %@", agent.name, name), from: self)
    }

    private func confirmRemove() {
        let alert = UIAlertController(
            title: Localized.text("Remove %@ from %@?", agent.name, profile.name),
            message: Localized.text("Its conversations stay. It leaves the model pill until it is added again."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localized.text("Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: Localized.text("Remove"), style: .destructive) { [weak self] _ in
                guard let self else { return }
                let id = self.agent.id
                let hosting = self.hosting
                Task { [weak self] in
                    try? await hosting.removeAgent(id)
                    self?.onChange?()
                    MachineDesk.shared.refresh(force: true)
                    self?.navigationController?.popViewController(animated: true)
                }
            })
        present(alert, animated: true)
    }

    private func openLink(_ url: URL) {
        present(SFSafariViewController(url: url), animated: true)
    }

    private func say(_ message: String) {
        ToastView(message: message).flash(in: view, above: view.safeAreaLayoutGuide.bottomAnchor)
    }

    /// What a refusal from the machine says, without the transport's dump around it.
    static func words(_ error: Error) -> String {
        if case AgentError.http(_, let body) = error {
            if let data = body.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = object["error"] as? String
            {
                return message
            }
            if !body.isEmpty { return body }
        }
        return Localized.text("The machine did not answer. Try again.")
    }
}

/// One choice in a list of choices, as the mock draws a brain: a dot, a name, where it lives.
final class OptionButton: UIControl {
    init(title: String, detail: String, selected: Bool) {
        super.init(frame: .zero)
        backgroundColor = Theme.Color.groupedBackground
        layer.cornerRadius = Theme.Radius.control
        layer.cornerCurve = .continuous
        if selected {
            layer.borderWidth = 1.5
            layer.borderColor = Theme.Color.accent.cgColor
        }
        let dot = UIView()
        dot.backgroundColor = selected ? Theme.Color.accent : Theme.Color.tertiaryLabel
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let name = UILabel()
        name.text = title
        name.font = Theme.Ramp.font(.option)
        name.textColor = Theme.Color.label
        name.adjustsFontForContentSizeCategory = true
        let place = UILabel()
        place.text = detail
        place.font = Theme.Ramp.font(.rowMeta)
        place.textColor = Theme.Color.secondaryLabel
        place.adjustsFontForContentSizeCategory = true
        place.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [dot, name, place])
        row.spacing = Theme.Spacing.s
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.s),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.s),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.s + 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Theme.Spacing.s + 2)),
        ])
        accessibilityLabel = "\(title), \(detail)"
        accessibilityTraits = selected ? [.button, .selected] : .button
        isAccessibilityElement = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : (isEnabled ? 1 : 0.5) }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.5 }
    }
}

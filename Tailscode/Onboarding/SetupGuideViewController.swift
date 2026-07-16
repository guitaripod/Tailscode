import CodingAgentKit
import SafariServices
import UIKit

@MainActor
final class SetupGuideViewController: UIViewController {
    var onReadyToConnect: (() -> Void)?
    var onTryDemo: (() -> Void)?

    private let diagram = TailnetDiagramView()
    private let backendControl = UISegmentedControl(items: ["opencode", "Claude Code"])
    private let stepsStack = UIStackView()

    private var backend: AgentType { backendControl.selectedSegmentIndex == 0 ? .openCode : .claudeCode }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Set up a server"
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.largeTitleDisplayMode = .never
        buildUI()
        backendControl.selectedSegmentIndex = 0
        backendControl.addTarget(self, action: #selector(backendChanged), for: .valueChanged)
        rebuildSteps()
    }

    private func buildUI() {
        let title = UILabel()
        title.text = "Run agents on your own machine"
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.textColor = Theme.Color.label
        title.numberOfLines = 0

        let subtitle = UILabel()
        subtitle.text = "Three steps, about five minutes. Your code and your Claude or opencode session stay on hardware you own — Tailscale just lets your phone reach them."
        subtitle.font = Theme.Font.subheadline()
        subtitle.textColor = Theme.Color.secondaryLabel
        subtitle.numberOfLines = 0

        let backendCaption = UILabel()
        backendCaption.text = "WHICH AGENT?"
        backendCaption.font = .preferredFont(forTextStyle: .caption2)
        backendCaption.textColor = Theme.Color.tertiaryLabel

        stepsStack.axis = .vertical
        stepsStack.spacing = 0

        let ready = PrimaryButton(title: "My server is running — connect")
        ready.addTarget(self, action: #selector(readyTapped), for: .touchUpInside)

        let demo = UIButton(type: .system)
        var demoConfig = UIButton.Configuration.plain()
        demoConfig.title = "Not yet? Explore the demo"
        demoConfig.image = UIImage(systemName: "play.circle")
        demoConfig.imagePadding = 6
        demoConfig.baseForegroundColor = Theme.Color.accent
        demo.configuration = demoConfig
        demo.addTarget(self, action: #selector(demoTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            diagram, title, subtitle, backendCaption, backendControl, stepsStack, ready, demo,
        ])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.l
        stack.setCustomSpacing(Theme.Spacing.xl, after: diagram)
        stack.setCustomSpacing(Theme.Spacing.xs, after: title)
        stack.setCustomSpacing(Theme.Spacing.xl, after: subtitle)
        stack.setCustomSpacing(Theme.Spacing.s, after: backendCaption)
        stack.setCustomSpacing(Theme.Spacing.xl, after: backendControl)
        stack.setCustomSpacing(Theme.Spacing.xl, after: stepsStack)
        stack.setCustomSpacing(Theme.Spacing.s, after: ready)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.addSubview(stack)
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.l),
            stack.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xl),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * Theme.Spacing.l),
            diagram.heightAnchor.constraint(equalToConstant: 168),
        ])
    }

    @objc private func backendChanged() {
        Theme.Haptics.selection()
        diagram.setBackend(backend)
        rebuildSteps()
    }

    private func rebuildSteps() {
        stepsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let steps = Self.steps(for: backend)
        for (i, step) in steps.enumerated() {
            let view = SetupStepView(
                step: step, isFirst: i == 0, isLast: i == steps.count - 1)
            view.onCopy = { [weak self] text in self?.copy(text) }
            view.onLink = { [weak self] url in self?.open(url) }
            stepsStack.addArrangedSubview(view)
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        Theme.Haptics.success()
        let toast = ToastView(message: "Copied")
        toast.flash(in: view, above: view.safeAreaLayoutGuide.bottomAnchor)
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        Theme.Haptics.tap()
        present(SFSafariViewController(url: url), animated: true)
    }

    @objc private func readyTapped() {
        Theme.Haptics.tap()
        onReadyToConnect?()
    }

    @objc private func demoTapped() {
        Theme.Haptics.tap()
        onTryDemo?()
    }

    private static func steps(for backend: AgentType) -> [SetupStep] {
        let serverStep: SetupStep
        switch backend {
        case .openCode:
            serverStep = SetupStep(
                icon: "terminal", title: "Start opencode",
                detail: "On that machine, serve opencode on the tailnet. Install it first if needed.",
                command: "opencode serve --hostname 0.0.0.0 --port 4096",
                link: ("Install opencode", "https://opencode.ai"))
        case .claudeCode:
            serverStep = SetupStep(
                icon: "terminal", title: "Start claude-bridge",
                detail:
                    "claude-bridge fronts your logged-in Claude Code CLI. Build it once, then run it with a password.",
                command:
                    "git clone https://github.com/guitaripod/claude-bridge\ncd claude-bridge && swift build -c release\nBRIDGE_PASSWORD=your-password .build/release/claude-bridge",
                link: ("claude-bridge on GitHub", "https://github.com/guitaripod/claude-bridge"))
        }
        return [
            SetupStep(
                icon: "network", title: "Join your tailnet",
                detail:
                    "Install Tailscale on this iPhone and on the computer that will run the agent, signed into the same account. Now they share a private, encrypted network.",
                command: nil,
                link: ("Get Tailscale", "https://tailscale.com/download")),
            serverStep,
            SetupStep(
                icon: "checkmark.circle", title: "Connect from your phone",
                detail:
                    "Come back here. Tap Discover to scan your tailnet, or enter the machine's Tailscale address — like \(Self.exampleURL(backend)).",
                command: nil,
                link: nil),
        ]
    }

    private static func exampleURL(_ backend: AgentType) -> String {
        backend == .openCode ? "http://100.x.y.z:4096" : "http://100.x.y.z:4098"
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override init(nibName: String?, bundle: Bundle?) { super.init(nibName: nibName, bundle: bundle) }
}

private struct SetupStep {
    let icon: String
    let title: String
    let detail: String
    let command: String?
    let link: (title: String, url: String)?
}

@MainActor
private final class SetupStepView: UIView {
    var onCopy: ((String) -> Void)?
    var onLink: ((String) -> Void)?

    init(step: SetupStep, isFirst: Bool, isLast: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let spine = UIView()
        spine.backgroundColor = Theme.Color.accent.withAlphaComponent(0.25)
        spine.translatesAutoresizingMaskIntoConstraints = false

        let badge = UIImageView(
            image: UIImage(
                systemName: step.icon,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)))
        badge.tintColor = .white
        badge.contentMode = .center
        badge.backgroundColor = Theme.Color.accent
        badge.layer.cornerRadius = 16
        badge.layer.cornerCurve = .continuous
        badge.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = step.title
        title.font = Theme.Font.headline()
        title.textColor = Theme.Color.label
        title.numberOfLines = 0

        let detail = UILabel()
        detail.text = step.detail
        detail.font = Theme.Font.subheadline()
        detail.textColor = Theme.Color.secondaryLabel
        detail.numberOfLines = 0

        let content = UIStackView(arrangedSubviews: [title, detail])
        content.axis = .vertical
        content.spacing = Theme.Spacing.xs
        content.translatesAutoresizingMaskIntoConstraints = false

        if let command = step.command {
            let block = CommandBlockView(command: command)
            block.onCopy = { [weak self] in self?.onCopy?(command) }
            content.addArrangedSubview(block)
            content.setCustomSpacing(Theme.Spacing.m, after: detail)
        }
        if let link = step.link {
            let button = UIButton(type: .system)
            var config = UIButton.Configuration.plain()
            config.title = link.title
            config.image = UIImage(
                systemName: "arrow.up.right",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
            config.imagePlacement = .trailing
            config.imagePadding = 5
            config.contentInsets = .zero
            config.baseForegroundColor = Theme.Color.accent
            button.configuration = config
            button.contentHorizontalAlignment = .leading
            button.addAction(
                UIAction { [weak self] _ in self?.onLink?(link.url) }, for: .touchUpInside)
            content.addArrangedSubview(button)
            content.setCustomSpacing(Theme.Spacing.s, after: content.arrangedSubviews[content.arrangedSubviews.count - 2])
        }

        addSubview(spine)
        addSubview(badge)
        addSubview(content)

        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: topAnchor),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor),
            badge.widthAnchor.constraint(equalToConstant: 32),
            badge.heightAnchor.constraint(equalToConstant: 32),

            spine.widthAnchor.constraint(equalToConstant: 2),
            spine.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            spine.topAnchor.constraint(equalTo: isFirst ? badge.centerYAnchor : topAnchor),
            spine.bottomAnchor.constraint(equalTo: isLast ? badge.centerYAnchor : bottomAnchor),

            content.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            content.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: Theme.Spacing.l),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: isLast ? 0 : -Theme.Spacing.xl),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

@MainActor
private final class CommandBlockView: UIView {
    var onCopy: (() -> Void)?
    private let copyButton = UIButton(type: .system)

    init(command: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.10, alpha: 1) : UIColor(white: 0.08, alpha: 1) }
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous

        let label = UILabel()
        label.attributedText = Self.render(command)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(label)

        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "doc.on.doc",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        config.baseForegroundColor = UIColor(white: 0.65, alpha: 1)
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        copyButton.configuration = config
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.addAction(UIAction { [weak self] _ in self?.copyTapped() }, for: .touchUpInside)

        addSubview(scroll)
        addSubview(copyButton)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.m),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            scroll.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -Theme.Spacing.xs),

            label.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            label.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            label.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),

            copyButton.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.s),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.s),
            copyButton.widthAnchor.constraint(equalToConstant: 30),
            copyButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    private func copyTapped() {
        onCopy?()
        var config = copyButton.configuration
        config?.image = UIImage(
            systemName: "checkmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        config?.baseForegroundColor = Theme.Color.success
        copyButton.configuration = config
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            var reset = self.copyButton.configuration
            reset?.image = UIImage(
                systemName: "doc.on.doc",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
            reset?.baseForegroundColor = UIColor(white: 0.65, alpha: 1)
            self.copyButton.configuration = reset
        }
    }

    /// Renders each line as `$ command`, the prompt tinted, so the block reads like a terminal.
    private static func render(_ command: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = Theme.Font.mono(12.5)
        let promptColor = UIColor(red: 0.40, green: 0.85, blue: 0.55, alpha: 1)
        let lines = command.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            result.append(NSAttributedString(
                string: "$ ", attributes: [.font: font, .foregroundColor: promptColor]))
            result.append(NSAttributedString(
                string: String(line),
                attributes: [.font: font, .foregroundColor: UIColor(white: 0.94, alpha: 1)]))
            if i < lines.count - 1 { result.append(NSAttributedString(string: "\n")) }
        }
        return result
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// Animated phone ↔ Tailscale ↔ server diagram that heads the guide.
@MainActor
private final class TailnetDiagramView: UIView {
    private let phoneNode = NodeView(symbol: "iphone", caption: "This iPhone", tint: Theme.Color.accent)
    private let serverNode = NodeView(symbol: "server.rack", caption: "Your machine", tint: Theme.Color.opencode)
    private let lineLayer = CAShapeLayer()
    private let dotLayer = CAShapeLayer()
    private let lockBadge = UIView()

    init() {
        super.init(frame: .zero)
        lineLayer.strokeColor = Theme.Color.accent.withAlphaComponent(0.55).cgColor
        lineLayer.lineWidth = 2
        lineLayer.lineDashPattern = [2, 6]
        lineLayer.lineCap = .round
        lineLayer.fillColor = UIColor.clear.cgColor
        layer.addSublayer(lineLayer)

        dotLayer.fillColor = Theme.Color.accent.cgColor
        layer.addSublayer(dotLayer)

        lockBadge.backgroundColor = Theme.Color.secondaryBackground
        lockBadge.layer.cornerRadius = 14
        lockBadge.layer.cornerCurve = .continuous
        lockBadge.translatesAutoresizingMaskIntoConstraints = false
        let lock = UIImageView(
            image: UIImage(
                systemName: "lock.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)))
        lock.tintColor = Theme.Color.success
        lock.translatesAutoresizingMaskIntoConstraints = false
        lockBadge.addSubview(lock)

        for node in [phoneNode, serverNode] { addSubview(node) }
        addSubview(lockBadge)

        NSLayoutConstraint.activate([
            phoneNode.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.s),
            phoneNode.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            serverNode.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.s),
            serverNode.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            lockBadge.centerXAnchor.constraint(equalTo: centerXAnchor),
            lockBadge.centerYAnchor.constraint(equalTo: phoneNode.imageCenterYAnchor),
            lockBadge.widthAnchor.constraint(equalToConstant: 28),
            lockBadge.heightAnchor.constraint(equalToConstant: 28),
            lock.centerXAnchor.constraint(equalTo: lockBadge.centerXAnchor),
            lock.centerYAnchor.constraint(equalTo: lockBadge.centerYAnchor),
        ])

        let caption = UILabel()
        caption.text = "TAILSCALE"
        caption.font = .systemFont(ofSize: 9, weight: .bold)
        caption.textColor = Theme.Color.tertiaryLabel
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)
        NSLayoutConstraint.activate([
            caption.centerXAnchor.constraint(equalTo: centerXAnchor),
            caption.topAnchor.constraint(equalTo: lockBadge.bottomAnchor, constant: 4),
        ])
    }

    func setBackend(_ backend: AgentType) {
        serverNode.setTint(backend == .openCode ? Theme.Color.opencode : Theme.Color.claude)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let y = phoneNode.frame.minY + 30
        let startX = phoneNode.frame.maxX + 6
        let endX = serverNode.frame.minX - 6
        let path = UIBezierPath()
        path.move(to: CGPoint(x: startX, y: y))
        path.addLine(to: CGPoint(x: endX, y: y))
        lineLayer.path = path.cgPath
        dotLayer.path = UIBezierPath(
            ovalIn: CGRect(x: -3, y: -3, width: 6, height: 6)).cgPath
        startAnimations(from: CGPoint(x: startX, y: y), to: CGPoint(x: endX, y: y))
    }

    private var animating = false
    private func startAnimations(from: CGPoint, to: CGPoint) {
        guard !animating, window != nil else { return }
        animating = true

        let dash = CABasicAnimation(keyPath: "lineDashPhase")
        dash.fromValue = 0
        dash.toValue = -8
        dash.duration = 0.6
        dash.repeatCount = .infinity
        lineLayer.add(dash, forKey: "dash")

        let travel = CAKeyframeAnimation(keyPath: "position")
        let path = UIBezierPath()
        path.move(to: from)
        path.addLine(to: to)
        travel.path = path.cgPath
        travel.duration = 1.8
        travel.repeatCount = .infinity
        travel.calculationMode = .paced

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.85, 1]
        fade.duration = 1.8
        fade.repeatCount = .infinity

        dotLayer.add(travel, forKey: "travel")
        dotLayer.add(fade, forKey: "fade")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            animating = false
        } else {
            setNeedsLayout()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

@MainActor
private final class NodeView: UIView {
    private let circle = UIView()
    private let imageView = UIImageView()

    var imageCenterYAnchor: NSLayoutYAxisAnchor { circle.centerYAnchor }

    init(symbol: String, caption: String, tint: UIColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        circle.backgroundColor = Theme.Color.secondaryBackground
        circle.layer.cornerRadius = 30
        circle.layer.borderWidth = 1.5
        circle.layer.borderColor = tint.withAlphaComponent(0.4).cgColor
        circle.translatesAutoresizingMaskIntoConstraints = false

        imageView.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .regular))
        imageView.tintColor = tint
        imageView.contentMode = .center
        imageView.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(imageView)

        let label = UILabel()
        label.text = caption
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = Theme.Color.secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(circle)
        addSubview(label)
        NSLayoutConstraint.activate([
            circle.topAnchor.constraint(equalTo: topAnchor),
            circle.centerXAnchor.constraint(equalTo: centerXAnchor),
            circle.widthAnchor.constraint(equalToConstant: 60),
            circle.heightAnchor.constraint(equalToConstant: 60),
            imageView.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            label.topAnchor.constraint(equalTo: circle.bottomAnchor, constant: 6),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func setTint(_ tint: UIColor) {
        imageView.tintColor = tint
        circle.layer.borderColor = tint.withAlphaComponent(0.4).cgColor
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

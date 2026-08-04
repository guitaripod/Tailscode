import CodingAgentKit
import UIKit

/// The first screen of the app. It used to be a credentials form: four competing
/// entry points, a password field, and no statement of what Tailscode is or what
/// it needs. Now it makes the argument, states the requirement, and offers
/// exactly two ways forward — with the demo as a peer, not a footnote.
@MainActor
final class WelcomeViewController: UIViewController {
    var onConnected: (() -> Void)?

    private let hero = TailnetLinkView()
    private let scroll = UIScrollView()
    private let column = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        buildUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshTailnet),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        AppLogger.lifecycle.info("welcome shown")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        refreshTailnet()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if environment["TAILSCODE_OPEN_GUIDE"] != nil {
                pushSetup(focusingConnect: environment["TAILSCODE_OPEN_CONNECT"] != nil)
            }
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    @objc private func refreshTailnet() {
        guard let address = TailnetStatus.localAddress() else {
            hero.setState(.down)
            return
        }
        hero.setState(.linked(address))
    }

    private func buildUI() {
        let headline = UILabel()
        headline.text = String(localized: "Your agents stay on your machine.")
        headline.font = Theme.Font.display(.title1)
        headline.adjustsFontForContentSizeCategory = true
        headline.textColor = Theme.Color.label
        headline.numberOfLines = 0
        Self.letWrap(headline)

        let subtitle = UILabel()
        subtitle.text = String(
            localized:
                "Tailscode is the remote. Send a prompt from anywhere on your tailnet and watch the turn land — thinking, tool runs, approvals."
        )
        subtitle.font = Theme.Font.subheadline()
        subtitle.adjustsFontForContentSizeCategory = true
        subtitle.textColor = Theme.Color.secondaryLabel
        subtitle.numberOfLines = 0
        Self.letWrap(subtitle)

        let values = UIStackView(arrangedSubviews: [
            Self.valueRow(
                symbol: "lock.shield",
                text: String(
                    localized: "Point to point over your own tailnet. No relay, no account, no analytics.")),
            Self.valueRow(
                symbol: "desktopcomputer",
                text: String(
                    localized: "Needs a computer on that tailnet running opencode or Claude Code.")),
            Self.valueRow(
                symbol: "bell.badge",
                text: String(
                    localized: "Turns finish on your Lock Screen while the phone is in your pocket.")),
        ])
        values.axis = .vertical
        values.spacing = Theme.Spacing.m

        let setUp = PrimaryButton(title: String(localized: "Set up my machine"))
        setUp.addAction(UIAction { [weak self] _ in self?.setUpTapped() }, for: .touchUpInside)

        var demoConfig = Theme.Glass.buttonConfiguration()
        demoConfig.title = String(localized: "Try the demo")
        demoConfig.subtitle = String(localized: "Two sample servers. Nothing real.")
        demoConfig.image = UIImage(
            systemName: "play.circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        demoConfig.imagePadding = Theme.Spacing.s
        demoConfig.buttonSize = .large
        demoConfig.cornerStyle = .large
        demoConfig.baseForegroundColor = Theme.Color.label
        demoConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var out = $0
            out.font = Theme.Font.headline()
            return out
        }
        demoConfig.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var out = $0
            out.font = .preferredFont(forTextStyle: .caption2)
            out.foregroundColor = Theme.Color.secondaryLabel
            return out
        }
        let demo = UIButton(configuration: demoConfig)
        demo.addAction(UIAction { [weak self] _ in self?.demoTapped() }, for: .touchUpInside)

        var existingConfig = UIButton.Configuration.plain()
        existingConfig.title = String(localized: "I already have a server running")
        existingConfig.baseForegroundColor = Theme.Color.accent
        existingConfig.contentInsets = NSDirectionalEdgeInsets(
            top: 12, leading: 12, bottom: 12, trailing: 12)
        let existing = UIButton(configuration: existingConfig)
        existing.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                self?.pushSetup(focusingConnect: true)
            }, for: .touchUpInside)

        let footnote = UILabel()
        footnote.text = String(
            localized: "No account, no sign-in, no telemetry. App, engine, and bridge are GPL-3.0.")
        footnote.font = .preferredFont(forTextStyle: .caption2)
        footnote.adjustsFontForContentSizeCategory = true
        footnote.textColor = Theme.Color.tertiaryLabel
        footnote.textAlignment = .center
        footnote.numberOfLines = 0
        Self.letWrap(footnote)

        let heroBox = UIView()
        heroBox.translatesAutoresizingMaskIntoConstraints = false
        heroBox.addSubview(hero)
        NSLayoutConstraint.activate([
            hero.topAnchor.constraint(equalTo: heroBox.topAnchor),
            hero.bottomAnchor.constraint(equalTo: heroBox.bottomAnchor),
            hero.centerXAnchor.constraint(equalTo: heroBox.centerXAnchor),
            hero.widthAnchor.constraint(lessThanOrEqualTo: heroBox.widthAnchor),
            hero.widthAnchor.constraint(lessThanOrEqualToConstant: 320).withPriority(
                UILayoutPriority(999)),
            hero.widthAnchor.constraint(
                equalTo: heroBox.widthAnchor, multiplier: 1, constant: 0).withPriority(
                    UILayoutPriority(998)),
        ])

        column.axis = .vertical
        column.spacing = Theme.Spacing.l
        [heroBox, headline, subtitle, values, setUp, demo, existing, footnote].forEach(
            column.addArrangedSubview)
        column.setCustomSpacing(Theme.Spacing.xxl, after: heroBox)
        column.setCustomSpacing(Theme.Spacing.s, after: headline)
        column.setCustomSpacing(Theme.Spacing.xl, after: subtitle)
        column.setCustomSpacing(Theme.Spacing.xxl, after: values)
        column.setCustomSpacing(Theme.Spacing.m, after: setUp)
        column.setCustomSpacing(Theme.Spacing.s, after: demo)
        column.setCustomSpacing(Theme.Spacing.l, after: existing)
        column.translatesAutoresizingMaskIntoConstraints = false

        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(column)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.addSubview(box)
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            box.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            box.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            box.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            box.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            box.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),

            column.topAnchor.constraint(
                greaterThanOrEqualTo: box.topAnchor, constant: Theme.Spacing.xl),
            column.bottomAnchor.constraint(lessThanOrEqualTo: box.bottomAnchor, constant: -Theme.Spacing.xl),
            column.centerYAnchor.constraint(equalTo: box.centerYAnchor).withPriority(.defaultLow),
            column.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            column.widthAnchor.constraint(
                lessThanOrEqualTo: box.widthAnchor, constant: -2 * Theme.Spacing.l),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            column.widthAnchor.constraint(
                equalTo: box.widthAnchor, constant: -2 * Theme.Spacing.l)
                .withPriority(UILayoutPriority(999)),
        ])
    }

    /// A multi-line label defends its longest line at the same priority a column
    /// uses to fit the screen, and that tie is how a headline decides the width
    /// of everything under it. Text that is meant to wrap must say so.
    private static func letWrap(_ label: UILabel) {
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private static func valueRow(symbol: String, text: String) -> UIView {
        let icon = UIImageView(
            image: UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)))
        icon.tintColor = Theme.Color.accent
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.isAccessibilityElement = false

        let label = UILabel()
        label.text = text
        label.font = Theme.Font.footnote()
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.secondaryLabel
        label.numberOfLines = 0
        letWrap(label)

        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.spacing = Theme.Spacing.m
        row.alignment = .firstBaseline
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 22)])
        return row
    }

    private func setUpTapped() {
        Theme.Haptics.tap()
        pushSetup(focusingConnect: false)
    }

    private func pushSetup(focusingConnect: Bool) {
        guard navigationController?.topViewController === self else { return }
        navigationController?.pushViewController(makeSetup(), animated: true)
        if focusingConnect { setup?.startOnConnectStep = true }
    }

    /// `tailscode://connect?host=…&port=…` — a link the machine can print, texted
    /// or AirDropped to the phone, so the address never has to be transcribed. It
    /// only ever prefills; nothing is saved until the user connects.
    func openSetup(prefilling address: String) {
        if let setup {
            setup.prefill(address: address)
            return
        }
        let setup = makeSetup()
        navigationController?.pushViewController(setup, animated: true)
        setup.prefill(address: address)
    }

    private var setup: ServerSetupViewController? {
        navigationController?.viewControllers.compactMap { $0 as? ServerSetupViewController }.last
    }

    private func makeSetup() -> ServerSetupViewController {
        let setup = ServerSetupViewController(mode: .firstRun)
        setup.onConnected = onConnected
        setup.onTryDemo = { [weak self] in self?.demoTapped() }
        return setup
    }

    private func demoTapped() {
        Theme.Haptics.success()
        ConnectionController.shared.enterDemoMode()
        AppLogger.lifecycle.info("demo mode entered from welcome")
        onConnected?()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override init(nibName: String?, bundle: Bundle?) { super.init(nibName: nibName, bundle: bundle) }
}

extension NSLayoutConstraint {
    /// Lets a constraint carry its priority inline, so a stack of anchors that
    /// only differ in priority still reads as one list.
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

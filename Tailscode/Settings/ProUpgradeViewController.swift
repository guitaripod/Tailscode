import StoreKit
import TailscodeCore
import UIKit

/// The Pro unlock + tip jar sheet. Shown only when a gate is touched or the
/// Settings row is tapped — never on launch, never on a timer.
@MainActor
final class ProUpgradeViewController: UIViewController {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let purchaseButton = PrimaryButton(title: String(localized: "Unlock Pro"))
    private let restoreButton = UIButton(type: .system)
    private let tipStack = UIStackView()
    private let tipHeader = UILabel()
    private let statusLabel = UILabel()
    private var proProduct: Product?
    private let lead: Lead

    /// Which perk brought somebody here, so the sheet leads with the thing they touched rather than
    /// the general case.
    enum Lead {
        case general
        case delegate
    }

    init(lead: Lead = .general) {
        self.lead = lead
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func present(from presenter: UIViewController, lead: Lead = .general) {
        let nav = UINavigationController(rootViewController: ProUpgradeViewController(lead: lead))
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(nav, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Tailscode Pro"
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close))
        build()
        NotificationCenter.default.addObserver(
            self, selector: #selector(proStateChanged), name: ProStore.didChange, object: nil)
        Task { await load() }
    }

    @objc private func proStateChanged() {
        guard ProStore.shared.isPro else { return }
        purchaseButton.setTitle(String(localized: "You're a supporter — thank you ♥"))
        purchaseButton.isEnabled = false
        statusLabel.text = nil
    }

    private func build() {
        let hero = Theme.Glass.view()
        hero.layer.cornerRadius = Theme.Radius.card
        hero.layer.cornerCurve = .continuous
        hero.clipsToBounds = true
        hero.isUserInteractionEnabled = false
        hero.translatesAutoresizingMaskIntoConstraints = false

        let heroIcon = UIImageView(
            image: UIImage(
                systemName: lead == .delegate ? DelegateEntryPoint.symbol : "sparkles",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .medium)))
        heroIcon.tintColor = Theme.Color.accent
        heroIcon.contentMode = .scaleAspectFit

        let heroTitle = UILabel()
        heroTitle.text = lead == .delegate ? DelegateProGate.requirement : String(localized: "Support Tailscode")
        heroTitle.font = Theme.Ramp.font(.cardTitle)
        heroTitle.textAlignment = .center

        let heroBody = UILabel()
        heroBody.text = lead == .delegate ? DelegateProGate.pitch : ProOffer.pitch
        heroBody.font = Theme.Ramp.font(.panelLabel)
        heroBody.textColor = Theme.Color.secondaryLabel
        heroBody.textAlignment = .center
        heroBody.numberOfLines = 0

        let heroStack = UIStackView(arrangedSubviews: [heroIcon, heroTitle, heroBody])
        heroStack.axis = .vertical
        heroStack.spacing = Theme.Spacing.s
        heroStack.translatesAutoresizingMaskIntoConstraints = false

        let heroContainer = UIView()
        heroContainer.translatesAutoresizingMaskIntoConstraints = false
        heroContainer.addSubview(hero)
        heroContainer.addSubview(heroStack)
        NSLayoutConstraint.activate([
            hero.topAnchor.constraint(equalTo: heroContainer.topAnchor),
            hero.bottomAnchor.constraint(equalTo: heroContainer.bottomAnchor),
            hero.leadingAnchor.constraint(equalTo: heroContainer.leadingAnchor),
            hero.trailingAnchor.constraint(equalTo: heroContainer.trailingAnchor),
            heroStack.topAnchor.constraint(equalTo: heroContainer.topAnchor, constant: Theme.Spacing.l),
            heroStack.bottomAnchor.constraint(equalTo: heroContainer.bottomAnchor, constant: -Theme.Spacing.l),
            heroStack.leadingAnchor.constraint(equalTo: heroContainer.leadingAnchor, constant: Theme.Spacing.l),
            heroStack.trailingAnchor.constraint(equalTo: heroContainer.trailingAnchor, constant: -Theme.Spacing.l),
        ])

        stack.axis = .vertical
        stack.spacing = Theme.Spacing.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(heroContainer)
        stack.setCustomSpacing(Theme.Spacing.xl, after: heroContainer)

        let delegatePerk = (DelegateProGate.perk.symbol, DelegateProGate.perk.text)
        for (symbol, text) in [delegatePerk] + [
            (
                "server.rack",
                String(
                    localized:
                        "Connect unlimited servers — one unified session list across every machine on your tailnet"
                )
            ),
            (
                "bolt.badge.clock",
                String(
                    localized:
                        "Concurrent Live Activities for every running session, not just one")
            ),
            (
                "heart.fill",
                String(localized: "Supporter badge, and a say in what gets built next")
            ),
        ] {
            stack.addArrangedSubview(featureRow(symbol: symbol, text: text))
        }

        purchaseButton.addTarget(self, action: #selector(purchaseTapped), for: .touchUpInside)
        stack.setCustomSpacing(Theme.Spacing.xl, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(purchaseButton)

        restoreButton.setTitle(String(localized: "Restore purchases"), for: .normal)
        restoreButton.titleLabel?.font = Theme.Ramp.font(.panelFootnote)
        restoreButton.addTarget(self, action: #selector(restoreTapped), for: .touchUpInside)
        stack.addArrangedSubview(restoreButton)

        tipHeader.text = String(localized: "Or leave a tip — no unlock, just thanks")
        tipHeader.font = Theme.Ramp.font(.panelFootnote)
        tipHeader.textColor = Theme.Color.secondaryLabel
        tipHeader.textAlignment = .center
        tipHeader.isHidden = true
        stack.setCustomSpacing(Theme.Spacing.xl, after: restoreButton)
        stack.addArrangedSubview(tipHeader)

        tipStack.axis = .horizontal
        tipStack.spacing = Theme.Spacing.s
        tipStack.distribution = .fillEqually
        stack.addArrangedSubview(tipStack)

        statusLabel.font = Theme.Ramp.font(.panelFootnote)
        statusLabel.textColor = Theme.Color.secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        stack.addArrangedSubview(statusLabel)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.l),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xl),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
            stack.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -2 * Theme.Spacing.l),
        ])
    }

    private func featureRow(symbol: String, text: String) -> UIView {
        let icon = UIImageView(
            image: UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)))
        icon.tintColor = Theme.Color.accent
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = UILabel()
        label.text = text
        label.font = Theme.Ramp.font(.panelLabel)
        label.numberOfLines = 0

        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.spacing = Theme.Spacing.m
        row.alignment = .top
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 26)])
        return row
    }

    private func load() async {
        if ProStore.shared.isPro {
            purchaseButton.setTitle(String(localized: "You're a supporter — thank you ♥"))
            purchaseButton.isEnabled = false
        } else {
            purchaseButton.isEnabled = false
            purchaseButton.setLoading(true)
        }
        let (pro, tips) = await ProStore.shared.products()
        proProduct = pro
        if !ProStore.shared.isPro {
            purchaseButton.setLoading(false)
            if let pro {
                purchaseButton.isEnabled = true
                purchaseButton.setTitle(String(localized: "Unlock Pro · \(pro.displayPrice)"))
                statusLabel.text = nil
            } else {
                purchaseButton.isEnabled = true
                purchaseButton.setTitle(String(localized: "Store unavailable — tap to retry"))
                statusLabel.text = String(
                    localized: "Couldn't reach the App Store. Check your connection and try again.")
            }
        }
        tipStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for tip in tips {
            var config = Theme.Glass.buttonConfiguration()
            config.title = tip.displayPrice
            config.baseForegroundColor = Theme.Color.label
            let button = UIButton(configuration: config)
            button.addAction(
                UIAction { [weak self] _ in self?.tip(tip) }, for: .touchUpInside)
            tipStack.addArrangedSubview(button)
        }
        tipStack.isHidden = tips.isEmpty
        tipHeader.isHidden = tips.isEmpty
    }

    @objc private func purchaseTapped() {
        guard let proProduct else {
            Theme.Haptics.tap()
            statusLabel.text = nil
            Task { await load() }
            return
        }
        Theme.Haptics.tap()
        purchaseButton.setLoading(true)
        Task {
            defer { purchaseButton.setLoading(false) }
            do {
                switch try await ProStore.shared.purchase(proProduct) {
                case .success:
                    Theme.Haptics.success()
                    dismiss(animated: true)
                case .pending:
                    statusLabel.text = String(
                        localized: "Waiting for approval — Pro unlocks automatically once approved.")
                case .unverified:
                    statusLabel.text = String(
                        localized: "Purchase couldn't be verified — try Restore purchases later.")
                    Theme.Haptics.error()
                case .cancelled:
                    break
                }
            } catch {
                statusLabel.text = String(
                    localized: "Purchase failed: \(error.localizedDescription)")
                Theme.Haptics.error()
            }
        }
    }

    private func tip(_ product: Product) {
        Theme.Haptics.tap()
        tipStack.isUserInteractionEnabled = false
        Task {
            defer { tipStack.isUserInteractionEnabled = true }
            do {
                switch try await ProStore.shared.purchase(product) {
                case .success:
                    Theme.Haptics.success()
                    statusLabel.text = String(localized: "Thank you! 🙏")
                case .pending:
                    statusLabel.text = String(localized: "Waiting for approval — thank you!")
                case .unverified:
                    statusLabel.text = String(
                        localized: "Purchase couldn't be verified — please try again later.")
                case .cancelled:
                    break
                }
            } catch {
                statusLabel.text = String(
                    localized: "Purchase failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func restoreTapped() {
        Theme.Haptics.tap()
        restoreButton.isEnabled = false
        statusLabel.text = String(localized: "Restoring…")
        Task {
            defer { restoreButton.isEnabled = true }
            do {
                try await ProStore.shared.restore()
                if ProStore.shared.isPro {
                    Theme.Haptics.success()
                    dismiss(animated: true)
                } else {
                    statusLabel.text = String(localized: "No previous purchase found for this Apple ID.")
                }
            } catch StoreKitError.userCancelled {
                statusLabel.text = nil
            } catch {
                statusLabel.text = String(localized: "Restore failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func close() { dismiss(animated: true) }
}

import MidgarCommerce
import MidgarCore
import TailscodeCore
import UIKit

/// The Pro sheet. Shown only when a gate is touched or the Settings row is tapped — never on launch, never on a timer.
/// It leads with the person (`ProPersonalDetails`) and lists what they get; nothing on it asks for anything. A copy that
/// never had a Pro week is offered one here, as the primary action, with the purchase beside it; whichever the person
/// takes, the thing that brought them here carries on.
@MainActor
final class ProUpgradeViewController: UIViewController {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let offersWeek = ProAccess.shared.canStartProWeek
    private lazy var purchaseButton: UIButton & WorkingButton =
        offersWeek
        ? SecondaryButton(title: String(localized: "Unlock Pro")) : PrimaryButton(title: String(localized: "Unlock Pro"))
    private let weekButton = PrimaryButton(title: ProWeek.startTitle)
    private let restoreButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private var proProduct: StoreProduct?
    private let lead: Lead
    private let facts = ProPersonalDetails.Facts.onThisDevice
    private let placement: MidgarSignal.Placement
    private var hasReportedShown = false
    private let onAccess: (() -> Void)?

    /// Which perk brought somebody here, so the sheet leads with the thing they touched rather than
    /// the general case.
    enum Lead {
        case general
        case delegate
    }

    /// - Parameters:
    ///   - placement: Where the sheet was opened from, sent with `paywall.view`.
    ///   - onAccess: What to carry on with once Pro is open, by the week, a purchase or a restore, run after the sheet
    ///     has gone.
    init(lead: Lead = .general, placement: MidgarSignal.Placement, onAccess: (() -> Void)? = nil) {
        self.lead = lead
        self.placement = placement
        self.onAccess = onAccess
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func present(
        from presenter: UIViewController, lead: Lead = .general, placement: MidgarSignal.Placement,
        onAccess: (() -> Void)? = nil
    ) {
        let nav = UINavigationController(
            rootViewController: ProUpgradeViewController(lead: lead, placement: placement, onAccess: onAccess))
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            if ProAccess.shared.canStartProWeek { sheet.selectedDetentIdentifier = .large }
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
            self, selector: #selector(proStateChanged), name: ProAccess.didChange, object: nil)
        Task { await load() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ReviewPromptPolicy.notePaywallShown()
        reportShownOnce()
    }

    /// Sends `paywall.view` with where the sheet was opened from, once per sheet: a page pushed over it and popped
    /// again is not a second view.
    private func reportShownOnce() {
        guard !hasReportedShown else { return }
        hasReportedShown = true
        MidgarPaywallMoments.noteShown(placement: placement)
    }

    @objc private func proStateChanged() {
        guard ProAccess.shared.isPro else { return }
        purchaseButton.setTitle(ProOffer.owned)
        purchaseButton.isEnabled = false
        weekButton.isEnabled = false
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
        heroTitle.text = lead == .delegate ? DelegateProGate.requirement : ProPersonalDetails.headline(facts)
        heroTitle.font = Theme.Ramp.font(.cardTitle)
        heroTitle.textAlignment = .center
        heroTitle.numberOfLines = 0

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
        if let endsAt = ProAccess.shared.proWeekEndsAt {
            let running = UILabel()
            running.text = ProWeek.runningLine(endsAt: endsAt)
            running.font = Theme.Ramp.font(.panelLabel)
            running.textColor = Theme.Color.accent
            running.textAlignment = .center
            running.numberOfLines = 0
            stack.addArrangedSubview(running)
            stack.setCustomSpacing(Theme.Spacing.xl, after: running)
        }

        for perk in ProPersonalDetails.perks(facts, liveActivities: true) {
            stack.addArrangedSubview(featureRow(symbol: perk.symbol, text: perk.text))
        }

        purchaseButton.addTarget(self, action: #selector(purchaseTapped), for: .touchUpInside)
        stack.setCustomSpacing(Theme.Spacing.xl, after: stack.arrangedSubviews.last!)
        if offersWeek {
            let card = weekCard()
            stack.addArrangedSubview(card)
            stack.setCustomSpacing(Theme.Spacing.m, after: card)
        }
        stack.addArrangedSubview(purchaseButton)

        restoreButton.setTitle(String(localized: "Restore purchases"), for: .normal)
        restoreButton.titleLabel?.font = Theme.Ramp.font(.panelFootnote)
        restoreButton.addTarget(self, action: #selector(restoreTapped), for: .touchUpInside)
        stack.addArrangedSubview(restoreButton)

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
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.l),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xl),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * Theme.Spacing.l),
        ])
    }

    /// The week as its own card: what it opens, that it costs nothing and what happens after, then the button that starts it.
    private func weekCard() -> UIView {
        let title = UILabel()
        title.text = ProWeek.offerTitle
        title.font = Theme.Ramp.font(.cardTitle)
        title.textAlignment = .center
        title.numberOfLines = 0
        title.accessibilityTraits = .header

        let body = UILabel()
        body.text = ProWeek.offerBody
        body.font = Theme.Ramp.font(.panelFootnote)
        body.textColor = Theme.Color.secondaryLabel
        body.textAlignment = .center
        body.numberOfLines = 0

        weekButton.addTarget(self, action: #selector(startWeekTapped), for: .touchUpInside)
        weekButton.accessibilityIdentifier = "pro.startWeek"

        let column = UIStackView(arrangedSubviews: [title, body, weekButton])
        column.axis = .vertical
        column.spacing = Theme.Spacing.s
        column.setCustomSpacing(Theme.Spacing.m, after: body)
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.l, leading: Theme.Spacing.l, bottom: Theme.Spacing.l, trailing: Theme.Spacing.l)
        column.backgroundColor = Theme.Color.groupedSurface
        column.layer.cornerRadius = Theme.Radius.card
        column.layer.cornerCurve = .continuous
        return column
    }

    @objc private func startWeekTapped() {
        let servers = ConnectionController.shared.savedProfiles.filter { !$0.id.hasPrefix(DemoWorld.profilePrefix) }.count
        guard ProAccess.shared.startProWeek(servers: servers) else { return }
        Theme.Haptics.success()
        finishWithAccess()
    }

    /// Closes the sheet and carries on with whatever brought the person here.
    private func finishWithAccess() {
        let onAccess = onAccess
        dismiss(animated: true) { onAccess?() }
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
        if ProAccess.shared.isPro {
            purchaseButton.setTitle(ProOffer.owned)
            purchaseButton.isEnabled = false
        } else {
            purchaseButton.isEnabled = false
            purchaseButton.setLoading(true)
        }
        let pro = await ProAccess.shared.proProduct()
        proProduct = pro
        if !ProAccess.shared.isPro {
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
                switch try await ProAccess.shared.purchase(proProduct) {
                case .success:
                    Theme.Haptics.success()
                    finishWithAccess()
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
                statusLabel.text = error.localizedDescription
                Theme.Haptics.error()
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
                switch try await ProAccess.shared.restore() {
                case .restored:
                    Theme.Haptics.success()
                    finishWithAccess()
                case .nothingFound:
                    statusLabel.text = String(localized: "No previous purchase found for this Apple ID.")
                case .cancelled:
                    statusLabel.text = nil
                }
            } catch {
                statusLabel.text = error.localizedDescription
            }
        }
    }

    @objc private func close() { dismiss(animated: true) }
}

/// A button that can show it is working and change its title, whichever style it is drawn in.
@MainActor
protocol WorkingButton: UIButton {
    func setLoading(_ loading: Bool)
    func setTitle(_ title: String)
}

extension PrimaryButton: WorkingButton {}
extension SecondaryButton: WorkingButton {}

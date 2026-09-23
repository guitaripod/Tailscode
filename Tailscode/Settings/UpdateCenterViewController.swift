import SafariServices
import TailscodeCore
import UIKit

/// A card's press, carried out. Shared by the Software Updates screen and a server's own screen,
/// so a press drawn in two places is kept one way — and the question asked before a restart is the
/// one Core wrote, word for word, on every desk.
@MainActor
enum UpdatePress {
    static func perform(
        _ action: UpdateCard.Action, for reading: UpdateReading, from presenter: UIViewController
    ) {
        switch action.kind {
        case .invitation(let invitation):
            take(invitation, action: action, reading: reading, from: presenter)
        case .setAside:
            Theme.Haptics.selection()
            UpdateLedger.acknowledge(reading)
        case .showLog:
            Theme.Haptics.tap()
            let log = UpdateLogViewController(title: reading.title, log: reading.log ?? "")
            presenter.present(UINavigationController(rootViewController: log), animated: true)
        case .checkNow:
            Theme.Haptics.tap()
            Task { await UpdateMonitor.check(reading.component) }
        }
    }

    private static func take(
        _ invitation: UpdateInvitation, action: UpdateCard.Action, reading: UpdateReading,
        from presenter: UIViewController
    ) {
        switch invitation {
        case .installHere, .restartHere:
            guard let confirmation = action.confirmation else {
                start(reading)
                return
            }
            let alert = UIAlertController(
                title: confirmation.title, message: confirmation.message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
            alert.addAction(
                UIAlertAction(title: confirmation.confirm, style: .default) { _ in
                    start(reading)
                })
            presenter.present(alert, animated: true)
        case .openStore(let url):
            Theme.Haptics.tap()
            open(url)
        case .copyCommand(let command):
            UIPasteboard.general.string = command
            Theme.Haptics.success()
            let alert = UIAlertController(
                title: String(localized: "Command copied"),
                message: [command, invitation.promise].compactMap { $0 }.joined(separator: "\n\n"),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
            presenter.present(alert, animated: true)
        case .openPage(let url):
            Theme.Haptics.tap()
            guard let link = URL(string: url), link.scheme?.hasPrefix("http") == true else {
                open(url)
                return
            }
            presenter.present(SFSafariViewController(url: link), animated: true)
        case .recheck:
            Theme.Haptics.tap()
            Task { await UpdateMonitor.check(reading.component) }
        }
    }

    private static func start(_ reading: UpdateReading) {
        Theme.Haptics.tap()
        Task { await UpdateMonitor.perform(reading.component) }
    }

    private static func open(_ url: String) {
        guard let link = URL(string: url) else { return }
        UIApplication.shared.open(link)
    }

    /// Turning a machine's own policy on or off. The card draws the switch from what the machine
    /// said; a refusal puts it back there and says why.
    static func setAutomation(
        _ enabled: Bool, for reading: UpdateReading, card: UpdateCardView,
        from presenter: UIViewController
    ) {
        Task {
            guard let failure = await UpdateMonitor.setAutoUpdate(reading.component, enabled) else {
                return
            }
            card.restoreAutomation()
            Theme.Haptics.warning()
            let alert = UIAlertController(
                title: String(localized: "\(reading.title) didn't change its update setting"),
                message: failure, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
            presenter.present(alert, animated: true)
        }
    }
}

/// What a failed update printed, readable and copyable.
@MainActor
final class UpdateLogViewController: UIViewController {
    private let log: String

    init(title: String, log: String) {
        self.log = log
        super.init(nibName: nil, bundle: nil)
        self.title = String(localized: "\(title) — update log")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        let text = UITextView()
        text.text = log
        text.isEditable = false
        text.font = Theme.Ramp.font(.code)
        text.adjustsFontForContentSizeCategory = true
        text.textColor = Theme.Color.label
        text.backgroundColor = .clear
        text.textContainerInset = UIEdgeInsets(
            top: Theme.Spacing.l, left: Theme.Spacing.m, bottom: Theme.Spacing.l,
            right: Theme.Spacing.m)
        text.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: view.topAnchor),
            text.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            text.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc"),
            primaryAction: UIAction { [weak self] _ in
                UIPasteboard.general.string = self?.log
                Theme.Haptics.success()
            })
    }
}

/// Every machine in the picture and what it is running, one card each.
///
/// The screen leads with the one line that sums it up — something to update, something updating,
/// or nothing to do — and a single press for every server that can take its own update. Each card
/// below is Core's: what is new and the press that takes it, the steps while it runs, what it
/// became once it lands. Nothing here decides what a verdict means.
///
/// It renders from `UpdateLedger` the instant it opens and corrects itself as answers land, and the
/// cards are rewritten in place: a job lands a new reading every two seconds, and a screen that
/// rebuilt itself on each would move the button under the reader's thumb.
@MainActor
final class UpdateCenterViewController: UIViewController {
    static func present(from presenter: UIViewController) {
        let center = UpdateCenterViewController()
        guard let nav = presenter.navigationController else {
            presenter.present(UINavigationController(rootViewController: center), animated: true)
            return
        }
        nav.pushViewController(center, animated: true)
    }

    private let scroll = UIScrollView()
    private let column = UIStackView()
    private let heroTitle = UILabel()
    private let heroDetail = UILabel()
    private let heroChecked = UILabel()
    private let everythingButton = UIButton(type: .system)
    private let hero = UIStackView()
    private let emptyLabel = UILabel()
    private let refresher = UIRefreshControl()
    private var cards: [String: UpdateCardView] = [:]
    private var order: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Software Updates")
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            primaryAction: UIAction { [weak self] _ in self?.recheck() })
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "Check now")
        build()
        render()
        NotificationCenter.default.addObserver(
            self, selector: #selector(changed), name: UpdateMonitor.didChange, object: nil)
        UpdateMonitor.checkIfDue()
    }

    @objc private func changed() { render() }

    private func build() {
        scroll.alwaysBounceVertical = true
        scroll.refreshControl = refresher
        refresher.addAction(UIAction { [weak self] _ in self?.recheck() }, for: .valueChanged)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        heroTitle.font = Theme.Ramp.font(.headline)
        heroTitle.adjustsFontForContentSizeCategory = true
        heroTitle.textColor = Theme.Color.label
        heroTitle.numberOfLines = 0
        heroTitle.accessibilityTraits = .header
        heroDetail.font = Theme.Ramp.font(.panelDetail)
        heroDetail.adjustsFontForContentSizeCategory = true
        heroDetail.textColor = Theme.Color.secondaryLabel
        heroDetail.numberOfLines = 0
        heroChecked.font = Theme.Ramp.font(.panelFootnote)
        heroChecked.adjustsFontForContentSizeCategory = true
        heroChecked.textColor = Theme.Color.tertiaryLabel

        var everything = Theme.Glass.buttonConfiguration(prominent: true)
        everything.cornerStyle = .capsule
        everything.image = UIImage(systemName: "arrow.down.circle")
        everything.imagePadding = Theme.Spacing.xs
        everythingButton.configuration = everything
        everythingButton.addAction(
            UIAction { [weak self] _ in self?.updateEverything() }, for: .touchUpInside)

        for view: UIView in [heroTitle, heroDetail, everythingButton, heroChecked] {
            hero.addArrangedSubview(view)
        }
        hero.axis = .vertical
        hero.alignment = .leading
        hero.spacing = Theme.Spacing.xs
        hero.setCustomSpacing(Theme.Spacing.m, after: heroDetail)
        hero.setCustomSpacing(Theme.Spacing.m, after: everythingButton)
        hero.isLayoutMarginsRelativeArrangement = true
        hero.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0, leading: Theme.Spacing.xs, bottom: Theme.Spacing.xs,
            trailing: Theme.Spacing.xs)

        emptyLabel.text = String(
            localized: "Nothing has answered yet. Pull down to ask this app and every server what they are running.")
        emptyLabel.font = Theme.Ramp.font(.panelDetail)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = Theme.Color.secondaryLabel
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center

        column.axis = .vertical
        column.spacing = Theme.Spacing.l
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        let content = scroll.contentLayoutGuide
        let frame = scroll.frameLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: Theme.Spacing.l),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Theme.Spacing.xl),
            column.leadingAnchor.constraint(
                equalTo: view.readableContentGuide.leadingAnchor),
            column.trailingAnchor.constraint(
                equalTo: view.readableContentGuide.trailingAnchor),
            column.widthAnchor.constraint(
                lessThanOrEqualTo: frame.widthAnchor, constant: -2 * Theme.Spacing.l),
        ])
    }

    private func render() {
        let rollup = UpdateLedger.rollup()
        let snapshot = UpdateMonitor.snapshot
        let ids = rollup.readings.map(\.id)
        if ids != order || column.arrangedSubviews.isEmpty {
            relayout(ids)
        }
        renderHero(rollup, snapshot: snapshot)
        for reading in rollup.readings {
            cards[reading.id]?.apply(
                UpdateCard(
                    reading, acknowledged: rollup.isAcknowledged(reading),
                    busy: snapshot.isBusy(reading.component)))
        }
        emptyLabel.isHidden = !rollup.readings.isEmpty
        if refresher.isRefreshing, !snapshot.checking { refresher.endRefreshing() }
    }

    /// The column rebuilt around a new set — or a new order — of machines. The cards themselves
    /// are kept and moved rather than made again, so one that merely moved up the list carries
    /// what its reader had opened with it.
    private func relayout(_ ids: [String]) {
        for stale in Set(cards.keys).subtracting(ids) { cards.removeValue(forKey: stale) }
        for view in column.arrangedSubviews { view.removeFromSuperview() }
        column.addArrangedSubview(hero)
        for id in ids {
            let card = cards[id] ?? makeCard(id)
            cards[id] = card
            column.addArrangedSubview(card)
        }
        column.addArrangedSubview(emptyLabel)
        order = ids
    }

    private func makeCard(_ id: String) -> UpdateCardView {
        let card = UpdateCardView(style: .standalone)
        card.onAction = { [weak self] action in
            guard let self, let reading = self.reading(id) else { return }
            UpdatePress.perform(action, for: reading, from: self)
        }
        card.onAutomation = { [weak self, weak card] enabled in
            guard let self, let card, let reading = self.reading(id) else { return }
            UpdatePress.setAutomation(enabled, for: reading, card: card, from: self)
        }
        return card
    }

    private func reading(_ id: String) -> UpdateReading? {
        UpdateLedger.rollup().readings.first { $0.id == id }
    }

    private func renderHero(_ rollup: UpdateRollup, snapshot: UpdateDriver.Snapshot) {
        heroTitle.text = rollup.headline
        heroDetail.text = rollup.readings.isEmpty ? nil : rollup.detail()
        heroDetail.isHidden = heroDetail.text?.isEmpty ?? true
        if let walk = snapshot.walk {
            everythingButton.isHidden = false
            everythingButton.isEnabled = false
            everythingButton.configuration?.title = String(
                localized: "Updating \(min(walk.done + 1, walk.total)) of \(walk.total)…")
        } else {
            everythingButton.isHidden = !rollup.canUpdateEverything
            everythingButton.isEnabled = true
            everythingButton.configuration?.title = String(
                localized: "Update all \(rollup.installableServers.count) servers")
        }
        if snapshot.checking {
            heroChecked.text = String(localized: "Checking every machine…")
        } else if let last = UpdateLedger.lastCheck() {
            heroChecked.text = String(localized: "Last checked \(RelativeWhen.ago(last))")
        } else {
            heroChecked.text = nil
        }
        heroChecked.isHidden = heroChecked.text == nil
    }

    private func recheck() {
        Theme.Haptics.tap()
        Task { [weak self] in
            await UpdateMonitor.checkAll()
            self?.refresher.endRefreshing()
        }
    }

    private func updateEverything() {
        let count = UpdateLedger.rollup().installableServers.count
        let alert = UIAlertController(
            title: String(localized: "Update all \(count) servers?"),
            message: String(
                localized:
                    "One at a time: each downloads and builds, then restarts once nothing is running on it."
            ),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Update all"), style: .default) { _ in
                Theme.Haptics.tap()
                Task { await UpdateMonitor.updateEverything() }
            })
        present(alert, animated: true)
    }
}

/// The gear on Home. It used to carry the update mark as a dot in its corner; the mark now has a
/// word of its own beside it (`UpdateChipButton`), so the gear is only the way to Settings.
@MainActor
final class SettingsGearButton: UIButton {
    private static let side: CGFloat = 34

    init() {
        super.init(frame: .zero)
        setImage(
            UIImage(
                systemName: "gearshape",
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)), for: .normal)
        accessibilityLabel = String(localized: "Settings")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.side, height: Self.side)
    }
}

/// The standing update mark, in words: `Update`, `2 updates`, `Updating`, `Update failed`.
///
/// A dot on a gear told a reader that something somewhere wanted attention and left them to find
/// out what. The chip says what, in the chrome beside the gear, and opens the screen that answers
/// it. It covers nothing and has no dismiss gesture — it goes when the fact it stands for stops
/// being true, or when the person sets that exact offer aside. It holds perfectly still unless a
/// machine is actually being updated, and then only its symbol turns.
@MainActor
final class UpdateChipButton: UIButton {
    private var turning = false

    init() {
        super.init(frame: .zero)
        var config = UIButton.Configuration.tinted()
        config.cornerStyle = .capsule
        config.buttonSize = .mini
        config.imagePadding = 4
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            textStyle: .caption1, scale: .medium)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = Theme.Ramp.font(.metricLabel)
            return attributes
        }
        configuration = config
        NotificationCenter.default.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ chip: UpdateChip) {
        configuration?.title = chip.title
        configuration?.image = UIImage(systemName: chip.symbol)
        configuration?.baseForegroundColor = chip.tone.color
        configuration?.baseBackgroundColor = chip.tone.color
        accessibilityLabel = chip.title
        accessibilityHint = String(localized: "Opens Software Updates")
        turning = chip.motion.isAnimated
        applyMotion()
    }

    @objc private func motionPreferenceChanged() { applyMotion() }

    private func applyMotion() {
        imageView?.removeAllSymbolEffects()
        guard turning, !UIAccessibility.isReduceMotionEnabled else { return }
        imageView?.addSymbolEffect(.rotate, options: .repeat(.continuous))
    }
}

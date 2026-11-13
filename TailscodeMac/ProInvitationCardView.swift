import AppKit
import TailscodeCore

/// The invitation to Pro, in the sidebar's footer where the update card stands: one card, drawn only while
/// `ProInvitation` says it is due, and gone for good on either button. A copy that can still start its Pro week is
/// handed the week by the card's own button; any other is told what Pro does and led to the Pro window.
@MainActor
final class ProInvitationCardView: NSView {
    var onUnlock: (() -> Void)?

    private let mark = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let acceptButton = NSButton()
    private let notNowButton = NSButton()
    private let column = FillingStack()
    private var price: String?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.card
        layer?.borderWidth = 1

        mark.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        mark.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        mark.contentTintColor = MacTheme.Color.accent
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        body.isSelectable = false
        body.translatesAutoresizingMaskIntoConstraints = false
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [mark, title, RowKit.spacer()])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = MacTheme.Spacing.s

        notNowButton.title = ProInvitation.secondaryAction
        for (button, action) in [
            (acceptButton, #selector(accept)), (notNowButton, #selector(notNow)),
        ] {
            button.setButtonType(.momentaryPushIn)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = MacTheme.Ramp.font(.control)
            button.target = self
            button.action = action
        }
        acceptButton.keyEquivalent = ""
        let buttons = NSStackView(views: [acceptButton, notNowButton, RowKit.spacer()])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = MacTheme.Spacing.s

        column.spacing = MacTheme.Spacing.s
        column.translatesAutoresizingMaskIntoConstraints = false
        for row in [header, body, buttons] { column.addArrangedSubview(row) }
        addSubview(column)
        let inset = MacTheme.Spacing.m
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            column.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: ProInvitation.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: ProAccess.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyTheme), name: MacTheme.Chrome.didRepaint, object: nil)
        applyTheme()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc func refresh() {
        let store = ProAccess.shared
        if store.isPro { ProInvitation.settle() }
        let due = store.sellsPro && ProInvitation.isDue(isPro: store.isPro)
        isHidden = !due
        let gift = ProInvitation.gift(canStartWeek: store.canStartProWeek)
        title.stringValue = ProInvitation.title(ProPersonalDetails.Facts(turns: ReviewPromptPolicy.successCount))
        body.stringValue = ProInvitation.body(gift)
        acceptButton.title = ProInvitation.primaryAction(gift, price: price)
        guard due, gift == .pro, price == nil else { return }
        Task { @MainActor [weak self] in
            guard let product = await store.proProduct() else { return }
            self?.price = product.displayPrice
            self?.refresh()
        }
    }

    @objc private func applyTheme() {
        layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
        layer?.borderColor = MacTheme.Color.separator.cgColor
        title.font = MacTheme.Ramp.font(.cardTitle)
        title.textColor = MacTheme.Color.label
        body.font = MacTheme.Ramp.font(.panelFootnote)
        body.textColor = MacTheme.Color.secondaryLabel
        mark.contentTintColor = MacTheme.Color.accent
        for button in [acceptButton, notNowButton] { button.font = MacTheme.Ramp.font(.control) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    /// A copy that can still start its Pro week starts it here, on the person's press, and the invitation is answered;
    /// any other copy opens the Pro window.
    @objc private func accept() {
        let servers = ServerDirectory.shared.savedProfiles.filter { !$0.id.hasPrefix(DemoWorld.profilePrefix) }.count
        if ProAccess.shared.startProWeek(servers: servers) {
            ProInvitation.settle()
            return
        }
        onUnlock?()
    }

    @objc private func notNow() {
        ProInvitation.dismiss()
    }
}

import AppKit
import TailscodeCore

/// The supporter invitation, in the sidebar's footer where the update card stands: one card,
/// drawn only while `SupporterInvitation` says it is due, and gone for good on either button.
@MainActor
final class SupporterCardView: NSView {
    var onUnlock: (() -> Void)?

    private let mark = NSImageView()
    private let title = NSTextField(labelWithString: SupporterInvitation.title)
    private let body = NSTextField(wrappingLabelWithString: SupporterInvitation.body)
    private let unlockButton = NSButton()
    private let notNowButton = NSButton()
    private let column = FillingStack()
    private var price: String?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.card
        layer?.borderWidth = 1

        mark.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)
        mark.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        mark.contentTintColor = MacTheme.Color.accent
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        body.isSelectable = false
        body.translatesAutoresizingMaskIntoConstraints = false
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [mark, title, RowKit.spacer()])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = MacTheme.Spacing.s

        notNowButton.title = SupporterInvitation.secondaryAction
        for (button, action) in [
            (unlockButton, #selector(unlock)), (notNowButton, #selector(notNow)),
        ] {
            button.setButtonType(.momentaryPushIn)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = MacTheme.Ramp.font(.control)
            button.target = self
            button.action = action
        }
        unlockButton.keyEquivalent = ""
        let buttons = NSStackView(views: [unlockButton, notNowButton, RowKit.spacer()])
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
            self, selector: #selector(refresh), name: SupporterInvitation.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: MacProStore.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyTheme), name: MacTheme.Chrome.didRepaint, object: nil)
        applyTheme()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc func refresh() {
        let store = MacProStore.shared
        if store.isPro { SupporterInvitation.settle() }
        let due = store.sellsPro && SupporterInvitation.isDue(isPro: store.isPro)
        isHidden = !due
        unlockButton.title = SupporterInvitation.primaryAction(price: price)
        guard due, price == nil else { return }
        Task { @MainActor [weak self] in
            guard let product = await store.products().pro else { return }
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
        for button in [unlockButton, notNowButton] { button.font = MacTheme.Ramp.font(.control) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    @objc private func unlock() {
        onUnlock?()
    }

    @objc private func notNow() {
        SupporterInvitation.dismiss()
    }
}

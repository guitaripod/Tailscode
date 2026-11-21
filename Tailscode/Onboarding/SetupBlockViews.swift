import CodingAgentKit
import TailscodeCore
import UIKit

extension FirstRunPlan.Way.Kind {
    var symbolName: String {
        switch self {
        case .scan: return "qrcode.viewfinder"
        case .link: return "link"
        case .install: return "terminal"
        case .tailnet: return "dot.radiowaves.left.and.right"
        }
    }
}

extension FirstRunPlan.Row.Glyph {
    var cardStatus: SetupStepCard.Status {
        switch self {
        case .waiting: return .pending
        case .current, .working, .attention: return .active
        case .proven: return .done
        }
    }

    var pillSymbol: String {
        switch self {
        case .proven: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .working: return "ellipsis.circle.fill"
        case .current, .waiting: return "circle.dashed"
        }
    }

    var pillTint: UIColor {
        switch self {
        case .proven: return Theme.Color.success
        case .attention: return Theme.Color.warning
        case .working, .current, .waiting: return Theme.Color.secondaryLabel
        }
    }
}

@MainActor
enum SetupLink {
    static func button(title: String, symbol: String? = "arrow.up.right") -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        if let symbol {
            config.image = UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            config.imagePlacement = .trailing
            config.imagePadding = Theme.Spacing.xs
        }
        config.baseForegroundColor = Theme.Color.accent
        config.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 0, bottom: 11, trailing: 0)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var out = $0
            out.font = Theme.Ramp.font(.panelDetail)
            return out
        }
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        return button
    }

    static func label(
        _ text: String, role: TypeRole = .panelDetail, color: UIColor = Theme.Color.secondaryLabel
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Ramp.font(role)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }
}

@MainActor
final class SetupWayRow: UIControl {
    convenience init(way: FirstRunPlan.Way) {
        self.init(
            symbol: way.kind.symbolName, tint: Theme.Color.accent, title: way.title,
            detail: way.detail)
    }

    /// An answer to first run's question, drawn as the same row a way in is: its mark in the
    /// agent's own colour, and a chevron, because the press goes somewhere.
    convenience init(choice: FirstRunPlan.AgentChoice) {
        self.init(
            symbol: choice.agent.symbolName, tint: choice.agent.brandColor, title: choice.title,
            detail: choice.detail)
    }

    init(symbol: String, tint: UIColor, title: String, detail: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Theme.Color.groupedBackground
        layer.cornerRadius = Theme.Radius.control
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.5

        let glyph = UIImageView(
            image: UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)))
        glyph.tintColor = tint
        glyph.contentMode = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let chevron = UIImageView(
            image: UIImage(
                systemName: "chevron.right",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.contentMode = .center
        chevron.translatesAutoresizingMaskIntoConstraints = false

        let text = UIStackView(arrangedSubviews: [
            SetupLink.label(title, role: .panelLabel, color: Theme.Color.label),
            SetupLink.label(detail, role: .panelFootnote),
        ])
        text.axis = .vertical
        text.spacing = 2
        text.isUserInteractionEnabled = false
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glyph)
        addSubview(text)
        addSubview(chevron)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            glyph.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            glyph.widthAnchor.constraint(equalToConstant: 22),
            text.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: Theme.Spacing.s),
            text.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.m),
            text.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -Theme.Spacing.s),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 22),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(title). \(detail)"
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: SetupWayRow, _) in view.applyBorder()
        }
        applyBorder()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    private func applyBorder() {
        layer.borderColor = Theme.Color.separator.resolvedColor(with: traitCollection).cgColor
    }
}

@MainActor
final class PasteBlockView: UIStackView {
    var onPaste: ((String) -> Void)?
    var onType: ((String) -> Void)?
    var onOffer: (() -> Void)?
    var onSubmit: (() -> Void)?

    let field = FormField(
        title: Localized.text("Address"), placeholder: "100.101.102.103",
        keyboard: .URL, contentType: .URL, returnKey: .go)
    private let offerButton = SetupLink.button(title: "", symbol: "doc.on.clipboard")
    private let hint = UILabel()
    private let messageCard = DiagnosisCardView()
    private var shownMessage: ConnectLinkReading.Message?

    init() {
        super.init(frame: .zero)
        axis = .vertical
        spacing = Theme.Spacing.s

        let pasteConfig = UIPasteControl.Configuration()
        pasteConfig.displayMode = .iconAndLabel
        pasteConfig.cornerStyle = .capsule
        pasteConfig.baseBackgroundColor = Theme.Color.groupedBackground
        let paste = UIPasteControl(configuration: pasteConfig)
        paste.target = self
        paste.translatesAutoresizingMaskIntoConstraints = false
        pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: ["public.url", "public.plain-text", "public.text"])

        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        paste.setContentHuggingPriority(.required, for: .horizontal)
        paste.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = AdaptiveRow([field, paste], alignment: .bottom)
        row.distribution = .fill

        field.textField.addAction(
            UIAction { [weak self] _ in self?.edited() }, for: .editingChanged)
        field.onSubmit = { [weak self] in self?.onSubmit?() }

        hint.font = Theme.Font.scaledMono(.caption1)
        hint.adjustsFontForContentSizeCategory = true
        hint.textColor = Theme.Color.tertiaryLabel
        hint.numberOfLines = 0
        hint.isHidden = true

        offerButton.isHidden = true
        offerButton.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                self?.onOffer?()
            }, for: .touchUpInside)

        [offerButton, row, hint, messageCard].forEach(addArrangedSubview)
        setCustomSpacing(Theme.Spacing.xs, after: row)
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) })
        else { return }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
            guard let text = value as? String else { return }
            Task { @MainActor in self?.deliver(pasted: text) }
        }
    }

    private func deliver(pasted text: String) {
        field.textField.resignFirstResponder()
        Theme.Haptics.tap()
        onPaste?(text)
    }

    private func edited() {
        let text = field.text
        if text.range(of: "tailscode://", options: .caseInsensitive) != nil {
            onPaste?(text)
        } else {
            onType?(text)
        }
    }

    func apply(_ paste: FirstRunPlan.Paste) {
        field.textField.placeholder = paste.placeholder
        if !field.textField.isFirstResponder, field.text != paste.text { field.setText(paste.text) }
        hint.text = paste.reading
        hint.isHidden = paste.reading == nil
        if let offer = paste.offer {
            offerButton.configuration?.title = offer
            offerButton.isHidden = false
        } else {
            offerButton.isHidden = true
        }
        guard paste.message != shownMessage else { return }
        shownMessage = paste.message
        guard let message = paste.message else {
            messageCard.hide()
            return
        }
        messageCard.show(
            ConnectDiagnosis(
                symbol: "exclamationmark.triangle", title: message.title, detail: message.detail,
                fix: .none, actionTitle: nil),
            tint: Theme.Color.warning)
    }
}

@MainActor
final class PasswordBlockView: UIStackView {
    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?

    let field = FormField(
        title: Localized.text("Password"), placeholder: Localized.text("From your server"),
        secure: true, contentType: .password, returnKey: .go)
    private let note = SetupLink.label("", role: .panelFootnote, color: Theme.Color.tertiaryLabel)

    init() {
        super.init(frame: .zero)
        axis = .vertical
        spacing = Theme.Spacing.xs
        field.textField.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.onChange?(self.field.text)
            }, for: .editingChanged)
        field.onSubmit = { [weak self] in self?.onSubmit?() }
        note.isHidden = true
        addArrangedSubview(field)
        addArrangedSubview(note)
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    func apply(_ password: FirstRunPlan.PasswordField) {
        if !field.textField.isFirstResponder, field.text != password.text {
            field.setText(password.text)
        }
        note.text = password.note
        note.isHidden = password.note == nil
    }
}

/// What a person does about Tailscale not being up on this device: open it, or read what it is.
/// The open press steps aside while the screen's one primary button is that same press, so the
/// screen never offers it twice.
@MainActor
final class TailscaleRemedyView: UIStackView {
    var onOpen: (() -> Void)?
    var onAbout: (() -> Void)?

    var showsOpenButton = true {
        didSet { open.isHidden = !showsOpenButton }
    }

    private let open: UIButton

    init() {
        var config = Theme.Glass.buttonConfiguration()
        config.title = Localized.text("Open Tailscale")
        config.image = UIImage(
            systemName: "arrow.up.forward.app",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        config.imagePadding = Theme.Spacing.xs
        config.baseForegroundColor = Theme.Color.label
        config.titleLineBreakMode = .byTruncatingTail
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        open = UIButton(configuration: config)
        super.init(frame: .zero)
        axis = .vertical
        alignment = .leading
        spacing = Theme.Spacing.xs
        open.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                self?.onOpen?()
            }, for: .touchUpInside)
        let about = SetupLink.button(title: Localized.text("What is Tailscale?"))
        about.addAction(UIAction { [weak self] _ in self?.onAbout?() }, for: .touchUpInside)
        addArrangedSubview(open)
        addArrangedSubview(about)
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
}

@MainActor
final class WaitingLineView: UIStackView {
    init(text: String) {
        super.init(frame: .zero)
        axis = .horizontal
        spacing = Theme.Spacing.s
        alignment = .center
        let spinner = ActivityBadgeView(pointSize: 16)
        spinner.working(true)
        addArrangedSubview(spinner)
        addArrangedSubview(SetupLink.label(text))
        isAccessibilityElement = true
        accessibilityLabel = text
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
}

@MainActor
final class LinkCardView: UIView {
    init(card: FirstRunPlan.LinkCard, onConnectAnyway: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Theme.Color.groupedBackground
        layer.cornerRadius = Theme.Radius.control
        layer.cornerCurve = .continuous

        let column = UIStackView()
        column.axis = .vertical
        column.spacing = Theme.Spacing.xs
        column.alignment = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(
            SetupLink.label(card.headline, role: .panelLabel, color: Theme.Color.label))
        card.lines.forEach { column.addArrangedSubview(SetupLink.label($0, role: .panelFootnote)) }
        if let title = card.connectAnywayTitle {
            let button = SetupLink.button(title: title, symbol: nil)
            button.addAction(
                UIAction { _ in
                    Theme.Haptics.tap()
                    onConnectAnyway()
                }, for: .touchUpInside)
            column.addArrangedSubview(button)
        }
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

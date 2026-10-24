import TailscodeCore
import UIKit

/// One slot of the party as a card: a glass ball in the model's hue, the name it goes by, the
/// model and its level in words, five bars for the level, and the machine when it is not this one.
///
/// A card is a button to a screen reader and to a thumb, and it never clips, so the release badge
/// and the glow of the slot in use can leave its edge. In edit mode the same card turns the name
/// into a field, the ball's button into a level stepper, and a ball can be lifted and dropped on
/// another; none of that is decided here, the card only reports.
@MainActor
final class PartyCardView: UIControl {
    static let minimumHeight: CGFloat = 130
    private static let radius: CGFloat = 20

    let slot: Int
    var onTake: (() -> Void)?
    var onRelease: (() -> Void)?
    var onRename: ((String?) -> Void)?
    var onStep: (() -> Void)?
    var onReplace: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onStartRename: (() -> Void)?
    var onNameFocus: ((Bool) -> Void)?

    private(set) var card: PartyCard
    private(set) var isEditing = false
    private var isBusy = false

    private let halo = UIView()
    private let dashed = CAShapeLayer()
    private let ball = PartyBallView()
    private let hollowBall = PartyBallView()
    private let slotLabel = UILabel()
    private let titleLabel = UILabel()
    private let nameField = UITextView()
    private let underline = UIView()
    private let subtitleLabel = UILabel()
    private let bars = PartyBarsView()
    private let machine = PartyPillView(
        font: PartyCardView.font(11, .medium), insets: UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8))
    private let hollowLabel = UILabel()
    private let filled = UIStackView()
    private let hollow = UIStackView()
    private let badge = SlopButton(type: .custom)
    private let stepper = SlopButton(type: .custom)
    private let titleHost = UIView()

    init(slot: Int) {
        self.slot = slot
        self.card = .hollow(slot)
        super.init(frame: .zero)
        build()
        render(card, editing: false, busy: false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func font(_ size: CGFloat, _ weight: UIFont.Weight, mono: Bool = false) -> UIFont {
        let base =
            mono
            ? UIFont.monospacedSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base, maximumPointSize: size * 1.6)
    }

    var ballFrame: CGRect { convert(ball.bounds, from: ball).insetBy(dx: -8, dy: -8) }

    var isNameFocused: Bool { nameField.isFirstResponder }

    func focusName() {
        guard !card.isHollow else { return }
        nameField.becomeFirstResponder()
        nameField.selectAll(nil)
    }

    func endNaming() { nameField.resignFirstResponder() }

    private func build() {
        layer.cornerRadius = Self.radius
        layer.cornerCurve = .continuous
        isAccessibilityElement = true
        accessibilityTraits = .button

        halo.isUserInteractionEnabled = false
        halo.layer.cornerRadius = Self.radius
        halo.layer.cornerCurve = .continuous
        halo.layer.borderWidth = 2
        halo.layer.shadowOffset = .zero
        halo.layer.shadowRadius = 10
        halo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(halo)

        dashed.fillColor = nil
        dashed.lineWidth = 1.5
        dashed.lineDashPattern = [6, 5]
        layer.addSublayer(dashed)

        slotLabel.font = Self.font(11, .regular, mono: true)
        slotLabel.adjustsFontForContentSizeCategory = true
        slotLabel.textAlignment = .right
        slotLabel.setContentHuggingPriority(.required, for: .horizontal)
        slotLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let top = UIView()
        ball.translatesAutoresizingMaskIntoConstraints = false
        slotLabel.translatesAutoresizingMaskIntoConstraints = false
        top.addSubview(ball)
        top.addSubview(slotLabel)
        NSLayoutConstraint.activate([
            ball.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            ball.topAnchor.constraint(equalTo: top.topAnchor),
            ball.bottomAnchor.constraint(equalTo: top.bottomAnchor),
            slotLabel.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            slotLabel.topAnchor.constraint(equalTo: top.topAnchor, constant: 2),
            slotLabel.leadingAnchor.constraint(greaterThanOrEqualTo: ball.trailingAnchor, constant: 4),
        ])

        titleLabel.font = Self.font(16, .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        nameField.font = Self.font(16, .semibold)
        nameField.adjustsFontForContentSizeCategory = true
        nameField.textColor = Theme.Color.label
        nameField.backgroundColor = .clear
        nameField.isScrollEnabled = false
        nameField.textContainerInset = .zero
        nameField.textContainer.lineFragmentPadding = 0
        nameField.returnKeyType = .done
        nameField.autocorrectionType = .no
        nameField.delegate = self
        nameField.isHidden = true
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.accessibilityLabel = String(localized: "Name")

        underline.backgroundColor = Theme.Color.label.withAlphaComponent(0.8)
        underline.isHidden = true
        underline.isUserInteractionEnabled = false
        underline.translatesAutoresizingMaskIntoConstraints = false

        titleHost.addSubview(titleLabel)
        titleHost.addSubview(nameField)
        titleHost.addSubview(underline)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: titleHost.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: titleHost.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: titleHost.trailingAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: titleHost.bottomAnchor),
            nameField.topAnchor.constraint(equalTo: titleHost.topAnchor),
            nameField.leadingAnchor.constraint(equalTo: titleHost.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: titleHost.trailingAnchor),
            nameField.bottomAnchor.constraint(equalTo: titleHost.bottomAnchor),
            underline.leadingAnchor.constraint(equalTo: titleHost.leadingAnchor),
            underline.trailingAnchor.constraint(equalTo: titleHost.trailingAnchor),
            underline.bottomAnchor.constraint(equalTo: titleHost.bottomAnchor, constant: 2),
            underline.heightAnchor.constraint(equalToConstant: 1),
        ])

        subtitleLabel.font = Self.font(12.5, .regular)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = Theme.Color.secondaryLabel
        subtitleLabel.numberOfLines = 0

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow - 1, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow - 1, for: .vertical)

        let bottom = UIView()
        machine.translatesAutoresizingMaskIntoConstraints = false
        machine.isUserInteractionEnabled = false
        bars.translatesAutoresizingMaskIntoConstraints = false
        bottom.addSubview(machine)
        bottom.addSubview(bars)
        NSLayoutConstraint.activate([
            machine.leadingAnchor.constraint(equalTo: bottom.leadingAnchor),
            machine.topAnchor.constraint(equalTo: bottom.topAnchor),
            machine.bottomAnchor.constraint(equalTo: bottom.bottomAnchor),
            bars.trailingAnchor.constraint(equalTo: bottom.trailingAnchor),
            bars.bottomAnchor.constraint(equalTo: bottom.bottomAnchor, constant: -3),
            bars.leadingAnchor.constraint(greaterThanOrEqualTo: machine.trailingAnchor, constant: 6),
            bottom.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])

        filled.axis = .vertical
        filled.alignment = .fill
        filled.isUserInteractionEnabled = true
        [top, titleHost, subtitleLabel, spacer, bottom].forEach(filled.addArrangedSubview)
        filled.setCustomSpacing(8, after: top)
        filled.setCustomSpacing(3, after: titleHost)
        filled.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filled)

        hollowLabel.font = Self.font(14, .regular)
        hollowLabel.adjustsFontForContentSizeCategory = true
        hollowLabel.textColor = Theme.Color.secondaryLabel
        hollowLabel.numberOfLines = 0
        hollowLabel.textAlignment = .center
        hollow.axis = .vertical
        hollow.alignment = .center
        hollow.spacing = 8
        hollow.isUserInteractionEnabled = false
        hollow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hollow)
        hollowBall.isHollow = true
        hollow.addArrangedSubview(hollowBall)
        hollow.addArrangedSubview(hollowLabel)

        stepper.addAction(UIAction { [weak self] _ in self?.onStep?() }, for: .touchUpInside)
        stepper.translatesAutoresizingMaskIntoConstraints = false
        stepper.accessibilityLabel = String(localized: "Change level")
        stepper.isHidden = true
        addSubview(stepper)

        var badgeConfig = UIButton.Configuration.plain()
        badgeConfig.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        badgeConfig.baseForegroundColor = Theme.Color.label
        badge.configuration = badgeConfig
        badge.backgroundColor = Theme.Color.groupedSurface
        badge.layer.cornerRadius = 13
        badge.layer.borderWidth = 1
        badge.layer.borderColor = Theme.Color.separator.cgColor
        badge.accessibilityLabel = String(localized: "Release")
        badge.addAction(UIAction { [weak self] _ in self?.onRelease?() }, for: .touchUpInside)
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumHeight),
            halo.topAnchor.constraint(equalTo: topAnchor),
            halo.bottomAnchor.constraint(equalTo: bottomAnchor),
            halo.leadingAnchor.constraint(equalTo: leadingAnchor),
            halo.trailingAnchor.constraint(equalTo: trailingAnchor),
            filled.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            filled.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            filled.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            filled.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            hollow.centerXAnchor.constraint(equalTo: centerXAnchor),
            hollow.centerYAnchor.constraint(equalTo: centerYAnchor),
            hollow.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            hollow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stepper.centerXAnchor.constraint(equalTo: ball.centerXAnchor),
            stepper.centerYAnchor.constraint(equalTo: ball.centerYAnchor),
            stepper.widthAnchor.constraint(equalToConstant: 30),
            stepper.heightAnchor.constraint(equalToConstant: 30),
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 26),
            badge.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            badge.centerYAnchor.constraint(equalTo: topAnchor, constant: 6),
        ])

        addAction(UIAction { [weak self] _ in self?.tapped() }, for: .touchUpInside)
        isContextMenuInteractionEnabled = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: PartyCardView, _) in view.paintSurface()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dashed.frame = bounds
        dashed.path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerRadius: Self.radius).cgPath
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        applyMotion()
    }

    override var isHighlighted: Bool {
        didSet {
            guard !isEditing || card.isHollow else { return }
            alpha = isHighlighted ? 0.8 : (card.isAway ? 0.45 : 1)
        }
    }

    /// Everything the card says, from one reading. The same call redraws it after a rename, a
    /// level, a swap or a release, so a card has no state of its own to fall out of step.
    func render(_ reading: PartyCard, editing: Bool, busy: Bool) {
        card = reading
        isEditing = editing
        isBusy = busy
        let isHollow = reading.isHollow
        filled.isHidden = isHollow
        hollow.isHidden = !isHollow
        if isHollow {
            hollowLabel.text =
                editing
                ? String(localized: "Fill slot \(reading.chord)")
                : String(localized: "Slot \(reading.chord)")
        }
        let hue = reading.chip.map { Theme.Color.modelIdentity($0) }
        ball.hue = hue
        let inUse = reading.isInUse && !editing
        slotLabel.text = inUse ? String(localized: "\(reading.chord) · IN USE") : "\(reading.chord)"
        slotLabel.textColor =
            inUse ? (hue ?? Theme.Color.label) : Theme.Color.secondaryLabel.withAlphaComponent(0.62)
        if !nameField.isFirstResponder {
            nameField.text = reading.title
            titleLabel.text = reading.title
        }
        subtitleLabel.text = reading.subtitle
        bars.hue = hue
        bars.lit = reading.bars
        bars.isHidden = !reading.takesLevels
        machine.text = reading.machine.map { String(localized: "on \($0)") }
        machine.isHidden = reading.machine == nil
        titleLabel.isHidden = editing && !isHollow
        nameField.isHidden = !(editing && !isHollow)
        underline.isHidden = nameField.isHidden
        badge.isHidden = !(editing && !isHollow)
        stepper.isHidden = !(editing && !isHollow && reading.takesLevels)
        nameField.isUserInteractionEnabled = editing && !isHollow
        halo.isHidden = !inUse
        halo.layer.borderColor = (hue ?? Theme.Color.label).resolvedColor(with: traitCollection).cgColor
        halo.layer.shadowColor = (hue ?? Theme.Color.label).resolvedColor(with: traitCollection).cgColor
        halo.layer.shadowOpacity = 0.45
        alpha = reading.isAway ? 0.45 : 1
        paintSurface()
        applyMotion()
        describe()
    }

    private func paintSurface() {
        let isHollow = card.isHollow
        backgroundColor = isHollow ? .clear : Theme.Color.secondaryBackground
        dashed.isHidden = !isHollow
        dashed.strokeColor = Theme.Color.tertiaryLabel.resolvedColor(with: traitCollection).cgColor
        underline.backgroundColor =
            (ball.hue ?? Theme.Color.label).resolvedColor(with: traitCollection)
        badge.layer.borderColor = Theme.Color.separator.resolvedColor(with: traitCollection).cgColor
    }

    /// The halo breathes only while the chat's turn is running, on the vocabulary's own clock; at
    /// rest it holds exactly still.
    private func applyMotion() {
        halo.layer.setActivityMotion(isBusy && card.isInUse ? .working : .still)
    }

    private func describe() {
        accessibilityLabel = card.spoken
        guard !card.isHollow else {
            accessibilityCustomActions = nil
            return
        }
        var actions: [UIAccessibilityCustomAction] = []
        func add(_ name: String, _ run: @escaping @MainActor () -> Void) {
            actions.append(
                UIAccessibilityCustomAction(name: name) { _ in
                    run()
                    return true
                })
        }
        add(String(localized: "Rename")) { [weak self] in self?.onStartRename?() }
        if card.takesLevels { add(String(localized: "Change level")) { [weak self] in self?.onStep?() } }
        add(String(localized: "Replace…")) { [weak self] in self?.onReplace?() }
        if slot > 0 { add(String(localized: "Move earlier")) { [weak self] in self?.onMove?(-1) } }
        if slot < ModelParty.size - 1 {
            add(String(localized: "Move later")) { [weak self] in self?.onMove?(1) }
        }
        add(String(localized: "Release")) { [weak self] in self?.onRelease?() }
        accessibilityCustomActions = actions
    }

    private func tapped() {
        if nameField.isFirstResponder {
            nameField.resignFirstResponder()
            return
        }
        if isEditing, !card.isHollow { return }
        onTake?()
    }

    /// The ball picked up: a little larger, tilted the other way a moment, and a shadow under it,
    /// carried by the finger.
    func lift(by translation: CGPoint) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 8)
        layer.shadowRadius = 14
        layer.shadowOpacity = 0.35
        transform = CGAffineTransform(translationX: translation.x, y: translation.y)
            .rotated(by: -1.5 * .pi / 180).scaledBy(x: 1.04, y: 1.04)
    }

    func settle() {
        transform = .identity
        layer.shadowOpacity = 0
    }

    func setTargeted(_ targeted: Bool) {
        layer.borderWidth = targeted ? 2 : 0
        layer.borderColor = Theme.Color.accent.cgColor
    }
}

extension PartyCardView: UITextViewDelegate {
    func textViewDidBeginEditing(_ textView: UITextView) { onNameFocus?(true) }

    func textView(
        _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
        if text == "\n" {
            textView.resignFirstResponder()
            return false
        }
        let current = textView.text ?? ""
        guard let span = Range(range, in: current) else { return true }
        return current.replacingCharacters(in: span, with: text).count <= ModelParty.nameLimit
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        let entered = ModelParty.normalized(textView.text)
        let unchanged = entered == card.name || (card.name == nil && entered == card.title)
        textView.text = card.title
        onNameFocus?(false)
        guard !unchanged else { return }
        onRename?(entered)
    }
}

extension PartyCardView {
    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard isEditing, !card.isHollow else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [
                UIAction(
                    title: String(localized: "Replace…"),
                    image: UIImage(systemName: "arrow.triangle.2.circlepath")
                ) { _ in self.onReplace?() },
                UIAction(title: String(localized: "Rename"), image: UIImage(systemName: "pencil")) {
                    _ in self.focusName()
                },
                UIAction(
                    title: String(localized: "Release"), image: UIImage(systemName: "xmark"),
                    attributes: .destructive
                ) { _ in self.onRelease?() },
            ])
        }
    }
}

import CodingAgentKit
import TailscodeCore
import UIKit

/// The phone ↔ tailnet ↔ machine hero, told as a fact rather than a decoration:
/// it renders whether this iPhone actually has a tailnet address right now, and
/// says so. Reduce Motion gets the same picture without the crawl.
@MainActor
final class TailnetLinkView: UIView {
    enum State: Equatable {
        case unknown
        case linked(String)
        case down
    }

    private let phoneNode = TailnetNodeView(symbol: "iphone", caption: String(localized: "This iPhone"))
    private let serverNode = TailnetNodeView(symbol: "server.rack", caption: String(localized: "Your machine"))
    private let lineLayer = CAShapeLayer()
    private let dotLayer = CAShapeLayer()
    private let badge = UIView()
    private let badgeIcon = UIImageView()
    private let caption = UILabel()
    private var state: State = .unknown
    private var backend: AgentType = .openCode

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        lineLayer.lineWidth = 2
        lineLayer.lineCap = .round
        lineLayer.fillColor = UIColor.clear.cgColor
        layer.addSublayer(lineLayer)
        layer.addSublayer(dotLayer)

        badge.backgroundColor = Theme.Color.groupedSurface
        badge.layer.cornerRadius = 15
        badge.layer.cornerCurve = .continuous
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeIcon.contentMode = .center
        badgeIcon.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeIcon)

        caption.font = Theme.Font.capped(.caption1, maximum: 15)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = Theme.Color.tertiaryLabel
        caption.textAlignment = .center
        caption.numberOfLines = 2
        caption.adjustsFontSizeToFitWidth = true
        caption.minimumScaleFactor = 0.7
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        caption.translatesAutoresizingMaskIntoConstraints = false

        addSubview(phoneNode)
        addSubview(serverNode)
        addSubview(badge)
        addSubview(caption)

        NSLayoutConstraint.activate([
            phoneNode.topAnchor.constraint(equalTo: topAnchor),
            phoneNode.leadingAnchor.constraint(equalTo: leadingAnchor),
            serverNode.topAnchor.constraint(equalTo: topAnchor),
            serverNode.trailingAnchor.constraint(equalTo: trailingAnchor),
            phoneNode.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.28),
            serverNode.widthAnchor.constraint(equalTo: phoneNode.widthAnchor),
            serverNode.leadingAnchor.constraint(
                greaterThanOrEqualTo: phoneNode.trailingAnchor, constant: Theme.Spacing.xxl),

            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: phoneNode.glyphCenterYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 30),
            badge.heightAnchor.constraint(equalToConstant: 30),
            badgeIcon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeIcon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            caption.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: Theme.Spacing.s),
            caption.centerXAnchor.constraint(equalTo: centerXAnchor),
            caption.leadingAnchor.constraint(greaterThanOrEqualTo: phoneNode.trailingAnchor, constant: Theme.Spacing.xs),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: serverNode.leadingAnchor, constant: -Theme.Spacing.xs),
            bottomAnchor.constraint(greaterThanOrEqualTo: caption.bottomAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: phoneNode.bottomAnchor),
            bottomAnchor.constraint(equalTo: caption.bottomAnchor).withPriority(.defaultLow),
            bottomAnchor.constraint(equalTo: phoneNode.bottomAnchor).withPriority(.defaultLow),
        ])

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TailnetLinkView, _) in
            view.applyState()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(rearm), name: UIApplication.didBecomeActiveNotification,
            object: nil)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        setBackend(.openCode)
        applyState()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setBackend(_ backend: AgentType) {
        self.backend = backend
        serverNode.setTint(backend.brandColor)
    }

    func setState(_ state: State) {
        guard state != self.state else { return }
        self.state = state
        applyState()
    }

    private func applyState() {
        let linked: Bool
        switch state {
        case .linked: linked = true
        case .unknown, .down: linked = false
        }
        let tint = linked ? Theme.Color.success : Theme.Color.tertiaryLabel
        lineLayer.strokeColor =
            (linked ? Theme.Color.accent.withAlphaComponent(0.6) : Theme.Color.separator)
            .resolvedColor(with: traitCollection).cgColor
        lineLayer.lineDashPattern = linked ? [2, 6] : [2, 5]
        dotLayer.fillColor = Theme.Color.accent.resolvedColor(with: traitCollection).cgColor
        badgeIcon.image = UIImage(
            systemName: linked ? "lock.fill" : "lock.slash",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        badgeIcon.tintColor = tint
        phoneNode.setTint(linked ? Theme.Color.accent : Theme.Color.tertiaryLabel)

        switch state {
        case .linked(let address):
            caption.text = "TAILSCALE\n" + address
            accessibilityLabel = String(
                localized: "This iPhone is on your tailnet at \(address), able to reach your machine.")
        case .down:
            caption.text = "TAILSCALE\n" + String(localized: "not connected")
            accessibilityLabel = String(
                localized: "This iPhone is not on your tailnet, so it cannot reach your machine yet.")
        case .unknown:
            caption.text = "TAILSCALE"
            accessibilityLabel = String(
                localized: "Your iPhone reaches your machine over an encrypted Tailscale link.")
        }
        dotLayer.isHidden = !linked || UIAccessibility.isReduceMotionEnabled
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let y = phoneNode.frame.minY + phoneNode.glyphCenterOffset
        let startX = phoneNode.frame.maxX + Theme.Spacing.s
        let endX = serverNode.frame.minX - Theme.Spacing.s
        guard endX > startX else { return }
        let path = UIBezierPath()
        path.move(to: CGPoint(x: startX, y: y))
        path.addLine(to: CGPoint(x: endX, y: y))
        lineLayer.path = path.cgPath
        dotLayer.path = UIBezierPath(ovalIn: CGRect(x: -3, y: -3, width: 6, height: 6)).cgPath
        animate(from: CGPoint(x: startX, y: y), to: CGPoint(x: endX, y: y))
    }

    /// CoreAnimation strips repeating animations when the app backgrounds, and
    /// this screen's whole job is to send the user to the Tailscale app — so the
    /// crawl is re-armed on every return instead of dying after one trip.
    @objc private func rearm() {
        guard window != nil else { return }
        setNeedsLayout()
    }

    private func animate(from: CGPoint, to: CGPoint) {
        lineLayer.removeAllAnimations()
        dotLayer.removeAllAnimations()
        dotLayer.position = from
        guard window != nil, !UIAccessibility.isReduceMotionEnabled, case .linked = state else { return }

        let dash = CABasicAnimation(keyPath: "lineDashPhase")
        dash.fromValue = 0
        dash.toValue = -8
        dash.duration = 0.7
        dash.repeatCount = .infinity
        lineLayer.add(dash, forKey: "dash")

        let travel = CAKeyframeAnimation(keyPath: "position")
        let path = UIBezierPath()
        path.move(to: from)
        path.addLine(to: to)
        travel.path = path.cgPath
        travel.duration = 1.9
        travel.repeatCount = .infinity
        travel.calculationMode = .paced

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.85, 1]
        fade.duration = 1.9
        fade.repeatCount = .infinity

        dotLayer.add(travel, forKey: "travel")
        dotLayer.add(fade, forKey: "fade")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            lineLayer.removeAllAnimations()
            dotLayer.removeAllAnimations()
        } else {
            setNeedsLayout()
        }
    }
}

@MainActor
private final class TailnetNodeView: UIView {
    private let circle = UIView()
    private let glyph = UIImageView()
    private let caption = UILabel()
    private var tint: UIColor = Theme.Color.accent

    var glyphCenterYAnchor: NSLayoutYAxisAnchor { circle.centerYAnchor }
    var glyphCenterOffset: CGFloat { circle.frame.midY }

    init(symbol: String, caption text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        circle.backgroundColor = Theme.Color.groupedSurface
        circle.layer.cornerRadius = 29
        circle.layer.borderWidth = 1.5
        circle.translatesAutoresizingMaskIntoConstraints = false

        glyph.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .regular))
        glyph.contentMode = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(glyph)

        caption.text = text
        caption.font = Theme.Font.capped(.caption1, maximum: 17)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = Theme.Color.secondaryLabel
        caption.textAlignment = .center
        caption.numberOfLines = 2
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        caption.translatesAutoresizingMaskIntoConstraints = false

        addSubview(circle)
        addSubview(caption)
        NSLayoutConstraint.activate([
            circle.topAnchor.constraint(equalTo: topAnchor),
            circle.centerXAnchor.constraint(equalTo: centerXAnchor),
            circle.widthAnchor.constraint(equalToConstant: 58),
            circle.heightAnchor.constraint(equalToConstant: 58),
            glyph.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            caption.topAnchor.constraint(equalTo: circle.bottomAnchor, constant: Theme.Spacing.s),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualTo: circle.widthAnchor),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TailnetNodeView, _) in
            view.applyTint()
        }
        applyTint()
    }

    func setTint(_ tint: UIColor) {
        self.tint = tint
        applyTint()
    }

    private func applyTint() {
        glyph.tintColor = tint
        circle.layer.borderColor =
            tint.withAlphaComponent(0.45).resolvedColor(with: traitCollection).cgColor
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// One step of setup as a card that knows whether it is done. A badge that never
/// changes turns a five-minute, two-machine procedure into a rendered document;
/// this one is a checklist.
@MainActor
final class SetupStepCard: UIView {
    enum Status: Equatable {
        case pending
        case active
        case done
    }

    let content = UIStackView()
    private let badge = UIView()
    private let badgeNumber = UILabel()
    private let badgeCheck = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let statusPill = StatusPillView()
    private let index: Int
    private let total: Int
    private var status: Status = .pending
    private weak var headerText: UIStackView?

    init(index: Int, total: Int, title: String, detail: String) {
        self.index = index
        self.total = total
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Theme.Color.groupedSurface
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous

        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.layer.cornerRadius = 15
        badge.layer.borderWidth = 1.5
        badgeNumber.text = "\(index)"
        badgeNumber.font = .systemFont(ofSize: 14, weight: .semibold)
        badgeNumber.textAlignment = .center
        badgeNumber.translatesAutoresizingMaskIntoConstraints = false
        badgeCheck.image = UIImage(
            systemName: "checkmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        badgeCheck.tintColor = .white
        badgeCheck.contentMode = .center
        badgeCheck.isHidden = true
        badgeCheck.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeNumber)
        badge.addSubview(badgeCheck)

        titleLabel.text = title
        titleLabel.font = Theme.Font.headline()
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityLabel = String(localized: "Step \(index) of \(total): \(title)")

        detailLabel.text = detail
        detailLabel.font = Theme.Font.footnote()
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.numberOfLines = 0

        content.axis = .vertical
        content.spacing = Theme.Spacing.m

        let headerText = UIStackView(arrangedSubviews: [titleLabel, statusPill])
        headerText.axis = .horizontal
        headerText.spacing = Theme.Spacing.s
        headerText.alignment = .firstBaseline
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusPill.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let column = UIStackView(arrangedSubviews: [headerText, detailLabel, content])
        column.axis = .vertical
        column.spacing = Theme.Spacing.xs
        column.setCustomSpacing(Theme.Spacing.m, after: detailLabel)
        column.translatesAutoresizingMaskIntoConstraints = false

        addSubview(badge)
        addSubview(column)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.l),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            badge.widthAnchor.constraint(equalToConstant: 30),
            badge.heightAnchor.constraint(equalToConstant: 30),
            badgeNumber.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeNumber.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badgeCheck.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeCheck.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            column.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.l),
            column.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: Theme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.l),
        ])
        self.headerText = headerText
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SetupStepCard, _) in
            view.applyStatus(animated: false)
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (view: SetupStepCard, _) in view.applyHeaderAxis()
        }
        applyStatus(animated: false)
        applyHeaderAxis()
    }

    /// At accessibility text sizes a status chip beside the title squeezes it into
    /// a two-character column, so the header becomes two rows instead.
    private func applyHeaderAxis() {
        let accessible = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        headerText?.axis = accessible ? .vertical : .horizontal
        headerText?.alignment = accessible ? .leading : .firstBaseline
        headerText?.spacing = accessible ? Theme.Spacing.xs : Theme.Spacing.s
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setStatus(_ status: Status, animated: Bool = true) {
        guard status != self.status else { return }
        self.status = status
        applyStatus(animated: animated)
    }

    func setDetail(_ text: String) {
        detailLabel.text = text
    }

    func setPill(_ text: String?, symbol: String = "checkmark.circle.fill", tint: UIColor = Theme.Color.success) {
        statusPill.set(text, symbol: symbol, tint: tint)
    }

    private func applyStatus(animated: Bool) {
        let apply = {
            switch self.status {
            case .pending:
                self.badge.backgroundColor = .clear
                self.badge.layer.borderColor = Theme.Color.tertiaryLabel.resolvedColor(
                    with: self.traitCollection).cgColor
                self.badgeNumber.textColor = Theme.Color.tertiaryLabel
                self.badgeNumber.isHidden = false
                self.badgeCheck.isHidden = true
            case .active:
                self.badge.backgroundColor = Theme.Color.accent
                self.badge.layer.borderColor = UIColor.clear.cgColor
                self.badgeNumber.textColor = .white
                self.badgeNumber.isHidden = false
                self.badgeCheck.isHidden = true
            case .done:
                self.badge.backgroundColor = Theme.Color.success
                self.badge.layer.borderColor = UIColor.clear.cgColor
                self.badgeNumber.isHidden = true
                self.badgeCheck.isHidden = false
            }
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            apply()
            return
        }
        UIView.transition(with: badge, duration: 0.25, options: .transitionCrossDissolve, animations: apply)
        if status == .done { badgeCheck.addSymbolEffect(.bounce) }
    }
}

/// A row that becomes a column at accessibility text sizes, where two controls
/// side by side leave each one a few characters wide.
@MainActor
final class AdaptiveRow: UIStackView {
    private let standardAlignment: UIStackView.Alignment

    init(_ views: [UIView], alignment: UIStackView.Alignment = .center) {
        standardAlignment = alignment
        super.init(frame: .zero)
        views.forEach(addArrangedSubview)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (row: AdaptiveRow, _) in row.apply()
        }
        apply()
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    private func apply() {
        let accessible = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        axis = accessible ? .vertical : .horizontal
        alignment = accessible ? .leading : standardAlignment
        spacing = accessible ? Theme.Spacing.xs : Theme.Spacing.s
    }
}

@MainActor
final class StatusPillView: UIView {
    private let icon = UIImageView()
    private let label = UILabel()
    private let stack = UIStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        icon.contentMode = .center
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.font = .preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle
        stack.axis = .horizontal
        stack.spacing = Theme.Spacing.xs
        stack.alignment = .center
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String?, symbol: String, tint: UIColor) {
        guard let text else {
            isHidden = true
            return
        }
        isHidden = false
        label.text = text
        label.textColor = tint
        icon.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        icon.tintColor = tint
        accessibilityLabel = text
    }
}

/// A command that has to be typed on another machine. Copy only reaches a Mac
/// with Universal Clipboard, so the block can hand the text to anything that
/// takes text — AirDrop, Messages, Mail — and it wraps instead of clipping the
/// one string the user must transcribe exactly.
@MainActor
final class CommandBlockView: UIView {
    var onShare: ((String, UIView) -> Void)?
    var onCopy: (() -> Void)?

    private let command: String
    private let label = UILabel()
    private let copyButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private var resetTask: Task<Void, Never>?

    init(command: String) {
        self.command = command
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1)
        layer.cornerRadius = Theme.Radius.control
        layer.cornerCurve = .continuous

        label.attributedText = Self.render(command)
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.accessibilityAttributedLabel = NSAttributedString(
            string: command,
            attributes: [.accessibilitySpeechPunctuation: true])

        configure(copyButton, symbol: "doc.on.doc", label: String(localized: "Copy command"))
        configure(shareButton, symbol: "square.and.arrow.up", label: String(localized: "Send command to another device"))
        copyButton.addAction(UIAction { [weak self] _ in self?.copy() }, for: .touchUpInside)
        shareButton.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                Theme.Haptics.tap()
                self.onShare?(self.command, self.shareButton)
            }, for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [copyButton, shareButton])
        buttons.axis = .horizontal
        buttons.spacing = 0
        buttons.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(buttons)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
            buttons.topAnchor.constraint(equalTo: label.bottomAnchor, constant: Theme.Spacing.xs),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.xs),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.xs),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func configure(_ button: UIButton, symbol: String, label: String) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        config.baseForegroundColor = UIColor(white: 0.72, alpha: 1)
        config.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 11, bottom: 11, trailing: 11)
        button.configuration = config
        button.accessibilityLabel = label
    }

    private func copy() {
        UIPasteboard.general.string = command
        onCopy?()
        Theme.Haptics.success()
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Command copied"))
        setCopyGlyph("checkmark", tint: Theme.Color.success)
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self.setCopyGlyph("doc.on.doc", tint: UIColor(white: 0.72, alpha: 1))
        }
    }

    private func setCopyGlyph(_ symbol: String, tint: UIColor) {
        let apply = { [weak self] in
            self?.copyButton.configuration?.image = UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
            self?.copyButton.configuration?.baseForegroundColor = tint
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            apply()
            return
        }
        UIView.transition(with: copyButton, duration: 0.2, options: .transitionCrossDissolve, animations: apply)
    }

    /// Each line reads as `$ command`, the prompt tinted, forced left-to-right so
    /// a shell command never reverses under an RTL language.
    private static func render(_ command: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = Theme.Font.scaledMono(.footnote)
        let promptColor = UIColor(red: 0.40, green: 0.85, blue: 0.55, alpha: 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = .leftToRight
        paragraph.lineSpacing = 2
        let lines = command.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            result.append(
                NSAttributedString(
                    string: "$ ",
                    attributes: [.font: font, .foregroundColor: promptColor, .paragraphStyle: paragraph]))
            result.append(
                NSAttributedString(
                    string: String(line),
                    attributes: [
                        .font: font, .foregroundColor: UIColor(white: 0.94, alpha: 1),
                        .paragraphStyle: paragraph,
                    ]))
            if index < lines.count - 1 { result.append(NSAttributedString(string: "\n")) }
        }
        return result
    }
}

/// A choice that changes the install path, the port, and the brand — too
/// consequential for a segmented control whose only feedback is a tint change
/// somewhere off screen.
@MainActor
final class AgentChoiceCard: UIControl {
    private let glyph = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let check = UIImageView()
    private let tint: UIColor

    init(backend: AgentType, title: String, detail: String) {
        self.tint = backend.brandColor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Theme.Color.groupedBackground
        layer.cornerRadius = Theme.Radius.control
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.5

        glyph.image = UIImage(
            systemName: backend.symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        glyph.tintColor = tint
        glyph.contentMode = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0

        detailLabel.text = detail
        detailLabel.font = .preferredFont(forTextStyle: .caption2)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.numberOfLines = 0

        check.image = UIImage(
            systemName: "checkmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        check.tintColor = tint
        check.contentMode = .center
        check.translatesAutoresizingMaskIntoConstraints = false

        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        text.isUserInteractionEnabled = false

        addSubview(glyph)
        addSubview(text)
        addSubview(check)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            glyph.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            glyph.widthAnchor.constraint(equalToConstant: 22),
            text.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: Theme.Spacing.s),
            text.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.m),
            text.trailingAnchor.constraint(equalTo: check.leadingAnchor, constant: -Theme.Spacing.s),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(greaterThanOrEqualTo: glyph.heightAnchor, constant: 2 * Theme.Spacing.m),
        ])
        accessibilityTraits = .button
        accessibilityLabel = "\(title). \(detail)"
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: AgentChoiceCard, _) in
            view.applySelection()
        }
        applySelection()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isSelected: Bool {
        didSet { applySelection() }
    }

    private func applySelection() {
        check.isHidden = !isSelected
        layer.borderColor =
            (isSelected ? tint.withAlphaComponent(0.9) : Theme.Color.separator)
            .resolvedColor(with: traitCollection).cgColor
        backgroundColor =
            isSelected
            ? tint.withAlphaComponent(0.10).blended(over: Theme.Color.groupedSurface, traits: traitCollection)
            : Theme.Color.groupedBackground
        accessibilityTraits = isSelected ? [.button, .selected] : .button
    }
}

/// What is actually wrong, and the one tap that fixes it.
@MainActor
final class DiagnosisCardView: UIView {
    var onAction: (() -> Void)?

    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let column = UIStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Theme.Radius.control
        layer.cornerCurve = .continuous
        isHidden = true

        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        detailLabel.font = Theme.Font.footnote()
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.numberOfLines = 0

        var config = UIButton.Configuration.gray()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        actionButton.configuration = config
        actionButton.isHidden = true
        actionButton.addAction(UIAction { [weak self] _ in self?.onAction?() }, for: .touchUpInside)

        column.axis = .vertical
        column.spacing = Theme.Spacing.xs
        column.alignment = .leading
        column.addArrangedSubview(titleLabel)
        column.addArrangedSubview(detailLabel)
        column.addArrangedSubview(actionButton)
        column.setCustomSpacing(Theme.Spacing.m, after: detailLabel)
        column.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(column)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            icon.widthAnchor.constraint(equalToConstant: 20),
            column.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            column.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Spacing.s),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ diagnosis: ConnectDiagnosis, tint: UIColor = Theme.Color.warning) {
        icon.image = UIImage(
            systemName: diagnosis.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        icon.tintColor = tint
        titleLabel.text = diagnosis.title
        titleLabel.textColor = Theme.Color.label
        detailLabel.text = diagnosis.detail
        backgroundColor = tint.withAlphaComponent(0.12)
        if let action = diagnosis.actionTitle {
            actionButton.configuration?.title = action
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
        reveal()
        UIAccessibility.post(
            notification: .announcement, argument: "\(diagnosis.title). \(diagnosis.detail)")
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        alpha = 0
    }

    private func reveal() {
        guard isHidden else { return }
        isHidden = false
        guard !UIAccessibility.isReduceMotionEnabled else {
            alpha = 1
            return
        }
        alpha = 0
        transform = CGAffineTransform(translationX: 0, y: -6)
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.3) {
            self.alpha = 1
            self.transform = .identity
        }
    }
}

/// The primary action, docked in glass above the safe area so it is never the
/// thing that scrolled away.
@MainActor
final class OnboardingFooterBar: UIView {
    let primary = PrimaryButton(title: "")
    private let glass = Theme.Glass.view()
    private let secondary = UIButton(type: .system)
    private let stack = UIStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        secondary.isHidden = true
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.xs
        stack.addArrangedSubview(primary)
        stack.addArrangedSubview(secondary)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -Theme.Spacing.s),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setSecondary(title: String, action: @escaping () -> Void) {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = Theme.Color.accent
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        secondary.configuration = config
        secondary.isHidden = false
        secondary.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }
}

import TailscodeCore
import UIKit

/// Chips laid out in as many rows as they need. A decision is a label over its value, and a value
/// is never cut: when a row has no room for the next chip the chip starts the next row, and a
/// chip wider than the dock wraps its own words rather than losing them. Larger Text only makes
/// the rows taller.
final class StudioChipFlow: UIView {
    static let minimumHeight: CGFloat = 44

    private var chips: [UIView] = []
    private var measuredWidth: CGFloat = 0

    func set(_ next: [UIView]) {
        chips.forEach { $0.removeFromSuperview() }
        chips = next
        chips.forEach(addSubview)
        measuredWidth = 0
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        return CGSize(width: UIView.noIntrinsicMetric, height: place(width: width, apply: false))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: place(width: size.width, apply: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = place(width: bounds.width, apply: true)
        if abs(measuredWidth - bounds.width) > 0.5 {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    @discardableResult
    private func place(width: CGFloat, apply: Bool) -> CGFloat {
        guard width > 0, !chips.isEmpty else { return Self.minimumHeight }
        let gap = Theme.Spacing.xs + 2
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for chip in chips {
            var size = chip.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            if size.width > width {
                size = chip.systemLayoutSizeFitting(
                    CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel)
            }
            size.width = min(size.width, width)
            size.height = max(size.height, Self.minimumHeight)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + gap
                rowHeight = 0
            }
            if apply { chip.frame = CGRect(origin: CGPoint(x: x, y: y), size: size) }
            x += size.width + gap
            rowHeight = max(rowHeight, size.height)
        }
        return y + rowHeight
    }
}

/// The words box. It tells its owner when its width is known or changes, because how tall the box
/// must be depends on how wide it is, and the first layout of a dock inside a glass view can come
/// after the screen's own has finished.
final class StudioPromptView: UITextView {
    var onWidth: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        guard abs(bounds.width - lastWidth) > 0.5 else { return }
        lastWidth = bounds.width
        onWidth?()
    }
}

/// The decision chips both studios wear: the decision's name small over its value in full, a
/// glass control at least forty-four points tall.
enum StudioChip {
    @MainActor
    static func button(
        label: String, value: String, tint: UIColor? = nil, symbol: String? = nil
    ) -> UIButton {
        var config = Theme.Glass.buttonConfiguration()
        config.cornerStyle = .large
        config.buttonSize = .small
        config.titleAlignment = .leading
        config.titleLineBreakMode = .byWordWrapping
        config.imagePadding = Theme.Spacing.xs
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        if let symbol {
            config.image = UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        }
        var name = AttributedString(label)
        name.font = Theme.Ramp.font(.sectionLabel)
        name.foregroundColor = Theme.Color.tertiaryLabel
        var body = AttributedString("\n\(value)")
        body.font = Theme.Ramp.font(.rowTitle)
        body.foregroundColor = tint ?? Theme.Color.label
        config.attributedTitle = name + body
        let button = UIButton(configuration: config)
        button.accessibilityLabel = "\(label), \(value)"
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: StudioChipFlow.minimumHeight)
            .isActive = true
        return button
    }
}

/// The machine in the bar: a status dot that breathes only while a job runs, whose machine it is,
/// and the one fact worth knowing before pressing Render. It opens the machine sheet, and wears
/// the failure tone when the machine cannot paint at all. Words are Core's.
final class StudioMachinePill: UIControl {
    private let dot = UIView()
    private let badge = ActivityBadgeView(pointSize: 9)
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.codeBackground
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.isUserInteractionEnabled = false
        let row = UIStackView(arrangedSubviews: [dotHolder(), label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    private func dotHolder() -> UIView {
        let holder = UIView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(dot)
        holder.addSubview(badge)
        NSLayoutConstraint.activate([
            holder.widthAnchor.constraint(equalToConstant: 12),
            holder.heightAnchor.constraint(equalToConstant: 12),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            badge.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        return holder
    }

    func apply(_ reading: StudioMachineReading?, working: Bool) {
        isHidden = reading == nil
        guard let reading else { return }
        let tone = reading.cannotPaint ? ActivityTone.danger : reading.tone
        dot.backgroundColor = tone.color
        dot.isHidden = working
        badge.activity = working ? .working : nil
        layer.borderColor = (reading.cannotPaint ? Theme.Color.danger : Theme.Color.separator)
            .cgColor
        let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        label.numberOfLines = stacked ? 2 : 1
        let font = Theme.Font.capped(.footnote, maximum: 17)
        let boldFont = UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        let text = NSMutableAttributedString(
            string: reading.name,
            attributes: [.font: boldFont, .foregroundColor: Theme.Color.label])
        text.append(
            NSAttributedString(
                string: stacked ? "\n\(reading.fact)" : " · \(reading.fact)",
                attributes: [
                    .font: font,
                    .foregroundColor: reading.cannotPaint
                        ? Theme.Color.danger : Theme.Color.secondaryLabel,
                ]))
        label.attributedText = text
        accessibilityLabel = reading.spoken
        accessibilityHint = ImageGenMachineWords.title
    }
}

/// The helper list, which is the same list wherever a brief can be rewritten: every machine that
/// answered the last survey and the models each serves, the current one marked, with looking
/// again and switching the helper off. One helper is filed on the device and offered in the image
/// studio and the video forge alike, so the menu lives here once.
enum StudioHelperMenu {
    @MainActor
    static func make() -> UIMenu {
        let studio = ImageStudio.shared
        let current = studio.helper
        let models = UIDeferredMenuElement.uncached { complete in
            let build: @MainActor @Sendable ([ImageGenHelperServer]) -> Void = { servers in
                var groups: [UIMenuElement] = servers.map { server in
                    UIMenu(
                        title: server.heading, options: .displayInline,
                        children: server.models.prefix(24).map { model in
                            let on = studio.helper?.address == server.address
                                && studio.helper?.model == model.id
                            return UIAction(
                                title: model.label, subtitle: model.detail, state: on ? .on : .off
                            ) { _ in
                                studio.setHelper(ImageGenHelper(address: server.address, model: model))
                            }
                        })
                }
                if groups.isEmpty {
                    groups.append(
                        UIAction(
                            title: ImageGenRewriteWords.noneFoundTitle,
                            subtitle: ImageGenRewriteWords.noneFoundHint, attributes: .disabled
                        ) { _ in })
                }
                complete(groups)
            }
            Task { @MainActor in
                if studio.helperServers.isEmpty {
                    studio.surveyHelpers(completion: build)
                } else {
                    build(studio.helperServers)
                }
            }
        }
        var children: [UIMenuElement] = [models]
        children.append(
            UIAction(
                title: ImageGenRewriteWords.lookAgainTitle,
                subtitle: ImageGenRewriteWords.lookAgainHint,
                image: UIImage(systemName: "arrow.clockwise")
            ) { _ in studio.surveyHelpers() })
        if let current {
            children.append(
                UIAction(
                    title: current.enabled
                        ? ImageGenRewriteWords.offTitle : ImageGenRewriteWords.onTitle,
                    subtitle: current.enabled ? ImageGenWords.helperOffHint : current.displayHost,
                    image: UIImage(
                        systemName: current.enabled ? "wand.and.stars.inverse" : "wand.and.stars")
                ) { _ in studio.toggleHelper() })
        }
        return UIMenu(title: ImageGenRewriteWords.chooseTitle, children: children)
    }
}

/// Enhance and the helper beside it, worn at the trailing edge of a words box: one press asks the
/// helper to write the brief out (and, once taken, gives the typed sentence back), the chevron
/// opens the list of who would write. The same two controls sit on the image brief and the video
/// brief, because the question is the same and only the helper's instructions differ.
final class StudioEnhanceControl: UIView {
    var onEnhance: (() -> Void)?

    private let enhance = UIButton(type: .system)
    private let chooser = UIButton(type: .system)

    /// Short enough that the control sits in the foot of a two-line box without covering the
    /// first line, which is what lets the words flow around it instead of under it.
    static let height: CGFloat = 26
    private static let insets = NSDirectionalEdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)

    override init(frame: CGRect) {
        super.init(frame: frame)
        var config = Theme.Glass.buttonConfiguration()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.imagePadding = Theme.Spacing.xs
        config.contentInsets = Self.insets
        enhance.configuration = config
        enhance.addAction(UIAction { [weak self] _ in self?.onEnhance?() }, for: .touchUpInside)
        var drop = Theme.Glass.buttonConfiguration()
        drop.cornerStyle = .capsule
        drop.buttonSize = .small
        drop.contentInsets = Self.insets
        drop.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        chooser.configuration = drop
        chooser.showsMenuAsPrimaryAction = true
        chooser.accessibilityLabel = ImageGenRewriteWords.chooseTitle
        chooser.accessibilityHint = ImageGenRewriteWords.chooseHint
        let row = UIStackView(arrangedSubviews: [enhance, chooser])
        row.axis = .horizontal
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// What the control says for the state the brief is in. `undoing` is the paragraph just taken,
    /// which one press gives the typed sentence back for.
    func apply(busy: Bool, undoing: Bool, enabled: Bool, helper: ImageGenHelper?) {
        let title = busy
            ? ImageGenWords.enhancingTitle
            : (undoing ? ImageGenWords.undoTitle : ImageGenWords.enhanceTitle)
        var config = enhance.configuration ?? Theme.Glass.buttonConfiguration()
        config.image = UIImage(
            systemName: busy ? "hourglass" : (undoing ? "arrow.uturn.backward" : "wand.and.stars"),
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        var attributed = AttributedString(title)
        attributed.font = Theme.Font.capped(.caption1, maximum: 15)
        config.attributedTitle = attributed
        config.baseForegroundColor = busy || undoing ? Theme.Color.accent : nil
        enhance.configuration = config
        enhance.isEnabled = enabled && !busy
        enhance.accessibilityLabel = title
        enhance.accessibilityHint = helper.map(ImageGenWords.enhanceHint)
            ?? ImageGenWords.enhanceLookingHint
        chooser.menu = StudioHelperMenu.make()
        chooser.isEnabled = !busy
    }

    var size: CGSize {
        systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    }
}

/// One thing a finished picture or clip can be made to do: what it is called, what it promises
/// before it is pressed, and what pressing it runs. Both studios describe their verbs in this one
/// shape and one bar draws them.
struct StudioVerb {
    let title: String
    let hint: String?
    let symbol: String
    var value: String?
    var enabled = true
    let run: @MainActor () -> Void
}

/// What a finished picture can be made to do, in one bar under the stage: icon over word, the same
/// width each, and the rest behind a menu. The bar keeps its room while a render runs — invisible,
/// untouchable — so the stage does not change size the moment the picture lands.
final class StudioVerbsBar: UIView {
    static let height: CGFloat = 34

    private let row = UIStackView()
    private let note = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.alignment = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        note.numberOfLines = 2
        note.textAlignment = .center
        note.translatesAutoresizingMaskIntoConstraints = false
        note.alpha = 0
        addSubview(row)
        addSubview(note)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            note.centerYAnchor.constraint(equalTo: centerYAnchor),
            note.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// `verbs` are the bar's, `more` the ones behind the menu. While `holding` the bar is
    /// invisible and takes no touch; `waiting` is the sentence that stands in its room.
    func apply(verbs: [StudioVerb], more: [UIMenuElement], holding: Bool, waiting: String?) {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let iconOnly = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        for verb in verbs { row.addArrangedSubview(button(for: verb, iconOnly: iconOnly)) }
        if !more.isEmpty { row.addArrangedSubview(moreButton(more, iconOnly: iconOnly)) }
        row.alpha = holding ? 0 : 1
        row.isUserInteractionEnabled = !holding
        row.accessibilityElementsHidden = holding
        note.alpha = waiting == nil ? 0 : 1
        note.attributedText = NSAttributedString(
            string: waiting ?? "",
            attributes: Theme.Ramp.attributes(
                .panelFootnote, color: Theme.Color.tertiaryLabel, alignment: .center))
        note.isAccessibilityElement = waiting != nil
    }

    private func configuration(symbol: String, title: String, iconOnly: Bool) -> UIButton.Configuration {
        var config = UIButton.Configuration.plain()
        config.imagePlacement = .top
        config.imagePadding = 2
        config.contentInsets = NSDirectionalEdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0)
        config.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        if !iconOnly {
            var text = AttributedString(title)
            text.font = Theme.Font.capped(.caption2, maximum: 12)
            config.attributedTitle = text
        }
        config.titleAlignment = .center
        config.baseForegroundColor = Theme.Color.accent
        return config
    }

    private func button(for verb: StudioVerb, iconOnly: Bool) -> UIButton {
        let button = UIButton(
            configuration: configuration(symbol: verb.symbol, title: verb.title, iconOnly: iconOnly))
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.75
        let run = verb.run
        button.addAction(UIAction { _ in run() }, for: .touchUpInside)
        button.accessibilityLabel = verb.title
        button.accessibilityHint = verb.hint
        button.accessibilityValue = verb.value
        button.isEnabled = verb.enabled
        return button
    }

    private func moreButton(_ elements: [UIMenuElement], iconOnly: Bool) -> UIButton {
        let button = UIButton(
            configuration: configuration(
                symbol: "ellipsis.circle", title: ImageGenWords.moreTitle, iconOnly: iconOnly))
        button.titleLabel?.numberOfLines = 1
        button.menu = UIMenu(children: elements)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = ImageGenWords.moreTitle
        return button
    }
}

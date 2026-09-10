import TailscodeCore
import UIKit

/// Everything the stage draws, in one value, so the cell is told what the studio is rather than
/// reaching back into it while it scrolls.
struct ImageStageReading {
    let slot: ImageGenSlot
    let picture: ImageGenPicture?
    let image: UIImage?
    let startedAt: Date?
}

/// The room: one picture at the size the screen can give it, and — when there is no picture yet —
/// the state that explains why. An empty studio argues for itself rather than showing a grey
/// rectangle, and a render in flight paints in place of the picture so the eye never has to go
/// looking for where the answer will appear.
final class ImageStageCell: UICollectionViewListCell {
    var onOpen: (() -> Void)?

    private let stage = UIView()
    private let picture = UIImageView()
    private let glyph = UIImageView()
    private let badge = ActivityBadgeView(pointSize: 22)
    private let title = UILabel()
    private let body = UILabel()
    private let idle = UIStackView()
    private var ratio: NSLayoutConstraint?
    private var appliedRatio: CGFloat = 0
    private var clock: Task<Void, Never>?

    private static let floor: CGFloat = 240
    private static let ceiling: CGFloat = 460

    override init(frame: CGRect) {
        super.init(frame: frame)
        stage.backgroundColor = Theme.Color.codeBackground
        stage.layer.cornerRadius = Theme.Radius.card
        stage.layer.cornerCurve = .continuous
        stage.clipsToBounds = true
        stage.translatesAutoresizingMaskIntoConstraints = false
        picture.contentMode = .scaleAspectFit
        picture.translatesAutoresizingMaskIntoConstraints = false
        picture.isAccessibilityElement = false
        glyph.contentMode = .center
        glyph.tintColor = Theme.Color.tertiaryLabel
        badge.translatesAutoresizingMaskIntoConstraints = false
        title.numberOfLines = 2
        title.textAlignment = .center
        body.numberOfLines = 3
        body.textAlignment = .center
        idle.axis = .vertical
        idle.alignment = .center
        idle.spacing = Theme.Spacing.s
        idle.translatesAutoresizingMaskIntoConstraints = false
        [glyph, badge, title, body].forEach(idle.addArrangedSubview)

        contentView.addSubview(stage)
        stage.addSubview(picture)
        stage.addSubview(idle)
        let cap = stage.heightAnchor.constraint(lessThanOrEqualToConstant: Self.ceiling)
        cap.priority = .required
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            stage.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
            stage.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            stage.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            stage.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.floor),
            cap,
            picture.topAnchor.constraint(equalTo: stage.topAnchor),
            picture.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            picture.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            idle.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            idle.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            idle.leadingAnchor.constraint(
                greaterThanOrEqualTo: stage.leadingAnchor, constant: Theme.Spacing.l),
            idle.trailingAnchor.constraint(
                lessThanOrEqualTo: stage.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        stage.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(stageTapped)))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        clock?.cancel()
        clock = nil
        onOpen = nil
    }

    func apply(_ reading: ImageStageReading) {
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = Theme.Color.groupedSurface
        backgroundConfiguration = background
        applyShape(of: reading.picture?.aspect ?? reading.slot.aspect)
        applyStage(reading)
    }

    /// The stage takes the shape of the picture on it — or, with none, of the one being asked for
    /// — inside a floor and a ceiling, so a portrait render is tall and neither shape takes the
    /// whole screen.
    private func applyShape(of aspect: ImageGenAspect) {
        let pixels = aspect.pixels
        let wanted = CGFloat(pixels.height) / CGFloat(max(pixels.width, 1))
        guard wanted != appliedRatio else { return }
        appliedRatio = wanted
        ratio?.isActive = false
        let pin = stage.heightAnchor.constraint(equalTo: stage.widthAnchor, multiplier: wanted)
        pin.priority = UILayoutPriority(999)
        pin.isActive = true
        ratio = pin
    }

    private func applyStage(_ reading: ImageStageReading) {
        clock?.cancel()
        clock = nil
        if let image = reading.image, !reading.slot.isBusy {
            picture.image = image
            picture.isHidden = false
            idle.isHidden = true
            badge.activity = nil
            stage.isUserInteractionEnabled = true
            accessibilityLabel = reading.picture.map(ImageGenFacts.caption(for:))
            accessibilityTraits = [.image, .button]
            isAccessibilityElement = true
            return
        }
        picture.image = nil
        picture.isHidden = true
        idle.isHidden = false
        stage.isUserInteractionEnabled = false
        accessibilityTraits = []
        switch reading.slot.phase {
        case .painting:
            badge.activity = .working
            badge.isHidden = false
            glyph.isHidden = true
            show(title: reading.slot.activePrompt ?? "", tone: Theme.Color.label)
            startClock(reading)
        case .failed(_, let reason):
            badge.activity = nil
            badge.isHidden = true
            glyph.isHidden = false
            showGlyph("exclamationmark.triangle", tint: Theme.Color.danger)
            show(title: reason, tone: Theme.Color.danger)
            show(body: reading.slot.activePrompt ?? "")
        case .asking, .composing:
            badge.activity = nil
            badge.isHidden = true
            glyph.isHidden = false
            showGlyph(ImageGenEntryPoint.symbol, tint: Theme.Color.tertiaryLabel)
            show(title: ImageGenWords.emptyTitle, tone: Theme.Color.label)
            show(body: ImageGenWords.emptyBody)
        }
        isAccessibilityElement = true
        accessibilityLabel = [title.text, body.text].compactMap { $0 }.joined(separator: ", ")
    }

    /// One second is the whole resolution a wait like this needs, and the clock stops the moment
    /// the render does — a cell that keeps a timer alive over a settled state spends frames on
    /// nothing.
    private func startClock(_ reading: ImageStageReading) {
        show(body: reading.slot.waitingLine(since: reading.startedAt))
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.show(body: reading.slot.waitingLine(since: reading.startedAt))
            }
        }
    }

    private func showGlyph(_ symbol: String, tint: UIColor) {
        glyph.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .regular))
        glyph.tintColor = tint
    }

    private func show(title words: String, tone: UIColor) {
        title.isHidden = words.isEmpty
        title.attributedText = NSAttributedString(
            string: words,
            attributes: Theme.Ramp.attributes(.cardTitle, color: tone, alignment: .center))
    }

    private func show(body words: String) {
        body.isHidden = words.isEmpty
        body.attributedText = NSAttributedString(
            string: words,
            attributes: Theme.Ramp.attributes(
                .panelFootnote, color: Theme.Color.secondaryLabel, alignment: .center))
    }

    @objc private func stageTapped() {
        onOpen?()
    }
}

/// The words that made the picture, and what it cost. Facts rather than a caption: the prompt is
/// what a person reads before deciding whether to roll again, and the line under it is mono and
/// tabular so a column of renders can be compared down the page.
final class ImageFactsCell: UICollectionViewListCell {
    private let caption = UILabel()
    private let facts = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        caption.numberOfLines = 4
        facts.numberOfLines = 1
        facts.lineBreakMode = .byTruncatingTail
        let column = UIStackView(arrangedSubviews: [caption, facts])
        column.axis = .vertical
        column.spacing = Theme.Spacing.xs
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.s),
            column.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.s),
            column.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            column.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ picture: ImageGenPicture) {
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = Theme.Color.groupedSurface
        backgroundConfiguration = background
        caption.attributedText = NSAttributedString(
            string: ImageGenFacts.caption(for: picture),
            attributes: Theme.Ramp.attributes(.cardBody, color: Theme.Color.label))
        facts.attributedText = NSAttributedString(
            string: ImageGenFacts.line(for: picture),
            attributes: Theme.Ramp.attributes(.responseStat, color: Theme.Color.tertiaryLabel))
        isAccessibilityElement = true
        accessibilityLabel = "\(ImageGenFacts.caption(for: picture)), \(ImageGenFacts.line(for: picture))"
    }
}

/// What a finished picture can be made to do, which is the reason this is a place rather than a
/// button. Every verb says what it promises before it is pressed, the one that destroys something
/// is drawn in the failure colour, and they wrap onto as many rows as they need — a verb behind a
/// scroll edge is a verb nobody finds.
final class ImageActionsCell: UICollectionViewListCell {
    var onAction: ((ImageGenAction) -> Void)?

    private let wrap = WrapRow()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wrap.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(wrap)
        NSLayoutConstraint.activate([
            wrap.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            wrap.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.s),
            wrap.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            wrap.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAction = nil
    }

    func apply(holding reference: Bool) {
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = Theme.Color.groupedSurface
        backgroundConfiguration = background
        wrap.set(ImageGenAction.forPicture.map { button(for: $0, holding: reference) })
    }

    private func button(for action: ImageGenAction, holding reference: Bool) -> UIButton {
        var config = Theme.Glass.buttonConfiguration()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.imagePadding = Theme.Spacing.xs
        config.image = UIImage(
            systemName: action.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        var title = AttributedString(action.title)
        title.font = Theme.Ramp.font(.sectionLabel)
        config.attributedTitle = title
        if action.isDestructive { config.baseForegroundColor = Theme.Color.danger }
        let button = UIButton(configuration: config)
        button.addAction(
            UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
        button.accessibilityLabel = action.title
        button.accessibilityHint = action.hint
        button.isEnabled = action != .reference || !reference
        return button
    }
}

/// A row of controls that becomes as many rows as the width needs. Everything here is one press
/// away, which a horizontal scroller cannot promise: what sits past its edge is a verb the reader
/// has no reason to believe exists.
final class WrapRow: UIView {
    private let spacing = Theme.Spacing.s
    private var measured: CGFloat = 0

    func set(_ views: [UIView]) {
        subviews.forEach { $0.removeFromSuperview() }
        views.forEach(addSubview)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        for view in subviews {
            let size = view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            if x > 0, x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            view.frame = CGRect(
                x: x, y: y, width: min(size.width, width), height: size.height)
            x += size.width + spacing
            line = max(line, size.height)
        }
        let total = y + line
        guard abs(total - measured) > 0.5 else { return }
        measured = total
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: measured)
    }
}

/// Everything made this session, newest first, as one strip. A picture is a thing you compare
/// against the words that made it, so nothing is overwritten and the one on the stage is marked.
final class ImageHistoryCell: UICollectionViewListCell {
    var onPick: ((String) -> Void)?

    private let heading = UILabel()
    private let scrollView = UIScrollView()
    private let row = UIStackView()

    private static let thumb: CGFloat = 64

    override init(frame: CGRect) {
        super.init(frame: frame)
        heading.numberOfLines = 1
        heading.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(row)
        contentView.addSubview(heading)
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.s),
            heading.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            heading.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            scrollView.topAnchor.constraint(
                equalTo: heading.bottomAnchor, constant: Theme.Spacing.s),
            scrollView.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
            scrollView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            scrollView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            row.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: Self.thumb),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        onPick = nil
    }

    func apply(pictures: [ImageGenPicture], current: String?, thumbnails: [String: UIImage]) {
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = Theme.Color.groupedSurface
        backgroundConfiguration = background
        heading.attributedText = NSAttributedString(
            string: ImageGenWords.historyTitle(count: pictures.count),
            attributes: Theme.Ramp.attributes(.sectionLabel, color: Theme.Color.secondaryLabel))
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for picture in pictures {
            row.addArrangedSubview(
                tile(
                    picture, image: thumbnails[picture.path],
                    on: picture.path == (current ?? pictures.first?.path)))
        }
    }

    private func tile(_ picture: ImageGenPicture, image: UIImage?, on: Bool) -> UIButton {
        let button = UIButton(type: .custom)
        button.setImage(image, for: .normal)
        button.imageView?.contentMode = .scaleAspectFill
        button.backgroundColor = Theme.Color.codeBackground
        button.clipsToBounds = true
        button.layer.cornerRadius = Theme.Radius.control
        button.layer.cornerCurve = .continuous
        button.layer.borderWidth = on ? 2 : 0
        button.layer.borderColor = Theme.Color.accent.cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.thumb),
            button.heightAnchor.constraint(equalToConstant: Self.thumb),
        ])
        let path = picture.path
        button.addAction(UIAction { [weak self] _ in self?.onPick?(path) }, for: .touchUpInside)
        button.accessibilityLabel = ImageGenFacts.caption(for: picture)
        button.accessibilityTraits = on ? [.button, .selected] : [.button]
        return button
    }
}

/// One decision, worn as a control, in both places a picture is composed — the studio's dock and
/// the composer's lane. A press walks the value because a chip is a value that walks; the whole
/// short list is a press and a hold away, because a phone has no tooltip to say what the other
/// shapes are called.
enum ImageChip {
    @MainActor
    static func button(symbol: String, title: String) -> UIButton {
        var config = Theme.Glass.buttonConfiguration()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.imagePadding = Theme.Spacing.xs
        config.titleLineBreakMode = .byTruncatingTail
        config.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        var name = AttributedString(title)
        name.font = Theme.Ramp.font(.sectionLabel)
        config.attributedTitle = name
        let button = UIButton(configuration: config)
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        return button
    }

    @MainActor
    static func menu(
        for field: ImageGenField, slot: ImageGenSlot,
        onEngine: @escaping (ImageGenEngine) -> Void,
        onAspect: @escaping (ImageGenAspect) -> Void
    ) -> UIMenu {
        switch field {
        case .engine:
            return UIMenu(
                title: field.label,
                children: ImageGenEngine.allCases.map { engine in
                    UIAction(
                        title: engine.short, subtitle: engine.label,
                        state: engine == slot.engine ? .on : .off
                    ) { _ in onEngine(engine) }
                })
        case .aspect:
            return UIMenu(
                title: field.label,
                children: ImageGenAspect.allCases.map { aspect in
                    UIAction(
                        title: aspect.short, subtitle: aspect.label,
                        state: aspect == slot.aspect ? .on : .off
                    ) { _ in onAspect(aspect) }
                })
        }
    }
}

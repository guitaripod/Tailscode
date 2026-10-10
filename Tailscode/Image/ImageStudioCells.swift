import TailscodeCore
import UIKit

/// One kept picture, drawn small. The tile asks the library for its own thumbnail and shows it
/// when it lands, keyed so a cell reused mid-flight never wears the wrong picture; the one on the
/// stage is framed in the accent.
final class ImageTileCell: UICollectionViewCell {
    private let picture = UIImageView()
    private let frameView = UIView()
    private let placeholder = UIImageView()
    private var token = UUID()
    /// How thick the accent ring is on the picture that is on the stage. The shelf strip wears a
    /// finer one than the picker's grid, because its tiles are small and a ring that eats a
    /// fifth of the picture stops being a mark and becomes a frame.
    var ringWidth: CGFloat = 3 {
        didSet { frameView.layer.borderWidth = ringWidth }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Theme.Color.codeBackground
        contentView.layer.cornerRadius = 6
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        picture.contentMode = .scaleAspectFill
        picture.translatesAutoresizingMaskIntoConstraints = false
        placeholder.contentMode = .center
        placeholder.tintColor = Theme.Color.tertiaryLabel
        placeholder.image = UIImage(
            systemName: "photo",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .light))
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        frameView.layer.borderWidth = 3
        frameView.layer.cornerRadius = 6
        frameView.layer.cornerCurve = .continuous
        frameView.isUserInteractionEnabled = false
        frameView.translatesAutoresizingMaskIntoConstraints = false
        frameView.isHidden = true
        contentView.addSubview(placeholder)
        contentView.addSubview(picture)
        contentView.addSubview(frameView)
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: contentView.topAnchor),
            picture.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            picture.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            placeholder.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            frameView.topAnchor.constraint(equalTo: contentView.topAnchor),
            frameView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            frameView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            frameView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = [.image, .button]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        token = UUID()
        picture.image = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        frameView.layer.borderColor = Theme.Color.accent.cgColor
    }

    func apply(_ item: ImageGenLibraryItem, library: ImageLibrary, onStage: Bool) {
        frameView.isHidden = !onStage
        accessibilityTraits = onStage ? [.image, .button, .selected] : [.image, .button]
        let facts = library.facts(of: item)
        accessibilityLabel = facts.map(ImageGenFacts.caption(for:)) ?? item.filename
        if let held = library.cachedThumbnail(of: item) {
            picture.image = held
            return
        }
        picture.image = nil
        let mine = token
        Task { [weak self] in
            let image = await library.thumbnail(of: item)
            guard let self, self.token == mine, let image else { return }
            UIView.transition(with: self.picture, duration: 0.18, options: .transitionCrossDissolve) {
                self.picture.image = image
            }
        }
    }
}

/// The ink of the small marks drawn on a tile — a sampler step, a clip's length. Tiles are a fixed
/// size, so the mark answers Larger Text up to a ceiling and stops rather than outgrowing them.
enum StudioBadge {
    @MainActor
    static var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return [
            .font: Theme.Font.capped(.caption2, maximum: 11), .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
        ]
    }
}

/// The render in flight, leading the shelf as a tile that wears the sketch: the machine's own
/// picture so far, the sampler's step in the corner and the same fraction along the foot. Before
/// a sketch exists it breathes on the vocabulary's own swell, and a render whose machine sends no
/// sketches stays a breathing tile rather than a blank one. It is never a picture on the machine,
/// so pressing it puts nothing on the stage.
final class ImageJobTileCell: UICollectionViewCell {
    private let picture = UIImageView()
    private let badge = ActivityBadgeView(pointSize: 18)
    private let step = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private var fraction: Double?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Theme.Color.codeBackground
        contentView.layer.cornerRadius = 8
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        picture.contentMode = .scaleAspectFill
        picture.isAccessibilityElement = false
        badge.activity = .working
        step.numberOfLines = 1
        step.textAlignment = .center
        step.layer.cornerRadius = 7
        step.layer.masksToBounds = true
        step.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        step.isAccessibilityElement = false
        track.backgroundColor = Theme.Color.separator
        fill.backgroundColor = Theme.Color.accent
        [picture, badge, step, track, fill].forEach { contentView.addSubview($0) }
        isAccessibilityElement = true
        accessibilityTraits = [.updatesFrequently]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        picture.frame = bounds
        badge.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        badge.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let size = step.sizeThatFits(CGSize(width: bounds.width, height: 16))
        step.frame = CGRect(x: 4, y: 4, width: min(bounds.width - 8, size.width + 8), height: 14)
        track.frame = CGRect(x: 0, y: bounds.height - 3, width: bounds.width, height: 3)
        fill.frame = CGRect(
            x: 0, y: bounds.height - 3, width: bounds.width * CGFloat(fraction ?? 0), height: 3)
    }

    func apply(sketch: UIImage?, progress: ImageGenProgress?, words: String) {
        var stepWords: String?
        if let step = progress?.step, let steps = progress?.steps, steps > 0 {
            stepWords = "\(min(step, steps))/\(steps)"
        }
        apply(sketch: sketch, step: stepWords, fraction: progress?.bar, words: words)
    }

    func apply(sketch: UIImage?, step stepWords: String?, fraction share: Double?, words: String) {
        picture.image = sketch
        badge.isHidden = sketch != nil
        step.isHidden = stepWords == nil
        step.attributedText = NSAttributedString(
            string: stepWords ?? "",
            attributes: StudioBadge.attributes)
        fraction = share
        track.isHidden = fraction == nil
        fill.isHidden = fraction == nil
        accessibilityLabel = words
        setNeedsLayout()
    }
}

/// What the shelf says when it has no tiles: that it is asking, that there is nothing yet, or why
/// it could not ask — in the machine's name, on one line, never as a blank.
final class ImageStripNoteCell: UICollectionViewCell {
    private let label = UILabel()
    private let spinner = ActivityBadgeView(pointSize: 14)

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 3
        let row = UIStackView(arrangedSubviews: [spinner, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ state: ImageLibrary.State, machine: String) {
        let words: String
        let ink: UIColor
        switch state {
        case .idle, .loading:
            words = ImageGenLibraryWords.loading
            ink = Theme.Color.secondaryLabel
            spinner.working(true)
        case .loaded:
            words = ImageGenLibraryWords.emptyBody
            ink = Theme.Color.secondaryLabel
            spinner.working(false)
        case .failed(let reason):
            words = reason
            ink = Theme.Color.warning
            spinner.working(false)
        }
        show(words: words, ink: ink, machine: ImageGenLibraryWords.heading(machine: machine))
    }

    /// The same line for a shelf that is not the machine's gallery — a forge with no clips yet.
    func apply(words: String, machine: String) {
        spinner.working(false)
        show(words: words, ink: Theme.Color.secondaryLabel, machine: machine)
    }

    private func show(words: String, ink: UIColor, machine: String) {
        label.attributedText = NSAttributedString(
            string: words, attributes: Theme.Ramp.attributes(.panelFootnote, color: ink))
        isAccessibilityElement = true
        accessibilityLabel = "\(machine), \(words)"
    }
}

/// One decision, worn as a control, in both places a picture is composed — the studio's dock and
/// the composer's lane. A press walks the value because a chip is a value that walks; the whole
/// short list is a press and a hold away, because a phone has no tooltip to say what the other
/// shapes are called.
enum ImageChip {
    @MainActor
    static func button(
        symbol: String, title: String, image: UIImage? = nil, traits: UITraitCollection = .current
    ) -> UIButton {
        var config = Theme.Glass.buttonConfiguration()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.imagePadding = Theme.Spacing.xs
        config.titleLineBreakMode = .byTruncatingTail
        if let image {
            let side: CGFloat = 20
            let format = UIGraphicsImageRendererFormat.matching(traits)
            let thumb = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
                .image { _ in
                    let path = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: 5)
                    path.addClip()
                    let scale = max(side / image.size.width, side / image.size.height)
                    let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(
                        in: CGRect(
                            x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                            width: drawn.width, height: drawn.height))
                }
            config.image = thumb.withRenderingMode(.alwaysOriginal)
        } else {
            config.image = UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        }
        var name = AttributedString(title)
        name.font = Theme.Ramp.font(.sectionLabel)
        config.attributedTitle = name
        let button = UIButton(configuration: config)
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        return button
    }

    /// The engine list says what each engine is for and which the machine, as last seen, cannot
    /// run — greyed with the count of files it lacks, rather than offered and refused at send.
    @MainActor
    static func engineMenu(
        slot: ImageGenSlot, sighting: ImageGenSighting?, onEngine: @escaping (ImageGenEngine) -> Void
    ) -> UIMenu {
        UIMenu(
            title: ImageGenField.engine.label,
            children: ImageGenEngine.allCases.map { engine in
                let missing = sighting?.reachable == true ? sighting?.missing(for: engine).count ?? 0 : 0
                let subtitle = missing > 0
                    ? ImageGenWords.engineUnavailable(engine, missing: missing) : engine.detail
                return UIAction(
                    title: engine.short, subtitle: subtitle,
                    image: missing > 0 ? UIImage(systemName: "exclamationmark.triangle") : nil,
                    state: engine == slot.engine ? .on : .off
                ) { _ in onEngine(engine) }
            })
    }

    @MainActor
    static func aspectMenu(slot: ImageGenSlot, onAspect: @escaping (ImageGenAspect) -> Void) -> UIMenu {
        let size = slot.size
        return UIMenu(
            title: ImageGenField.aspect.label,
            children: ImageGenAspect.allCases.map { aspect in
                UIAction(
                    title: "\(aspect.glyph)  \(aspect.short) · \(aspect.ratioLabel)",
                    subtitle: aspect.label(size),
                    state: aspect == slot.aspect ? .on : .off
                ) { _ in onAspect(aspect) }
            })
    }

    /// How many pixels the shape is filled with, and what each rung costs — the middle one is
    /// what the model paints natively and the top one is its real 2K, not an upscale.
    @MainActor
    static func sizeMenu(slot: ImageGenSlot, onSize: @escaping (ImageGenSize) -> Void) -> UIMenu {
        let aspect = slot.aspect
        return UIMenu(
            title: ImageGenField.size.label,
            children: ImageGenSize.allCases.map { size in
                UIAction(
                    title: "\(size.title) · \(aspect.label(size))", subtitle: size.detail,
                    state: size == slot.size ? .on : .off
                ) { _ in onSize(size) }
            })
    }

    @MainActor
    static func detailMenu(slot: ImageGenSlot, onDetail: @escaping (ImageGenDetail) -> Void) -> UIMenu {
        UIMenu(
            title: ImageGenField.detail.label,
            children: ImageGenDetail.allCases.map { detail in
                UIAction(
                    title: detail.short, subtitle: detail.detail,
                    state: detail == slot.detail ? .on : .off
                ) { _ in onDetail(detail) }
            })
    }

    /// The craft, as six rules that cannot be pressed and four briefs that can: pressing one
    /// fills the composer and sends nothing.
    @MainActor
    static func craftMenu(onExample: @escaping (ImageGenBrief.Example) -> Void) -> UIMenu {
        let rules = ImageGenBrief.rules.map { rule in
            let action = UIAction(title: rule.title, subtitle: rule.detail) { _ in }
            action.attributes = .disabled
            return action
        }
        let examples = ImageGenBrief.examples.map { example in
            UIAction(
                title: example.title, subtitle: example.detail,
                image: UIImage(systemName: "text.badge.plus")
            ) { _ in onExample(example) }
        }
        return UIMenu(
            title: ImageGenBrief.craftTitle,
            children: [
                UIMenu(title: "", options: .displayInline, children: examples),
                UIMenu(title: "", options: .displayInline, children: rules),
            ])
    }

    /// The sources a reference can come from on this device, as menu rows.
    @MainActor
    static func sourceActions(
        available: [ImageGenReferenceSource], onPick: @escaping (ImageGenReferenceSource) -> Void
    ) -> [UIAction] {
        available.map { source in
            UIAction(title: source.title, image: UIImage(systemName: source.symbol)) { _ in
                onPick(source)
            }
        }
    }
}

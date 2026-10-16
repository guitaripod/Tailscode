import ImageIO
import TailscodeCore
import UIKit

/// What a failed build looks like over the picture that still works: the plain-words headline, the
/// compiler's first problem in mono ink, and the one button that hands it to the agent. An opaque
/// card on the canvas, because it is content the reader acts on, not a control floating over it.
@MainActor
final class PreviewBannerView: UIView {
    var onAsk: (() -> Void)?

    private let headline = UILabel()
    private let problemLabel = UILabel()
    private let problemBox = UIView()
    private let ask = UIButton(type: .system)
    private(set) var problem = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        backgroundColor = Theme.Color.groupedSurface
        layer.cornerRadius = Theme.Radius.card + 6
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.5
        layer.borderColor = Theme.Color.danger.resolvedColor(with: traitCollection).cgColor
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: PreviewBannerView, _) in
            view.layer.borderColor = Theme.Color.danger.resolvedColor(with: view.traitCollection).cgColor
        }

        let mark = UIImageView(
            image: UIImage(
                systemName: "exclamationmark.circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)))
        mark.tintColor = Theme.Color.danger
        mark.setContentHuggingPriority(.required, for: .horizontal)
        mark.isAccessibilityElement = false

        headline.font = Theme.Ramp.font(.rowTitleStrong)
        headline.textColor = Theme.Color.label
        headline.numberOfLines = 0
        headline.adjustsFontForContentSizeCategory = true
        let top = UIStackView(arrangedSubviews: [mark, headline])
        top.alignment = .top
        top.spacing = Theme.Spacing.m

        problemLabel.font = Theme.Ramp.font(.code)
        problemLabel.textColor = Theme.Color.danger
        problemLabel.numberOfLines = 5
        problemLabel.lineBreakMode = .byTruncatingTail
        problemLabel.adjustsFontForContentSizeCategory = true
        problemLabel.translatesAutoresizingMaskIntoConstraints = false
        problemBox.backgroundColor = Theme.Color.codeBackground
        problemBox.layer.cornerRadius = Theme.Radius.control
        problemBox.layer.cornerCurve = .continuous
        problemBox.addSubview(problemLabel)
        NSLayoutConstraint.activate([
            problemLabel.topAnchor.constraint(equalTo: problemBox.topAnchor, constant: Theme.Spacing.s),
            problemLabel.bottomAnchor.constraint(equalTo: problemBox.bottomAnchor, constant: -Theme.Spacing.s),
            problemLabel.leadingAnchor.constraint(equalTo: problemBox.leadingAnchor, constant: Theme.Spacing.m),
            problemLabel.trailingAnchor.constraint(equalTo: problemBox.trailingAnchor, constant: -Theme.Spacing.m),
        ])

        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = Theme.Color.accent
        config.baseForegroundColor = Theme.Color.onAccent
        config.title = Localized.text("Ask the agent to fix it")
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Ramp.font(ChatChrome.chipRole)
            return outgoing
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        ask.configuration = config
        ask.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        ask.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                self?.onAsk?()
            }, for: .touchUpInside)

        let column = UIStackView(arrangedSubviews: [top, problemBox, ask])
        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.l),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.l),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
        ])
        isHidden = true
    }

    func show(headline text: String, problem line: String?) {
        headline.text = text
        problem = line ?? ""
        problemLabel.text = problem
        problemBox.isHidden = problem.isEmpty
    }
}

/// A short word over the top of a dimmed picture, in an opaque capsule on the canvas.
@MainActor
final class PreviewChipLabel: UIView {
    private let label = UILabel()

    var text: String {
        get { label.text ?? "" }
        set { label.text = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = ChatChip.fillColor(share: ChatChrome.fill(.fact).inkShare)
        layer.cornerCurve = .continuous
        label.font = Theme.Ramp.font(ChatChrome.chipRole)
        label.textColor = Theme.Color.label
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.xs + 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(Theme.Spacing.xs + 2)),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (chip: PreviewChipLabel, _) in
            chip.backgroundColor = ChatChip.fillColor(share: ChatChrome.fill(.fact).inkShare)
        }
        isUserInteractionEnabled = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

/// The newest picture, drawn by handing the layer the decoded image rather than drawing it again:
/// the compositor scales it, and a stream of sixty pictures a second costs one assignment each.
/// Its corners follow the device it shows, so the picture reads as the phone's own screen.
@MainActor
final class PreviewPictureView: UIView {
    private(set) var image: CGImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        layer.minificationFilter = .trilinear
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        isOpaque = true
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ next: CGImage) {
        image = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = traitCollection.displayScale
        layer.contents = next
        CATransaction.commit()
    }

    func clear() {
        image = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = nil
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = Self.cornerRadius(for: bounds.size)
        CATransaction.commit()
    }

    /// A phone's screen is rounded in proportion to its width and an iPad's barely at all, so the
    /// shape of the picture says which of the two it is showing.
    static func cornerRadius(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 0 }
        let narrow = min(size.width, size.height)
        let tall = max(size.width, size.height) / narrow > 1.6
        return narrow * (tall ? 0.135 : 0.035)
    }
}

/// The live face: the newest picture aspect-fitted into the room the controls leave, with the dim
/// word over its top and the failure card over its foot. It is placed by frame rather than by
/// constraint because the picture's shape arrives with its first frame and changes with the
/// device, and a layout pass per frame is not something a stream should cost.
@MainActor
final class PreviewLiveView: UIView {
    let banner = PreviewBannerView()
    let picture = PreviewPictureView()
    private let host = UIView()
    private let chipLabel = PreviewChipLabel()
    private let stale: CGFloat = 0.55
    private lazy var bannerBottom = banner.bottomAnchor.constraint(equalTo: bottomAnchor)

    var contentInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16) {
        didSet {
            guard contentInsets != oldValue else { return }
            bannerBottom.constant = -contentInsets.bottom
            setNeedsLayout()
        }
    }

    var image: CGImage? { picture.image }
    var pictureAlpha: CGFloat { picture.alpha }
    var chipWords: String? { chipLabel.isHidden ? nil : chipLabel.text }

    override init(frame: CGRect) {
        super.init(frame: frame)
        host.addSubview(picture)
        banner.translatesAutoresizingMaskIntoConstraints = false
        chipLabel.translatesAutoresizingMaskIntoConstraints = false
        chipLabel.isHidden = true
        host.addSubview(chipLabel)
        addSubview(host)
        addSubview(banner)
        NSLayoutConstraint.activate([
            chipLabel.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            chipLabel.topAnchor.constraint(equalTo: host.topAnchor, constant: Theme.Spacing.m),
            chipLabel.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -Theme.Spacing.l),
            banner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
            bannerBottom,
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ image: CGImage) {
        let reshaped = picture.image.map { $0.width != image.width || $0.height != image.height } ?? true
        picture.show(image)
        if reshaped { setNeedsLayout() }
    }

    func clear() {
        picture.clear()
        setNeedsLayout()
    }

    func setDimmed(_ dimmed: Bool, words: String) {
        let target: CGFloat = dimmed ? stale : 1
        if picture.alpha != target {
            if UIAccessibility.isReduceMotionEnabled {
                picture.alpha = target
            } else {
                UIView.animate(withDuration: 0.2) { self.picture.alpha = target }
            }
        }
        chipLabel.isHidden = !dimmed
        chipLabel.text = words
    }

    func setAccessibility(_ label: String) {
        picture.accessibilityLabel = label
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let room = bounds.inset(by: contentInsets)
        guard let image = picture.image, room.width > 0, room.height > 0 else {
            host.frame = .zero
            return
        }
        let ratio = CGFloat(image.width) / CGFloat(image.height)
        var fitted = CGSize(width: room.height * ratio, height: room.height)
        if fitted.width > room.width { fitted = CGSize(width: room.width, height: room.width / ratio) }
        let scale = traitCollection.displayScale
        func snapped(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        host.frame = CGRect(
            x: snapped(room.midX - fitted.width / 2), y: snapped(room.midY - fitted.height / 2),
            width: snapped(fitted.width), height: snapped(fitted.height))
        picture.frame = host.bounds
    }
}

extension PreviewPictureView {
    /// Decodes a JPEG once, fully, so the layer is handed pixels and the compositor never has to
    /// decode lazily on its own thread in the middle of a frame.
    nonisolated static func decode(_ bytes: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }
}

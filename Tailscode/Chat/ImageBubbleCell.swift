import CodingAgentKit
import TailscodeCore
import UIKit

@MainActor
protocol ImageBubbleCellDelegate: AnyObject {
    func imageBubbleCell(_ cell: ImageBubbleCell, didTap image: UIImage, from view: UIView)
    func imageBubbleCell(_ cell: ImageBubbleCell, menuFor payload: ImagePayload) -> UIMenu
}

/// An attached image, rendered at the size it actually is (capped) rather than
/// in a fixed box, so a screenshot reads as a screenshot and a photo as a photo.
/// A picture the agent sent names itself underneath; one you sent needs no
/// caption and is drawn small (``ImagePreview``) — you already know what you
/// handed over, and a tap still opens it full size. Press and hold for the
/// things you do with a picture, or drag it straight into another app.
final class ImageBubbleCell: UICollectionViewCell {
    static let reuseID = "ImageBubbleCell"
    weak var delegate: ImageBubbleCellDelegate?
    /// Called once the bytes land, so the list can re-measure a row that was
    /// laid out against a placeholder ratio — a self-sizing cell keeps the
    /// height it was first given otherwise, and the image renders cropped.
    var onLoaded: (() -> Void)?

    private let bubble = UIView()
    private let imageView = UIImageView()
    private let caption = UILabel()
    private let shimmer = CAGradientLayer()
    private let failure = UILabel()
    private var leadingPin: NSLayoutConstraint!
    private var trailingPin: NSLayoutConstraint!
    private var bubbleTop: NSLayoutConstraint!
    private var imageBottomPin: NSLayoutConstraint!
    private var captionBottomPin: NSLayoutConstraint!
    private var ratio: NSLayoutConstraint?
    private var widthPin: NSLayoutConstraint!
    private var maxHeightPin: NSLayoutConstraint!
    private var loadToken = UUID()
    private var file: FileReference?
    private var originalData: Data?

    private static let maxHeight: CGFloat = 300
    private static let bubbleShare: CGFloat = 0.72

    /// Extra gap above the bubble when this row opens a new turn.
    var turnInset: CGFloat = 0 {
        didSet { bubbleTop.constant = Theme.Spacing.xs + turnInset }
    }

    var displayedImage: UIImage? { imageView.image }
    var imageContainer: UIView { imageView }

    var payload: ImagePayload? {
        guard let image = imageView.image else { return nil }
        return ImagePayload(
            image: image, data: originalData, filename: file?.displayName ?? "")
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.layer.cornerRadius = Theme.Radius.bubble
        bubble.layer.cornerCurve = .continuous
        bubble.clipsToBounds = true
        bubble.backgroundColor = Theme.Color.assistantBubble
        bubble.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.isUserInteractionEnabled = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = [.image, .button]
        imageView.translatesAutoresizingMaskIntoConstraints = false
        caption.font = Theme.Ramp.font(.panelFootnote)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = Theme.Color.secondaryLabel
        caption.lineBreakMode = .byTruncatingMiddle
        caption.isHidden = true
        caption.translatesAutoresizingMaskIntoConstraints = false
        failure.font = Theme.Ramp.font(.panelFootnote)
        failure.textColor = Theme.Color.tertiaryLabel
        failure.textAlignment = .center
        failure.numberOfLines = 2
        failure.isHidden = true
        failure.translatesAutoresizingMaskIntoConstraints = false
        shimmer.colors = [
            UIColor.clear.cgColor, UIColor.white.withAlphaComponent(0.14).cgColor,
            UIColor.clear.cgColor,
        ]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        bubble.layer.addSublayer(shimmer)
        contentView.addSubview(bubble)
        bubble.addSubview(imageView)
        bubble.addSubview(caption)
        bubble.addSubview(failure)

        leadingPin = bubble.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l)
        trailingPin = bubble.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l)
        widthPin = Self.widthPin(bubble: bubble, container: contentView, mine: false)
        maxHeightPin = imageView.heightAnchor.constraint(
            lessThanOrEqualToConstant: Self.maxHeight)
        bubbleTop = bubble.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: Theme.Spacing.xs)
        imageBottomPin = imageView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor)
        captionBottomPin = caption.bottomAnchor.constraint(
            equalTo: bubble.bottomAnchor, constant: -Theme.Spacing.s)
        imageBottomPin.isActive = true
        NSLayoutConstraint.activate([
            bubbleTop,
            bubble.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            widthPin,
            maxHeightPin,
            imageView.topAnchor.constraint(equalTo: bubble.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            caption.topAnchor.constraint(
                equalTo: imageView.bottomAnchor, constant: Theme.Spacing.s),
            caption.leadingAnchor.constraint(
                equalTo: bubble.leadingAnchor, constant: Theme.Spacing.m),
            caption.trailingAnchor.constraint(
                equalTo: bubble.trailingAnchor, constant: -Theme.Spacing.m),
            failure.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            failure.leadingAnchor.constraint(
                equalTo: bubble.leadingAnchor, constant: Theme.Spacing.m),
            failure.trailingAnchor.constraint(
                equalTo: bubble.trailingAnchor, constant: -Theme.Spacing.m),
        ])
        imageView.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        imageView.addInteraction(UIContextMenuInteraction(delegate: self))
        let drag = UIDragInteraction(delegate: self)
        drag.isEnabled = true
        imageView.addInteraction(drag)
        NotificationCenter.default.addObserver(
            self, selector: #selector(retuneShimmer),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        shimmer.frame = bubble.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadToken = UUID()
        imageView.image = nil
        imageView.alpha = 1
        failure.isHidden = true
        caption.isHidden = true
        imageBottomPin.isActive = true
        captionBottomPin.isActive = false
        file = nil
        originalData = nil
        delegate = nil
        onLoaded = nil
    }

    func configure(
        file: FileReference, role: MessageRole, backend: any CodingAgentBackend,
        localData: Data? = nil
    ) {
        let isUser = role == .user
        applyDirection(mine: isUser)
        leadingPin.constant = isUser ? Theme.Spacing.l : Theme.Spacing.s
        trailingPin.constant = isUser ? -Theme.Spacing.l : -Theme.Spacing.s
        leadingPin.isActive = !isUser
        trailingPin.isActive = isUser
        self.file = file
        self.originalData = localData
        imageView.accessibilityLabel = file.displayName
        showCaption(isUser ? nil : file.displayName)
        if let cached = AttachmentImageStore.shared.cached(file) {
            originalData = localData ?? AttachmentImageStore.shared.cachedData(file)
            show(cached, animated: false)
            return
        }
        if let localData, let image = UIImage(data: localData) {
            AttachmentImageStore.shared.store(image, for: file, data: localData)
            show(image, animated: false)
            return
        }
        startShimmer()
        let token = loadToken
        Task { [weak self] in
            let image = await AttachmentImageStore.shared.image(for: file, using: backend)
            guard let self, self.loadToken == token else { return }
            guard let image else {
                self.showFailure(file)
                return
            }
            self.originalData = AttachmentImageStore.shared.cachedData(file)
            self.show(image, animated: true)
            self.onLoaded?()
        }
    }

    /// A picture you sent is a receipt, not something to read: it keeps the same shape and the
    /// same tap, at ``ImagePreview``'s share of the box a picture from the agent gets.
    private func applyDirection(mine: Bool) {
        maxHeightPin.constant = CGFloat(ImagePreview.bound(Double(Self.maxHeight), mine: mine))
        widthPin.isActive = false
        widthPin = Self.widthPin(bubble: bubble, container: contentView, mine: mine)
        widthPin.isActive = true
    }

    private static func widthPin(bubble: UIView, container: UIView, mine: Bool)
        -> NSLayoutConstraint
    {
        let pin = bubble.widthAnchor.constraint(
            equalTo: container.widthAnchor,
            multiplier: CGFloat(ImagePreview.share(Double(bubbleShare), mine: mine)))
        pin.priority = UILayoutPriority(999)
        return pin
    }

    /// A caption is what makes a picture from the agent legible as a file on the
    /// server rather than an image from nowhere.
    private func showCaption(_ name: String?) {
        guard let name, !name.isEmpty else {
            caption.isHidden = true
            captionBottomPin.isActive = false
            imageBottomPin.isActive = true
            return
        }
        caption.text = name
        caption.isHidden = false
        imageBottomPin.isActive = false
        captionBottomPin.isActive = true
    }

    /// The intrinsic aspect ratio drives the bubble's height, clamped so a tall
    /// screenshot cannot eat the whole scroll view.
    private func show(_ image: UIImage, animated: Bool) {
        stopShimmer()
        failure.isHidden = true
        imageView.image = image
        ratio?.isActive = false
        let aspect = max(image.size.width, 1) / max(image.size.height, 1)
        let clamped = min(max(aspect, 0.55), 2.4)
        ratio = imageView.widthAnchor.constraint(
            equalTo: imageView.heightAnchor, multiplier: clamped)
        ratio?.priority = UILayoutPriority(998)
        ratio?.isActive = true
        guard animated else { return }
        imageView.alpha = 0
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut]) {
            self.imageView.alpha = 1
        }
    }

    private func showFailure(_ file: FileReference) {
        stopShimmer()
        failure.isHidden = false
        failure.text = String(localized: "Couldn't load \(file.displayName)")
        ratio?.isActive = false
        ratio = imageView.widthAnchor.constraint(equalTo: imageView.heightAnchor, multiplier: 1.9)
        ratio?.priority = UILayoutPriority(998)
        ratio?.isActive = true
    }

    private func startShimmer() {
        shimmer.isHidden = false
        slideShimmer()
        ratio?.isActive = false
        ratio = imageView.widthAnchor.constraint(equalTo: imageView.heightAnchor, multiplier: 1.4)
        ratio?.priority = UILayoutPriority(998)
        ratio?.isActive = true
    }

    /// The wait's own motion, laid on apart from the shape it waits in, so a reader who changes
    /// their mind about movement while the bytes are still coming re-decides the motion and leaves
    /// the bubble's size exactly where it was. Whether it moves at all is the vocabulary's to say.
    private func slideShimmer() {
        let slide = CABasicAnimation(keyPath: "locations")
        slide.fromValue = [-1.0, -0.5, 0.0]
        slide.toValue = [1.0, 1.5, 2.0]
        slide.duration = 1.1
        slide.repeatCount = .infinity
        shimmer.locations = [0.0, 0.5, 1.0]
        shimmer.setPlaceholderMotion(slide, forKey: "shimmer")
    }

    /// Reads the reader's mind again when they change it mid-download. A bubble whose picture has
    /// already landed is left alone: there is no wait left to draw.
    @objc private func retuneShimmer() {
        guard !shimmer.isHidden else { return }
        slideShimmer()
    }

    private func stopShimmer() {
        shimmer.removeAnimation(forKey: "shimmer")
        shimmer.isHidden = true
    }

    @objc private func handleTap() {
        guard let image = imageView.image else { return }
        Theme.Haptics.tap()
        delegate?.imageBubbleCell(self, didTap: image, from: imageView)
    }
}

extension ImageBubbleCell: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let payload, let delegate else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [weak self] _ in
            guard let self else { return nil }
            return delegate.imageBubbleCell(self, menuFor: payload)
        }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        highlightPreviewForItemWithIdentifier identifier: NSCopying
    ) -> UITargetedPreview? {
        preview()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemWithIdentifier identifier: NSCopying
    ) -> UITargetedPreview? {
        preview()
    }

    private func preview() -> UITargetedPreview? {
        guard imageView.image != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(
            roundedRect: imageView.bounds, cornerRadius: Theme.Radius.bubble)
        return UITargetedPreview(view: imageView, parameters: parameters)
    }
}

extension ImageBubbleCell: UIDragInteractionDelegate {
    func dragInteraction(
        _ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession
    ) -> [UIDragItem] {
        guard let payload else { return [] }
        let provider = NSItemProvider(object: payload.image)
        provider.suggestedName = payload.exportFilename
        let item = UIDragItem(itemProvider: provider)
        item.localObject = payload.image
        return item.itemProvider.registeredTypeIdentifiers.isEmpty ? [] : [item]
    }

    func dragInteraction(
        _ interaction: UIDragInteraction, previewForLifting item: UIDragItem,
        session: any UIDragSession
    ) -> UITargetedDragPreview? {
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(
            roundedRect: imageView.bounds, cornerRadius: Theme.Radius.bubble)
        return UITargetedDragPreview(view: imageView, parameters: parameters)
    }
}

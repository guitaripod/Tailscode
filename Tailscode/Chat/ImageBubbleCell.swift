import CodingAgentKit
import UIKit

@MainActor
protocol ImageBubbleCellDelegate: AnyObject {
    func imageBubbleCell(_ cell: ImageBubbleCell, didTap image: UIImage, from view: UIView)
}

/// An attached image, rendered at the size it actually is (capped) rather than
/// in a fixed box, so a screenshot reads as a screenshot and a photo as a photo.
final class ImageBubbleCell: UICollectionViewCell {
    static let reuseID = "ImageBubbleCell"
    weak var delegate: ImageBubbleCellDelegate?
    /// Called once the bytes land, so the list can re-measure a row that was
    /// laid out against a placeholder ratio — a self-sizing cell keeps the
    /// height it was first given otherwise, and the image renders cropped.
    var onLoaded: (() -> Void)?

    private let bubble = UIView()
    private let imageView = UIImageView()
    private let shimmer = CAGradientLayer()
    private let failure = UILabel()
    private var leadingPin: NSLayoutConstraint!
    private var trailingPin: NSLayoutConstraint!
    private var ratio: NSLayoutConstraint?
    private var loadToken = UUID()

    private static let maxHeight: CGFloat = 260

    var displayedImage: UIImage? { imageView.image }
    var imageContainer: UIView { imageView }

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
        imageView.translatesAutoresizingMaskIntoConstraints = false
        failure.font = Theme.Font.caption()
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
        bubble.addSubview(failure)

        leadingPin = bubble.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l)
        trailingPin = bubble.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l)
        let widthPin = bubble.widthAnchor.constraint(
            equalTo: contentView.widthAnchor, multiplier: 0.72)
        widthPin.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            bubble.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            widthPin,
            bubble.heightAnchor.constraint(lessThanOrEqualToConstant: Self.maxHeight),
            imageView.topAnchor.constraint(equalTo: bubble.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            failure.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            failure.leadingAnchor.constraint(
                equalTo: bubble.leadingAnchor, constant: Theme.Spacing.m),
            failure.trailingAnchor.constraint(
                equalTo: bubble.trailingAnchor, constant: -Theme.Spacing.m),
        ])
        imageView.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleTap)))
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
        delegate = nil
        onLoaded = nil
    }

    func configure(
        file: FileReference, role: MessageRole, backend: any CodingAgentBackend,
        localData: Data? = nil
    ) {
        let isUser = role == .user
        leadingPin.isActive = !isUser
        trailingPin.isActive = isUser
        if let cached = AttachmentImageStore.shared.cached(file) {
            show(cached, animated: false)
            return
        }
        if let localData, let image = UIImage(data: localData) {
            AttachmentImageStore.shared.store(image, for: file)
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
            self.show(image, animated: true)
            self.onLoaded?()
        }
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
        failure.text = "Couldn't load \(file.displayName)"
        ratio?.isActive = false
        ratio = imageView.widthAnchor.constraint(equalTo: imageView.heightAnchor, multiplier: 1.9)
        ratio?.priority = UILayoutPriority(998)
        ratio?.isActive = true
    }

    private func startShimmer() {
        shimmer.isHidden = false
        let slide = CABasicAnimation(keyPath: "locations")
        slide.fromValue = [-1.0, -0.5, 0.0]
        slide.toValue = [1.0, 1.5, 2.0]
        slide.duration = 1.1
        slide.repeatCount = .infinity
        shimmer.locations = [0.0, 0.5, 1.0]
        shimmer.add(slide, forKey: "shimmer")
        ratio?.isActive = false
        ratio = imageView.widthAnchor.constraint(equalTo: imageView.heightAnchor, multiplier: 1.4)
        ratio?.priority = UILayoutPriority(998)
        ratio?.isActive = true
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

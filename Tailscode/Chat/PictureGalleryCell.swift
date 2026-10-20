import CodingAgentKit
import TailscodeCore
import UIKit

@MainActor
protocol PictureGalleryCellDelegate: AnyObject {
    func pictureGalleryCell(_ cell: PictureGalleryCell, didTapFrom view: UIView)
}

/// The pictures an agent made, as one square of small tiles rather than a poster each: a turn that
/// looked at sixteen screenshots spends one picture's height on them, and the corner counts the
/// ones the square could not draw. The whole square is one press — it opens the conversation's
/// gallery on this group's first picture, where every picture can be paged through, zoomed, put in
/// Photos, copied, shared or dragged out — so the verbs a single picture used to carry in the
/// transcript are a press away on the picture itself rather than four small targets here.
///
/// The frames are `PictureGalleryLayout`'s and the height is the same arithmetic asked in
/// `preferredLayoutAttributesFitting`, so the row has its height before any picture has loaded and
/// a picture arriving changes it only when the group's first picture turns out to be a different
/// shape than the guess.
final class PictureGalleryCell: UICollectionViewCell {
    static let reuseID = "PictureGalleryCell"
    weak var delegate: PictureGalleryCellDelegate?

    /// Called once a picture's bytes land, so the list measures the row again against its real
    /// shape.
    var onLoaded: (() -> Void)?

    private var tiles: [PictureThumb] = []
    private var files: [FileReference] = []
    private var badge: UILabel?
    private var loadToken = UUID()
    private var tap: UITapGestureRecognizer?
    private static let inset = Theme.Spacing.l

    var gapAbove: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = [.image, .button]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadToken = UUID()
        tiles.forEach { $0.removeFromSuperview() }
        tiles = []
        files = []
        badge?.removeFromSuperview()
        badge = nil
        gestureRecognizers?.forEach(removeGestureRecognizer)
        tap = nil
        delegate = nil
        onLoaded = nil
    }

    func configure(files: [FileReference], backend: any CodingAgentBackend) {
        guard files != self.files else { return }
        loadToken = UUID()
        tiles.forEach { $0.removeFromSuperview() }
        badge?.removeFromSuperview()
        badge = nil
        self.files = files
        let shown = Array(files.prefix(PictureGalleryLayout.maximumTiles))
        let single = shown.count == 1
        tiles = shown.map { file in
            let tile = PictureThumb(fitted: single)
            tile.isUserInteractionEnabled = false
            tile.isAccessibilityElement = false
            contentView.addSubview(tile)
            load(file, into: tile, backend: backend)
            return tile
        }
        let hidden = PictureGalleryLayout.hidden(count: files.count)
        if hidden > 0, !tiles.isEmpty {
            let label = UILabel()
            label.text = "+\(hidden)"
            label.font = .systemFont(ofSize: 20, weight: .bold)
            label.textColor = .white
            label.textAlignment = .center
            label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            label.layer.cornerRadius = Theme.Radius.control
            label.layer.cornerCurve = .continuous
            label.layer.masksToBounds = true
            label.isUserInteractionEnabled = false
            label.isAccessibilityElement = false
            contentView.addSubview(label)
            badge = label
        }
        if tap == nil {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(pressed))
            contentView.addGestureRecognizer(recognizer)
            tap = recognizer
        }
        accessibilityLabel = PictureGalleryReading.spoken(
            count: files.count, names: files.map(\.displayName))
        setNeedsLayout()
    }

    private func load(_ file: FileReference, into tile: PictureThumb, backend: any CodingAgentBackend) {
        let store = AttachmentImageStore.shared
        let box = Self.thumbnailBox
        if let cached = store.cachedThumbnail(file, box: box) {
            tile.show(cached)
            return
        }
        let token = loadToken
        Task { [weak self, weak tile] in
            let image = await store.thumbnail(for: file, box: box, using: backend)
            guard let self, let tile, self.loadToken == token else { return }
            if let image {
                tile.show(image)
            } else {
                tile.showFailure()
            }
            self.setNeedsLayout()
            self.onLoaded?()
        }
    }

    /// The pixels a tile asks for: the square it is drawn at, so the same picture asks for the same
    /// size wherever it is drawn.
    private static var thumbnailBox: ThumbnailBox {
        .pinnedHeight(
            CGFloat(Theme.Chat.metrics.imageMaxHeight),
            maxWidth: max(0, UIScreen.main.bounds.width - 2 * inset), scale: UIScreen.main.scale)
    }

    @objc private func pressed() {
        guard !tiles.isEmpty else { return }
        Theme.Haptics.tap()
        delegate?.pictureGalleryCell(self, didTapFrom: self)
    }

    override func accessibilityActivate() -> Bool {
        pressed()
        return true
    }

    private func layout(in width: CGFloat) -> (tiles: [PictureGalleryLayout.Tile], height: CGFloat) {
        let side = PictureGalleryLayout.side(metrics: Theme.Chat.metrics, width: Double(width))
        let shape = PictureShape.shape(of: tiles.first?.aspect)
        let tiles = PictureGalleryLayout.mosaic(
            count: tiles.count, side: side, gap: Theme.Chat.metrics.imageStripGap,
            shape: tiles.count == 1 ? shape : nil, maxWidth: Double(width))
        return (tiles, side)
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let attributes = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
        let width = max(0, layoutAttributes.size.width - 2 * Self.inset)
        attributes.size.height = ceil(gapAbove + CGFloat(layout(in: width).height))
        return attributes
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !tiles.isEmpty else { return }
        let width = max(0, bounds.width - 2 * Self.inset)
        let placed = layout(in: width)
        for frame in placed.tiles where frame.index < tiles.count {
            tiles[frame.index].frame = CGRect(
                x: Self.inset + CGFloat(frame.x), y: gapAbove + CGFloat(frame.y),
                width: CGFloat(frame.width), height: CGFloat(frame.height))
        }
        if let badge, let last = placed.tiles.last {
            badge.frame = CGRect(
                x: Self.inset + CGFloat(last.x), y: gapAbove + CGFloat(last.y),
                width: CGFloat(last.width), height: CGFloat(last.height))
        }
    }
}

/// One tile of a gallery: the image cropped to the square the layout gave it.
final class PictureThumb: UIImageView {
    /// Width over height of the picture once it is known; nil while it is on its way.
    var aspect: Double? {
        guard let image, image.size.height > 0 else { return nil }
        return Double(image.size.width / image.size.height)
    }

    init(fitted: Bool) {
        super.init(image: nil)
        contentMode = fitted ? .scaleAspectFit : .scaleAspectFill
        clipsToBounds = true
        layer.cornerRadius = Theme.Radius.control
        layer.cornerCurve = .continuous
        backgroundColor = Theme.Color.assistantBubble
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ picture: UIImage) {
        image = picture
    }

    func showFailure() {
        image = nil
    }
}

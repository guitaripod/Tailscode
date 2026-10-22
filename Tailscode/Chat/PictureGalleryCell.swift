import CodingAgentKit
import TailscodeCore
import UIKit

@MainActor
protocol PictureGalleryCellDelegate: AnyObject {
    func pictureGalleryCell(_ cell: PictureGalleryCell, didTapPictureAt index: Int)
}

/// The pictures an agent made, as one grid of small tiles rather than a poster each: a turn that
/// looked at sixteen screenshots spends one picture's height on them, spread across the row's
/// width, and a chip in the last tile's corner counts the ones the grid could not draw. Every tile is its own
/// press — it opens the conversation's gallery on that picture, where every picture can be paged
/// through, zoomed, put in Photos, copied, shared or dragged out — so the verbs a single picture
/// used to carry in the transcript are a press away on the picture itself rather than many small
/// targets here.
///
/// The frames are `PictureGalleryLayout`'s and the height is the same arithmetic asked in
/// `preferredLayoutAttributesFitting`, so the row has its height before any picture has loaded and
/// a picture arriving never changes it: the block is always one picture tall, and a lone picture's
/// real shape moves only its width, which the cell lays out again by itself. Tiles are made as the layout asks for them, so a group of seventeen scoped
/// to six on a phone loads six pictures rather than seventeen.
final class PictureGalleryCell: UICollectionViewCell {
    static let reuseID = "PictureGalleryCell"
    weak var delegate: PictureGalleryCellDelegate?

    private var tiles: [PictureThumb] = []
    private var placed: [PictureGalleryLayout.Tile] = []
    private var files: [FileReference] = []
    private var backend: (any CodingAgentBackend)?
    private var badge: UILabel?
    private var loadToken = UUID()
    private var elements: [PictureTileElement] = []
    private static let inset = Theme.Spacing.l

    var gapAbove: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        contentView.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(pressed)))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadToken = UUID()
        tiles.forEach { $0.removeFromSuperview() }
        tiles = []
        placed = []
        files = []
        backend = nil
        badge?.removeFromSuperview()
        badge = nil
        elements = []
        delegate = nil
    }

    func configure(files: [FileReference], backend: any CodingAgentBackend) {
        guard files != self.files else { return }
        loadToken = UUID()
        tiles.forEach { $0.removeFromSuperview() }
        tiles = []
        placed = []
        badge?.removeFromSuperview()
        badge = nil
        self.files = files
        self.backend = backend
        elements = []
        setNeedsLayout()
    }

    /// Tiles for the pictures a given arrangement draws, made only as they are asked for: the
    /// images a wide row can show are more than a phone's, and a group is as many as twenty.
    private func prepare(_ count: Int, from files: [FileReference]) {
        guard count > tiles.count else { return }
        for index in tiles.count..<count where files.indices.contains(index) {
            let tile = PictureThumb(fitted: count == 1)
            tile.isUserInteractionEnabled = false
            tile.isAccessibilityElement = false
            contentView.addSubview(tile)
            tiles.append(tile)
            load(files[index], into: tile)
        }
    }

    private func load(_ file: FileReference, into tile: PictureThumb) {
        guard let backend else { return }
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
        }
    }

    /// The pixels a tile asks for: the tallest a tile can be drawn, so the same picture asks for
    /// the same size wherever it is drawn.
    private static var thumbnailBox: ThumbnailBox {
        .pinnedHeight(
            CGFloat(Theme.Chat.metrics.imageMaxHeight),
            maxWidth: max(0, UIScreen.main.bounds.width - 2 * inset), scale: UIScreen.main.scale)
    }

    @objc private func pressed(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: contentView)
        guard let tile = placed.first(where: {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                .offsetBy(dx: Self.inset, dy: gapAbove)
                .contains(point)
        }) else { return }
        open(tile.index)
    }

    private func open(_ index: Int) {
        Theme.Haptics.tap()
        delegate?.pictureGalleryCell(self, didTapPictureAt: index)
    }

    /// One accessibility element per tile drawn, each named for its own picture and opening that
    /// picture when activated: the tiles are plain image views, so without these a screen reader
    /// reaches one lump for the whole grid and every activation opens the first picture.
    override var accessibilityElements: [Any]? {
        get {
            if elements.count != placed.count { rebuildElements() }
            return elements
        }
        set {}
    }

    private func rebuildElements() {
        elements = placed.compactMap { tile in
            guard files.indices.contains(tile.index) else { return nil }
            let element = PictureTileElement(accessibilityContainer: self)
            element.accessibilityLabel = Localized.text(
                "Open %1$@, picture %2$@ of %3$@", files[tile.index].displayName,
                "\(tile.index + 1)", "\(files.count)")
            element.accessibilityTraits = [.image, .button]
            element.onActivate = { [weak self] in self?.open(tile.index) }
            return element
        }
        refreshElementFrames()
    }

    private func refreshElementFrames() {
        for (element, tile) in zip(elements, placed) {
            element.accessibilityFrameInContainerSpace = CGRect(
                x: Self.inset + CGFloat(tile.x), y: gapAbove + CGFloat(tile.y),
                width: CGFloat(tile.width), height: CGFloat(tile.height))
        }
    }

    private func layout(in width: CGFloat) -> PictureGalleryLayout.Arrangement {
        let metrics = Theme.Chat.metrics
        let side = PictureGalleryLayout.side(metrics: metrics, width: Double(width))
        return PictureGalleryLayout.grid(
            count: files.count, side: side, available: Double(width),
            shape: files.count == 1 ? PictureShape.shape(of: tiles.first?.aspect) : nil,
            maxWidth: min(Double(width), Double(ImagePreview.deskWidth)))
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let attributes = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
        let width = max(0, layoutAttributes.size.width - 2 * Self.inset)
        guard !files.isEmpty else {
            attributes.size.height = gapAbove
            return attributes
        }
        attributes.size.height = ceil(gapAbove + CGFloat(layout(in: width).height))
        return attributes
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !files.isEmpty else { return }
        let width = max(0, bounds.width - 2 * Self.inset)
        let arrangement = layout(in: width)
        placed = arrangement.tiles
        let shown = (arrangement.tiles.map(\.index).max() ?? -1) + 1
        prepare(shown, from: files)
        for tile in arrangement.tiles where tile.index < tiles.count {
            tiles[tile.index].isHidden = false
            tiles[tile.index].frame = CGRect(
                x: Self.inset + CGFloat(tile.x), y: gapAbove + CGFloat(tile.y),
                width: CGFloat(tile.width), height: CGFloat(tile.height))
        }
        for (index, thumb) in tiles.enumerated() where index >= shown {
            thumb.isHidden = true
        }
        if elements.count == placed.count { refreshElementFrames() } else { rebuildElements() }
        if let words = PictureGalleryReading.badge(hidden: arrangement.hidden),
            let last = arrangement.tiles.last
        {
            let badge = badgeLabel()
            badge.text = words
            let width = (words as NSString).size(withAttributes: [.font: badge.font as Any]).width
            let chip = PictureGalleryLayout.badge(on: last, textWidth: Double(width))
            badge.frame = CGRect(
                x: Self.inset + CGFloat(chip.x), y: gapAbove + CGFloat(chip.y),
                width: CGFloat(chip.width), height: CGFloat(chip.height))
            badge.layer.cornerRadius = badge.bounds.height / 2
            badge.isHidden = false
            contentView.bringSubviewToFront(badge)
        } else {
            badge?.isHidden = true
        }
    }

    /// The chip that counts what the grid could not draw, made once and moved with the last tile.
    private func badgeLabel() -> UILabel {
        if let badge { return badge }
        let label = UILabel()
        label.font = .systemFont(ofSize: CGFloat(PictureGalleryLayout.chipFontSize), weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.layer.cornerCurve = .continuous
        label.layer.masksToBounds = true
        label.isUserInteractionEnabled = false
        label.isAccessibilityElement = false
        contentView.addSubview(label)
        badge = label
        return label
    }
}

/// One tile of a gallery as a screen reader meets it: its own name and its own activation.
private final class PictureTileElement: UIAccessibilityElement {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }
}

/// One tile of a gallery: the image cropped to the rectangle the layout gave it, or — when it is
/// the only picture — fitted whole, because one screenshot cropped to a square hides most of what
/// it is.
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

import CodingAgentKit
import TailscodeCore
import UIKit

@MainActor
protocol PictureStripCellDelegate: AnyObject {
    func pictureStripCell(_ cell: PictureStripCell, didTap index: Int, from view: UIView)
    func pictureStripCell(_ cell: PictureStripCell, menuFor payload: ImagePayload, from view: UIView)
        -> UIMenu
}

/// Consecutive pictures the agent made, sharing one row: thumbnails no taller than the density
/// allows, each as wide as its own shape asks, wrapping when a line is full. A picture is a fact
/// the agent handed over, not a thing to read at length, so the row spends a thumbnail's height on
/// it and no caption — the filename is what VoiceOver says and what the long-press menu is titled.
/// Tapping one opens the gallery at that picture; the bytes still come from the server.
///
/// The frames are `PictureStripLayout`'s, and the height is the same arithmetic asked in
/// `preferredLayoutAttributesFitting`, so the row has its height before any picture has loaded
/// and a picture arriving changes it only by the difference between a guess at its shape and its
/// shape.
final class PictureStripCell: UICollectionViewCell {
    static let reuseID = "PictureStripCell"
    weak var delegate: PictureStripCellDelegate?

    /// Called once a picture's bytes land, so the list measures the row again against its real
    /// shape.
    var onLoaded: (() -> Void)?

    private var thumbs: [PictureThumb] = []
    private var files: [FileReference] = []
    private var loadToken = UUID()
    private static let inset = Theme.Spacing.l

    var gapAbove: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadToken = UUID()
        thumbs.forEach { $0.removeFromSuperview() }
        thumbs = []
        files = []
        delegate = nil
        onLoaded = nil
    }

    func configure(files: [FileReference], backend: any CodingAgentBackend) {
        guard files != self.files else { return }
        loadToken = UUID()
        thumbs.forEach { $0.removeFromSuperview() }
        self.files = files
        thumbs = files.enumerated().map { index, file in
            let thumb = PictureThumb()
            thumb.accessibilityLabel = file.displayName
            thumb.onTap = { [weak self, weak thumb] in
                guard let self, let thumb else { return }
                self.delegate?.pictureStripCell(self, didTap: index, from: thumb)
            }
            thumb.menuProvider = { [weak self, weak thumb] payload in
                guard let self, let thumb else { return nil }
                return self.delegate?.pictureStripCell(self, menuFor: payload, from: thumb)
            }
            contentView.addSubview(thumb)
            load(file, into: thumb, backend: backend)
            return thumb
        }
        setNeedsLayout()
    }

    private func load(_ file: FileReference, into thumb: PictureThumb, backend: any CodingAgentBackend) {
        if let cached = AttachmentImageStore.shared.cached(file) {
            thumb.show(cached, file: file, data: AttachmentImageStore.shared.cachedData(file))
            return
        }
        let token = loadToken
        Task { [weak self, weak thumb] in
            let image = await AttachmentImageStore.shared.image(for: file, using: backend)
            guard let self, let thumb, self.loadToken == token else { return }
            if let image {
                thumb.show(image, file: file, data: AttachmentImageStore.shared.cachedData(file))
            } else {
                thumb.showFailure(file)
            }
            self.setNeedsLayout()
            self.onLoaded?()
        }
    }

    #if DEBUG
        var firstThumb: UIView? { thumbs.first }
    #endif

    private func placements(width: CGFloat) -> PictureStripLayout.Result {
        PictureStripLayout.layout(
            aspects: thumbs.map(\.aspect), width: Double(width), metrics: Theme.Chat.metrics)
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let attributes = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
        let width = max(0, layoutAttributes.size.width - 2 * Self.inset)
        attributes.size.height = ceil(gapAbove + CGFloat(placements(width: width).height))
        return attributes
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0, bounds.width - 2 * Self.inset)
        for frame in placements(width: width).frames {
            thumbs[frame.index].frame = CGRect(
                x: Self.inset + CGFloat(frame.x), y: gapAbove + CGFloat(frame.y),
                width: CGFloat(frame.width), height: CGFloat(frame.height))
        }
    }
}

/// One picture of a strip: the image cropped to the shape the layout gave it, with the things a
/// picture in a chat answers to — a tap, a long-press menu named for the file, and a drag into
/// another app.
final class PictureThumb: UIImageView {
    var onTap: (() -> Void)?
    var menuProvider: ((ImagePayload) -> UIMenu?)?
    private(set) var payload: ImagePayload?

    /// Width over height of the picture once it is known; nil while it is on its way.
    var aspect: Double? {
        guard let image, image.size.height > 0 else { return nil }
        return Double(image.size.width / image.size.height)
    }

    init() {
        super.init(image: nil)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        layer.cornerRadius = Theme.Radius.control
        layer.cornerCurve = .continuous
        backgroundColor = Theme.Color.assistantBubble
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = [.image, .button]
        answersPointer(cornerRadius: Theme.Radius.control)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addInteraction(UIContextMenuInteraction(delegate: self))
        addInteraction(UIDragInteraction(delegate: self))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ picture: UIImage, file: FileReference, data: Data?) {
        image = picture
        payload = ImagePayload(image: picture, data: data, filename: file.displayName)
    }

    func showFailure(_ file: FileReference) {
        image = nil
        payload = nil
        accessibilityValue = String(localized: "Couldn't load \(file.displayName)")
    }

    @objc private func tapped() {
        guard image != nil else { return }
        Theme.Haptics.tap()
        onTap?()
    }
}

extension PictureThumb: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let payload else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [weak self] _ in self?.menuProvider?(payload)
        }
    }
}

extension PictureThumb: UIDragInteractionDelegate {
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
}

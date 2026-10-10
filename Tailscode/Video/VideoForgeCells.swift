import AVFoundation
import TailscodeCore
import UIKit

/// A poster for a clip that lives on another machine: its first frame, read over the same `/view`
/// road a player uses, small, and kept for the life of the process. A clip the renderer has since
/// cleaned up has no first frame to give, which is an answer rather than an error — the tile wears
/// the film glyph instead.
@MainActor
enum ClipPosters {
    private static let held = NSCache<NSString, UIImage>()
    private static var loading: [String: Task<UIImage?, Never>] = [:]

    static func cached(_ key: String) -> UIImage? { held.object(forKey: key as NSString) }

    static func poster(of url: URL, key: String) async -> UIImage? {
        if let image = cached(key) { return image }
        if let running = loading[key] { return await running.value }
        let load = Task<UIImage?, Never> {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            guard let result = try? await generator.image(at: .zero) else { return nil }
            return UIImage(cgImage: result.image)
        }
        loading[key] = load
        let image = await load.value
        loading[key] = nil
        if let image { held.setObject(image, forKey: key as NSString) }
        return image
    }
}

/// One clip on the shelf: its poster, its length in the corner, the one on the stage ringed in the
/// accent. A render that did not produce a clip wears the failure glyph and says why when it is
/// read to a screen reader, and a clip whose file the renderer no longer has wears the film glyph
/// rather than a blank. The poster is asked for once a tile is on screen, keyed so a cell reused
/// mid-flight never wears the wrong clip.
final class ForgeClipTileCell: UICollectionViewCell {
    private let poster = UIImageView()
    private let glyph = UIImageView()
    private let length = UILabel()
    private let ring = UIView()
    private var token = UUID()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Theme.Color.codeBackground
        contentView.layer.cornerRadius = 8
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        poster.contentMode = .scaleAspectFill
        poster.isAccessibilityElement = false
        glyph.contentMode = .center
        length.numberOfLines = 1
        length.textAlignment = .center
        length.layer.cornerRadius = 7
        length.layer.masksToBounds = true
        length.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        ring.layer.borderWidth = 2
        ring.layer.cornerRadius = 8
        ring.layer.cornerCurve = .continuous
        ring.isUserInteractionEnabled = false
        [poster, glyph, length, ring].forEach { contentView.addSubview($0) }
        isAccessibilityElement = true
        accessibilityTraits = [.button]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        token = UUID()
        poster.image = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        poster.frame = bounds
        glyph.frame = bounds
        ring.frame = bounds
        ring.layer.borderColor = Theme.Color.accent.cgColor
        let size = length.sizeThatFits(CGSize(width: bounds.width, height: 16))
        let width = min(bounds.width - 8, size.width + 8)
        length.frame = CGRect(
            x: bounds.width - width - 4, y: bounds.height - 18, width: width, height: 14)
    }

    func apply(_ entry: ForgeEntry, endpoint: ForgeEndpoint?, onStage: Bool, gone: Bool) {
        ring.isHidden = !onStage
        accessibilityTraits = onStage ? [.button, .selected] : [.button]
        accessibilityLabel = "\(entry.title), \(entry.failure ?? entry.recipe.summary)"
        length.attributedText = NSAttributedString(
            string: entry.isPlayable ? Localized.text("%@s", "\(entry.recipe.seconds)") : "",
            attributes: StudioBadge.attributes)
        length.isHidden = !entry.isPlayable
        let symbol = entry.isPlayable && !gone ? "film" : "exclamationmark.triangle.fill"
        glyph.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .light))
        glyph.tintColor = entry.isPlayable && !gone ? Theme.Color.tertiaryLabel : Theme.Color.danger
        glyph.isHidden = false
        poster.image = nil
        guard entry.isPlayable, !gone, let asset = entry.asset, let endpoint,
            let url = asset.url(on: endpoint)
        else { return }
        let key = "\(endpoint.host)/\(asset.annotatedName)"
        if let held = ClipPosters.cached(key) {
            poster.image = held
            glyph.isHidden = true
            return
        }
        let mine = token
        Task { [weak self] in
            let image = await ClipPosters.poster(of: url, key: key)
            guard let self, self.token == mine, let image else { return }
            UIView.transition(with: self.poster, duration: 0.18, options: .transitionCrossDissolve) {
                self.poster.image = image
            }
            self.glyph.isHidden = true
        }
    }
}

/// A line the board owed the reader — an empty history, a section that failed, the standing fact
/// about where a render actually happens. Never something to press.
final class ForgeNoteCell: UICollectionViewListCell {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            label.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
            label.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            label.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ words: String, tone: ActivityTone) {
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = Theme.Color.groupedSurface
        backgroundConfiguration = background
        label.attributedText = NSAttributedString(
            string: words,
            attributes: Theme.Ramp.attributes(
                .panelFootnote,
                color: tone == .danger ? Theme.Color.danger : Theme.Color.tertiaryLabel))
        isAccessibilityElement = true
        accessibilityLabel = words
    }
}

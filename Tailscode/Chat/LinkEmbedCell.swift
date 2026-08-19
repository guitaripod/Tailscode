import TailscodeCore
import UIKit

/// A tiny preview card for an address the transcript mentioned: an icon slot, one line of title,
/// one line of host. The card states itself honestly at every stage — the host wearing the face
/// until the page's own title and icon arrive, and the host alone if the fetch fails — so the
/// address is never presented as a page nobody has read. The fetch is the store's; the cell owns
/// only the debounce that keeps a URL still being streamed from firing a request at all.
final class LinkEmbedCell: UICollectionViewCell {
    static let reuseID = "LinkEmbedCell"

    private static let debounce: Duration = .milliseconds(700)

    private let card = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let hostLabel = UILabel()
    private var cardTop: NSLayoutConstraint!
    private var urlString = ""
    private var generation = 0
    private var fetchTask: Task<Void, Never>?
    private var onOpen: ((URL) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.backgroundColor = Theme.Color.assistantBubble
        card.layer.cornerRadius = Theme.Radius.card
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = UIColor(white: 0.5, alpha: 1)
        iconView.clipsToBounds = true
        iconView.layer.cornerRadius = 7
        iconView.layer.cornerCurve = .continuous
        /// A favicon is a page's own mark and mostly dark; a light tile under it keeps it legible
        /// on a dark transcript without washing it out on a light one.
        iconView.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.94, alpha: 1)
                : Theme.Color.secondaryBackground
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Theme.Ramp.font(.toolName)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        hostLabel.font = Theme.Ramp.font(.treePath)
        hostLabel.adjustsFontForContentSizeCategory = true
        hostLabel.textColor = Theme.Color.tertiaryLabel
        hostLabel.numberOfLines = 1
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.translatesAutoresizingMaskIntoConstraints = false

        let lines = UIStackView(arrangedSubviews: [titleLabel, hostLabel])
        lines.axis = .vertical
        lines.spacing = 1
        lines.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(card)
        card.addSubview(iconView)
        card.addSubview(lines)

        cardTop = card.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: Theme.Spacing.xs)
        NSLayoutConstraint.activate([
            cardTop,
            card.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            card.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.s),
            card.trailingAnchor.constraint(
                lessThanOrEqualTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            card.widthAnchor.constraint(
                lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.82),

            iconView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Spacing.m),
            iconView.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Spacing.m),
            iconView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.Spacing.m),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),

            lines.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Theme.Spacing.s),
            lines.trailingAnchor.constraint(
                lessThanOrEqualTo: card.trailingAnchor, constant: -Theme.Spacing.m),
            lines.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(cardTapped))
        card.addGestureRecognizer(tap)
        card.addInteraction(UIContextMenuInteraction(delegate: self))
        isAccessibilityElement = true
        accessibilityTraits = [.button, .link]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var turnInset: CGFloat = 0 {
        didSet { cardTop.constant = Theme.Spacing.xs + turnInset }
    }

    func configure(_ embed: WebEmbed, onOpen: @escaping (URL) -> Void) {
        self.onOpen = onOpen
        generation += 1
        fetchTask?.cancel()
        urlString = embed.url
        guard let url = URL(string: embed.url) else { return }
        iconView.contentMode = .scaleAspectFit
        iconView.image = UIImage(
            systemName: "globe",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        applyFace(nil, url: url)
        let target = embed.url
        let expected = generation
        fetchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard let self, self.generation == expected, self.urlString == target else { return }
            await self.loadPreview(for: url, expected: expected)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        generation += 1
        fetchTask?.cancel()
        fetchTask = nil
        onOpen = nil
        iconView.image = nil
        titleLabel.text = nil
        hostLabel.text = nil
    }

    /// The face before the page has spoken — the host in the title's seat — and the face after,
    /// which is the same host whenever the fetch failed or the page never said what it is. Both
    /// lines are always populated so the card never changes height under the reader.
    private func applyFace(_ metadata: LinkPreviewMetadata?, url: URL) {
        let host = url.host ?? url.absoluteString
        if let title = metadata?.title, !title.isEmpty {
            titleLabel.text = title
            titleLabel.textColor = Theme.Color.label
            hostLabel.text = host
        } else {
            titleLabel.text = host
            titleLabel.textColor = Theme.Color.secondaryLabel
            hostLabel.text = Self.readablePath(of: url)
        }
        accessibilityLabel = String(localized: "Link preview")
        accessibilityValue = "\(titleLabel.text ?? "") · \(hostLabel.text ?? "")"
        accessibilityHint = String(localized: "Opens the link")
    }

    private func loadPreview(for url: URL, expected: Int) async {
        let metadata = await LinkPreviewStore.shared.metadata(for: url.absoluteString)
        guard generation == expected, urlString == url.absoluteString else { return }
        applyFace(metadata, url: url)
        if let icon = await LinkPreviewStore.shared.favicon(for: url.absoluteString),
            generation == expected, urlString == url.absoluteString
        {
            iconView.contentMode = .scaleAspectFill
            iconView.image = icon.withRenderingMode(.alwaysOriginal)
        }
    }

    @objc private func cardTapped() {
        guard let url = URL(string: urlString) else { return }
        Theme.Haptics.tap()
        onOpen?(url)
    }

    private static func readablePath(of url: URL) -> String {
        var text = url.absoluteString
        if let range = text.range(of: "://") {
            text = String(text[range.upperBound...])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return text.isEmpty ? url.host ?? "" : text
    }
}

extension LinkEmbedCell: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let open = UIAction(
                title: String(localized: "Open Link"),
                image: UIImage(systemName: "safari")
            ) { [weak self] _ in
                guard let self, let url = URL(string: self.urlString) else { return }
                self.onOpen?(url)
            }
            let copy = UIAction(
                title: String(localized: "Copy link"),
                image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in
                guard let self else { return }
                UIPasteboard.general.string = self.urlString
                Theme.Haptics.success()
            }
            return UIMenu(children: [open, copy])
        }
    }
}

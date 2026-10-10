import TailscodeCore
import UIKit

/// The addresses a run of prose mentioned, as one line instead of a card each: a stack of
/// favicons, the hosts in the ink a link wears in prose, how many more, and a quiet chevron. A
/// tap opens the line in place into one row per address — the same rows a pointer client floats
/// over its neighbours — and a second tap folds it again.
///
/// The line is `railRowHeight` tall and stays that tall whatever a fetch says: the words are the
/// host before the page has spoken, its title once it has, and the host alone if it never does,
/// and a favicon is a globe until the page's own arrives. The words are Core's `LinkRailReading`,
/// the fetching is Core's `LinkRailPolicy` and `LinkEmbedPolicy` debounce, and the cell only draws.
final class LinkRailCell: UICollectionViewCell {
    static let reuseID = "LinkRailCell"

    private let outer = UIStackView()
    private let rail = UIControl()
    private let faviconStack = UIView()
    private let summaryLabel = UILabel()
    private let chevron = UIImageView()
    private let list = UIStackView()
    private var faviconViews: [FaviconView] = []
    private var rows: [LinkRailRowView] = []
    private var topConstraint: NSLayoutConstraint!
    private var stackWidth: NSLayoutConstraint!

    private var addresses: [String] = []
    private var reading = LinkRailReading(items: [])
    private var fetches = LinkRailFetches()
    private var opened = false
    private var generation = 0
    private var fetchTask: Task<Void, Never>?
    private var onToggle: (() -> Void)?
    private var onOpen: ((URL) -> Void)?

    private static let faviconSize: CGFloat = 14
    private static let faviconStep: CGFloat = 9

    var gapAbove: CGFloat = 0 {
        didSet { topConstraint.constant = gapAbove }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        faviconStack.translatesAutoresizingMaskIntoConstraints = false
        faviconStack.isUserInteractionEnabled = false
        for index in 0..<LinkRailPolicy.stackSize {
            let view = FaviconView(size: Self.faviconSize)
            view.frame.origin = CGPoint(x: CGFloat(index) * Self.faviconStep, y: 0)
            faviconViews.append(view)
        }
        for view in faviconViews.reversed() { faviconStack.addSubview(view) }

        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.isUserInteractionEnabled = false
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.contentMode = .center
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.isUserInteractionEnabled = false
        chevron.translatesAutoresizingMaskIntoConstraints = false

        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.addTarget(self, action: #selector(railTapped), for: .touchUpInside)
        rail.addInteraction(UIContextMenuInteraction(delegate: self))
        rail.answersPointer(cornerRadius: Theme.Radius.control)
        [faviconStack, summaryLabel, chevron].forEach(rail.addSubview)

        list.axis = .vertical
        list.isHidden = true

        outer.axis = .vertical
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(rail)
        outer.addArrangedSubview(list)
        contentView.addSubview(outer)

        stackWidth = faviconStack.widthAnchor.constraint(equalToConstant: Self.faviconSize)
        topConstraint = outer.topAnchor.constraint(equalTo: contentView.topAnchor)
        NSLayoutConstraint.activate([
            topConstraint,
            outer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            outer.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            outer.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),

            rail.heightAnchor.constraint(
                greaterThanOrEqualToConstant: CGFloat(Theme.Chat.metrics.railRowHeight)),

            faviconStack.leadingAnchor.constraint(equalTo: rail.leadingAnchor),
            faviconStack.centerYAnchor.constraint(equalTo: rail.centerYAnchor),
            faviconStack.heightAnchor.constraint(equalToConstant: Self.faviconSize),
            stackWidth,

            summaryLabel.leadingAnchor.constraint(
                equalTo: faviconStack.trailingAnchor, constant: Theme.Spacing.s),
            summaryLabel.topAnchor.constraint(greaterThanOrEqualTo: rail.topAnchor, constant: 4),
            summaryLabel.bottomAnchor.constraint(lessThanOrEqualTo: rail.bottomAnchor, constant: -4),
            summaryLabel.centerYAnchor.constraint(equalTo: rail.centerYAnchor),

            chevron.leadingAnchor.constraint(
                greaterThanOrEqualTo: summaryLabel.trailingAnchor, constant: Theme.Spacing.s),
            chevron.trailingAnchor.constraint(equalTo: rail.trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: rail.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelFetch()
        addresses = []
        reading = LinkRailReading(items: [])
        fetches = LinkRailFetches()
        onToggle = nil
        onOpen = nil
    }

    func configure(
        _ run: LinkRailRun, opened: Bool, onToggle: @escaping () -> Void,
        onOpen: @escaping (URL) -> Void
    ) {
        self.onToggle = onToggle
        self.onOpen = onOpen
        self.opened = opened
        if run.addresses != addresses {
            cancelFetch()
            addresses = run.addresses
            fetches = LinkRailFetches()
            reading = Self.initialReading(for: run.addresses)
            for (index, view) in faviconViews.enumerated() {
                view.show(
                    reading.stack.indices.contains(index)
                        ? LinkPreviewStore.shared.cachedFavicon(for: reading.stack[index].url) : nil,
                    visible: reading.stack.indices.contains(index))
            }
            rebuildRows()
        }
        draw()
        fetchMissing()
    }

    /// The rail before any request: every address in its placeholder, overlaid with whatever the
    /// process already learned of it, so a rail built again does not stand as hosts through the
    /// debounce for answers it holds.
    private static func initialReading(for urls: [String]) -> LinkRailReading {
        var reading = LinkRailReading.placeholder(for: urls)
        for url in urls {
            if let face = LinkPreviewFetcher.shared.cachedFace(for: url) {
                reading = reading.replacing(face, for: url)
            }
        }
        return reading
    }

    private func draw() {
        let stack = reading.stack
        stackWidth.constant = Self.faviconSize + Self.faviconStep * CGFloat(max(0, stack.count - 1))
        for (index, view) in faviconViews.enumerated() { view.isHidden = index >= stack.count }
        summaryLabel.attributedText = summary()
        summaryLabel.numberOfLines =
            traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 0 : 1
        chevron.transform = opened ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        list.isHidden = !opened
        rail.isAccessibilityElement = true
        rail.accessibilityTraits = .button
        rail.accessibilityLabel = reading.spoken(expanded: opened)
        rail.accessibilityHint =
            opened ? String(localized: "Double tap to hide the links")
            : String(localized: "Double tap to show the links")
        for (row, item) in zip(rows, reading.items) { row.show(item) }
    }

    /// The line's words: the lone address's title with its host after it, or the hosts of the
    /// stack with how many more lie beyond it. Hosts wear the ink a link wears in prose.
    private func summary() -> NSAttributedString {
        let text = NSMutableAttributedString()
        if let title = reading.singleTitle, let item = reading.items.first {
            text.append(
                NSAttributedString(
                    string: title,
                    attributes: Theme.Ramp.attributes(.rowTitle, color: Theme.Color.accent)))
            if !item.face.headlineIsQuiet {
                text.append(
                    NSAttributedString(
                        string: "  " + item.face.host,
                        attributes: Theme.Ramp.attributes(
                            .toolDetail, color: Theme.Color.tertiaryLabel)))
            }
            return text
        }
        text.append(
            NSAttributedString(
                string: reading.hostsLine,
                attributes: Theme.Ramp.attributes(.rowTitle, color: Theme.Color.accent)))
        if let more = reading.moreLabel {
            text.append(
                NSAttributedString(
                    string: "  " + more,
                    attributes: Theme.Ramp.attributes(.toolDetail, color: Theme.Color.tertiaryLabel)))
        }
        return text
    }

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = reading.items.map { item in
            let row = LinkRailRowView()
            row.onOpen = { [weak self] url in self?.onOpen?(url) }
            row.show(item)
            list.addArrangedSubview(row)
            return row
        }
    }

    /// The pages the plan asks about now: the stack at creation, everything once opened. Each
    /// address is asked about once for the life of this rail, after the debounce that keeps a
    /// streamed address from firing a request, and a fetch that fails leaves the host standing.
    private func fetchMissing() {
        let fresh = fetches.claim(for: addresses, opened: opened).filter {
            LinkPreviewFetcher.shared.cachedFace(for: $0) == nil
                || LinkPreviewStore.shared.cachedFavicon(for: $0) == nil
        }
        guard !fresh.isEmpty else { return }
        let expected = generation
        let wanted = addresses
        fetchTask = Task { [weak self] in
            let proceed = await LinkEmbedPolicy.settle { @MainActor [weak self] in
                guard let self else { return false }
                return self.generation == expected && self.addresses == wanted
            }
            guard proceed, let self else { return }
            await withTaskGroup(of: Void.self) { group in
                for url in fresh {
                    group.addTask { await self.load(url, expected: expected) }
                }
            }
        }
    }

    private func load(_ url: String, expected: Int) async {
        guard let parsed = URL(string: url) else { return }
        let metadata = await LinkPreviewStore.shared.metadata(for: url)
        guard generation == expected else { return }
        reading = reading.replacing(.settled(for: parsed, metadata: metadata), for: url)
        draw()
        if let icon = await LinkPreviewStore.shared.favicon(for: url), generation == expected {
            showFavicon(icon, for: url)
        }
    }

    private func showFavicon(_ icon: UIImage, for url: String) {
        if let index = reading.stack.firstIndex(where: { $0.url == url }) {
            faviconViews[index].show(icon, visible: true)
        }
        if let index = reading.items.firstIndex(where: { $0.url == url }), rows.indices.contains(index) {
            rows[index].showFavicon(icon)
        }
    }

    private func cancelFetch() {
        generation += 1
        fetchTask?.cancel()
        fetchTask = nil
    }

    @objc private func railTapped() {
        Theme.Haptics.selection()
        onToggle?()
    }
}

extension LinkRailCell: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !reading.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let copy = UIAction(
                title: LinkRailReading.copyAllTitle, image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in
                guard let self else { return }
                UIPasteboard.general.string = self.reading.copyAllText
                Theme.Haptics.success()
            }
            return UIMenu(children: [copy])
        }
    }
}

/// One favicon on the stack or in an opened row: a round tile with the host's globe until the
/// page's own mark is known. A favicon is a page's own mark and mostly dark, so the tile under it
/// is light on a dark transcript and the canvas's own grey on a light one, with a ring in the
/// canvas colour so overlapping neighbours stay two marks.
final class FaviconView: UIImageView {
    private let side: CGFloat

    init(size: CGFloat) {
        side = size
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        layer.cornerRadius = size / 2
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.5
        layer.borderColor = Theme.Color.background.cgColor
        clipsToBounds = true
        backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.94, alpha: 1) : Theme.Color.secondaryBackground
        }
        showGlobe()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        layer.borderColor = Theme.Color.background.cgColor
    }

    override var intrinsicContentSize: CGSize { CGSize(width: side, height: side) }

    func show(_ icon: UIImage?, visible: Bool) {
        isHidden = !visible
        guard let icon else {
            showGlobe()
            return
        }
        contentMode = .scaleAspectFill
        image = icon.withRenderingMode(.alwaysOriginal)
    }

    private func showGlobe() {
        contentMode = .center
        tintColor = UIColor(white: 0.5, alpha: 1)
        image = UIImage(
            systemName: "globe",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: side * 0.8, weight: .medium))
    }
}

/// One address of an opened rail: favicon, the page's title on one line and its host at the
/// trailing edge, as tall as a finger needs. Tapping it opens the address exactly as a link in
/// prose does; long-pressing offers to copy it.
final class LinkRailRowView: UIControl {
    var onOpen: ((URL) -> Void)?
    private let favicon = FaviconView(size: 16)
    private let titleLabel = UILabel()
    private let hostLabel = UILabel()
    private var url: URL?

    init() {
        super.init(frame: .zero)
        favicon.layer.borderWidth = 0
        favicon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Theme.Ramp.font(.rowTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hostLabel.font = Theme.Ramp.font(.rowMeta)
        hostLabel.adjustsFontForContentSizeCategory = true
        hostLabel.textColor = Theme.Color.tertiaryLabel
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.textAlignment = .right
        hostLabel.setContentHuggingPriority(.required, for: .horizontal)
        hostLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [favicon, titleLabel, hostLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(
                greaterThanOrEqualToConstant: CGFloat(Theme.Chat.metrics.railOpenRowHeight)),
            favicon.widthAnchor.constraint(equalToConstant: 16),
            favicon.heightAnchor.constraint(equalToConstant: 16),
        ])
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        addInteraction(UIContextMenuInteraction(delegate: self))
        answersPointer(cornerRadius: Theme.Radius.control)
        isAccessibilityElement = true
        accessibilityTraits = .link
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ item: LinkRailItem) {
        url = URL(string: item.url)
        titleLabel.text = item.face.headline
        titleLabel.textColor = item.face.headlineIsQuiet ? Theme.Color.secondaryLabel : Theme.Color.label
        hostLabel.text = item.face.headlineIsQuiet ? nil : item.face.host
        hostLabel.isHidden = item.face.headlineIsQuiet
        accessibilityLabel = item.face.headline
        accessibilityValue = item.face.host
        accessibilityHint = String(localized: "Opens the link")
        favicon.show(LinkPreviewStore.shared.cachedFavicon(for: item.url), visible: true)
    }

    func showFavicon(_ icon: UIImage) {
        favicon.show(icon, visible: true)
    }

    @objc private func tapped() {
        guard let url else { return }
        Theme.Haptics.tap()
        onOpen?(url)
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let url else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let copy = UIAction(
                title: String(localized: "Copy address"), image: UIImage(systemName: "doc.on.doc")
            ) { _ in
                UIPasteboard.general.string = url.absoluteString
                Theme.Haptics.success()
            }
            return UIMenu(children: [copy])
        }
    }
}

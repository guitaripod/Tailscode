import AppKit
import TailscodeCore

/// The preview card for an address a message mentioned: an icon slot, one line of title, one line
/// of host. The words are Core's `LinkCardFace`, the debounce and the fetch are Core's too; this
/// draws them. A card never presents an address as a page nobody has read — the host wears the
/// face until the page's own title arrives, and stays if it never does — and both lines exist from
/// the first frame, so the row's height does not change when the page answers.
///
/// Pressing it opens the address in the reader's own browser, the way a link in the prose does;
/// the ground that comes up under the pointer is the window's usual answer to one.
@MainActor
final class LinkCardView: NSView {
    private static let iconSide: CGFloat = 30
    private static let widest: CGFloat = 460

    let url: String
    private let source: LinkCardSource
    private let surface: PressSurface
    private let iconView: NSImageView
    let titleLabel: NSTextField
    let hostLabel: NSTextField
    private var fetch: Task<Void, Never>?

    init(url: String, source: LinkCardSource = .live) {
        let title = RowKit.label("", font: MacTheme.Ramp.font(.toolName), color: MacTheme.Color.label)
        let host = RowKit.label(
            "", font: MacTheme.Ramp.font(.treePath), color: MacTheme.Color.tertiaryLabel)
        host.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1
        host.maximumNumberOfLines = 1

        let lines = NSStackView(views: [title, host])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        lines.translatesAutoresizingMaskIntoConstraints = false

        let tile = RowKit.Ground(frame: .zero)
        tile.radius = 7
        tile.fill = Self.tileFill
        tile.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        RowKit.ground(
            behind: content, fill: MacTheme.Color.subagentBackground,
            stroke: MacTheme.Color.separator, radius: MacTheme.Radius.card)
        content.addSubview(tile)
        content.addSubview(icon)
        content.addSubview(lines)
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: MacTheme.Spacing.m),
            tile.topAnchor.constraint(equalTo: content.topAnchor, constant: MacTheme.Spacing.m),
            tile.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -MacTheme.Spacing.m),
            tile.widthAnchor.constraint(equalToConstant: Self.iconSide),
            tile.heightAnchor.constraint(equalToConstant: Self.iconSide),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            icon.widthAnchor.constraint(equalTo: tile.widthAnchor, multiplier: 0.6),
            icon.heightAnchor.constraint(equalTo: tile.heightAnchor, multiplier: 0.6),
            lines.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: MacTheme.Spacing.s),
            lines.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -MacTheme.Spacing.m),
            lines.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            lines.widthAnchor.constraint(lessThanOrEqualToConstant: Self.widest),
        ])

        self.url = url
        self.source = source
        self.titleLabel = title
        self.hostLabel = host
        self.iconView = icon
        self.surface = PressSurface(
            content: content, outset: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
            radius: MacTheme.Radius.card)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let target = URL(string: url)
        surface.onPress = { if let target { NSWorkspace.shared.open(target) } }
        if let target {
            let menu = NSMenu()
            for item in RowKit.ProseLabel.linkItems(target) { menu.addItem(item) }
            surface.menu = menu
        }
        surface.setAccessibilityElement(true)
        surface.setAccessibilityRole(.link)
        surface.setAccessibilityLabel(Localized.text("Link preview"))
        surface.setAccessibilityHelp(Localized.text("Opens the link"))

        showGlobe()
        begin(target)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A favicon is a page's own mark and mostly dark; a light tile under it keeps it legible on a
    /// dark transcript without washing it out on a light one.
    private static var tileFill: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.94, alpha: 1) : MacTheme.Color.canvasRaised
        }
    }

    var headline: String { titleLabel.stringValue }
    var caption: String { hostLabel.stringValue }
    var plateLevel: PointerPlate.Level { surface.plateLevel }

    private func showGlobe() {
        iconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 15 * MacTheme.UIScale.factor, weight: .medium))
        iconView.contentTintColor = MacTheme.Color.secondaryLabel
    }

    private func apply(_ face: LinkCardFace) {
        titleLabel.stringValue = face.headline
        titleLabel.textColor = face.headlineIsQuiet
            ? MacTheme.Color.secondaryLabel : MacTheme.Color.label
        hostLabel.stringValue = face.caption
        surface.setAccessibilityValue(face.spoken)
    }

    /// The first face is the one the process already holds, if it holds one; otherwise the
    /// placeholder, and the page is asked for only once the address has held still through the
    /// debounce. A card for an address that was still growing has been taken out of the transcript
    /// before that, and its request is never made.
    private func begin(_ target: URL?) {
        let source = source
        let url = url
        guard let target else {
            apply(.placeholder(host: url, path: url))
            return
        }
        if let held = source.cachedFace(url) {
            apply(held)
            fetch = Task { [weak self] in await self?.paintIcon() }
            return
        }
        apply(.placeholder(for: target))
        fetch = Task { [weak self] in
            let wanted = await LinkEmbedPolicy.settle(debounce: source.debounce) {
                @MainActor [weak self] in self?.superview != nil
            }
            guard wanted, let self else { return }
            let metadata = await source.metadata(url)
            guard !Task.isCancelled else { return }
            self.apply(.settled(for: target, metadata: metadata))
            await self.paintIcon()
        }
    }

    private func paintIcon() async {
        if let cached = ImageStore.shared.icon(forKey: url) {
            show(icon: cached)
            return
        }
        guard let data = await source.favicon(url), !Task.isCancelled else { return }
        let decoded = await Task.detached(priority: .utility) { ImageStore.decode(data) }.value
        guard let decoded else { return }
        ImageStore.shared.store(icon: decoded.image, forKey: url)
        show(icon: decoded.image)
    }

    private func show(icon: NSImage) {
        iconView.image = icon
        iconView.contentTintColor = nil
    }
}

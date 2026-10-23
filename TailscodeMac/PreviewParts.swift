import AppKit
import CodingAgentKit
import CodingAgentKitApple
import ImageIO
import TailscodeCore

/// The live face: the newest picture aspect-fitted above a quiet row of chips. It is placed by
/// frame rather than by constraint because the picture's shape arrives with its first frame and
/// changes with the device, and a layout pass per frame is not something a stream should cost.
@MainActor
final class PreviewLiveView: NSView {
    let banner = PreviewBannerView()
    private let host = NSView()
    private let picture = PreviewPictureView()
    private let chipLabel = PreviewChipLabel()
    private let chips = NSStackView()

    var image: CGImage? { picture.image }
    var pictureAlpha: CGFloat { picture.alphaValue }
    var chipWords: String? { chipLabel.isHidden ? nil : chipLabel.text }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.addSubview(picture)
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        chipLabel.translatesAutoresizingMaskIntoConstraints = false
        chipLabel.isHidden = true
        host.addSubview(banner)
        host.addSubview(chipLabel)
        addSubview(host)
        chips.orientation = .horizontal
        chips.spacing = MacTheme.Spacing.s
        chips.alignment = .centerY
        addSubview(chips)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: MacTheme.Spacing.s),
            banner.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -MacTheme.Spacing.s),
            banner.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -MacTheme.Spacing.s),
            chipLabel.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            chipLabel.topAnchor.constraint(equalTo: host.topAnchor, constant: MacTheme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func install(chips views: [NSView]) {
        for view in views { chips.addArrangedSubview(view) }
        needsLayout = true
    }

    func show(_ image: CGImage) {
        let reshaped = picture.image.map { $0.width != image.width || $0.height != image.height } ?? true
        picture.show(image)
        if reshaped { needsLayout = true }
    }

    func clear() {
        picture.clear()
        needsLayout = true
    }

    func setDimmed(_ dimmed: Bool, words: String) {
        picture.alphaValue = dimmed ? 0.55 : 1
        chipLabel.isHidden = !dimmed
        chipLabel.text = words
    }

    func setAccessibility(_ label: String) {
        picture.setAccessibilityLabel(label)
    }

    func snapshot() -> (rep: NSBitmapImageRep, frame: NSRect)? {
        layoutSubtreeIfNeeded()
        let area = picture.bounds
        guard area.width > 0, area.height > 0, let rep = picture.bitmapImageRepForCachingDisplay(in: area)
        else { return nil }
        picture.cacheDisplay(in: area, to: rep)
        return (rep, host.frame)
    }

    override func layout() {
        super.layout()
        let side = MacTheme.Spacing.l
        let below = chips.fittingSize
        let chipsFrame = NSRect(
            x: ((bounds.width - below.width) / 2).rounded(), y: MacTheme.Spacing.m,
            width: below.width, height: below.height)
        chips.frame = chipsFrame
        let room = NSRect(
            x: side, y: chipsFrame.maxY + MacTheme.Spacing.m, width: max(0, bounds.width - side * 2),
            height: max(0, bounds.height - chipsFrame.maxY - MacTheme.Spacing.m - side))
        guard let image = picture.image, room.width > 0, room.height > 0 else {
            host.frame = .zero
            return
        }
        let ratio = CGFloat(image.width) / CGFloat(image.height)
        var fitted = NSSize(width: room.height * ratio, height: room.height)
        if fitted.width > room.width { fitted = NSSize(width: room.width, height: room.width / ratio) }
        host.frame = NSRect(
            x: room.midX - fitted.width / 2, y: room.midY - fitted.height / 2, width: fitted.width.rounded(),
            height: fitted.height.rounded())
        picture.frame = host.bounds
    }
}

/// The newest picture, drawn by handing the layer the decoded image rather than by drawing it
/// again: the compositor scales it, and a stream of 60 pictures a second costs one assignment each.
@MainActor
final class PreviewPictureView: NSView {
    private(set) var image: CGImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = MacTheme.Radius.card
        layer?.masksToBounds = true
        setAccessibilityRole(.image)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ next: CGImage) {
        image = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        layer?.contents = next
        CATransaction.commit()
    }

    func clear() {
        image = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = nil
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let clip = CGPath(
            roundedRect: bounds, cornerWidth: MacTheme.Radius.card, cornerHeight: MacTheme.Radius.card,
            transform: nil)
        context.addPath(clip)
        context.clip()
        context.draw(image, in: bounds)
        context.restoreGState()
    }
}

/// A short word over the top of a dimmed picture, in a capsule on the opaque canvas.
@MainActor
final class PreviewChipLabel: NSView {
    private let label = NSTextField(labelWithString: "")
    private let capsule = CapsuleView()

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        capsule.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = MacTheme.Ramp.font(ChatChrome.chipRole)
        label.textColor = MacTheme.Color.label
        addSubview(capsule)
        capsule.addSubview(label)
        NSLayoutConstraint.activate([
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor),
            capsule.topAnchor.constraint(equalTo: topAnchor),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: MacTheme.Spacing.m),
            label.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -MacTheme.Spacing.m),
            label.topAnchor.constraint(equalTo: capsule.topAnchor, constant: MacTheme.Spacing.xs),
            label.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -MacTheme.Spacing.xs),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let layer = capsule.layer else { return }
        capsule.effectiveAppearance.performAsCurrentDrawingAppearance {
            ChipGround.paint(layer, kind: .fact, height: bounds.height)
        }
    }
}

/// What a failed build looks like over a picture: the headline, the first problem in mono ink, and
/// the one button that hands it to the agent. A card on the opaque canvas, never glass.
@MainActor
final class PreviewBannerView: NSView {
    var onAsk: (() -> Void)?
    private(set) var problem = ""
    private let glyph = NSImageView()
    private let headline = NSTextField(wrappingLabelWithString: "")
    private let problemLabel = NSTextField(wrappingLabelWithString: "")
    private let ask = SymbolChip(kind: .control)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = MacTheme.Radius.control
        layer?.borderWidth = 1

        glyph.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: MacTheme.Ramp.font(.rowTitleStrong).pointSize, weight: .medium))
        glyph.contentTintColor = MacTheme.Color.danger
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setAccessibilityElement(false)
        headline.font = MacTheme.Ramp.font(.rowTitleStrong)
        headline.textColor = MacTheme.Color.label
        headline.isSelectable = false
        headline.maximumNumberOfLines = 0
        headline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        problemLabel.font = MacTheme.Ramp.font(.toolOutput)
        problemLabel.textColor = MacTheme.Color.secondaryLabel
        problemLabel.isSelectable = true
        problemLabel.maximumNumberOfLines = 0
        problemLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ask.text = Localized.text("Ask the agent to fix it")
        ask.accented = true
        ask.onTap = { [weak self] in self?.onAsk?() }

        let top = NSStackView(views: [glyph, headline])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = MacTheme.Spacing.s
        let column = FillingStack(topDown: true)
        column.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(top)
        column.addArrangedSubview(problemLabel)
        let row = NSStackView(views: [ask])
        row.orientation = .horizontal
        column.addArrangedSubview(row)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.m),
            column.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.m),
        ])
        paint()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(headline text: String, problem line: String?) {
        headline.stringValue = text
        problem = line ?? ""
        problemLabel.stringValue = problem
        problemLabel.isHidden = problem.isEmpty
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacTheme.Color.canvas.blended(
                withFraction: 0.07, of: MacTheme.Color.label)?.cgColor
            layer?.borderColor = MacTheme.Color.separator.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }
}

/// A bar for a job whose progress the host reports: a track and a fill, drawn from layers so a
/// step in the number is a change of width and nothing is re-laid-out.
@MainActor
final class PreviewProgressBar: NSView {
    var fraction: Double = 0 {
        didSet { needsLayout = true }
    }
    private let fill = NSView()

    private static let thickness: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fill.wantsLayer = true
        addSubview(fill)
        paint()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.thickness)
    }

    override func layout() {
        super.layout()
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(fraction), height: bounds.height)
        layer?.cornerRadius = bounds.height / 2
        fill.layer?.cornerRadius = bounds.height / 2
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacTheme.Color.separator.cgColor
            fill.layer?.backgroundColor = MacTheme.Color.accent.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }
}

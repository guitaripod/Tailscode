import TailscodeCore
import UIKit

/// A turn collapsed: one card whose picture is the head itself, lit where the turn worked, and
/// whose words are what the turn came to, in the reader's terms. The whole card is one button;
/// Replay and Rows, and the zone chips that open the brain already diving into a zone, are small
/// buttons on it that do not open it.
///
/// A running turn's card keeps the settled card's size and says what is happening now: the verdict
/// with its glyph, the counts ticking, the step in flight and the last line it printed, or the note
/// the agent has just written. When the turn ends the card settles in one 400 ms move, driven by
/// `NeuralCardSettle`, and a card that settles out of sight is simply settled when it arrives.
@MainActor
final class BrainCardView: UIView {
    var onOpen: (() -> Void)?
    var onReplay: (() -> Void)?
    var onRows: (() -> Void)?
    var onShare: (() -> Void)?
    var onDive: ((NeuralZone) -> Void)?
    var onPrefetch: (() -> Void)?

    /// The press and the pointer, which lift the card's lights and take its hairline to its tone.
    private(set) var isHovered = false {
        didSet { applyEmphasis() }
    }
    private var isPressed = false {
        didSet { applyEmphasis() }
    }

    let surface = UIView()
    let edge = CAShapeLayer()
    let moveEdge = CAShapeLayer()
    let textGroup = UIView()
    let press = UIControl()
    let picture = BrainCardPicture()
    let headline = UILabel()
    let clauses = UILabel()
    let liveHeadline = UILabel()
    let liveCounts = UILabel()
    let nowLabel = UILabel()
    let nowTrailing = UILabel()
    let quoteLabel = UILabel()
    let third = UILabel()
    let wordmark = UILabel()
    var wordmarkShown: Bool { !wordmark.isHidden }
    let chipHost = UIView()
    var chips: [BrainZoneChip] = []
    let replay = CardButton()
    let rows = CardButton()
    let open = CardButton()

    var model: NeuralBrainModel?
    var row: BrainRow?
    var card: NeuralBrainCard?
    var metrics: NeuralStageMetrics?
    var memory: BrainLiveMemory?
    var ink: BrainInk?
    var drawnSignature = ""
    var layoutMemo: (key: String, layout: Layout)?
    var settleLink: CADisplayLink?
    var quoteRelease: DispatchWorkItem?
    var lastLayout: Layout?
    var settle = NeuralCardSettle.settled

    /// What a card drew, for the debug log and the checks.
    var drawn = (headline: "", chips: [String](), third: "", live: false)

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self, UITraitPreferredContentSizeCategory.self]) { (view: BrainCardView, _) in view.traitsChanged() }
        surface.layer.cornerRadius = 12
        surface.layer.cornerCurve = .continuous
        surface.layer.borderWidth = 1
        surface.layer.masksToBounds = true
        surface.isUserInteractionEnabled = false
        addSubview(surface)
        edge.lineWidth = 3
        edge.fillColor = nil
        surface.layer.addSublayer(edge)

        moveEdge.lineWidth = 3
        moveEdge.fillColor = nil
        moveEdge.isHidden = true
        layer.addSublayer(moveEdge)
        press.addTarget(self, action: #selector(pressed), for: .touchUpInside)
        press.addTarget(self, action: #selector(touchDown), for: .touchDown)
        press.addTarget(self, action: #selector(touchUp), for: [.touchUpOutside, .touchCancel, .touchUpInside])
        press.accessibilityTraits = .button
        addSubview(press)
        addSubview(picture)
        textGroup.isUserInteractionEnabled = true
        addSubview(textGroup)
        for label in [headline, clauses, liveHeadline, liveCounts, nowLabel, nowTrailing, quoteLabel, third] {
            label.isUserInteractionEnabled = false
            label.adjustsFontForContentSizeCategory = true
            label.lineBreakMode = .byTruncatingTail
            label.numberOfLines = 1
            textGroup.addSubview(label)
        }
        nowTrailing.textAlignment = .right
        wordmark.isUserInteractionEnabled = false
        wordmark.lineBreakMode = .byClipping
        textGroup.addSubview(wordmark)
        chipHost.clipsToBounds = true
        textGroup.addSubview(chipHost)
        for button in [replay, rows, open] { textGroup.addSubview(button) }
        replay.onTap = { [weak self] in
            Theme.Haptics.tap()
            self?.onReplay?()
        }
        rows.onTap = { [weak self] in
            Theme.Haptics.selection()
            self?.onRows?()
        }
        open.onTap = { [weak self] in
            Theme.Haptics.selection()
            self?.onOpen?()
        }
        isAccessibilityElement = false
        installPointer()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        MainActor.assumeIsolated {
            settleLink?.invalidate()
            BrainLiveClock.shared.unregister(self)
        }
    }

    private func installPointer() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        press.addGestureRecognizer(hover)
        press.addInteraction(UIPointerInteraction(delegate: self))
        press.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @objc func hovered(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            if !isHovered { onPrefetch?() }
            isHovered = true
        default: isHovered = false
        }
    }

    @objc private func touchDown() {
        isPressed = true
        onPrefetch?()
    }

    @objc private func touchUp() { isPressed = false }

    @objc private func pressed() {
        Theme.Haptics.selection()
        onOpen?()
    }

    func applyEmphasis() {
        let lit = isHovered || isPressed
        picture.setHovered(lit)
        guard let card else { return }
        let tone = BrainCanvas.tone(card.edgeTone).resolvedColor(with: traitCollection)
        surface.layer.borderColor =
            (lit ? tone.wash(0.7) : Theme.Color.separator).resolvedColor(with: traitCollection).cgColor
    }

    var density: ChatDensity { metrics?.density ?? .comfortable }
    var isCompact: Bool { density == .compact }

    /// Draws the card for a turn at a row width. Nothing is rebuilt when nothing the card says
    /// changed.
    func configure(
        model newModel: NeuralBrainModel, row newRow: BrainRow, memory newMemory: BrainLiveMemory,
        metrics newMetrics: NeuralStageMetrics, now: Date = BrainDebug.now
    ) {
        model = newModel
        row = newRow
        memory = newMemory
        let changedWidth = metrics?.width != newMetrics.width || metrics?.density != newMetrics.density
        metrics = newMetrics
        let made = newModel.brainCard(now: now)
        card = made
        let palette = BrainPalette.palette(for: traitCollection)
        if ink == nil || ink?.palette != palette || ink?.face != newModel.face {
            ink = BrainInk(palette: palette, face: newModel.face)
        }
        if changedWidth { lastLayout = nil }
        rebuild(now: now)
        requestPictures()
        registerClock()
        setNeedsLayout()
    }

    /// The time moved, or the model did: the words that depend on either are written again.
    func refresh(model newModel: NeuralBrainModel, now: Date = BrainDebug.now) {
        guard row != nil, metrics != nil else { return }
        let before = card?.edge
        model = newModel
        card = newModel.brainCard(now: now)
        if let before, before != .waiting, card?.edge == .waiting, window != nil { Theme.Haptics.needsYou() }
        rebuild(now: now)
        registerClock()
    }

    var isLive: Bool { card?.live != nil }

    private func registerClock() {
        if isLive, window != nil {
            BrainLiveClock.shared.register(self) { [weak self] in self?.clockTick() }
        } else {
            BrainLiveClock.shared.unregister(self)
        }
    }

    func clockTick() {
        guard let model, isLive else { return }
        refresh(model: model, now: BrainDebug.now)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        registerClock()
        if window == nil {
            settleLink?.invalidate()
            settleLink = nil
        } else {
            requestPictures()
        }
    }

    private func traitsChanged() {
        drawnSignature = ""
        restPicture = nil
        livePictures = nil
        lastLayout = nil
        ink = nil
        if let model, let row, let memory, let metrics {
            configure(model: model, row: row, memory: memory, metrics: metrics)
        }
    }

    /// The settle move, from `NeuralCardSettle`, applied to the card's two sets of words, the
    /// picture and the edge.
    func apply(settle value: NeuralCardSettle) {
        settle = value
        liveHeadline.alpha = CGFloat(value.liveHeadlineAlpha)
        liveCounts.alpha = CGFloat(value.liveHeadlineAlpha)
        liveHeadline.transform = CGAffineTransform(translationX: 0, y: CGFloat(value.liveHeadlineOffsetY))
        liveCounts.transform = liveHeadline.transform
        headline.alpha = CGFloat(value.settledHeadlineAlpha)
        clauses.alpha = CGFloat(value.settledHeadlineAlpha)
        headline.transform = CGAffineTransform(translationX: 0, y: CGFloat(value.settledHeadlineOffsetY))
        clauses.transform = headline.transform
        for label in [nowLabel, nowTrailing, quoteLabel] { label.alpha = CGFloat(value.nowLineAlpha) }
        third.alpha = CGFloat(value.firstWordsAlpha)
        picture.setLiveShare(CGFloat(1 - value.lights))
        edge.removeAnimation(forKey: "pulse")
    }

    var wideHeadline = NSMutableAttributedString()
    var narrowMain = NSAttributedString()

    var quoteSource: (speaker: String, words: String)?

    var restPicture: PictureKey?
    var livePictures: (floor: PictureKey, peak: PictureKey)?

    var hapticSettle: TimeInterval?

    var moveOffsetX: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutTexts(animated: false)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: requiredHeight(width: size.width))
    }
}

extension BrainCardView: UIPointerInteractionDelegate {
    func pointerInteraction(
        _ interaction: UIPointerInteraction, styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        guard let view = interaction.view else { return nil }
        let preview = UITargetedPreview(view: view)
        return UIPointerStyle(effect: .hover(preview, preferredTintMode: .none, prefersShadow: false, prefersScaledContent: false))
    }
}

extension BrainCardView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self, let model = self.model else { return nil }
            var items: [UIMenuElement] = []
            if model.turn.outcome != .running {
                items.append(
                    UIAction(
                        title: Localized.text("Share this turn"),
                        image: UIImage(systemName: "square.and.arrow.up")
                    ) { _ in self.onShare?() })
                items.append(
                    UIAction(
                        title: NeuralReading.replayLabel, image: UIImage(systemName: "play.circle")
                    ) { _ in self.onReplay?() })
            }
            items.append(
                UIAction(
                    title: NeuralReading.rowsLabel, image: UIImage(systemName: "list.bullet"),
                    state: self.row?.showsRows == true ? .on : .off
                ) { _ in self.onRows?() })
            return UIMenu(children: items)
        }
    }
}

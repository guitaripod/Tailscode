import TailscodeCore
import UIKit

/// One starter idea on an empty stage: a few words that put a whole brief in the box.
struct StudioStarter: Equatable {
    let title: String
}

/// Everything the stage is told, in one value, so the view is handed a state rather than asked to
/// reach back into a studio. The image studio and the video forge describe themselves in the same
/// shape and one view draws both, so a picture and a clip are watched arriving the same way.
struct StudioStageState {
    enum Face: Equatable {
        case empty
        case waiting
        case painting
        case finished
        case failed
        case stopped
    }

    var face: Face = .empty
    /// The line over the stage: what the machine is doing, or what stopped it.
    var sentence: String?
    var tone: ActivityTone = .quiet
    /// The face the sentence breathes on while the work is out. Nil holds perfectly still.
    var activity: ActivityKind?
    /// The picture held on the stage: a finished one, or the previous one under a wait.
    var picture: UIImage?
    /// The machine's sketch of the picture so far, filling the stage while one is painted.
    var sketch: UIImage?
    /// Height over width of the rectangle the render lands in, decided before it starts.
    var ratio: CGFloat = 1
    /// Over the sketch, so it is never taken for the finished picture.
    var sketchCaption: String?
    /// Under a finished picture: the words that made it and what it cost.
    var caption: String?
    var facts: String?
    /// The line along the stage's bottom edge: one fraction per segment, empty for no line.
    var bar: [Double] = []
    var starters: [StudioStarter] = []
    var emptyTitle: String?
    var emptyBody: String?
    var remedy: String?
    /// A picture the machine already holds, dimmed behind an empty stage.
    var behind: UIImage?
    var spoken: String?
    var isOpenable = false
    /// The symbol an empty, waiting or stopped stage wears: a picture's or a clip's.
    var glyph = ImageGenEntryPoint.symbol
    /// A clip is playing in `overlay`, which crosses over the sketch once, in the rectangle the
    /// sketch used.
    var overlayVisible = false
    /// How far the picture under the words is let go of: a held picture under a wait, a sketch
    /// being decoded, a stopped render's last picture.
    var dim: CGFloat = 0
}

/// The room: the picture, the clip or the sketch of one, in a rectangle that never changes size
/// while a render runs. An empty stage argues for itself with starters, a wait says what the
/// machine is doing on a glyph that breathes, a failure holds still in the failure tone with the
/// one remedy, and the sketch fills the stage and crosses over to the finished picture once.
///
/// Frames are placed by hand rather than by constraints because the rectangle the render lands in
/// is arithmetic on the stage's own size and the ratio asked for, and a sketch replacing the last
/// one must change pixels and nothing else.
final class StudioStageView: UIView {
    var onOpen: (() -> Void)?
    var onStarter: ((Int) -> Void)?
    var onRemedy: (() -> Void)?
    /// A clip's player, drawn in the same rectangle as the picture would be.
    let overlay = UIView()

    private static let margin: CGFloat = 12
    private static let line: CGFloat = 2

    private let header = UILabel()
    private let badge = ActivityBadgeView(pointSize: 16)
    private let headerRow = UIStackView()
    private let content = UIView()
    private let held = UIImageView()
    private let behind = UIImageView()
    private let scrim = UIView()
    private let sketchChip = UILabel()
    private let centre = UIStackView()
    private let centreGlyph = UIImageView()
    private let centreBadge = ActivityBadgeView(pointSize: 26)
    private let centreTitle = UILabel()
    private let centreBody = UILabel()
    private let starters = UIStackView()
    private let remedy = UIButton(type: .system)
    private let progress = StudioProgressLine()
    private var state = StudioStageState()
    private var wantsStarters = false
    private var wantsBody = false
    private var wantsGlyph = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.background
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous
        clipsToBounds = true

        header.numberOfLines = 3
        header.textAlignment = .center
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = Theme.Spacing.s
        headerRow.addArrangedSubview(badge)
        headerRow.addArrangedSubview(header)

        content.clipsToBounds = true
        content.layer.cornerRadius = 8
        content.layer.cornerCurve = .continuous
        content.backgroundColor = Theme.Color.codeBackground
        held.contentMode = .scaleAspectFit
        held.isAccessibilityElement = false
        behind.contentMode = .scaleAspectFill
        behind.alpha = 0.18
        behind.isAccessibilityElement = false
        scrim.backgroundColor = Theme.Color.background
        scrim.alpha = 0
        scrim.isUserInteractionEnabled = false
        sketchChip.numberOfLines = 1
        sketchChip.layer.cornerRadius = 9
        sketchChip.layer.masksToBounds = true
        sketchChip.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        sketchChip.isAccessibilityElement = false
        overlay.isHidden = true
        content.addSubview(held)
        content.addSubview(scrim)
        content.addSubview(overlay)
        content.addSubview(sketchChip)

        centreTitle.numberOfLines = 0
        centreTitle.textAlignment = .center
        centreBody.numberOfLines = 0
        centreBody.textAlignment = .center
        centreGlyph.contentMode = .center
        starters.axis = .vertical
        starters.spacing = Theme.Spacing.s
        starters.alignment = .center
        remedy.addAction(UIAction { [weak self] _ in self?.onRemedy?() }, for: .touchUpInside)
        centre.axis = .vertical
        centre.alignment = .center
        centre.spacing = Theme.Spacing.s
        [centreGlyph, centreBadge, centreTitle, centreBody, starters, remedy].forEach(
            centre.addArrangedSubview)
        centre.setCustomSpacing(Theme.Spacing.m, after: centreBody)

        addSubview(behind)
        addSubview(headerRow)
        addSubview(content)
        addSubview(centre)
        addSubview(progress)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inner = bounds.insetBy(dx: Self.margin, dy: 0)
        behind.frame = bounds
        let headerSize = headerRow.systemLayoutSizeFitting(
            CGSize(width: inner.width - Theme.Spacing.l, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let headerHeight = headerRow.isHidden ? 0 : min(headerSize.height, bounds.height * 0.4)
        let headerWidth = min(headerSize.width, inner.width - 2 * Theme.Spacing.s)
        headerRow.frame = CGRect(
            x: bounds.midX - headerWidth / 2, y: Theme.Spacing.s, width: headerWidth,
            height: headerHeight)
        let top = headerRow.isHidden ? Self.margin : headerRow.frame.maxY + Theme.Spacing.s
        let bottom = bounds.height - Self.margin - Self.line
        let region = CGRect(
            x: inner.minX, y: top, width: inner.width, height: max(0, bottom - top))
        content.frame = Self.fit(ratio: state.ratio, in: region)
        held.frame = content.bounds
        scrim.frame = content.bounds
        overlay.frame = content.bounds
        let chip = sketchChip.sizeThatFits(CGSize(width: content.bounds.width - 16, height: 24))
        sketchChip.frame = CGRect(
            x: 8, y: 8, width: min(chip.width + 14, content.bounds.width - 16), height: 22)
        let room = CGSize(width: inner.width - 2 * Theme.Spacing.xl, height: bounds.height)
        let centreArea = centreInRegion ? content.frame : region
        let height = fitCentre(width: room.width, into: centreArea.height)
        centre.frame = CGRect(
            x: centreArea.midX - room.width / 2, y: centreArea.midY - height / 2,
            width: room.width, height: height)
        progress.frame = CGRect(
            x: 0, y: bounds.height - Self.line, width: bounds.width, height: Self.line)
    }

    /// What the centre column drops, in the order it can best be spared, when the stage has been
    /// shrunk — by a keyboard, by Larger Text — below what all of it needs: the starters first,
    /// then the explaining line, then the glyph. The sentence itself is never dropped.
    private func fitCentre(width: CGFloat, into available: CGFloat) -> CGFloat {
        let drops: [(UIView, Bool)] = [
            (starters, wantsStarters), (centreBody, wantsBody), (centreGlyph, wantsGlyph),
        ]
        for (view, wanted) in drops { view.isHidden = !wanted }
        func measured() -> CGFloat {
            centre.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
            ).height
        }
        var wanted = measured()
        for (view, _) in drops where wanted > available && !view.isHidden {
            view.isHidden = true
            wanted = measured()
        }
        return min(wanted, max(available, 0))
    }

    private var centreInRegion: Bool {
        switch state.face {
        case .waiting: return true
        case .empty, .failed, .stopped, .painting, .finished: return false
        }
    }

    private static func fit(ratio: CGFloat, in region: CGRect) -> CGRect {
        guard region.width > 0, region.height > 0, ratio > 0 else { return region }
        var width = region.width
        var height = width * ratio
        if height > region.height {
            height = region.height
            width = height / ratio
        }
        return CGRect(
            x: region.midX - width / 2, y: region.midY - height / 2, width: width, height: height)
    }

    func apply(_ next: StudioStageState) {
        let previous = state
        state = next
        let sketching = next.sketch != nil && (next.face == .painting || next.face == .waiting)
        let shown = sketching ? next.sketch : next.picture
        let keepSketch = next.overlayVisible && !previous.overlayVisible
        let crossing = !sketching && next.face == .finished
            && (previous.face == .painting || previous.face == .waiting) && previous.sketch != nil
            && held.image != nil && !UIAccessibility.isReduceMotionEnabled
        if crossing {
            UIView.transition(
                with: held, duration: 0.24, options: [.transitionCrossDissolve, .curveEaseOut]
            ) {
                self.held.image = shown
            }
        } else if !keepSketch, held.image !== shown {
            held.image = shown
        }
        held.isHidden = shown == nil && !keepSketch
        scrim.alpha = shown == nil ? 0 : next.dim
        applyOverlay(next.overlayVisible, previous: previous.overlayVisible)
        let visual = shown != nil || next.overlayVisible
        content.isHidden = !(visual || next.face == .waiting)
        content.backgroundColor = Theme.Color.codeBackground
        applyHeader(next)
        applyChip(next)
        applyCentre(next, holding: visual)
        behind.image = next.face == .empty ? next.behind : nil
        progress.apply(next.bar)
        let interactive = next.face == .empty || next.face == .failed
        isAccessibilityElement = !interactive
        accessibilityLabel = next.spoken ?? next.sentence ?? next.caption
        accessibilityTraits = next.isOpenable
            ? [.image, .button] : (next.activity != nil ? .updatesFrequently : .staticText)
        setNeedsLayout()
    }

    private func applyOverlay(_ visible: Bool, previous: Bool) {
        guard visible != previous || overlay.isHidden == visible else { return }
        if !visible {
            overlay.isHidden = true
            overlay.alpha = 1
            return
        }
        overlay.isHidden = false
        guard !UIAccessibility.isReduceMotionEnabled, held.image != nil else {
            overlay.alpha = 1
            held.image = nil
            return
        }
        overlay.alpha = 0
        UIView.animate(
            withDuration: 0.24, delay: 0, options: [.curveEaseOut],
            animations: { self.overlay.alpha = 1 },
            completion: { _ in self.held.image = nil })
    }

    private func applyHeader(_ next: StudioStageState) {
        let words: NSAttributedString
        switch next.face {
        case .finished:
            let result = NSMutableAttributedString()
            if let caption = next.caption, !caption.isEmpty {
                result.append(
                    NSAttributedString(
                        string: caption,
                        attributes: Theme.Ramp.attributes(
                            .panelFootnote, color: Theme.Color.label, alignment: .center)))
            }
            if let facts = next.facts, !facts.isEmpty {
                if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
                result.append(
                    NSAttributedString(
                        string: facts,
                        attributes: Theme.Ramp.attributes(
                            .responseStat, color: Theme.Color.tertiaryLabel, alignment: .center)))
            }
            words = result
            header.numberOfLines = 4
        case .painting, .waiting:
            words = NSAttributedString(
                string: next.sentence ?? "",
                attributes: Theme.Ramp.attributes(
                    .panelFootnote, color: Theme.Color.secondaryLabel, alignment: .center))
            header.numberOfLines = 2
        case .stopped:
            words = NSAttributedString(
                string: next.sentence ?? "",
                attributes: Theme.Ramp.attributes(
                    .panelFootnote, color: Theme.Color.warning, alignment: .center))
            header.numberOfLines = 2
        case .empty, .failed:
            words = NSAttributedString()
        }
        header.attributedText = words
        let sentenceOnly = next.face == .painting
        badge.activity = sentenceOnly ? next.activity : nil
        badge.isHidden = !sentenceOnly || next.activity == nil
        headerRow.isHidden = words.length == 0
    }

    private func applyChip(_ next: StudioStageState) {
        let showing = next.sketch != nil && next.face == .painting && next.sketchCaption != nil
        sketchChip.isHidden = !showing
        guard showing else { return }
        sketchChip.attributedText = NSAttributedString(
            string: " \(next.sketchCaption ?? "") ",
            attributes: Theme.Ramp.attributes(.sectionLabel, color: .white))
    }

    private func applyCentre(_ next: StudioStageState, holding: Bool) {
        let showing: Bool
        switch next.face {
        case .empty, .failed, .waiting: showing = true
        case .stopped: showing = !holding
        case .painting, .finished: showing = false
        }
        centre.isHidden = !showing
        guard showing else { return }
        let breathing = next.face == .waiting && next.activity != nil
        centreBadge.activity = breathing ? next.activity : nil
        centreBadge.isHidden = !breathing
        wantsGlyph = !breathing
        let failed = next.face == .failed
        centreGlyph.image = UIImage(
            systemName: failed ? "exclamationmark.triangle" : next.glyph,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .regular))
        centreGlyph.tintColor = failed ? Theme.Color.danger : Theme.Color.tertiaryLabel
        let title = next.face == .empty ? next.emptyTitle : next.sentence
        centreTitle.isHidden = (title ?? "").isEmpty
        centreTitle.attributedText = NSAttributedString(
            string: title ?? "",
            attributes: Theme.Ramp.attributes(
                .cardTitle, color: failed ? Theme.Color.danger : Theme.Color.label,
                alignment: .center))
        let body = next.face == .empty ? next.emptyBody : (failed ? next.caption : nil)
        wantsBody = !(body ?? "").isEmpty
        centreBody.attributedText = NSAttributedString(
            string: body ?? "",
            attributes: Theme.Ramp.attributes(
                .panelFootnote, color: Theme.Color.secondaryLabel, alignment: .center))
        starters.arrangedSubviews.forEach { $0.removeFromSuperview() }
        wantsStarters = next.face == .empty && !next.starters.isEmpty
        if next.face == .empty {
            for (index, starter) in next.starters.enumerated() {
                starters.addArrangedSubview(starterButton(starter, index: index))
            }
        }
        remedy.isHidden = !(failed || next.face == .empty) || next.remedy == nil
        if let words = next.remedy {
            var config = Theme.Glass.buttonConfiguration()
            config.cornerStyle = .capsule
            var title = AttributedString(words)
            title.font = Theme.Ramp.font(.control)
            config.attributedTitle = title
            remedy.configuration = config
            remedy.accessibilityLabel = words
        }
    }

    private func starterButton(_ starter: StudioStarter, index: Int) -> UIButton {
        var config = Theme.Glass.buttonConfiguration()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.titleLineBreakMode = .byWordWrapping
        var title = AttributedString(starter.title)
        title.font = Theme.Ramp.font(.sectionLabel)
        config.attributedTitle = title
        let button = UIButton(configuration: config)
        button.addAction(
            UIAction { [weak self] _ in self?.onStarter?(index) }, for: .touchUpInside)
        button.accessibilityLabel = starter.title
        return button
    }

    @objc private func tapped() {
        guard state.isOpenable else { return }
        onOpen?()
    }
}

/// The line along the stage's bottom edge: two points tall, one segment per pass of the render,
/// each filling to its own fraction. It belongs to the stage rather than to the window because it
/// measures the thing the stage is showing, and it is absent — never sitting at zero — until the
/// machine has a count to fill it from.
final class StudioProgressLine: UIView {
    private var segments: [UIView] = []
    private var fills: [UIView] = []
    private var fractions: [Double] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ next: [Double]) {
        guard next != fractions else { return }
        let rebuilt = next.count != fractions.count
        fractions = next
        isHidden = next.isEmpty
        if rebuilt {
            (segments + fills).forEach { $0.removeFromSuperview() }
            segments = next.map { _ in
                let track = UIView()
                track.backgroundColor = Theme.Color.separator
                return track
            }
            fills = next.map { _ in
                let fill = UIView()
                fill.backgroundColor = Theme.Color.accent
                return fill
            }
            zip(segments, fills).forEach { track, fill in
                addSubview(track)
                addSubview(fill)
            }
        }
        let animate = !rebuilt && !UIAccessibility.isReduceMotionEnabled && window != nil
        UIView.animate(withDuration: animate ? 0.25 : 0, delay: 0, options: [.curveEaseOut]) {
            self.layoutFills()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutFills()
    }

    private func layoutFills() {
        guard !segments.isEmpty else { return }
        let gap: CGFloat = segments.count > 1 ? 2 : 0
        let width = (bounds.width - gap * CGFloat(segments.count - 1)) / CGFloat(segments.count)
        for (index, track) in segments.enumerated() {
            let x = CGFloat(index) * (width + gap)
            track.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            let share = CGFloat(max(0, min(1, fractions[index])))
            fills[index].frame = CGRect(x: x, y: 0, width: width * share, height: bounds.height)
        }
    }
}

/// Where a sketch becomes a bitmap. A frame arrives on the socket's queue and is decoded there,
/// ready to draw, so the main thread never pays for a decode between two refreshes — and a frame
/// larger than a sketch can honestly be is dropped rather than decoded, because the machine bounds
/// them to a few hundred pixels and anything bigger is not one.
enum StudioSketch {
    static let ceiling = 4 * 1024 * 1024

    static func decode(_ frame: ImageGenPreviewFrame) -> UIImage? {
        guard frame.bytes.count <= ceiling, let image = UIImage(data: frame.bytes) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}

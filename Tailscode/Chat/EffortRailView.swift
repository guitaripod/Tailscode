import TailscodeCore
import UIKit

/// The effort ladder lifted out of the composer's pill as a column of rungs to tap or slide along.
///
/// What it draws is `ModelDial.rungs` — the power on top, then hottest first, the server's own
/// choice last — and what decides which rung a sliding finger holds lives in Core (`EffortRail`). This only
/// lays the rungs out, lights the one being held and says what it means.
@MainActor
final class EffortRailView: UIView {
    enum Density {
        case full
        case compact
        case tight

        var rowHeight: CGFloat {
            switch self {
            case .full: return 46
            case .compact: return 38
            case .tight: return 32
            }
        }

        var showsCaptions: Bool { self == .full }
        var showsFooter: Bool { self != .tight }
    }

    static let width: CGFloat = 268

    private let glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let column = UIStackView()
    private let footer = UILabel()
    private var rows: [RungRowView] = []
    private let rungs: [EffortRung]
    private let density: Density
    private(set) var held: Int

    init(rungs: [EffortRung], current: String?, density: Density) {
        self.rungs = rungs
        self.density = density
        self.held = rungs.firstIndex { $0.level == current } ?? max(0, rungs.count - 1)
        super.init(frame: .zero)
        build()
        light(held, animated: false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        layer.cornerRadius = 26
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.label.withAlphaComponent(0.12).cgColor
        clipsToBounds = true
        accessibilityViewIsModal = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        column.axis = .vertical
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(column)

        for (index, rung) in rungs.enumerated() {
            if rung.isServer, index > 0, !rungs[index - 1].isServer {
                column.addArrangedSubview(Self.gap())
            }
            let row = RungRowView(rung: rung, density: density)
            rows.append(row)
            column.addArrangedSubview(row)
            if rung.isPower, index + 1 < rungs.count { column.addArrangedSubview(Self.gap()) }
        }

        footer.numberOfLines = 0
        footer.font = Theme.Ramp.font(.panelFootnote)
        footer.textColor = Theme.Color.secondaryLabel
        footer.adjustsFontForContentSizeCategory = true
        footer.isHidden = !density.showsFooter
        let foot = UIView()
        foot.addSubview(footer)
        footer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            footer.topAnchor.constraint(equalTo: foot.topAnchor, constant: 8),
            footer.bottomAnchor.constraint(equalTo: foot.bottomAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: foot.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: foot.trailingAnchor, constant: -14),
        ])
        foot.isHidden = !density.showsFooter
        column.addArrangedSubview(foot)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 8),
            column.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -8),
            column.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -4),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    private static func gap() -> UIView {
        let gap = UIView()
        let line = UIView()
        line.backgroundColor = Theme.Color.separator
        line.translatesAutoresizingMaskIntoConstraints = false
        gap.addSubview(line)
        NSLayoutConstraint.activate([
            gap.heightAnchor.constraint(equalToConstant: 13),
            line.heightAnchor.constraint(equalToConstant: 0.5),
            line.centerYAnchor.constraint(equalTo: gap.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: gap.leadingAnchor, constant: 12),
            line.trailingAnchor.constraint(equalTo: gap.trailingAnchor, constant: -12),
        ])
        return gap
    }

    /// The vertical centre of every rung, in `view`'s coordinates, which is what the finger's
    /// travel is measured against.
    func centers(in view: UIView) -> [Double] {
        layoutIfNeeded()
        return rows.map { Double(view.convert(CGPoint(x: 0, y: $0.bounds.midY), from: $0).y) }
    }

    func rowIndex(at point: CGPoint) -> Int? {
        rows.firstIndex { $0.convert($0.bounds, to: self).contains(point) }
    }

    func light(_ index: Int, animated: Bool) {
        guard rows.indices.contains(index) else { return }
        held = index
        let apply = {
            for (position, row) in self.rows.enumerated() {
                row.setHeld(position == index, heat: Self.heatColor(for: self.rungs[position]))
            }
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            apply()
            return
        }
        UIView.animate(
            withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction],
            animations: apply)
    }

    func say(_ text: String?) {
        footer.text = text
    }

    private static func heatColor(for rung: EffortRung) -> UIColor {
        if rung.isPower { return Theme.Color.modelRainbowLetter(2, of: EffortMeter.bars) }
        guard let level = rung.level else { return Theme.Color.tertiaryLabel }
        return Theme.Color.modelEffort(level) ?? Theme.Color.secondaryLabel
    }
}

/// One rung of the rail: its bars, its word, what it means, and a tick where it is held.
@MainActor
private final class RungRowView: UIView {
    private let meter: EffortMeterView
    private let title = UILabel()
    private let caption = UILabel()
    private let check = UIImageView()
    private let rung: EffortRung

    init(rung: EffortRung, density: EffortRailView.Density) {
        self.rung = rung
        self.meter = EffortMeterView(reading: .init(rung: rung))
        super.init(frame: .zero)
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel =
            rung.caption.isEmpty ? rung.title : rung.title + ", " + rung.caption

        title.attributedText = Self.titleText(rung)
        caption.text = rung.caption
        caption.font = Theme.Ramp.font(.panelFootnote)
        caption.textColor = Theme.Color.secondaryLabel
        caption.isHidden = !density.showsCaptions || rung.caption.isEmpty
        caption.numberOfLines = 0
        title.adjustsFontForContentSizeCategory = true
        caption.adjustsFontForContentSizeCategory = true

        check.image = UIImage(
            systemName: "checkmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        check.tintColor = Theme.Color.accent
        check.contentMode = .center
        check.alpha = 0
        check.setContentHuggingPriority(.required, for: .horizontal)
        check.setContentCompressionResistancePriority(.required, for: .horizontal)
        check.widthAnchor.constraint(equalToConstant: 16).isActive = true
        meter.setContentHuggingPriority(.required, for: .horizontal)

        let text = UIStackView(arrangedSubviews: [title, caption])
        text.axis = .vertical
        text.spacing = 1
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [meter, text, check])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
            heightAnchor.constraint(greaterThanOrEqualToConstant: density.rowHeight),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setHeld(_ held: Bool, heat: UIColor) {
        check.alpha = held ? 1 : 0
        layer.borderWidth = held ? 1.5 : 0
        layer.borderColor = heat.cgColor
        backgroundColor = held ? UIColor.label.withAlphaComponent(0.08) : .clear
        accessibilityTraits = held ? [.button, .selected] : .button
    }

    private static func titleText(_ rung: EffortRung) -> NSAttributedString {
        let font = Theme.Ramp.font(.rowTitleStrong)
        guard rung.isPower else {
            return NSAttributedString(
                string: rung.title,
                attributes: [
                    .font: font,
                    .foregroundColor: rung.isServer ? Theme.Color.secondaryLabel : Theme.Color.label,
                ])
        }
        let text = NSMutableAttributedString()
        for (index, letter) in rung.title.enumerated() {
            text.append(
                NSAttributedString(
                    string: String(letter),
                    attributes: [
                        .font: font,
                        .foregroundColor: Theme.Color.modelRainbowLetter(index, of: rung.title.count),
                    ]))
        }
        return text
    }
}

/// Presents the rail over a screen and lets a finger choose on it.
///
/// One tap on the pill's effort half opens it with the level the chat is at already marked, and
/// then it works the way a list does: tap a level and it is set, or put a finger down on one and
/// slide to another before lifting — the level under the finger is the one that is held, with a
/// tick for each one entered. Lifting well off the side of the rail, or tapping the dimmed page,
/// chooses nothing. The scrim sits under the composer so the thing being aimed stays in view, and
/// the rail is a thick material rather than glass: a transparent one let the transcript run
/// through its words.
@MainActor
final class EffortRailPresenter {
    private weak var host: UIView?
    private weak var below: UIView?
    private var scrim: UIControl?
    private var rail: EffortRailView?
    private var rungs: [EffortRung] = []
    private var centers: [Double] = []
    private var held = 0
    private var engaged = false
    private var cancelling = false
    private var initialLevel: String?

    var footer: ((EffortRung) -> String?)?
    var onSet: ((String?) -> Void)?
    var onDismiss: (() -> Void)?

    var isPresented: Bool { rail != nil }

    private var keyboardProbe: KeyboardEdgeProbe?

    init(host: UIView, below: UIView?) {
        self.host = host
        self.below = below
    }

    func present(anchor: UIView, rungs: [EffortRung], current: String?) {
        guard let host, rail == nil, !rungs.isEmpty else { return }
        self.rungs = rungs
        initialLevel = current
        cancelling = false
        engaged = false

        let anchorFrame = anchor.convert(anchor.bounds, to: host)
        let belowTop = below.map { $0.convert($0.bounds, to: host).minY } ?? anchorFrame.minY
        let bottom = min(anchorFrame.minY, belowTop) - 10
        let available = bottom - Self.ceiling(in: host, above: bottom, rungCount: rungs.count) - 8
        let view = EffortRailView(
            rungs: rungs, current: current, density: Self.density(rungs: rungs, available: available))
        rail = view
        held = view.held

        let scrim = UIControl()
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        scrim.alpha = 0
        scrim.frame = host.bounds
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrim.addAction(UIAction { [weak self] _ in self?.dismiss(committing: false) }, for: .touchUpInside)
        scrim.isAccessibilityElement = true
        scrim.accessibilityLabel = String(localized: "Close")
        scrim.accessibilityTraits = .button
        if let below { host.insertSubview(scrim, belowSubview: below) } else { host.addSubview(scrim) }
        self.scrim = scrim

        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        let left = max(
            host.safeAreaInsets.left + 12,
            min(anchorFrame.minX - 6, host.bounds.width - host.safeAreaInsets.right - 12 - EffortRailView.width))
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: left),
            view.bottomAnchor.constraint(equalTo: host.topAnchor, constant: bottom),
        ])
        host.layoutIfNeeded()
        centers = view.centers(in: host)
        view.say(footer?(rungs[held]))

        let touch = UILongPressGestureRecognizer(target: self, action: #selector(railTouched(_:)))
        touch.minimumPressDuration = 0
        touch.allowableMovement = .greatestFiniteMagnitude
        view.addGestureRecognizer(touch)

        Theme.Haptics.tap()
        watchKeyboardEdge(in: host)
        UIAccessibility.post(notification: .screenChanged, argument: view)
        let appear = {
            scrim.alpha = 1
            view.alpha = 1
            view.transform = .identity
        }
        guard !UIAccessibility.isReduceMotionEnabled else { return appear() }
        view.alpha = 0
        view.transform = CGAffineTransform(translationX: 0, y: 14).scaledBy(x: 0.96, y: 0.96)
        UIView.animate(
            withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.3,
            options: [.allowUserInteraction], animations: appear)
    }

    /// A rail is drawn where the keyboard was when it opened, so a keyboard that moves — up, down,
    /// undocked, or resized by a fold — closes it. The keyboard's edge is read from the host's own
    /// keyboard guide rather than from a notification, so it follows whichever window and display
    /// the host is in.
    private func watchKeyboardEdge(in host: UIView) {
        let probe = KeyboardEdgeProbe()
        probe.translatesAutoresizingMaskIntoConstraints = false
        probe.isUserInteractionEnabled = false
        probe.onMove = { [weak self] in self?.dismiss(committing: false) }
        host.addSubview(probe)
        NSLayoutConstraint.activate([
            probe.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            probe.widthAnchor.constraint(equalToConstant: 1),
            probe.heightAnchor.constraint(equalToConstant: 0),
            probe.bottomAnchor.constraint(equalTo: host.keyboardLayoutGuide.topAnchor),
        ])
        keyboardProbe = probe
    }

    /// A finger on the rail: where it comes down on a level picks that level, and sliding moves the
    /// pick with it. A finger that comes down on the gaps or the footer is not choosing anything.
    @objc private func railTouched(_ gesture: UILongPressGestureRecognizer) {
        guard let rail, let host else { return }
        switch gesture.state {
        case .began:
            guard let index = rail.rowIndex(at: gesture.location(in: rail)) else { return }
            engaged = true
            select(index, in: rail)
        case .changed:
            guard engaged else { return }
            let point = gesture.location(in: host)
            let frame = rail.frame
            let stray = max(frame.minX - point.x, point.x - frame.maxX, 0)
            let nowCancelling = EffortRail.cancels(horizontalDistance: Double(stray))
            if nowCancelling != cancelling {
                cancelling = nowCancelling
                UIView.animate(withDuration: 0.15) { rail.alpha = nowCancelling ? 0.5 : 1 }
            }
            guard let next = EffortRail.target(current: held, centers: centers, y: Double(point.y)) else {
                return
            }
            select(next, in: rail)
        case .ended:
            guard engaged else { return }
            dismiss(committing: !cancelling)
        case .cancelled, .failed:
            dismiss(committing: false)
        default:
            break
        }
    }

    private func select(_ index: Int, in rail: EffortRailView) {
        guard index != held else { return }
        if EffortRail.ticks(from: held, to: index) { Theme.Haptics.notch() }
        held = index
        rail.light(index, animated: true)
        rail.say(footer?(rungs[index]))
    }

    func dismiss(committing: Bool) {
        guard let rail else { return }
        let chosen = rungs.indices.contains(held) ? rungs[held] : nil
        keyboardProbe?.removeFromSuperview()
        keyboardProbe = nil
        let scrim = self.scrim
        self.rail = nil
        self.scrim = nil
        if committing, let chosen, chosen.level != initialLevel {
            onSet?(chosen.level)
        }
        let finish = {
            rail.removeFromSuperview()
            scrim?.removeFromSuperview()
        }
        onDismiss?()
        guard !UIAccessibility.isReduceMotionEnabled else { return finish() }
        UIView.animate(
            withDuration: 0.2, delay: 0, options: [.curveEaseIn],
            animations: {
                rail.alpha = 0
                rail.transform = CGAffineTransform(translationX: 0, y: 10).scaledBy(x: 0.97, y: 0.97)
                scrim?.alpha = 0
            }
        ) { _ in finish() }
    }

    /// The highest the rail may reach. Held like a laptop the rail belongs on the base with the
    /// composer, below the fold; when the keyboard leaves the base too little room for even the
    /// tightest rail it reaches into the top region rather than not opening at all.
    private static func ceiling(in host: UIView, above bottom: CGFloat, rungCount: Int) -> CGFloat {
        let top = host.safeAreaInsets.top
        guard let fold = FoldReading.read(in: host), fold.isLaptop, bottom > fold.frame.maxY else {
            return top
        }
        let tightest = CGFloat(rungCount) * EffortRailView.Density.tight.rowHeight + 38
        return bottom - fold.frame.maxY >= tightest ? fold.frame.maxY : top
    }

    private static func density(rungs: [EffortRung], available: CGFloat) -> EffortRailView.Density {
        let gaps: CGFloat = 26
        let chrome: CGFloat = 12
        for density in [EffortRailView.Density.full, .compact, .tight] {
            let footer: CGFloat = density.showsFooter ? 56 : 0
            let need = CGFloat(rungs.count) * density.rowHeight + gaps + chrome + footer
            if need <= available { return density }
        }
        return .tight
    }
}

/// Zero-height view that sits on the keyboard guide's top edge and reports when that edge moves
/// after its first resting position.
@MainActor
private final class KeyboardEdgeProbe: UIView {
    var onMove: (() -> Void)?
    private var restingEdge: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard window != nil else { return }
        guard let restingEdge else {
            restingEdge = frame.maxY
            return
        }
        if abs(frame.maxY - restingEdge) > 0.5 { onMove?() }
    }
}

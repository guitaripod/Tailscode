import TailscodeCore
import UIKit

/// The effort ladder lifted out of the composer's pill as a column of rungs a thumb travels along.
///
/// What it draws is `ModelDial.rungs` — the power on top, then hottest first, the server's own
/// choice last — and what decides where the thumb is lives in Core (`EffortRail`). This only
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

    private let glass = Theme.Glass.view(interactive: false)
    private let column = UIStackView()
    private let thumb = UIView()
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
        clipsToBounds = true
        accessibilityViewIsModal = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        thumb.layer.cornerRadius = 18
        thumb.layer.cornerCurve = .continuous
        thumb.layer.borderWidth = 1.5
        thumb.backgroundColor = UIColor.label.withAlphaComponent(0.09)
        thumb.isUserInteractionEnabled = false
        glass.contentView.addSubview(thumb)

        column.axis = .vertical
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(column)

        for (index, rung) in rungs.enumerated() {
            if rung.isServer, index > 0 { column.addArrangedSubview(Self.gap()) }
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
        layoutIfNeeded()
        let frame = rows[index].convert(rows[index].bounds, to: glass.contentView)
        let heat = Self.heatColor(for: rungs[index])
        let apply = {
            self.thumb.frame = frame
            self.thumb.layer.borderColor = heat.cgColor
            for (position, row) in self.rows.enumerated() { row.setHeld(position == index) }
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            apply()
            return
        }
        UIView.animate(
            withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.4,
            options: [.beginFromCurrentState, .allowUserInteraction], animations: apply)
    }

    func say(_ text: String?) {
        footer.text = text
    }

    private static func heatColor(for rung: EffortRung) -> UIColor {
        if rung.isPower { return Theme.Color.modelRainbowLetter(2, of: EffortMeter.bars) }
        guard let level = rung.level else { return Theme.Color.tertiaryLabel }
        return Theme.Color.modelEffort(level) ?? Theme.Color.secondaryLabel
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard rows.indices.contains(held) else { return }
        thumb.frame = rows[held].convert(rows[held].bounds, to: glass.contentView)
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
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel =
            rung.caption.isEmpty ? rung.title : rung.title + ", " + rung.caption

        title.attributedText = Self.titleText(rung)
        caption.text = rung.caption
        caption.font = Theme.Ramp.font(.panelFootnote)
        caption.textColor = Theme.Color.secondaryLabel
        caption.isHidden = !density.showsCaptions || rung.caption.isEmpty
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
            heightAnchor.constraint(equalToConstant: density.rowHeight),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setHeld(_ held: Bool) {
        check.alpha = held ? 1 : 0
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

/// Presents the rail over a screen and walks a finger along it.
///
/// A press-and-slide starts on the pill and ends where the finger lifts, so what a finger does
/// is measured as travel from where it came down: the rail opens with the level the chat is
/// at already lit, and moving up is hotter by as many rows as the finger has crossed. A tap
/// that goes nowhere leaves the rail open to be tapped instead — which is also the road for a
/// screen reader and for anyone who cannot hold a press. The scrim sits under the composer so
/// the thing being aimed stays in view.
@MainActor
final class EffortRailPresenter {
    private weak var host: UIView?
    private weak var below: UIView?
    private var scrim: UIControl?
    private var rail: EffortRailView?
    private var rungs: [EffortRung] = []
    private var centers: [Double] = []
    private var origin = 0
    private var held = 0
    private var startFinger: CGPoint = .zero
    private var cancelling = false
    private var initialLevel: String?
    private var sticky = false

    var footer: ((EffortRung) -> String?)?
    var onSet: ((String?) -> Void)?
    var onDismiss: (() -> Void)?

    var isPresented: Bool { rail != nil }

    private nonisolated(unsafe) var keyboardWatch: NSObjectProtocol?

    init(host: UIView, below: UIView?) {
        self.host = host
        self.below = below
    }

    deinit {
        if let keyboardWatch { NotificationCenter.default.removeObserver(keyboardWatch) }
    }

    /// - Parameter finger: where a press came down, in the host's coordinates; nil for a tap,
    ///   which opens the rail to be tapped.
    func present(anchor: UIView, rungs: [EffortRung], current: String?, finger: CGPoint?) {
        guard let host, rail == nil, !rungs.isEmpty else { return }
        self.rungs = rungs
        initialLevel = current
        sticky = finger == nil
        cancelling = false

        let anchorFrame = anchor.convert(anchor.bounds, to: host)
        let belowTop = below.map { $0.convert($0.bounds, to: host).minY } ?? anchorFrame.minY
        let bottom = min(anchorFrame.minY, belowTop) - 10
        let available = bottom - host.safeAreaInsets.top - 8
        let view = EffortRailView(
            rungs: rungs, current: current, density: Self.density(rungs: rungs, available: available))
        rail = view
        origin = view.held
        held = view.held

        let scrim = UIControl()
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.34)
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
        startFinger = finger ?? .zero
        view.say(footer?(rungs[held]))

        if sticky {
            let tap = UITapGestureRecognizer(target: self, action: #selector(railTapped(_:)))
            view.addGestureRecognizer(tap)
        }
        Theme.Haptics.tap()
        keyboardWatch = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(committing: false) }
        }
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

    /// The finger moved. `point` is in the host's coordinates.
    func move(to point: CGPoint) {
        guard let rail, !sticky, !centers.isEmpty else { return }
        let travelled = Double(point.y - startFinger.y)
        let effective = centers[origin] + travelled
        let stray = Double(abs(point.x - startFinger.x))
        let nowCancelling = EffortRail.cancels(horizontalDistance: stray)
        if nowCancelling != cancelling {
            cancelling = nowCancelling
            UIView.animate(withDuration: 0.15) { rail.alpha = nowCancelling ? 0.45 : 1 }
        }
        guard let next = EffortRail.target(current: held, centers: centers, y: effective),
            next != held
        else { return }
        if EffortRail.ticks(from: held, to: next) { Theme.Haptics.notch() }
        held = next
        rail.light(next, animated: true)
        rail.say(footer?(rungs[next]))
    }

    /// The finger lifted.
    func end() {
        guard rail != nil, !sticky else { return }
        dismiss(committing: !cancelling)
    }

    @objc private func railTapped(_ gesture: UITapGestureRecognizer) {
        guard let rail, let index = rail.rowIndex(at: gesture.location(in: rail)) else { return }
        held = index
        rail.light(index, animated: true)
        Theme.Haptics.notch()
        dismiss(committing: true)
    }

    func dismiss(committing: Bool) {
        guard let rail else { return }
        let chosen = rungs.indices.contains(held) ? rungs[held] : nil
        if let keyboardWatch {
            NotificationCenter.default.removeObserver(keyboardWatch)
            self.keyboardWatch = nil
        }
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

import TailscodeCore
import UIKit

/// The ladder: one rung per tier, cheapest first, drawn the same way whether it is being set or
/// being read.
///
/// Composing, a tap on a rung is where the run starts and the cap dragged above a rung is how far
/// it may climb; tapping the start rung again unsets it, so "the class decides" is one tap away.
/// Reading, every rung wears the state the story gave it — the rung it passed at lit, the ones it
/// failed marked, the ones beyond its ceiling greyed — so composing and reading use one picture.
final class TierLadderControl: UIControl {
    enum Mode {
        case compose
        case display
    }

    var mode: Mode = .display { didSet { render() } }
    var rungs: [DelegateRung] = [] { didSet { rebuild() } }
    private(set) var start: String?
    private(set) var ceiling: String?
    var onChange: ((String?, String?) -> Void)?

    private let row = UIStackView()
    private let cap = UIView()
    private let capGlyph = UIImageView(image: UIImage(systemName: "chevron.compact.down"))
    private var buttons: [UIButton] = []
    private var capCenter: NSLayoutConstraint?
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(dragCap(_:)))

    init() {
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func set(start: String?, ceiling: String?) {
        self.start = start
        self.ceiling = ceiling
        render()
    }

    private func build() {
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = Theme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        cap.translatesAutoresizingMaskIntoConstraints = false
        cap.isUserInteractionEnabled = false
        capGlyph.translatesAutoresizingMaskIntoConstraints = false
        capGlyph.tintColor = Theme.Color.accent
        capGlyph.contentMode = .scaleAspectFit
        cap.addSubview(capGlyph)
        addSubview(cap)
        NSLayoutConstraint.activate([
            cap.topAnchor.constraint(equalTo: topAnchor),
            cap.heightAnchor.constraint(equalToConstant: 18),
            cap.widthAnchor.constraint(equalToConstant: 44),
            capGlyph.centerXAnchor.constraint(equalTo: cap.centerXAnchor),
            capGlyph.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
            capGlyph.heightAnchor.constraint(equalToConstant: 16),
            row.topAnchor.constraint(equalTo: cap.bottomAnchor, constant: Theme.Spacing.xs),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addGestureRecognizer(pan)
        isAccessibilityElement = false
    }

    private func rebuild() {
        for button in buttons { button.removeFromSuperview() }
        buttons = rungs.map { rung in
            var config = UIButton.Configuration.filled()
            config.cornerStyle = .medium
            config.titleAlignment = .center
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4)
            let button = UIButton(configuration: config)
            button.accessibilityIdentifier = "rung-\(rung.tier)"
            button.addAction(UIAction { [weak self] _ in self?.tapped(rung.tier) }, for: .touchUpInside)
            button.titleLabel?.numberOfLines = 3
            button.titleLabel?.textAlignment = .center
            row.addArrangedSubview(button)
            return button
        }
        render()
    }

    private func tapped(_ tier: String) {
        guard mode == .compose else { return }
        Theme.Haptics.selection()
        start = start == tier ? nil : tier
        if let start, let ceiling, index(of: ceiling) < index(of: start) { self.ceiling = start }
        render()
        onChange?(start, ceiling)
    }

    @objc private func dragCap(_ gesture: UIPanGestureRecognizer) {
        guard mode == .compose, !buttons.isEmpty else { return }
        let x = gesture.location(in: row).x
        guard let nearest = buttons.enumerated().min(by: { abs($0.element.center.x - x) < abs($1.element.center.x - x) }) else { return }
        let tier = rungs[nearest.offset].tier
        if gesture.state == .began || gesture.state == .changed {
            if ceiling != tier {
                ceiling = tier
                if let start, index(of: tier) < index(of: start) { self.start = tier }
                Theme.Haptics.selection()
                render()
            }
        } else if gesture.state == .ended {
            onChange?(start, ceiling)
        }
    }

    private func index(of tier: String) -> Int { rungs.firstIndex { $0.tier == tier } ?? 0 }

    private func render() {
        let startIndex = start.map(index(of:))
        let ceilingIndex = ceiling.map(index(of:))
        for (offset, rung) in rungs.enumerated() {
            let button = buttons[offset]
            var config = button.configuration ?? .filled()
            let (fill, ink, stroke): (UIColor, UIColor, UIColor?)
            let state: DelegateRungState
            switch mode {
            case .display:
                state = rung.state
            case .compose:
                if let startIndex, offset < startIndex {
                    state = .belowStart
                } else if let ceilingIndex, offset > ceilingIndex {
                    state = .beyondCeiling
                } else if let startIndex, offset == startIndex {
                    state = .current
                } else {
                    state = .pending
                }
            }
            switch state {
            case .current, .passed:
                (fill, ink, stroke) = (state.tone.color, Theme.Color.onAccent, nil)
            case .failed:
                (fill, ink, stroke) = (Theme.Color.danger.withAlphaComponent(0.14), Theme.Color.danger, Theme.Color.danger)
            case .held:
                (fill, ink, stroke) = (Theme.Color.warning.withAlphaComponent(0.16), Theme.Color.warning, Theme.Color.warning)
            case .skipped:
                (fill, ink, stroke) = (Theme.Color.groupedSurface, Theme.Color.tertiaryLabel, Theme.Color.separator)
            case .pending:
                (fill, ink, stroke) = (Theme.Color.accent.withAlphaComponent(0.10), Theme.Color.label, Theme.Color.accent.withAlphaComponent(0.5))
            case .belowStart, .beyondCeiling:
                (fill, ink, stroke) = (Theme.Color.groupedSurface, Theme.Color.tertiaryLabel, nil)
            }
            config.baseBackgroundColor = fill
            config.baseForegroundColor = ink
            config.background.strokeColor = stroke
            config.background.strokeWidth = stroke == nil ? 0 : 1
            config.attributedTitle = Self.title(rung, ink: ink, state: state)
            button.configuration = config
            button.accessibilityLabel = "\(rung.tier) \(rung.label) \(DelegateLadder.word(state))"
            button.accessibilityValue = rung.model
        }
        let capIndex = mode == .compose ? ceilingIndex : nil
        capCenter?.isActive = false
        cap.isHidden = capIndex == nil
        if let capIndex, capIndex < buttons.count {
            capCenter = cap.centerXAnchor.constraint(equalTo: buttons[capIndex].centerXAnchor)
            capCenter?.isActive = true
        }
        pan.isEnabled = mode == .compose
    }

    private static func title(_ rung: DelegateRung, ink: UIColor, state: DelegateRungState) -> AttributedString {
        var title = AttributedString(rung.tier)
        title.font = Theme.Ramp.font(.rowTitleStrong)
        title.foregroundColor = ink
        let mark: String
        switch state {
        case .passed: mark = " ✓"
        case .failed: mark = " ✗"
        case .held: mark = " ⏸"
        default: mark = ""
        }
        if !mark.isEmpty {
            var glyph = AttributedString(mark)
            glyph.font = Theme.Ramp.font(.rowTitleStrong)
            glyph.foregroundColor = ink
            title += glyph
        }
        let detailText = [rung.label, rung.model.map { Self.shortModel($0) }].compactMap { $0 }.filter { !$0.isEmpty }
        if !detailText.isEmpty {
            var detail = AttributedString("\n" + detailText.joined(separator: "\n"))
            detail.font = Theme.Ramp.font(.rowMeta)
            detail.foregroundColor = ink.withAlphaComponent(0.8)
            title += detail
        }
        return title
    }

    private static func shortModel(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }
}

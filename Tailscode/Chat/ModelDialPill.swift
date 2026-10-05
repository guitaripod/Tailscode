import TailscodeCore
import UIKit

/// The composer's one pill for model and effort: which machine answers and how hard it is asked
/// to think, in one capsule with two halves.
///
/// The model half is a button that opens the quick menu, and swiping along it steps through the
/// pinned pairs without opening anything. The effort half is the control for the level: pressed
/// and slid it lifts the ladder out as a rail (`EffortRailPresenter`), tapped it leaves the rail
/// open to be tapped, and to a screen reader it is an adjustable element that steps one level at
/// a time. Hue is who answers and heat is how hard, so colour sits on the dot and on the bars and
/// the words stay in ink.
@MainActor
final class ModelDialPill: UIView, UIGestureRecognizerDelegate {
    struct Content: Equatable {
        var modelWord: String
        var chip: ModelChip?
        var effort: String?
        var options: [String]
        var choosesModel: Bool
    }

    var content = Content(modelWord: "", chip: nil, effort: nil, options: [], choosesModel: true) {
        didSet {
            guard content != oldValue else { return }
            render()
        }
    }

    /// The model menu, rebuilt by the host whenever what it lists could have changed.
    var modelMenu: UIMenu? {
        get { modelButton.menu }
        set { modelButton.menu = newValue }
    }

    var onCycle: ((Int) -> Void)?
    var onEffort: ((String?) -> Void)?
    var footer: ((EffortRung) -> String?)?

    /// The screen the rail opens over, and the view it must stay beneath so the thing being aimed
    /// is never covered.
    var railHost: UIView? {
        didSet { presenter = nil }
    }
    weak var railBelow: UIView? {
        didSet { presenter = nil }
    }

    var isEnabled = true {
        didSet {
            modelButton.isEnabled = isEnabled
            effortZone.alpha = isEnabled ? 1 : 0.5
        }
    }

    private let modelButton = UIButton(type: .system)
    private let divider = UIView()
    private let effortZone = EffortZoneView()
    private let effortLabel = UILabel()
    private let meter = EffortMeterView()
    private let row = UIStackView()
    private var slotWidth: NSLayoutConstraint!
    private var presenter: EffortRailPresenter?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        backgroundColor = UIColor.label.withAlphaComponent(0.06)
        layer.cornerRadius = 17
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.label.withAlphaComponent(0.1).cgColor
        clipsToBounds = true

        var config = UIButton.Configuration.plain()
        config.imagePadding = 7
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 11)
        config.baseForegroundColor = Theme.Color.label
        modelButton.configuration = config
        modelButton.showsMenuAsPrimaryAction = true
        modelButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modelButton.titleLabel?.lineBreakMode = .byTruncatingTail
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            modelButton.addGestureRecognizer(swipe)
        }

        divider.backgroundColor = UIColor.label.withAlphaComponent(0.1)
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true

        effortLabel.font = Theme.Ramp.font(.rowTitle)
        effortLabel.textColor = Theme.Color.label
        effortLabel.adjustsFontForContentSizeCategory = true
        effortLabel.textAlignment = .left
        effortLabel.isAccessibilityElement = false
        slotWidth = effortLabel.widthAnchor.constraint(equalToConstant: 0)
        slotWidth.isActive = true

        let effort = UIStackView(arrangedSubviews: [effortLabel, meter])
        effort.axis = .horizontal
        effort.alignment = .center
        effort.spacing = 7
        effort.isUserInteractionEnabled = false
        effort.translatesAutoresizingMaskIntoConstraints = false
        effortZone.addSubview(effort)
        NSLayoutConstraint.activate([
            effort.leadingAnchor.constraint(equalTo: effortZone.leadingAnchor, constant: 11),
            effort.trailingAnchor.constraint(equalTo: effortZone.trailingAnchor, constant: -12),
            effort.topAnchor.constraint(equalTo: effortZone.topAnchor),
            effort.bottomAnchor.constraint(equalTo: effortZone.bottomAnchor),
        ])
        effortZone.isAccessibilityElement = true
        effortZone.accessibilityTraits = .adjustable
        effortZone.accessibilityLabel = String(localized: "Effort")
        effortZone.onIncrement = { [weak self] in self?.step(by: 1) }
        effortZone.onDecrement = { [weak self] in self?.step(by: -1) }

        let tap = UITapGestureRecognizer(target: self, action: #selector(effortTapped))
        let press = UILongPressGestureRecognizer(target: self, action: #selector(effortPressed(_:)))
        press.minimumPressDuration = 0.16
        press.allowableMovement = 10_000
        press.delegate = self
        tap.require(toFail: press)
        effortZone.addGestureRecognizer(tap)
        effortZone.addGestureRecognizer(press)

        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        [modelButton, divider, effortZone].forEach(row.addArrangedSubview)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 34),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: ModelDialPill, _) in
            view.backgroundColor = UIColor.label.withAlphaComponent(0.06)
            view.layer.borderColor = UIColor.label.withAlphaComponent(0.1).cgColor
            view.render()
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (view: ModelDialPill, _) in view.render()
        }
        render()
    }

    private func render() {
        let face = ModelDial.face(
            modelWord: content.modelWord, effort: content.effort, options: content.options)

        var config = modelButton.configuration ?? .plain()
        config.image = content.chip.map { EffortMeterView.dotImage(Theme.Color.modelIdentity($0)) }
            ?? UIImage(
                systemName: "circle",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .semibold))?
            .withTintColor(Theme.Color.tertiaryLabel, renderingMode: .alwaysOriginal)
        var title = AttributedString(content.modelWord)
        title.font = Theme.Ramp.font(.rowTitleStrong)
        config.attributedTitle = title
        modelButton.configuration = config
        modelButton.isUserInteractionEnabled = content.choosesModel
        modelButton.accessibilityLabel = String(localized: "Model: \(content.modelWord)")
        modelButton.accessibilityHint =
            content.choosesModel ? String(localized: "Opens the model menu") : nil

        effortZone.isHidden = !face.showsMeter
        divider.isHidden = !face.showsMeter
        guard face.showsMeter else { return }
        effortLabel.attributedText = Self.effortWord(
            face.effortWord ?? "", isPower: face.isPower, font: effortLabel.font)
        let widest = face.slotWords.map {
            ($0 as NSString).size(withAttributes: [.font: effortLabel.font as Any]).width
        }.max() ?? 0
        slotWidth.constant = ceil(widest)
        meter.reading = .init(face: face, level: ModelEffort.surviving(content.effort, options: content.options))
        effortZone.accessibilityValue = face.isServer ? String(localized: "server decides") : face.effortWord
        effortZone.accessibilityHint = String(localized: "Press and slide to change, or swipe up or down")
    }

    private static func effortWord(_ word: String, isPower: Bool, font: UIFont) -> NSAttributedString {
        guard isPower else {
            return NSAttributedString(
                string: word, attributes: [.font: font, .foregroundColor: Theme.Color.label])
        }
        let text = NSMutableAttributedString()
        for (index, letter) in word.enumerated() {
            text.append(
                NSAttributedString(
                    string: String(letter),
                    attributes: [
                        .font: font,
                        .foregroundColor: Theme.Color.modelRainbowLetter(index, of: word.count),
                    ]))
        }
        return text
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UILongPressGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        return isEnabled && ModelEffort.isOffered(options: content.options)
    }

    private func railPresenter() -> EffortRailPresenter? {
        if let presenter { return presenter }
        guard let railHost else { return nil }
        let made = EffortRailPresenter(host: railHost, below: railBelow)
        made.footer = { [weak self] rung in self?.footer?(rung) }
        made.onSet = { [weak self] level in self?.onEffort?(level) }
        presenter = made
        return made
    }

    /// Opens the rail to be tapped, from a key command, a slash command or a tap on the meter.
    func openRail() {
        guard isEnabled, ModelEffort.isOffered(options: content.options),
            let presenter = railPresenter()
        else { return }
        if presenter.isPresented { return presenter.dismiss(committing: false) }
        presenter.present(
            anchor: effortZone, rungs: ModelDial.rungs(options: content.options),
            current: ModelEffort.surviving(content.effort, options: content.options), finger: nil)
    }

    @objc private func effortTapped() { openRail() }

    @objc private func effortPressed(_ gesture: UILongPressGestureRecognizer) {
        guard let presenter = railPresenter(), let host = railHost else { return }
        let point = gesture.location(in: host)
        switch gesture.state {
        case .began:
            guard !presenter.isPresented else { return }
            presenter.present(
                anchor: effortZone, rungs: ModelDial.rungs(options: content.options),
                current: ModelEffort.surviving(content.effort, options: content.options),
                finger: point)
        case .changed:
            presenter.move(to: point)
        case .ended:
            presenter.end()
        case .cancelled, .failed:
            presenter.dismiss(committing: false)
        default:
            break
        }
    }

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        guard isEnabled else { return }
        let delta = gesture.direction == .left ? 1 : -1
        Theme.Haptics.selection()
        onCycle?(delta)
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let nudge: CGFloat = delta > 0 ? -10 : 10
        modelButton.transform = CGAffineTransform(translationX: nudge, y: 0)
        UIView.animate(
            withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5
        ) { self.modelButton.transform = .identity }
    }

    /// One level hotter or colder, for a screen reader's increment and decrement.
    private func step(by delta: Int) {
        guard isEnabled, ModelEffort.isOffered(options: content.options) else { return }
        let level = ModelEffort.surviving(content.effort, options: content.options)
        let next = ModelDial.step(level, by: delta, options: content.options)
        guard next != level else { return }
        onEffort?(next)
    }
}

/// The effort half of the pill, which has to say that it can be adjusted.
@MainActor
private final class EffortZoneView: UIView {
    var onIncrement: (() -> Void)?
    var onDecrement: (() -> Void)?

    override func accessibilityIncrement() { onIncrement?() }
    override func accessibilityDecrement() { onDecrement?() }
}

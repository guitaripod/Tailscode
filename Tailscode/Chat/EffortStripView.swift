import TailscodeCore
import UIKit

/// The effort ladder laid flat across the top of the catalog, so the sheet that chooses a model
/// can also say how hard it will work. It is the pill's own ladder, not a second one: the same
/// rungs as the rail in the same cold-to-hot order with the server's choice as the first stop, the
/// same five bars under the same words, and under the row the same sentence for what the held
/// level means.
///
/// It acts on the model the chat already runs and is live — a level is something a person nudges
/// while looking at the list, not something submitted with a row. A level is tapped or slid to, a
/// tick for every rung crossed.
@MainActor
final class EffortStripView: UIView {
    var onSet: ((String?) -> Void)?

    private let card = UIView()
    private let dot = UIImageView()
    private let heading = UILabel()
    private let context = UILabel()
    private let segments = UIStackView()
    private let caption = UILabel()
    private var rungs: [EffortRung] = []
    private var buttons: [UIControl] = []
    private var effort: String?
    private var options: [String] = []
    private var modelName = ""
    private var chip: ModelChip?
    private var contextWord = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        card.backgroundColor = UIColor.label.withAlphaComponent(0.05)
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.label.withAlphaComponent(0.07).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        heading.font = Theme.Ramp.font(.rowTitleStrong)
        heading.textColor = Theme.Color.label
        heading.adjustsFontForContentSizeCategory = true
        heading.numberOfLines = 0
        context.font = Theme.Ramp.font(.rowMeta)
        context.textColor = Theme.Color.tertiaryLabel
        context.adjustsFontForContentSizeCategory = true
        context.setContentHuggingPriority(.required, for: .horizontal)
        dot.setContentHuggingPriority(.required, for: .horizontal)

        let top = UIStackView(arrangedSubviews: [dot, heading, UIView(), context])
        top.axis = .horizontal
        top.alignment = .center
        top.spacing = 7

        segments.axis = .horizontal
        segments.spacing = 4
        segments.distribution = .fillEqually
        segments.addGestureRecognizer(
            UIPanGestureRecognizer(target: self, action: #selector(slid(_:))))

        caption.font = Theme.Ramp.font(.rowMeta)
        caption.textColor = Theme.Color.secondaryLabel
        caption.adjustsFontForContentSizeCategory = true
        caption.numberOfLines = 0

        let column = UIStackView(arrangedSubviews: [top, segments, caption])
        column.axis = .vertical
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.xs),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.xs),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
        ])

        isAccessibilityElement = false
        card.isAccessibilityElement = true
        card.accessibilityTraits = .adjustable
        card.accessibilityLabel = String(localized: "Effort")
        registerForTraitChanges([
            UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self,
            UITraitPreferredContentSizeCategory.self,
        ]) {
            (view: EffortStripView, _) in
            view.card.backgroundColor = UIColor.label.withAlphaComponent(0.05)
            view.card.layer.borderColor = UIColor.label.withAlphaComponent(0.07).cgColor
            view.render()
        }
    }

    func render(
        modelName: String, chip: ModelChip?, context: String, options: [String], effort: String?
    ) {
        self.modelName = modelName
        self.chip = chip
        self.contextWord = context
        self.options = options
        self.effort = ModelEffort.surviving(effort, options: options)
        render()
    }

    private func render() {
        isHidden = !ModelEffort.isOffered(options: options)
        guard !isHidden else { return }
        rungs = Array(ModelDial.rungs(options: options).reversed())
        dot.image = chip.map { EffortMeterView.dotImage(Theme.Color.modelIdentity($0)) }
            ?? UIImage(
                systemName: "circle",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .semibold))?
            .withTintColor(Theme.Color.tertiaryLabel, renderingMode: .alwaysOriginal)
        heading.text = modelName
        context.text = contextWord

        segments.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = []
        for rung in rungs {
            let selected = rung.level == effort
            let button = UIControl()
            button.layer.cornerRadius = 12
            button.layer.cornerCurve = .continuous
            button.backgroundColor = UIColor.label.withAlphaComponent(selected ? 0.12 : 0.04)
            let meter = EffortMeterView(reading: EffortMeterView.Reading(rung: rung))
            meter.translatesAutoresizingMaskIntoConstraints = false
            let label = UILabel()
            label.attributedText = Self.word(rung, selected: selected)
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.7
            label.textAlignment = .center
            let stack = UIStackView(arrangedSubviews: [meter, label])
            stack.axis = .vertical
            stack.alignment = .center
            stack.spacing = 5
            stack.isUserInteractionEnabled = false
            stack.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                stack.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 2),
                stack.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
                button.heightAnchor.constraint(equalToConstant: 50),
            ])
            button.isAccessibilityElement = false
            let level = rung.level
            button.addAction(UIAction { [weak self] _ in self?.choose(level) }, for: .touchUpInside)
            segments.addArrangedSubview(button)
            buttons.append(button)
        }
        let held = rungs.first { $0.level == effort }
        caption.text = held?.caption
        card.accessibilityValue = held?.title
        card.accessibilityHint = String(localized: "Swipe up or down to change")
    }

    private func choose(_ level: String?) {
        guard level != effort else { return }
        Theme.Haptics.notch()
        effort = level
        render()
        onSet?(level)
    }

    @objc private func slid(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed, !buttons.isEmpty else { return }
        let x = gesture.location(in: segments).x
        guard let index = buttons.firstIndex(where: { $0.frame.minX - 2 <= x && x <= $0.frame.maxX + 2 })
        else { return }
        choose(rungs[index].level)
    }

    override func accessibilityIncrement() { step(by: 1) }
    override func accessibilityDecrement() { step(by: -1) }

    /// One level hotter or colder for a screen reader, along the same ladder a finger slides.
    private func step(by delta: Int) {
        let next = ModelDial.step(effort, by: delta, options: options)
        guard next != effort else { return }
        choose(next)
    }

    private static func word(_ rung: EffortRung, selected: Bool) -> NSAttributedString {
        let font = selected ? Theme.Ramp.font(.rowTitleStrong) : Theme.Ramp.font(.rowMeta)
        let ink = selected ? Theme.Color.label : Theme.Color.secondaryLabel
        guard rung.isPower else {
            let text = rung.level == nil ? String(localized: "server") : rung.title
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink])
        }
        let text = NSMutableAttributedString()
        let word = String(Ultracode.menuTitle.lowercased().prefix(5))
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
}

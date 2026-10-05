import TailscodeCore
import UIKit

/// The effort ladder laid flat across the top of the catalog, so the sheet that chooses a model
/// can also say how hard it will work: one segment per level the current model takes, coldest at
/// the left, the server's own choice as a chip beside the heading.
///
/// It acts on the model the chat already runs and is live — a level is something a person nudges
/// while looking at the list, not something submitted with a row.
@MainActor
final class EffortStripView: UIView {
    var onSet: ((String?) -> Void)?

    private let card = UIView()
    private let heading = UILabel()
    private let serverChip = UIButton(type: .system)
    private let segments = UIStackView()
    private var options: [String] = []
    private var effort: String?
    private var modelName = ""

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

        heading.font = Theme.Ramp.font(.rowDetail)
        heading.textColor = Theme.Color.secondaryLabel
        heading.adjustsFontForContentSizeCategory = true

        var chip = UIButton.Configuration.plain()
        chip.imagePadding = 5
        chip.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)
        chip.baseForegroundColor = Theme.Color.secondaryLabel
        serverChip.configuration = chip
        serverChip.addAction(UIAction { [weak self] _ in self?.choose(nil) }, for: .touchUpInside)

        let top = UIStackView(arrangedSubviews: [heading, UIView(), serverChip])
        top.axis = .horizontal
        top.alignment = .center

        segments.axis = .horizontal
        segments.spacing = 4
        segments.distribution = .fillEqually

        let column = UIStackView(arrangedSubviews: [top, segments])
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
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: EffortStripView, _) in
            view.card.backgroundColor = UIColor.label.withAlphaComponent(0.05)
            view.card.layer.borderColor = UIColor.label.withAlphaComponent(0.07).cgColor
            view.render()
        }
    }

    func render(modelName: String, options: [String], effort: String?) {
        self.modelName = modelName
        self.options = ModelDial.ascending(options: options)
        self.effort = ModelEffort.surviving(effort, options: options)
        render()
    }

    private func render() {
        isHidden = options.isEmpty
        heading.text = String(localized: "Effort for \(modelName), this chat")

        var chip = serverChip.configuration ?? .plain()
        let server = effort == nil
        chip.image = UIImage(
            systemName: server ? "circle.fill" : "circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 7, weight: .semibold))
        var title = AttributedString(String(localized: "server decides"))
        title.font = Theme.Ramp.font(.rowMeta)
        chip.attributedTitle = title
        chip.baseForegroundColor = server ? Theme.Color.label : Theme.Color.secondaryLabel
        serverChip.configuration = chip
        serverChip.accessibilityTraits = server ? [.button, .selected] : .button

        segments.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for level in options {
            let reading = EffortMeterView.Reading(level: level, options: options)
            let selected = level == effort
            let button = UIButton(type: .custom)
            button.layer.cornerRadius = 12
            button.layer.cornerCurve = .continuous
            button.layer.borderWidth = selected ? 1.5 : 0
            button.layer.borderColor = (Theme.Color.modelEffort(level) ?? Theme.Color.label).cgColor
            button.backgroundColor = UIColor.label.withAlphaComponent(selected ? 0.1 : 0.04)
            let meter = EffortMeterView(reading: reading)
            meter.translatesAutoresizingMaskIntoConstraints = false
            let label = UILabel()
            label.attributedText = Self.word(level, selected: selected)
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
            button.accessibilityLabel = ModelDial.isPower(level) ? Ultracode.menuTitle : level
            button.accessibilityHint = ModelDial.caption(level)
            button.accessibilityTraits = selected ? [.button, .selected] : .button
            button.addAction(UIAction { [weak self] _ in self?.choose(level) }, for: .touchUpInside)
            segments.addArrangedSubview(button)
        }
    }

    private func choose(_ level: String?) {
        guard level != effort else { return }
        Theme.Haptics.notch()
        effort = level
        render()
        onSet?(level)
    }

    private static func word(_ level: String, selected: Bool) -> NSAttributedString {
        let font = Theme.Ramp.font(.rowMeta)
        let ink = selected ? Theme.Color.label : Theme.Color.secondaryLabel
        guard ModelDial.isPower(level) else {
            return NSAttributedString(string: level, attributes: [.font: font, .foregroundColor: ink])
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

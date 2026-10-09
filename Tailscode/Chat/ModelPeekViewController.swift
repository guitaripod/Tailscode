import TailscodeCore
import UIKit

/// The card a long press on a catalog row lifts: what the row had no room to say. It is drawn
/// from Core's `ModelPeekReading`, so what it claims is only what the catalog and the transcript
/// can show.
@MainActor
final class ModelPeekViewController: UIViewController {
    private let reading: ModelPeekReading
    private let hue: UIColor

    init(reading: ModelPeekReading, hue: UIColor) {
        self.reading = reading
        self.hue = hue
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedSurface

        let dot = UIImageView(image: EffortMeterView.dotImage(hue))
        let title = UILabel()
        title.text = reading.name
        title.font = Theme.Ramp.font(.headline)
        title.numberOfLines = 0
        let head = UIStackView(arrangedSubviews: [dot, title])
        head.spacing = 9
        head.alignment = .center

        var rows: [UIView] = [head]
        if !reading.detail.isEmpty { rows.append(Self.note(reading.detail, color: Theme.Color.secondaryLabel)) }
        rows.append(facts())
        if !reading.abilities.isEmpty {
            rows.append(Self.note(reading.abilities.joined(separator: " · "), color: Theme.Color.secondaryLabel))
        }
        if !reading.levels.isEmpty { rows.append(levels()) }
        if let wall = reading.wall { rows.append(Self.note(wall, color: Theme.Color.danger)) }
        if let carry = reading.carry { rows.append(Self.note(carry, color: Theme.Color.secondaryLabel)) }
        if let cost = reading.switchCost { rows.append(switchCost(cost)) }

        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
        let width: CGFloat = 320
        let fitted = stack.systemLayoutSizeFitting(
            CGSize(width: width - 32, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        preferredContentSize = CGSize(width: width, height: fitted.height + 32)
    }

    private static func note(_ text: String, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = Theme.Ramp.font(.panelFootnote)
        label.textColor = color
        return label
    }

    private func facts() -> UIView {
        let row = UIStackView(
            arrangedSubviews: reading.facts.prefix(3).map { fact in
                let value = UILabel()
                value.text = fact.value
                value.font = Theme.Ramp.font(.rowTitleStrong).monospacedDigits()
                let label = Self.note(fact.label, color: Theme.Color.tertiaryLabel)
                let cell = UIStackView(arrangedSubviews: [value, label])
                cell.axis = .vertical
                cell.spacing = 1
                cell.isLayoutMarginsRelativeArrangement = true
                cell.layoutMargins = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
                cell.backgroundColor = UIColor.label.withAlphaComponent(0.06)
                cell.layer.cornerRadius = 12
                cell.layer.cornerCurve = .continuous
                return cell
            })
        row.distribution = .fillEqually
        row.spacing = 8
        return row
    }

    private func levels() -> UIView {
        let row = UIStackView(
            arrangedSubviews: reading.levels.map { level in
                EffortMeterView(reading: .init(level: level, options: reading.levels))
            })
        row.spacing = 8
        row.alignment = .bottom
        let words = Self.note(
            reading.levels.map { ModelDial.isPower($0) ? Ultracode.menuTitle.lowercased() : $0 }
                .joined(separator: " · "), color: Theme.Color.secondaryLabel)
        let column = UIStackView(arrangedSubviews: [row, words])
        column.axis = .vertical
        column.spacing = 6
        column.alignment = .leading
        return column
    }

    private func switchCost(_ text: String) -> UIView {
        let icon = UIImageView(
            image: UIImage(
                systemName: "exclamationmark.triangle",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
        icon.tintColor = Theme.Color.warning
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = Self.note(text, color: Theme.Color.label)
        let box = UIStackView(arrangedSubviews: [icon, label])
        box.spacing = 10
        box.alignment = .top
        box.isLayoutMarginsRelativeArrangement = true
        box.layoutMargins = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        box.backgroundColor = Theme.Color.warning.withAlphaComponent(0.12)
        box.layer.cornerRadius = 14
        box.layer.cornerCurve = .continuous
        return box
    }
}

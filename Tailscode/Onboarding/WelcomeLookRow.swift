import TailscodeCore
import UIKit

/// The one line the welcome says about how the app looks: the look a newcomer starts in beside
/// the system's own, a press apart. Everything else about themes is in Settings.
final class WelcomeLookRow: UIView {
    private let title = UILabel()
    private let control = UISegmentedControl()
    private let caption = UILabel()
    private var look = ThemeSelection.welcomeLook

    init() {
        super.init(frame: .zero)
        title.font = Theme.Ramp.font(.panelFootnote)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = Theme.Color.secondaryLabel
        title.setContentHuggingPriority(.required, for: .horizontal)
        caption.font = Theme.Ramp.font(.panelFootnote)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = Theme.Color.tertiaryLabel
        caption.textAlignment = .center
        caption.numberOfLines = 0
        control.addAction(UIAction { [weak self] _ in self?.chosen() }, for: .valueChanged)
        control.accessibilityIdentifier = "welcome.look"
        let line = UIStackView(arrangedSubviews: [title, control])
        line.axis = .horizontal
        line.alignment = .center
        line.spacing = Theme.Spacing.m
        let column = UIStackView(arrangedSubviews: [line, caption])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = Theme.Spacing.xs
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        restate()
        NotificationCenter.default.addObserver(
            self, selector: #selector(restate), name: ThemeSelection.didChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func restate() {
        look = ThemeSelection.welcomeLook
        title.text = look.title
        caption.text = look.caption
        control.removeAllSegments()
        for (index, choice) in look.choices.enumerated() {
            control.insertSegment(withTitle: choice.title, at: index, animated: false)
        }
        control.selectedSegmentIndex = look.choices.firstIndex(where: \.isChosen) ?? UISegmentedControl.noSegment
    }

    private func chosen() {
        let index = control.selectedSegmentIndex
        guard look.choices.indices.contains(index), !look.choices[index].isChosen else { return }
        ThemeSelection.setThemeID(look.choices[index].id)
        Theme.Chrome.apply()
        Theme.Haptics.selection()
    }
}

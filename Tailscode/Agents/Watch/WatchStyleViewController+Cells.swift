import TailscodeCore
import UIKit

/// A row of the Style sheet: a title, an optional line under it and one control at the trailing
/// edge. A subclass makes its control once and a configure only sets what it shows, so a style
/// change that arrives while a finger is on a control never replaces the control it is holding.
@MainActor
class WatchStyleCell: SurfaceListCell {
    /// - Parameter isSoleElement: whether VoiceOver reads the control alone, as one element that
    ///   carries the title; a segmented control is several elements, so its row keeps its own words.
    func install(_ control: UIView, isSoleElement: Bool = true, width: CGFloat? = nil) {
        var configuration = UICellAccessory.CustomViewConfiguration(
            customView: control, placement: .trailing())
        if let width {
            control.frame = CGRect(x: 0, y: 0, width: width, height: 32)
            configuration.reservedLayoutWidth = .custom(width)
            configuration.maintainsFixedSize = true
        }
        accessories = [.customView(configuration: configuration)]
        if isSoleElement { accessibilityElements = [control] }
    }

    func show(row: WatchStyleRow, style: WallStyle, control: UIView) {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = row.title
        content.textProperties.color = Theme.Color.label
        content.secondaryText = row.detail(for: style)
        content.secondaryTextProperties.color = Theme.Color.secondaryLabel
        content.secondaryTextProperties.font = Theme.Ramp.font(.panelFootnote)
        content.textToSecondaryTextVerticalPadding = Theme.Spacing.xs / 2
        contentConfiguration = content
        control.accessibilityLabel = row.title
        control.accessibilityValue = row.value(for: style)
        control.accessibilityHint = row.caption
        control.accessibilityIdentifier = row.identifier
    }
}

@MainActor
final class WatchStyleSegmentedCell: WatchStyleCell {
    private let segments = UISegmentedControl()
    private var titles: [String] = []
    private var onSelect: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        segments.apportionsSegmentWidthsByContent = true
        segments.setTitleTextAttributes([.font: Theme.Ramp.font(.panelFootnote)], for: .normal)
        segments.addAction(
            UIAction { [weak self] _ in
                guard let self, self.segments.selectedSegmentIndex != UISegmentedControl.noSegment
                else { return }
                self.onSelect?(self.segments.selectedSegmentIndex)
            }, for: .valueChanged)
        install(segments, isSoleElement: false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The room a segmented control needs for these titles: each as wide as its words and a margin.
    private static func width(of titles: [String]) -> CGFloat {
        let font = Theme.Ramp.font(.panelFootnote)
        return titles.reduce(8) { total, title in
            total + ceil((title as NSString).size(withAttributes: [.font: font]).width) + 28
        }
    }

    func update(row: WatchStyleRow, style: WallStyle, onSelect: @escaping (Int) -> Void) {
        self.onSelect = onSelect
        show(row: row, style: style, control: segments)
        let choices = row.choices(for: style)
        let fresh = choices.map(\.title)
        if fresh != titles {
            segments.removeAllSegments()
            for (index, title) in fresh.enumerated() {
                segments.insertSegment(withTitle: title, at: index, animated: false)
            }
            titles = fresh
            install(segments, isSoleElement: false, width: Self.width(of: fresh))
        }
        guard !segments.isTracking else { return }
        let selected = choices.firstIndex { $0.isSelected } ?? UISegmentedControl.noSegment
        if segments.selectedSegmentIndex != selected { segments.selectedSegmentIndex = selected }
    }
}

@MainActor
final class WatchStyleMenuCell: WatchStyleCell {
    private let button = UIButton(configuration: .plain())
    private var onSelect: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = true
        install(button)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func update(row: WatchStyleRow, style: WallStyle, onSelect: @escaping (Int) -> Void) {
        self.onSelect = onSelect
        show(row: row, style: style, control: button)
        let choices = row.choices(for: style)
        let actions = choices.enumerated().map { index, choice in
            UIAction(title: choice.title, state: choice.isSelected ? .on : .off) {
                [weak self] _ in
                self?.onSelect?(index)
            }
        }
        button.menu = UIMenu(options: .singleSelection, children: actions)
        button.configuration?.title = row.value(for: style)
    }
}

@MainActor
final class WatchStyleToggleCell: WatchStyleCell {
    private let toggle = UISwitch()
    private var onChange: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        toggle.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.onChange?(self.toggle.isOn)
            }, for: .valueChanged)
        install(toggle)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func update(row: WatchStyleRow, style: WallStyle, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        show(row: row, style: style, control: toggle)
        let isOn = row.isOn(in: style)
        guard toggle.isOn != isOn, !toggle.isTracking else { return }
        toggle.setOn(isOn, animated: window != nil)
    }
}

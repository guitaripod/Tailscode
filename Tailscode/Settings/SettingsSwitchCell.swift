import UIKit

/// A settings row that ends in a switch, and keeps the one switch it was built with.
///
/// A `UISwitch` costs a visual element lookup and a layer tree to make, so building one each time a
/// row is configured put that cost on every row a scroll brought into view. The cell makes it once
/// and a configure only sets what it shows.
@MainActor
final class SettingsSwitchCell: SurfaceListCell {
    private let toggleView = UISwitch()
    private var onChange: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        toggleView.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.onChange?(self.toggleView.isOn)
            }, for: .valueChanged)
        accessories = [.customView(configuration: .init(customView: toggleView, placement: .trailing()))]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        toggleView.isOn = isOn
        toggleView.accessibilityLabel = title
        self.onChange = onChange
    }
}

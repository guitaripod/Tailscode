import TailscodeCore
import UIKit

/// The key legend: the table of keys the step list answers, which a hardware keyboard learns from.
@MainActor
final class BrainLegendViewController: UIViewController, UIPopoverPresentationControllerDelegate {
    var onDismiss: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.secondaryBackground
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for entry in NeuralBrowse.legend {
            let keys = UILabel()
            keys.attributedText = NSAttributedString(
                string: entry.keys, attributes: Theme.Ramp.attributes(.toolDetail, color: Theme.Color.label))
            keys.setContentHuggingPriority(.required, for: .horizontal)
            keys.widthAnchor.constraint(equalToConstant: 118).isActive = true
            let does = UILabel()
            does.numberOfLines = 0
            does.attributedText = NSAttributedString(
                string: entry.does, attributes: Self.wrapping(Theme.Ramp.attributes(.rowDetail, color: Theme.Color.secondaryLabel)))
            let row = UIStackView(arrangedSubviews: [keys, does])
            row.spacing = 12
            row.alignment = .firstBaseline
            stack.addArrangedSubview(row)
        }
        view.addSubview(stack)
        self.stack = stack
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
        preferredContentSize = CGSize(width: 560, height: 460)
        view.accessibilityLabel = Localized.text("Keys")
    }

    private weak var stack: UIStackView?

    /// The popover is as tall as the legend is at the width it was given, so no row is squeezed.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let stack, view.bounds.width > 0 else { return }
        let fitted = stack.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width - 32, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height + 32
        if abs(preferredContentSize.height - fitted) > 1 {
            preferredContentSize = CGSize(width: preferredContentSize.width, height: fitted)
        }
    }

    /// The ramp's attributes with word wrapping, since a legend row is a sentence and may take lines.
    private static func wrapping(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var result = attributes
        let style =
            (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        result[.paragraphStyle] = style
        return result
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        .none
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onDismiss?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDismiss?()
    }
}

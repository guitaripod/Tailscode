import UIKit

extension UIGraphicsImageRendererFormat {
    /// A format that renders at the scale of the display the traits describe. Traits that have not
    /// reached a window yet carry no scale, and then the device's preferred format answers.
    static func matching(_ traits: UITraitCollection) -> UIGraphicsImageRendererFormat {
        traits.displayScale > 0 ? UIGraphicsImageRendererFormat(for: traits) : .preferred()
    }
}

/// A rule one device pixel thick on whichever display it is shown, redrawn when the display
/// changes under it.
final class HairlineView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitDisplayScale.self]) { (self: Self, _) in
            self.invalidateIntrinsicContentSize()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 1 / max(traitCollection.displayScale, 1))
    }
}

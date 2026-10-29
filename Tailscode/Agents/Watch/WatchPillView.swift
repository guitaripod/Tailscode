import TailscodeCore
import UIKit

/// A button drawn on a tile: a rounded pill with one line of words. It takes no touch of its own,
/// because the wall reads every press from one recogniser and knows which pill a finger is on.
final class WatchPillView: UIView {
    enum Style { case hold, quiet }

    let label = WatchLabel()
    private var inkColor = UIColor.white
    private var style = Style.quiet

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.borderWidth = 1.5
        layer.cornerCurve = .continuous
        addSubview(label)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ words: String, size: CGFloat, ink: WallInk, style next: Style, alpha: CGFloat = 1) {
        style = next
        inkColor = ink.color()
        label.set(words, font: WatchFont.text(size, .semibold), ink: next == .hold ? ink.lifted(0.35).color() : ink.color(), lines: 1, alignment: .center)
        backgroundColor = ink.color(next == .hold ? 0.2 : 0.07)
        layer.borderColor = ink.color(next == .hold ? 0.85 : 0.5).cgColor
        self.alpha = alpha
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        let spare = (bounds.width - label.widthForOneLine()) / 2
        label.frame = bounds.insetBy(dx: min(10, max(2, spare)), dy: 0)
    }

    func naturalWidth() -> CGFloat { label.widthForOneLine() + 36 }
}

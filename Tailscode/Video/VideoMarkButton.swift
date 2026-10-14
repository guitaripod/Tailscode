import TailscodeCore
import UIKit

/// The way into the video surface, wearing where the render is.
///
/// A clip is minutes of another machine's card and the phone is expected to be put away while it is
/// made, so the one place the app is always looking at — Home's own chrome — says what is being
/// rendered elsewhere, as light round its own edge (`ForgeRingView`): working, waiting, landed or
/// broken, and nothing at all once the person has looked at how it ended.
@MainActor
final class VideoMarkButton: UIButton {
    private let ring = ForgeRingView()

    private static let side: CGFloat = 34

    init() {
        super.init(frame: .zero)
        setImage(
            UIImage(
                systemName: ForgeEntryPoint.symbol,
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)), for: .normal)
        accessibilityLabel = ForgeEntryPoint.accessibilityLabel(light: .dark)
        isPointerInteractionEnabled = true
        ring.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ring)
        NSLayoutConstraint.activate([
            ring.leadingAnchor.constraint(equalTo: leadingAnchor),
            ring.trailingAnchor.constraint(equalTo: trailingAnchor),
            ring.topAnchor.constraint(equalTo: topAnchor),
            ring.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.side, height: Self.side)
    }

    func apply(light: ForgeLight, configured: Bool) {
        ring.show(light)
        accessibilityLabel = ForgeEntryPoint.accessibilityLabel(light: light)
        accessibilityHint = ForgeEntryPoint.tooltip(configured: configured)
        accessibilityValue = nil
    }
}

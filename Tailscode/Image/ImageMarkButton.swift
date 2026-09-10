import TailscodeCore
import UIKit

/// The way into the image studio, wearing whether a picture is being made.
///
/// It sits beside the video mark because it is the same machine doing the other thing it can do —
/// one ComfyUI holds both sets of models — and it is the shared activity badge rather than a dot
/// drawn here, so it breathes on the same clock as every other live thing on screen and stops the
/// moment the render does.
@MainActor
final class ImageMarkButton: UIButton {
    private let mark = ActivityBadgeView(pointSize: 7)

    private static let side: CGFloat = 34

    init() {
        super.init(frame: .zero)
        setImage(
            UIImage(
                systemName: ImageGenEntryPoint.symbol,
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)), for: .normal)
        accessibilityLabel = ImageGenEntryPoint.accessibilityLabel(painting: false)
        mark.isUserInteractionEnabled = false
        mark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mark)
        NSLayoutConstraint.activate([
            mark.trailingAnchor.constraint(equalTo: trailingAnchor),
            mark.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.side, height: Self.side)
    }

    func apply(painting: Bool, door: ImageGenDoor) {
        mark.activity = ImageGenEntryPoint.activity(painting: painting)
        accessibilityLabel = ImageGenEntryPoint.accessibilityLabel(painting: painting)
        accessibilityHint = ImageGenEntryPoint.tooltip(configured: door.isOpen)
        accessibilityValue = door.line
    }
}

import UIKit

/// The stack of chips and strips that floats over the composer. A chip arriving or leaving changes
/// its height, and the transcript's room at the bottom is worked out from where this stack starts
/// — but nothing in the screen's own layout pass hears a hidden view being shown, so the stack
/// says so itself, and the last rows of a chat are never left behind it.
@MainActor
final class AccessoryStack: UIStackView {
    var onHeightChange: (() -> Void)?
    private var lastHeight: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        guard abs(bounds.height - lastHeight) > 0.5 else { return }
        lastHeight = bounds.height
        onHeightChange?()
    }
}

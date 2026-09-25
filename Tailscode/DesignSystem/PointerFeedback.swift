import UIKit

extension UIView {
    /// Answers a resting pointer with the platform's own hover plate, shaped like this view's
    /// corners — low-strength system ink, never a palette colour, because a hover is neither
    /// motion nor affirmation and it lands on glass as often as on the canvas.
    func answersPointer(cornerRadius: CGFloat) {
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: cornerRadius))
    }
}

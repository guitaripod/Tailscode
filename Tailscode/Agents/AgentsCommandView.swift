import UIKit

/// A command or a path set word for word: monospaced, wrapped, selectable, every line there. A
/// short one takes the height it needs; a very long one stops at a sensible height and scrolls
/// inside itself, so nothing is ever cut and a card never grows past the screen.
@MainActor
final class AgentsCommandView: UITextView {
    private static let lineLimit = 8
    private static let characterLimit = 320
    private static let visibleLines: CGFloat = 9

    private var heightLimit: NSLayoutConstraint?

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        dataDetectorTypes = []
        backgroundColor = Theme.Color.codeBackground
        layer.cornerRadius = Theme.Radius.control
        layer.cornerCurve = .continuous
        textContainerInset = UIEdgeInsets(
            top: Theme.Spacing.s + 2, left: Theme.Spacing.m, bottom: Theme.Spacing.s + 2,
            right: Theme.Spacing.m)
        textContainer.lineFragmentPadding = 0
        textColor = Theme.Color.label
        adjustsFontForContentSizeCategory = true
        accessibilityTraits = .staticText
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (view: AgentsCommandView, _) in view.fit()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ words: String) {
        font = Theme.Ramp.font(.code)
        text = words
        accessibilityLabel = words
        fit()
    }

    private func fit() {
        let lines = (text ?? "").split(separator: "\n", omittingEmptySubsequences: false).count
        let long = lines > Self.lineLimit || (text ?? "").count > Self.characterLimit
        isScrollEnabled = long
        heightLimit?.isActive = false
        heightLimit = nil
        guard long else { return }
        let height =
            ceil((font ?? Theme.Ramp.font(.code)).lineHeight * Self.visibleLines)
            + textContainerInset.top + textContainerInset.bottom
        heightLimit = heightAnchor.constraint(equalToConstant: height)
        heightLimit?.isActive = true
    }
}

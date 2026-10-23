import UIKit

/// A label that paints a diff's washes itself, the full width of the line. A background attribute
/// covers only glyph runs, so an attribute-painted wash stops at the last glyph and reads as a
/// rendering bug rather than a ground. Code never wraps in this label, so a source row is a drawn
/// row and the rect is arithmetic — row × lineHeight, edge to edge.
final class DiffWashLabel: UILabel {
    var washes: [(row: Int, color: UIColor)] = [] {
        didSet { setNeedsDisplay() }
    }
    private var settledSize: CGSize?
    private var settledWidth: CGFloat = .nan
    private var isRepainting = false

    /// A frame of the wave: the same glyphs, freshly tinted.
    ///
    /// `attributedText` is a copy on a label, so unlike a text view there is no storage to tint
    /// where it stands and the assignment cannot be avoided. What can be avoided is what the
    /// assignment costs: every one of them invalidates the intrinsic size, and a self-sizing cell
    /// answers that by measuring the whole block again — on the display's clock, up to a hundred
    /// and twenty times a second, for a size that cannot have moved because only the colours did.
    /// So a repaint keeps the measurement and any other assignment drops it: a frame may change
    /// light, never a size the layout depends on.
    func repaint(_ text: NSAttributedString) {
        isRepainting = true
        attributedText = text
        isRepainting = false
    }

    override var attributedText: NSAttributedString? {
        didSet { if !isRepainting { forget() } }
    }

    /// Everything that is not a repaint drops the measurement, and this is the only place that can
    /// know about most of them.
    ///
    /// A memo that outlives its reasons is worse than no memo. A wrapping label is measured twice:
    /// UIKit asks with no preferred width and gets the unwrapped size, then sets the width from the
    /// bounds it was given and invalidates for the real answer — and a memo that swallowed the
    /// second question would leave the label laid out at its one-line-per-newline height, clipping
    /// or spilling out of whatever holds it. A font, a line-break mode, a trait, a text change made
    /// through any road but `attributedText`: all of them arrive here and none of them are colour.
    override func invalidateIntrinsicContentSize() {
        if !isRepainting { forget() }
        super.invalidateIntrinsicContentSize()
    }

    /// The width the answer was measured against, so a memo can only ever be handed back to the
    /// question it answered. `preferredMaxLayoutWidth` is what a wrapping label wraps at once
    /// layout has told it; before that there is only the bounds.
    private var measuredWidth: CGFloat {
        preferredMaxLayoutWidth > 0 ? preferredMaxLayoutWidth : bounds.width
    }

    private func forget() {
        settledSize = nil
        settledWidth = .nan
    }

    override var intrinsicContentSize: CGSize {
        let width = measuredWidth
        if let settledSize, settledWidth == width { return settledSize }
        let size = super.intrinsicContentSize
        settledSize = size
        settledWidth = width
        return size
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (label: DiffWashLabel, _) in label.setNeedsDisplay()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        if !washes.isEmpty, let font {
            let height = font.lineHeight
            for wash in washes {
                wash.color.setFill()
                UIRectFill(CGRect(
                    x: 0, y: CGFloat(wash.row) * height, width: bounds.width, height: height))
            }
        }
        super.draw(rect)
    }
}

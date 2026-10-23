import UIKit

/// A text view whose height is whatever its owner measured.
///
/// Auto Layout asks a text view for its intrinsic size by setting its container to the width in
/// question, laying every word out, and setting the container back, which throws away the layout
/// it just made. A paragraph being written is measured on every arrival, and that is the whole
/// answer laid out twice for each word. An owner that has measured the text itself, at the width the
/// view will have, hands the answer over here and the question is never asked.
final class MeasuredTextView: UITextView {
    convenience init() {
        let storage = NSTextStorage()
        let manager = ColourLayoutManager()
        storage.addLayoutManager(manager)
        let container = EndlessTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }

    /// Runs `edit`, a rewrite of the storage's colours and nothing else, without the layout manager
    /// laying the words out again for it.
    func paintingColours(_ edit: () -> Void) {
        guard let manager = layoutManager as? ColourLayoutManager else {
            edit()
            return
        }
        manager.paintingColours(edit)
    }

    var measuredHeight: CGFloat? {
        didSet {
            if oldValue != measuredHeight { invalidateIntrinsicContentSize() }
        }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        guard let measuredHeight else { return super.intrinsicContentSize }
        return CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight)
    }
}

/// A layout manager that is told when an edit to its text is a change of colours, which move no
/// glyph. Any edit of the text storage, even one that only recolours, invalidates the layout of the
/// range and the manager lays the paragraph out again before the next draw; a wave that recolours
/// the last words of an answer every frame was therefore laying the whole paragraph out every
/// frame. An edit made inside `paintingColours` redraws the words it touched and nothing else.
final class ColourLayoutManager: NSLayoutManager {
    private var recolouring = false

    func paintingColours(_ edit: () -> Void) {
        recolouring = true
        defer { recolouring = false }
        edit()
    }

    override func processEditing(
        for textStorage: NSTextStorage, edited editMask: NSTextStorage.EditActions,
        range newCharRange: NSRange, changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange
    ) {
        guard recolouring, editMask == .editedAttributes, delta == 0 else {
            super.processEditing(
                for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta,
                invalidatedRange: invalidatedCharRange)
            return
        }
        invalidateDisplay(forCharacterRange: newCharRange)
    }
}

/// A container that is as tall as the words need and only as wide as it is told. A text view that
/// grows with its words resizes its container to its own frame whenever the frame changes, and a
/// container resized to the same width and a new height lays every word out again, so a paragraph
/// gaining a line was laid out from its first letter because the box around it got taller.
final class EndlessTextContainer: NSTextContainer {
    override var size: CGSize {
        get { super.size }
        set {
            let endless = CGSize(width: newValue.width, height: .greatestFiniteMagnitude)
            if endless != super.size { super.size = endless }
        }
    }
}

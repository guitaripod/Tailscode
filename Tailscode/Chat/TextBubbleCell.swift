import UIKit

final class TextBubbleCell: UICollectionViewCell {
    static let reuseID = "TextBubbleCell"
    weak var linkDelegate: TextBubbleCellDelegate?

    let bubble = BubbleView()
    let textView = MeasuredTextView()
    var measuresItself = false
    var leadingPin: NSLayoutConstraint!
    var trailingPin: NSLayoutConstraint!
    private var textInsetLeading: NSLayoutConstraint!
    private var textInsetTrailing: NSLayoutConstraint!
    var maxWidth: NSLayoutConstraint!
    var timestampLeading: NSLayoutConstraint?
    var timestampTrailing: NSLayoutConstraint?
    private var bubbleTop: NSLayoutConstraint!
    private var textTop: NSLayoutConstraint!
    private var textBottom: NSLayoutConstraint!
    private var heightPin: NSLayoutConstraint!
    private var placesItsWords = false
    lazy var aurora = AuroraTextPainter(textView: textView, host: bubble)
    var cascadeBase: (revision: Int, reasoning: Bool, text: NSAttributedString)?
    /// Whether the text view already wears the answer's font, ink and link style. Each of those is
    /// an edit to the whole text storage and a re-layout of the words in it, and a live answer is
    /// configured on every arrival, so a reconfigure of the same kind of row leaves them be.
    var wearsAnswerStyle = false
    private var fit: CGSize?

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.layer.cornerRadius = Theme.Radius.bubble
        bubble.layer.cornerCurve = .continuous
        bubble.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.heightTracksTextView = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.adjustsFontForContentSizeCategory = true
        textView.delegate = self
        contentView.addSubview(bubble)
        bubble.addSubview(textView)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (cell: TextBubbleCell, _) in
            cell.contentChanged()
        }

        leadingPin = bubble.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l)
        trailingPin = bubble.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l)
        textInsetLeading = textView.leadingAnchor.constraint(
            equalTo: bubble.leadingAnchor, constant: Theme.Spacing.m)
        textInsetTrailing = textView.trailingAnchor.constraint(
            equalTo: bubble.trailingAnchor, constant: -Theme.Spacing.m)
        maxWidth = bubble.widthAnchor.constraint(
            lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.82)
        bubbleTop = bubble.topAnchor.constraint(equalTo: contentView.topAnchor)
        textTop = textView.topAnchor.constraint(equalTo: bubble.topAnchor)
        textBottom = textView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor)
        heightPin = bubble.heightAnchor.constraint(equalToConstant: 0)
        heightPin.priority = .defaultHigh

        NSLayoutConstraint.activate([
            bubbleTop,
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            maxWidth,
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
            textInsetLeading,
            textInsetTrailing,
            textTop,
            textBottom,
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var gapAbove: CGFloat = 0 {
        didSet {
            guard gapAbove != oldValue else { return }
            bubbleTop.constant = gapAbove
            contentChanged()
        }
    }

    /// The air inside the bubble above and below its words. Only a prompt has a plate, so only a
    /// prompt and an error card pad their words; prose and stamps sit on the canvas.
    func padText(_ points: CGFloat) {
        textTop.constant = points
        textBottom.constant = -points
        syncPlacedInsets()
    }

    /// Hands the words to the frame: the text view leaves the constraint engine, which re-measured
    /// the whole text for its baseline on every arrival, and the bubble places it inside the insets
    /// the constraints would have, at a height the row has already measured.
    func placeWords() {
        guard !placesItsWords else { return }
        placesItsWords = true
        NSLayoutConstraint.deactivate([textInsetLeading, textInsetTrailing, textTop, textBottom])
        textView.translatesAutoresizingMaskIntoConstraints = true
        bubble.placedContent = textView
        heightPin.isActive = true
        syncPlacedInsets()
    }

    func constrainWords() {
        guard placesItsWords else { return }
        placesItsWords = false
        heightPin.isActive = false
        bubble.placedContent = nil
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([textInsetLeading, textInsetTrailing, textTop, textBottom])
    }

    private func syncPlacedInsets() {
        bubble.contentInsets = UIEdgeInsets(
            top: textTop.constant, left: textInsetLeading.constant,
            bottom: -textBottom.constant, right: -textInsetTrailing.constant)
        bubble.setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.layer.removeAllAnimations()
        contentView.alpha = 1
        contentView.transform = .identity
        bubble.layer.borderWidth = 0
        isAccessibilityElement = false
        accessibilityLabel = nil
        accessibilityHint = nil
        accessibilityTraits = []
        accessibilityCustomActions = nil
        textView.textAlignment = .natural
        wearsAnswerStyle = false
        measuresItself = false
        textView.measuredHeight = nil
        contentChanged()
        timestampLeading?.isActive = false
        timestampTrailing?.isActive = false
        aurora.release()
        cascadeBase = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        aurora.revalidate()
    }

    #if DEBUG
        nonisolated(unsafe) static var fitCount = 0
        nonisolated(unsafe) static var verifiedFits = 0
        private static let verifiesMeasure =
            ProcessInfo.processInfo.environment["TAILSCODE_VERIFY_TEXTFIT"] != nil
    #endif

    /// The list asks every visible cell for its size again whenever anything in it changes, and a
    /// text view answers by laying its words out twice. A row whose words, style and width are what
    /// they were when it last answered says the same height without being measured again; whatever
    /// can change either (`contentChanged()`) takes the answer back.
    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        if let fit, fit.width == layoutAttributes.size.width,
            let copy = layoutAttributes.copy() as? UICollectionViewLayoutAttributes
        {
            copy.size = fit
            return copy
        }
        #if DEBUG
            Self.fitCount += 1
        #endif
        let height = measuresItself ? measuredHeight(cellWidth: layoutAttributes.size.width) : nil
        textView.measuredHeight = height
        guard let height, let sized = layoutAttributes.copy() as? UICollectionViewLayoutAttributes
        else {
            constrainWords()
            let measured = super.preferredLayoutAttributesFitting(layoutAttributes)
            fit = measured.size
            return measured
        }
        let bubbleHeight = textTop.constant + height - textBottom.constant
        heightPin.constant = bubbleHeight
        sized.size.height = bubbleTop.constant + bubbleHeight
        #if DEBUG
            if Self.verifiesMeasure {
                constrainWords()
                textView.measuredHeight = nil
                let reference = super.preferredLayoutAttributesFitting(layoutAttributes)
                textView.measuredHeight = height
                placeWords()
                if abs(reference.size.height - sized.size.height) > 0.5 {
                    AppLogger.performance.info(
                        "TEXTFIT_MISMATCH ours=\(sized.size.height) uikit=\(reference.size.height) width=\(layoutAttributes.size.width) chars=\(textView.textStorage.length)")
                } else {
                    Self.verifiedFits += 1
                }
            }
        #endif
        fit = sized.size
        return sized
    }

    /// How tall the words are at the width this row gives them, laid out once and kept: the container
    /// is only resized when the width is not the one it already has, so the next arrival of a growing
    /// answer lays out what was added and nothing before it. The width is the row's less what the
    /// pins and the bubble's padding take, read from the constraints that take it.
    private func measuredHeight(cellWidth: CGFloat) -> CGFloat? {
        let width =
            cellWidth - leadingPin.constant + trailingPin.constant - textInsetLeading.constant
            + textInsetTrailing.constant
        guard width > 1 else { return nil }
        let container = textView.textContainer
        let target = CGSize(width: width, height: .greatestFiniteMagnitude)
        if container.size != target { container.size = target }
        container.heightTracksTextView = false
        let manager = textView.layoutManager
        manager.ensureLayout(for: container)
        let scale = traitCollection.displayScale
        guard scale > 0 else { return nil }
        return ceil(manager.usedRect(for: container).height * scale) / scale
    }

    func contentChanged() {
        fit = nil
    }

    /// Writes `text` into the view as an edit rather than a replacement. Replacing the storage
    /// invalidates every glyph already laid out, and an answer that grows by a word on every
    /// arrival was therefore laid out from its first letter again each time; an edit from the first
    /// place the new text differs lays out the words that changed and what follows them.
    func adopt(_ text: NSAttributedString) {
        let held = textView.textStorage
        let keep = Self.sharedLength(held, text)
        guard keep > 0 else {
            textView.attributedText = text
            return
        }
        guard keep < held.length || keep < text.length else { return }
        held.beginEditing()
        held.replaceCharacters(
            in: NSRange(location: keep, length: held.length - keep),
            with: text.attributedSubstring(
                from: NSRange(location: keep, length: text.length - keep)))
        held.endEditing()
    }

    /// How many leading UTF-16 units two attributed strings agree on, in characters and in every
    /// attribute they carry.
    private static func sharedLength(_ held: NSAttributedString, _ text: NSAttributedString) -> Int {
        let characters = (held.string as NSString).commonPrefix(with: text.string, options: []).utf16.count
        var verified = 0
        while verified < characters {
            var heldRun = NSRange(location: 0, length: 0)
            var textRun = NSRange(location: 0, length: 0)
            let limit = NSRange(location: verified, length: characters - verified)
            let heldAttributes = held.attributes(
                at: verified, longestEffectiveRange: &heldRun, in: limit)
            let textAttributes = text.attributes(
                at: verified, longestEffectiveRange: &textRun, in: limit)
            guard (heldAttributes as NSDictionary).isEqual(to: textAttributes) else { break }
            verified = min(heldRun.upperBound, textRun.upperBound)
        }
        return verified
    }

    /// The answer bubble hugs its text tighter than the other rows: the surface is
    /// the point, so the chrome around the words shrinks to the tokens above.
    func applyHorizontalInsets(outer: CGFloat, inner: CGFloat) {
        leadingPin.constant = outer
        trailingPin.constant = -outer
        textInsetLeading.constant = inner
        textInsetTrailing.constant = -inner
        syncPlacedInsets()
    }

    /// A message waiting for its turn: the words in a lighter ink on a plain plate with an outline,
    /// so it reads as not sent without being dimmed below legibility. The row is one element that
    /// says where it stands in the queue and offers the two things that can be done to it.
    func configureQueued(
        text: String, editing: Bool, spoken: String, hint: String,
        actions: [UIAccessibilityCustomAction]
    ) {
        configure(text: text, role: .user, reasoning: false)
        let ink = editing ? Theme.Color.tertiaryLabel : Theme.Color.secondaryLabel
        bubble.backgroundColor = Theme.Color.secondaryBackground
        bubble.layer.borderWidth = 1
        bubble.layer.borderColor = Theme.Color.separator.resolvedColor(with: traitCollection).cgColor
        textView.textColor = ink
        textView.attributedText = NSAttributedString(
            string: text, attributes: Theme.Ramp.attributes(.prompt, color: ink))
        textView.linkTextAttributes = [.foregroundColor: ink]
        isAccessibilityElement = true
        accessibilityLabel = spoken
        accessibilityHint = hint
        accessibilityTraits = .button
        accessibilityCustomActions = actions
    }
}

extension TextBubbleCell: UITextViewDelegate {
    func textView(
        _ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction
    ) -> UIAction? {
        guard case .link(let url) = textItem.content else { return defaultAction }
        return UIAction { [weak self] _ in
            guard let self else { return }
            self.linkDelegate?.textBubbleCell(self, didTapLink: url)
        }
    }
}

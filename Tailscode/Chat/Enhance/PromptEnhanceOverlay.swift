import UIKit

@MainActor
protocol PromptEnhanceOverlayDelegate: AnyObject {
    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didChoose prompt: EnhancedPrompt)
    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didCopy prompt: EnhancedPrompt)
    func enhanceOverlayDidRequestRetry(_ overlay: PromptEnhanceOverlay)
    func enhanceOverlayDidDismiss(_ overlay: PromptEnhanceOverlay)
}

/// A Liquid Glass bubble that grows out of the Send button, holding the on-device
/// rewrites in a zero-padding paging collection view. It retracts back into the
/// button on any dismissal — the close button, a tap outside, or a downward pull
/// once the current prompt is scrolled to its top.
@MainActor
final class PromptEnhanceOverlay: UIView, UIGestureRecognizerDelegate {
    weak var delegate: PromptEnhanceOverlayDelegate?

    private struct MessageInfo: Hashable {
        let symbol: String
        let text: String
        let showsRetry: Bool
    }

    private enum Item: Hashable {
        case prompt(EnhancedPrompt)
        case skeleton(Int)
        case message(MessageInfo)
    }

    private let scrim = UIView()
    private let bubble = UIView()
    private let glass = Theme.Glass.view(interactive: false)
    private let dismissButton = UIButton(type: .system)
    private let footer = UIStackView()
    private let pageControl = UIPageControl()
    private let copyButton = UIButton(type: .system)
    private let useButton = UIButton(type: .system)
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!

    private var glassEffect: UIVisualEffect?
    private var dismissAnimator: UIViewPropertyAnimator?
    private var bubblePan: UIPanGestureRecognizer!
    private var prompts: [EnhancedPrompt] = []
    private var currentPage = 0
    private var buttonCenter: CGPoint = .zero

    private enum PullToDismiss {
        static let commitTranslation: CGFloat = 96
        static let commitVelocity: CGFloat = 780
        static let overshootResistance: CGFloat = 0.55
        static let liftResistance: CGFloat = 0.14
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        backgroundColor = .clear

        scrim.translatesAutoresizingMaskIntoConstraints = false
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.12)
        addSubview(scrim)

        bubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)

        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.isUserInteractionEnabled = false
        glass.layer.cornerRadius = 26
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        bubble.addSubview(glass)
        glassEffect = glass.effect

        configureCollectionView()
        bubble.addSubview(collectionView)

        dismissButton.setImage(
            UIImage(
                systemName: "xmark.circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)),
            for: .normal)
        dismissButton.tintColor = Theme.Color.tertiaryLabel
        dismissButton.accessibilityLabel = "Dismiss"
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.addAction(UIAction { [weak self] _ in self?.requestDismiss() }, for: .touchUpInside)
        bubble.addSubview(dismissButton)

        pageControl.currentPageIndicatorTintColor = Theme.Color.accent
        pageControl.pageIndicatorTintColor = Theme.Color.separator
        pageControl.hidesForSinglePage = true
        pageControl.translatesAutoresizingMaskIntoConstraints = false
        pageControl.setContentHuggingPriority(.required, for: .horizontal)
        pageControl.addTarget(self, action: #selector(pageControlChanged), for: .valueChanged)

        copyButton.setImage(
            UIImage(
                systemName: "doc.on.doc",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)),
            for: .normal)
        copyButton.tintColor = Theme.Color.secondaryLabel
        copyButton.accessibilityLabel = "Copy"
        copyButton.addAction(UIAction { [weak self] _ in self?.useCopy() }, for: .touchUpInside)

        var use = Theme.Glass.buttonConfiguration(prominent: true)
        use.cornerStyle = .capsule
        use.title = "Use"
        use.image = UIImage(
            systemName: "arrow.up",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        use.imagePadding = Theme.Spacing.xs
        use.baseBackgroundColor = Theme.Color.accent
        use.baseForegroundColor = .white
        useButton.configuration = use
        useButton.accessibilityLabel = "Use this prompt"
        useButton.addAction(UIAction { [weak self] _ in self?.useCurrent() }, for: .touchUpInside)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.axis = .horizontal
        footer.alignment = .center
        footer.spacing = Theme.Spacing.s
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addArrangedSubview(pageControl)
        footer.addArrangedSubview(spacer)
        footer.addArrangedSubview(copyButton)
        footer.addArrangedSubview(useButton)
        bubble.addSubview(footer)

        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: topAnchor),
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: bottomAnchor),

            bubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.s),
            bubble.heightAnchor.constraint(equalToConstant: 300),

            glass.topAnchor.constraint(equalTo: bubble.topAnchor),
            glass.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),

            dismissButton.topAnchor.constraint(equalTo: bubble.topAnchor, constant: Theme.Spacing.s),
            dismissButton.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -Theme.Spacing.s),
            dismissButton.widthAnchor.constraint(equalToConstant: 30),
            dismissButton.heightAnchor.constraint(equalToConstant: 30),

            collectionView.topAnchor.constraint(equalTo: bubble.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -Theme.Spacing.xs),

            footer.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: Theme.Spacing.l),
            footer.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -Theme.Spacing.m),
            footer.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -Theme.Spacing.m),
            footer.heightAnchor.constraint(equalToConstant: 36),
        ])

        let noOverlap = bubble.topAnchor.constraint(
            greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.m)
        noOverlap.priority = UILayoutPriority(999)
        noOverlap.isActive = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(scrimTapped))
        tap.delegate = self
        addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleBubblePan))
        pan.delegate = self
        bubble.addGestureRecognizer(pan)
        bubblePan = pan

        configureDataSource()
    }

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] _, _ in
            let item = NSCollectionLayoutItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)),
                subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.orthogonalScrollingBehavior = .paging
            section.visibleItemsInvalidationHandler = { [weak self] _, offset, environment in
                self?.updateCurrentPage(offset: offset, width: environment.container.contentSize.width)
            }
            return section
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.register(EnhancedPromptCell.self, forCellWithReuseIdentifier: EnhancedPromptCell.reuseID)
        collectionView.register(EnhanceSkeletonCell.self, forCellWithReuseIdentifier: EnhanceSkeletonCell.reuseID)
        collectionView.register(EnhanceMessageCell.self, forCellWithReuseIdentifier: EnhanceMessageCell.reuseID)
    }

    private func updateCurrentPage(offset: CGPoint, width: CGFloat) {
        guard width > 0 else { return }
        let page = Int((offset.x / width).rounded())
        guard page != currentPage, page >= 0, page < max(pageControl.numberOfPages, 1) else { return }
        currentPage = page
        pageControl.currentPage = page
        Theme.Haptics.selection()
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collectionView) {
            [weak self] collectionView, indexPath, item in
            switch item {
            case .prompt(let prompt):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: EnhancedPromptCell.reuseID, for: indexPath) as! EnhancedPromptCell
                cell.configure(prompt)
                return cell
            case .skeleton:
                return collectionView.dequeueReusableCell(
                    withReuseIdentifier: EnhanceSkeletonCell.reuseID, for: indexPath)
            case .message(let info):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: EnhanceMessageCell.reuseID, for: indexPath) as! EnhanceMessageCell
                cell.configure(symbol: info.symbol, text: info.text, showsRetry: info.showsRetry)
                cell.onRetry = { [weak self] in
                    guard let self else { return }
                    self.delegate?.enhanceOverlayDidRequestRetry(self)
                }
                return cell
            }
        }
    }

    func render(_ status: PromptEnhancementController.Status, original: String) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        switch status {
        case .idle, .generating:
            prompts = []
            snapshot.appendItems((0..<PromptEnhancement.suggestionCount).map { .skeleton($0) })
            pageControl.numberOfPages = 0
            footer.isHidden = true
        case .ready(let ready):
            prompts = ready
            snapshot.appendItems(ready.map { .prompt($0) })
            pageControl.numberOfPages = ready.count
            footer.isHidden = false
        case .failed:
            prompts = []
            snapshot.appendItems([
                .message(MessageInfo(
                    symbol: "exclamationmark.bubble",
                    text: "Couldn't refine that one. Give it another try.", showsRetry: true))
            ])
            pageControl.numberOfPages = 0
            footer.isHidden = true
        case .unavailable(let reason):
            prompts = []
            snapshot.appendItems([
                .message(MessageInfo(symbol: "sparkles", text: reason, showsRetry: false))
            ])
            pageControl.numberOfPages = 0
            footer.isHidden = true
        }
        if currentPage >= pageControl.numberOfPages {
            currentPage = 0
            pageControl.currentPage = 0
        }
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    @objc private func pageControlChanged() {
        let page = pageControl.currentPage
        guard page < collectionView.numberOfItems(inSection: 0) else { return }
        collectionView.scrollToItem(
            at: IndexPath(item: page, section: 0), at: .centeredHorizontally, animated: true)
    }

    private func useCurrent() {
        guard prompts.indices.contains(currentPage) else { return }
        delegate?.enhanceOverlay(self, didChoose: prompts[currentPage])
    }

    private func useCopy() {
        guard prompts.indices.contains(currentPage) else { return }
        delegate?.enhanceOverlay(self, didCopy: prompts[currentPage])
    }

    @objc private func scrimTapped() { requestDismiss() }

    @objc private func handleBubblePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .changed:
            if let scroll = currentCardScrollView, scroll.contentOffset.y > 0 {
                pan.setTranslation(.zero, in: self)
                bubble.transform = .identity
                return
            }
            bubble.transform = CGAffineTransform(
                translationX: 0, y: pullOffset(for: pan.translation(in: self).y))
        case .ended:
            let translation = pan.translation(in: self).y
            let velocity = pan.velocity(in: self).y
            if translation > PullToDismiss.commitTranslation
                || velocity > PullToDismiss.commitVelocity
            {
                Theme.Haptics.tap()
                requestDismiss()
            } else {
                springBubbleBack()
            }
        case .cancelled, .failed:
            springBubbleBack()
        default:
            break
        }
    }

    /// The scroll view backing the current page's prompt text, so a downward
    /// pull defers to inner scrolling until the text is already at its top.
    private var currentCardScrollView: UIScrollView? {
        let indexPath = IndexPath(item: currentPage, section: 0)
        return (collectionView.cellForItem(at: indexPath) as? EnhancedPromptCell)?.promptScrollView
    }

    private func pullOffset(for translation: CGFloat) -> CGFloat {
        guard translation > 0 else { return translation * PullToDismiss.liftResistance }
        guard translation > PullToDismiss.commitTranslation else { return translation }
        let overshoot = translation - PullToDismiss.commitTranslation
        return PullToDismiss.commitTranslation + overshoot * PullToDismiss.overshootResistance
    }

    private func springBubbleBack() {
        UIView.animate(
            withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.82,
            initialSpringVelocity: 0.5, options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.bubble.transform = .identity
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === bubblePan else { return true }
        let velocity = bubblePan.velocity(in: self)
        return velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === bubblePan && other.view is UITextView
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer is UITapGestureRecognizer else { return true }
        guard let view = touch.view else { return true }
        return !view.isDescendant(of: bubble)
    }

    /// Grows the bubble out of the Send button: it starts scaled down over the
    /// button while the glass materialises, then springs up to full size.
    func animateIn(fromButtonCenter origin: CGPoint) {
        layoutIfNeeded()
        buttonCenter = origin
        dismissAnimator?.stopAnimation(true)
        dismissAnimator = nil

        guard !UIAccessibility.isReduceMotionEnabled else {
            glass.effect = glassEffect
            scrim.alpha = 1
            bubble.transform = .identity
            setContentAlpha(1)
            return
        }

        glass.effect = nil
        scrim.alpha = 0
        bubble.transform = retractedTransform()
        setContentAlpha(0)

        let glassForm = UIViewPropertyAnimator(duration: 0.5, curve: .easeOut) {
            self.glass.effect = self.glassEffect
            self.scrim.alpha = 1
        }
        glassForm.startAnimation()

        UIView.animate(
            withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.82,
            initialSpringVelocity: 0.5, options: [.allowUserInteraction]
        ) {
            self.bubble.transform = .identity
        }
        UIView.animate(withDuration: 0.28, delay: 0.1, options: [.curveEaseOut]) {
            self.setContentAlpha(1)
        }
    }

    func requestDismiss() {
        dismissAnimator?.stopAnimation(true)
        let animator = makeRetractAnimator()
        dismissAnimator = animator
        animator.startAnimation()
    }

    /// Retracts the bubble back into the Send button — the glass melts, the
    /// contents fade, and the bubble shrinks toward the button from wherever it
    /// currently sits (so a downward pull continues the motion smoothly).
    private func makeRetractAnimator() -> UIViewPropertyAnimator {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let animator = UIViewPropertyAnimator(duration: reduceMotion ? 0.2 : 0.34, dampingRatio: 0.9) {
            self.glass.effect = nil
            self.scrim.alpha = 0
            self.setContentAlpha(0)
            if !reduceMotion { self.bubble.transform = self.retractedTransform() }
        }
        animator.addCompletion { [weak self] position in
            guard let self else { return }
            if position == .end {
                self.removeFromSuperview()
                self.delegate?.enhanceOverlayDidDismiss(self)
            } else {
                self.glass.effect = self.glassEffect
                self.scrim.alpha = 1
                self.setContentAlpha(1)
                self.bubble.transform = .identity
            }
        }
        return animator
    }

    private func retractedTransform() -> CGAffineTransform {
        let target = buttonCenter == .zero
            ? CGPoint(x: bubble.center.x, y: bounds.height) : buttonCenter
        let dx = target.x - bubble.center.x
        let dy = target.y - bubble.center.y
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: 0.18, y: 0.18)
    }

    private func setContentAlpha(_ alpha: CGFloat) {
        collectionView.alpha = alpha
        footer.alpha = alpha
        dismissButton.alpha = alpha
    }

    #if DEBUG
    func debugScroll(toCard index: Int) {
        guard index < collectionView.numberOfItems(inSection: 0) else { return }
        collectionView.scrollToItem(
            at: IndexPath(item: index, section: 0), at: .centeredHorizontally, animated: false)
    }
    #endif
}

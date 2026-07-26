import UIKit

/// Full-screen attachment viewer: zooms out of the bubble it was tapped from,
/// pinches and double-taps to zoom, and follows a downward drag back to the
/// chat so dismissing feels like putting the image down rather than closing a
/// modal.
final class ImageViewerViewController: UIViewController {
    private let image: UIImage
    private let sourceView: UIView
    private let backdrop = UIView()
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let chrome = UIStackView()
    private var imageTop: NSLayoutConstraint!
    private var imageLeading: NSLayoutConstraint!
    private var dragOffset: CGFloat = 0

    init(image: UIImage, from sourceView: UIView) {
        self.image = image
        self.sourceView = sourceView
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        backdrop.backgroundColor = .black
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        imageTop = imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor)
        imageLeading = imageView.leadingAnchor.constraint(
            equalTo: scrollView.contentLayoutGuide.leadingAnchor)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageTop,
            imageLeading,
            imageView.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        buildChrome()

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(toggleChrome))
        singleTap.require(toFail: doubleTap)
        imageView.addGestureRecognizer(singleTap)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag))
        drag.delegate = self
        scrollView.addGestureRecognizer(drag)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard dragOffset == 0, imageView.transform == .identity else { return }
        animateIn()
    }

    private func buildChrome() {
        let close = UIButton(type: .system)
        close.setImage(
            UIImage(
                systemName: "xmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
            for: .normal)
        close.addAction(UIAction { [weak self] _ in self?.dismissViewer() }, for: .touchUpInside)
        let share = UIButton(type: .system)
        share.setImage(
            UIImage(
                systemName: "square.and.arrow.up",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
            for: .normal)
        share.addAction(UIAction { [weak self] _ in self?.share() }, for: .touchUpInside)
        for button in [close, share] {
            button.tintColor = .white
            button.backgroundColor = UIColor.white.withAlphaComponent(0.16)
            button.layer.cornerRadius = 17
            button.layer.cornerCurve = .continuous
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 34),
                button.heightAnchor.constraint(equalToConstant: 34),
            ])
        }
        chrome.axis = .horizontal
        chrome.spacing = Theme.Spacing.m
        chrome.translatesAutoresizingMaskIntoConstraints = false
        chrome.addArrangedSubview(share)
        chrome.addArrangedSubview(close)
        view.addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.s),
            chrome.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    /// Starts as a copy of the tapped thumbnail and springs up to full size, so
    /// the image appears to grow out of the bubble instead of fading in over it.
    private func animateIn() {
        guard let window = sourceView.window else { return }
        let origin = sourceView.convert(sourceView.bounds, to: window)
        let target = fittedFrame(in: view.bounds.size)
        guard target.width > 0, target.height > 0 else { return }
        let scale = CGSize(
            width: origin.width / target.width, height: origin.height / target.height)
        backdrop.alpha = 0
        chrome.alpha = 0
        imageView.transform = CGAffineTransform(scaleX: scale.width, y: scale.height)
            .concatenating(
                CGAffineTransform(
                    translationX: origin.midX - target.midX, y: origin.midY - target.midY))
        UIView.animate(
            withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.4,
            options: [.allowUserInteraction]
        ) {
            self.imageView.transform = .identity
            self.backdrop.alpha = 1
            self.chrome.alpha = 1
        }
    }

    /// Where the aspect-fit image actually sits inside the viewer — the frame a
    /// zoom animation has to match, not the full bounds.
    private func fittedFrame(in size: CGSize) -> CGRect {
        let aspect = image.size.width / max(image.size.height, 1)
        var width = size.width
        var height = width / max(aspect, 0.0001)
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        return CGRect(
            x: (size.width - width) / 2, y: (size.height - height) / 2, width: width,
            height: height)
    }

    private func share() {
        let sheet = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = chrome
        present(sheet, animated: true)
    }

    @objc private func toggleChrome() {
        UIView.animate(withDuration: 0.2) { self.chrome.alpha = self.chrome.alpha > 0 ? 0 : 1 }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }
        let point = gesture.location(in: imageView)
        let size = CGSize(
            width: scrollView.bounds.width / 3, height: scrollView.bounds.height / 3)
        scrollView.zoom(
            to: CGRect(
                x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width,
                height: size.height),
            animated: true)
    }

    @objc private func handleDrag(_ gesture: UIPanGestureRecognizer) {
        guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return }
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .changed:
            dragOffset = translation.y
            let progress = min(abs(translation.y) / 260, 1)
            imageView.transform = CGAffineTransform(
                translationX: translation.x * 0.6, y: translation.y
            ).scaledBy(x: 1 - progress * 0.2, y: 1 - progress * 0.2)
            backdrop.alpha = 1 - progress * 0.8
            chrome.alpha = 1 - progress
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: view).y
            if abs(translation.y) > 130 || abs(velocity) > 900 {
                dismissViewer(velocity: velocity)
            } else {
                dragOffset = 0
                UIView.animate(
                    withDuration: 0.34, delay: 0, usingSpringWithDamping: 0.82,
                    initialSpringVelocity: 0.3
                ) {
                    self.imageView.transform = .identity
                    self.backdrop.alpha = 1
                    self.chrome.alpha = 1
                }
            }
        default:
            break
        }
    }

    /// Reverses the entry animation back into the bubble when it is still on
    /// screen; a thrown-away image just keeps its momentum and fades.
    private func dismissViewer(velocity: CGFloat = 0) {
        let window = sourceView.window
        let target = fittedFrame(in: view.bounds.size)
        let origin = window.map { sourceView.convert(sourceView.bounds, to: $0) }
        let sourceVisible = origin.map { window?.bounds.intersects($0) == true } ?? false
        UIView.animate(
            withDuration: 0.3, delay: 0, options: [.curveEaseInOut],
            animations: {
                if sourceVisible, let origin, target.width > 0, target.height > 0 {
                    self.imageView.transform = CGAffineTransform(
                        scaleX: origin.width / target.width, y: origin.height / target.height
                    ).concatenating(
                        CGAffineTransform(
                            translationX: origin.midX - target.midX,
                            y: origin.midY - target.midY))
                } else {
                    self.imageView.transform = self.imageView.transform
                        .translatedBy(x: 0, y: velocity > 0 ? 400 : -400)
                }
                self.imageView.alpha = sourceVisible ? 1 : 0
                self.backdrop.alpha = 0
                self.chrome.alpha = 0
            },
            completion: { _ in self.dismiss(animated: false) })
    }
}

extension ImageViewerViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
}

extension ImageViewerViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

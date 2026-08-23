import CodingAgentKit
import UIKit
import VisionKit

/// One picture in a conversation, addressed the way the chat addresses its rows
/// so the viewer can open on the one that was tapped.
struct GalleryImage: Hashable, Sendable {
    let id: String
    let file: FileReference
    let localData: Data?

    var filename: String { file.displayName }
}

/// Full-screen viewer for the pictures in a conversation: it opens out of the
/// bubble that was tapped, swipes across every other image in the chat, zooms to
/// the pixel, lifts text out of a screenshot, and puts the picture in the photo
/// library, the pasteboard, or another app. A downward drag hands it back to the
/// chat, so dismissing feels like putting the image down rather than closing a
/// modal.
final class ImageViewerViewController: UIViewController {
    private let items: [GalleryImage]
    private let backend: any CodingAgentBackend
    private let sourceView: UIView?
    private let sourceIndex: Int
    private var index: Int

    private let backdrop = UIView()
    private let collectionView: UICollectionView
    private let transitionView = UIImageView()
    private let topBar = Theme.Glass.view()
    private let bottomBar = Theme.Glass.view()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let liveTextButton = UIButton(type: .system)
    private var chrome: [UIView] { [topBar, bottomBar] }
    private var chromeHidden = false
    private var didAnimateIn = false
    private var isDismissing = false
    private var liveTextOn = false
    private var pagesWithText: Set<Int> = []

    init(
        items: [GalleryImage], startIndex: Int, backend: any CodingAgentBackend,
        from sourceView: UIView?
    ) {
        self.items = items
        self.index = max(0, min(startIndex, items.count - 1))
        self.sourceIndex = self.index
        self.backend = backend
        self.sourceView = sourceView
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        overrideUserInterfaceStyle = .dark
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { chromeHidden }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        backdrop.backgroundColor = .black
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)

        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isPagingEnabled = true
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.register(ImagePageCell.self, forCellWithReuseIdentifier: ImagePageCell.reuseID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        transitionView.contentMode = .scaleAspectFill
        transitionView.clipsToBounds = true
        transitionView.layer.cornerCurve = .continuous
        transitionView.isHidden = true
        view.addSubview(transitionView)

        buildChrome()

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag))
        drag.delegate = self
        view.addGestureRecognizer(drag)
        updateChromeContent()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout,
            layout.itemSize != view.bounds.size, view.bounds.width > 0
        else { return }
        layout.itemSize = view.bounds.size
        layout.invalidateLayout()
        collectionView.setContentOffset(
            CGPoint(x: CGFloat(index) * view.bounds.width, y: 0), animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didAnimateIn else { return }
        didAnimateIn = true
        animateIn()
    }

    private func buildChrome() {
        titleLabel.font = Theme.Ramp.font(.panelLabel)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.font = Theme.Ramp.font(.panelFootnote)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical
        titles.spacing = 1
        titles.translatesAutoresizingMaskIntoConstraints = false

        closeButton.setImage(Self.symbol("xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.accessibilityLabel = String(localized: "Close")
        closeButton.addAction(UIAction { [weak self] _ in self?.dismissViewer() }, for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.clipsToBounds = true
        topBar.layer.cornerCurve = .continuous
        topBar.contentView.addSubview(titles)
        topBar.contentView.addSubview(closeButton)
        view.addSubview(topBar)

        let share = actionButton("square.and.arrow.up", String(localized: "Share")) {
            [weak self] in self?.share()
        }
        saveButton.setImage(Self.symbol("arrow.down.to.line"), for: .normal)
        saveButton.tintColor = .white
        saveButton.accessibilityLabel = String(localized: "Save to Photos")
        saveButton.addAction(UIAction { [weak self] _ in self?.save() }, for: .touchUpInside)
        let copy = actionButton("doc.on.doc", String(localized: "Copy")) {
            [weak self] in self?.copyImage()
        }
        liveTextButton.setImage(Self.symbol("text.viewfinder"), for: .normal)
        liveTextButton.tintColor = .white
        liveTextButton.accessibilityLabel = String(localized: "Live Text")
        liveTextButton.isHidden = true
        liveTextButton.addAction(
            UIAction { [weak self] _ in self?.toggleLiveText() }, for: .touchUpInside)

        let actions = UIStackView(arrangedSubviews: [share, saveButton, copy, liveTextButton])
        actions.axis = .horizontal
        actions.spacing = Theme.Spacing.xl
        actions.translatesAutoresizingMaskIntoConstraints = false
        for button in [share, saveButton, copy, liveTextButton] {
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }

        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.clipsToBounds = true
        bottomBar.layer.cornerCurve = .continuous
        bottomBar.contentView.addSubview(actions)
        view.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.s),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            topBar.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
            titles.leadingAnchor.constraint(
                equalTo: topBar.contentView.leadingAnchor, constant: Theme.Spacing.m),
            titles.topAnchor.constraint(
                equalTo: topBar.contentView.topAnchor, constant: Theme.Spacing.s),
            titles.bottomAnchor.constraint(
                equalTo: topBar.contentView.bottomAnchor, constant: -Theme.Spacing.s),
            titles.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor, constant: -Theme.Spacing.m),
            closeButton.trailingAnchor.constraint(
                equalTo: topBar.contentView.trailingAnchor, constant: -Theme.Spacing.m),
            closeButton.centerYAnchor.constraint(equalTo: topBar.contentView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
            bottomBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomBar.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Theme.Spacing.m),
            actions.topAnchor.constraint(
                equalTo: bottomBar.contentView.topAnchor, constant: Theme.Spacing.m),
            actions.bottomAnchor.constraint(
                equalTo: bottomBar.contentView.bottomAnchor, constant: -Theme.Spacing.m),
            actions.leadingAnchor.constraint(
                equalTo: bottomBar.contentView.leadingAnchor, constant: Theme.Spacing.xl),
            actions.trailingAnchor.constraint(
                equalTo: bottomBar.contentView.trailingAnchor, constant: -Theme.Spacing.xl),
        ])
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        topBar.layer.cornerRadius = min(topBar.bounds.height / 2, Theme.Radius.card + 4)
        bottomBar.layer.cornerRadius = bottomBar.bounds.height / 2
    }

    private func actionButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void)
        -> UIButton
    {
        let button = UIButton(type: .system)
        button.setImage(Self.symbol(symbol), for: .normal)
        button.tintColor = .white
        button.accessibilityLabel = label
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private static func symbol(_ name: String) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
    }

    private var currentCell: ImagePageCell? {
        collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? ImagePageCell
    }

    private var currentPayload: ImagePayload? {
        guard let cell = currentCell, let image = cell.image else { return nil }
        return ImagePayload(image: image, data: cell.data, filename: items[index].filename)
    }

    private func updateChromeContent() {
        guard items.indices.contains(index) else { return }
        titleLabel.text = items[index].filename
        var detail: [String] = []
        if items.count > 1 {
            detail.append(String(localized: "\(index + 1) of \(items.count)"))
        }
        if let image = currentCell?.image {
            let scale = image.scale
            detail.append(
                "\(Int(image.size.width * scale)) × \(Int(image.size.height * scale))")
        }
        subtitleLabel.text = detail.joined(separator: "  ·  ")
        subtitleLabel.isHidden = detail.isEmpty
        liveTextButton.isHidden = !pagesWithText.contains(index)
        liveTextButton.tintColor = liveTextOn ? Theme.Color.accent : .white
    }


    private func share() {
        guard let payload = currentPayload else { return }
        let item: Any = ImageExport.temporaryFile(payload) ?? payload.image
        let sheet = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = bottomBar
        sheet.popoverPresentationController?.sourceRect = bottomBar.bounds
        present(sheet, animated: true)
    }

    private func save() {
        guard let payload = currentPayload else { return }
        Theme.Haptics.tap()
        Task { [weak self] in
            let outcome = await ImageExport.saveToPhotos(payload)
            guard let self else { return }
            switch outcome {
            case .saved:
                Theme.Haptics.success()
                self.flashSaved()
                self.toast(String(localized: "Saved to Photos"))
            case .denied:
                Theme.Haptics.warning()
                self.presentPhotoAccessAlert()
            case .failed:
                Theme.Haptics.error()
                self.toast(String(localized: "Couldn't save to Photos"))
            }
        }
    }

    private func copyImage() {
        guard let payload = currentPayload else { return }
        ImageExport.copy(payload)
        Theme.Haptics.success()
        toast(String(localized: "Copied"))
    }

    /// The save button becomes the outcome for a moment: a checkmark says the
    /// picture landed without a banner having to say it.
    private func flashSaved() {
        saveButton.setImage(Self.symbol("checkmark"), for: .normal)
        saveButton.tintColor = Theme.Color.success
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let self else { return }
            self.saveButton.setImage(Self.symbol("arrow.down.to.line"), for: .normal)
            self.saveButton.tintColor = .white
        }
    }

    private func presentPhotoAccessAlert() {
        let alert = UIAlertController(
            title: String(localized: "Photos access is off"),
            message: String(
                localized: "Tailscode needs permission to add pictures to your photo library."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Not Now"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Open Settings"), style: .default) { _ in
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            })
        present(alert, animated: true)
    }

    private func toggleLiveText() {
        liveTextOn.toggle()
        Theme.Haptics.selection()
        currentCell?.setLiveText(liveTextOn)
        updateChromeContent()
    }

    private func toast(_ message: String) {
        ToastView(message: message).flash(in: view, above: bottomBar.topAnchor)
    }


    fileprivate func toggleChrome() {
        chromeHidden.toggle()
        UIView.animate(withDuration: 0.22) {
            for bar in self.chrome { bar.alpha = self.chromeHidden ? 0 : 1 }
            self.setNeedsUpdateOfHomeIndicatorAutoHidden()
        }
    }

    @objc private func handleDrag(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .changed:
            let progress = min(abs(translation.y) / 260, 1)
            collectionView.transform = CGAffineTransform(
                translationX: translation.x * 0.6, y: translation.y
            ).scaledBy(x: 1 - progress * 0.2, y: 1 - progress * 0.2)
            backdrop.alpha = 1 - progress * 0.8
            for bar in chrome { bar.alpha = (chromeHidden ? 0 : 1) * (1 - progress) }
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: view).y
            if abs(translation.y) > 130 || abs(velocity) > 900 {
                dismissViewer(thrownDown: velocity >= 0)
            } else {
                UIView.animate(
                    withDuration: 0.34, delay: 0, usingSpringWithDamping: 0.82,
                    initialSpringVelocity: 0.3
                ) {
                    self.collectionView.transform = .identity
                    self.backdrop.alpha = 1
                    for bar in self.chrome { bar.alpha = self.chromeHidden ? 0 : 1 }
                }
            }
        default:
            break
        }
    }


    /// Starts as a copy of the tapped thumbnail and springs up to full size, so
    /// the image appears to grow out of the bubble instead of fading in over it.
    private func animateIn() {
        guard let source = sourceView, source.window != nil, let image = currentCell?.image,
            let target = currentCell?.fittedFrame(in: view.bounds.size)
        else { return }
        let origin = source.convert(source.bounds, to: view)
        guard target.width > 0, target.height > 0, origin.width > 0 else { return }
        transitionView.image = image
        transitionView.frame = origin
        transitionView.layer.cornerRadius = Theme.Radius.bubble
        transitionView.isHidden = false
        collectionView.isHidden = true
        backdrop.alpha = 0
        for bar in chrome { bar.alpha = 0 }
        UIView.animate(
            withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.4,
            options: [.allowUserInteraction]
        ) {
            self.transitionView.frame = target
            self.transitionView.layer.cornerRadius = 0
            self.backdrop.alpha = 1
            for bar in self.chrome { bar.alpha = 1 }
        } completion: { _ in
            self.collectionView.isHidden = false
            self.transitionView.isHidden = true
        }
    }

    /// Reverses the entry animation into the bubble it came from when that
    /// bubble is still the picture on screen; anything else keeps its momentum
    /// and fades, because there is nowhere honest to put it back.
    fileprivate func dismissViewer(thrownDown: Bool = true) {
        guard !isDismissing else { return }
        isDismissing = true
        let image = currentCell?.image
        let frame = currentCell?.imageFrame(in: view)
        let origin = homeFrame()
        transitionView.image = image
        transitionView.frame = frame ?? view.bounds
        transitionView.layer.cornerRadius = 0
        transitionView.isHidden = image == nil
        collectionView.isHidden = true
        UIView.animate(
            withDuration: 0.3, delay: 0, options: [.curveEaseInOut],
            animations: {
                if let origin {
                    self.transitionView.frame = origin
                    self.transitionView.layer.cornerRadius = Theme.Radius.bubble
                } else {
                    self.transitionView.frame = (frame ?? self.view.bounds).offsetBy(
                        dx: 0, dy: thrownDown ? 420 : -420)
                    self.transitionView.alpha = 0
                }
                self.backdrop.alpha = 0
                for bar in self.chrome { bar.alpha = 0 }
            },
            completion: { _ in self.dismiss(animated: false) })
    }

    /// Where the picture belongs when the viewer closes: the bubble it was
    /// opened from, and only while that bubble is both on screen and still
    /// showing this image.
    private func homeFrame() -> CGRect? {
        guard index == sourceIndex, let source = sourceView, let window = source.window else {
            return nil
        }
        let frame = source.convert(source.bounds, to: window)
        guard window.bounds.intersects(frame), frame.width > 0 else { return nil }
        return view.convert(frame, from: window)
    }
}

extension ImageViewerViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int)
        -> Int
    { items.count }

    func collectionView(
        _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ImagePageCell.reuseID, for: indexPath) as! ImagePageCell
        cell.onSingleTap = { [weak self] in self?.toggleChrome() }
        cell.onLoaded = { [weak self] hasText in
            guard let self else { return }
            if hasText { self.pagesWithText.insert(indexPath.item) }
            guard indexPath.item == self.index else { return }
            self.updateChromeContent()
        }
        cell.configure(items[indexPath.item], backend: backend, liveText: liveTextOn)
        return cell
    }
}

extension ImageViewerViewController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView, view.bounds.width > 0, !isDismissing else { return }
        let page = Int((scrollView.contentOffset.x / view.bounds.width).rounded())
        guard page != index, items.indices.contains(page) else { return }
        index = page
        currentCell?.setLiveText(liveTextOn)
        updateChromeContent()
    }

    func collectionView(
        _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        (cell as? ImagePageCell)?.resetZoom()
    }
}

extension ImageViewerViewController: UIGestureRecognizerDelegate {
    /// The drag only takes over when the picture is at rest and the finger is
    /// heading down: a zoomed image pans, and a sideways swipe pages.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard currentCell?.isZoomed != true else { return false }
        let velocity = pan.velocity(in: view)
        return abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

/// One page of the viewer: a zoomable picture that loads its own bytes and,
/// once it has them, offers the text inside it up for selection.
final class ImagePageCell: UICollectionViewCell {
    static let reuseID = "ImagePageCell"

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = ActivityBadgeView(pointSize: 28)
    private let failure = UILabel()
    private let analysisInteraction = ImageAnalysisInteraction()
    private var token = UUID()
    private var liveTextRequested = false

    private(set) var image: UIImage?
    private(set) var data: Data?
    var onSingleTap: (() -> Void)?
    var onLoaded: ((_ hasText: Bool) -> Void)?

    var isZoomed: Bool { scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        contentView.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.addInteraction(analysisInteraction)
        scrollView.addSubview(imageView)

        spinner.overrideColor = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spinner)

        failure.font = Theme.Ramp.font(.panelLabel)
        failure.textColor = UIColor.white.withAlphaComponent(0.7)
        failure.textAlignment = .center
        failure.numberOfLines = 3
        failure.isHidden = true
        failure.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(failure)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            failure.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            failure.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            failure.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.xl),
            failure.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.xl),
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard scrollView.frame != contentView.bounds else { return }
        scrollView.frame = contentView.bounds
        layoutImage()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        token = UUID()
        image = nil
        data = nil
        imageView.image = nil
        analysisInteraction.analysis = nil
        analysisInteraction.preferredInteractionTypes = []
        failure.isHidden = true
        spinner.working(false)
        scrollView.zoomScale = 1
        onSingleTap = nil
        onLoaded = nil
    }

    func configure(_ item: GalleryImage, backend: any CodingAgentBackend, liveText: Bool) {
        liveTextRequested = liveText
        if let cached = AttachmentImageStore.shared.cached(item.file) {
            show(cached, data: AttachmentImageStore.shared.cachedData(item.file) ?? item.localData)
            return
        }
        if let local = item.localData, let decoded = UIImage(data: local) {
            AttachmentImageStore.shared.store(decoded, for: item.file, data: local)
            show(decoded, data: local)
            return
        }
        spinner.working(true, spoken: String(localized: "Loading the picture"))
        let token = self.token
        Task { [weak self] in
            let loaded = await AttachmentImageStore.shared.image(for: item.file, using: backend)
            guard let self, self.token == token else { return }
            self.spinner.working(false)
            guard let loaded else {
                self.failure.text = String(localized: "Couldn't load \(item.filename)")
                self.failure.isHidden = false
                return
            }
            self.show(loaded, data: AttachmentImageStore.shared.cachedData(item.file))
        }
    }

    private func show(_ image: UIImage, data: Data?) {
        spinner.working(false)
        failure.isHidden = true
        self.image = image
        self.data = data
        imageView.image = image
        layoutImage()
        onLoaded?(false)
        analyze(image)
    }

    /// Lays the picture out aspect-fit and lets it zoom to its own pixels — a
    /// screenshot of code is unreadable at fit scale and exact at 1:1.
    private func layoutImage() {
        guard let image, scrollView.bounds.width > 0 else { return }
        let target = Self.fitted(image.size, in: scrollView.bounds.size)
        scrollView.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: target)
        scrollView.contentSize = target
        let pixels = image.size.width * image.scale
        scrollView.maximumZoomScale = min(max(4, pixels / max(target.width, 1)), 12)
        centerImage()
    }

    private func centerImage() {
        let horizontal = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let vertical = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(
            top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    private static func fitted(_ size: CGSize, in bounds: CGSize) -> CGSize {
        let aspect = size.width / max(size.height, 1)
        var width = bounds.width
        var height = width / max(aspect, 0.0001)
        if height > bounds.height {
            height = bounds.height
            width = height * aspect
        }
        return CGSize(width: width, height: height)
    }

    func fittedFrame(in bounds: CGSize) -> CGRect {
        guard let image else { return .zero }
        let size = Self.fitted(image.size, in: bounds)
        return CGRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height)
    }

    func imageFrame(in view: UIView) -> CGRect {
        scrollView.convert(imageView.frame, to: view)
    }

    func resetZoom() {
        guard isZoomed else { return }
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        centerImage()
    }

    /// Live Text is offered rather than imposed: analysis runs as soon as the
    /// picture lands so the button can appear, but selection only turns on when
    /// it is asked for — otherwise a drag across a screenshot selects words
    /// instead of dismissing the viewer.
    private func analyze(_ image: UIImage) {
        guard ImageAnalyzer.isSupported else { return }
        let token = self.token
        Task { [weak self] in
            let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
            let analysis = try? await ImageAnalyzer().analyze(image, configuration: configuration)
            guard let self, self.token == token else { return }
            self.analysisInteraction.analysis = analysis
            let hasText = analysis?.hasResults(for: .text) == true
            if hasText, self.liveTextRequested {
                self.analysisInteraction.preferredInteractionTypes = .textSelection
            }
            guard hasText else { return }
            self.onLoaded?(true)
        }
    }

    func setLiveText(_ enabled: Bool) {
        liveTextRequested = enabled
        analysisInteraction.preferredInteractionTypes = enabled ? .textSelection : []
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if isZoomed {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }
        let point = gesture.location(in: imageView)
        let scale = min(scrollView.maximumZoomScale, 3)
        let size = CGSize(
            width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
        scrollView.zoom(
            to: CGRect(
                x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width,
                height: size.height),
            animated: true)
    }
}

extension ImagePageCell: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }
}

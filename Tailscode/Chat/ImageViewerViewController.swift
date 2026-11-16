import CodingAgentKit
import TailscodeCore
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
/// tile that was tapped, swipes across every other image in the chat, zooms to
/// the pixel, lifts text out of a screenshot, and puts the picture in the photo
/// library, the pasteboard, or another app. Closing it, or dragging it down,
/// puts the picture back in the tile it lives in now, which is the tile of the
/// page being shown and not the one that was opened (`PictureFlight`).
final class ImageViewerViewController: UIViewController {
    private let items: [GalleryImage]
    /// The server the pictures are fetched from, where they came from one. A picture this device
    /// made itself is already on disk, so the studio opens the same viewer with nothing behind it.
    private let backend: (any CodingAgentBackend)?
    /// Where a picture of the conversation stands right now, asked each time it matters.
    private let homes: ((String) -> PictureHome?)?
    /// The tile whose picture is in the viewer, and so is not drawn in the chat.
    private weak var outView: UIView?
    /// The page the flown tile's pixels are still standing in front of, while its own load.
    private var posterIndex: Int?
    private var index: Int

    private let backdrop = UIView()
    private let collectionView: UICollectionView
    private var pagerBottom: NSLayoutConstraint!
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

    /// Where a page's bytes come from when neither the item nor a backend has them: the image
    /// studio's shelf, which fetches from the machine that keeps the picture as each page is
    /// reached rather than downloading the whole shelf to open one.
    typealias Fetch = @Sendable (GalleryImage) async -> Data?

    private let fetch: Fetch?

    init(
        items: [GalleryImage], startIndex: Int, backend: (any CodingAgentBackend)?,
        homes: ((String) -> PictureHome?)? = nil, fetch: Fetch? = nil
    ) {
        self.items = items
        self.index = max(0, min(startIndex, items.count - 1))
        self.backend = backend
        self.homes = homes
        self.fetch = fetch
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
        collectionView.register(ImagePageCell.self, forCellWithReuseIdentifier: ImagePageCell.reuseID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        transitionView.contentMode = .scaleAspectFill
        transitionView.clipsToBounds = true
        transitionView.layer.cornerCurve = .continuous
        transitionView.isHidden = true
        view.addSubview(transitionView)

        buildChrome()
        backdrop.alpha = 0
        collectionView.alpha = 0
        for bar in chrome { bar.alpha = 0 }

        pagerBottom = collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            pagerBottom,
            collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])

        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag))
        drag.delegate = self
        view.addGestureRecognizer(drag)
        updateChromeContent()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        adaptToFold()
        guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout,
            layout.itemSize != collectionView.bounds.size, collectionView.bounds.width > 0
        else { return }
        layout.itemSize = collectionView.bounds.size
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()
        collectionView.setContentOffset(
            CGPoint(x: CGFloat(index) * collectionView.bounds.width, y: 0), animated: false)
    }

    /// A picture is media and stays off the fold: held open like a book it keeps to the page
    /// before the fold with its controls; held like a laptop it fills the top region, and the
    /// controls stay on the base below.
    private func adaptToFold() {
        let fold = FoldReading.read(in: view)
        keepToPageBeforeFold(fold)
        let wanted = fold.flatMap { $0.isLaptop ? -(view.bounds.height - $0.frame.minY) : nil } ?? 0
        if abs(pagerBottom.constant - wanted) > 0.5 { pagerBottom.constant = wanted }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didAnimateIn else { return }
        didAnimateIn = true
        arrive()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        takeOut(nil)
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
            topBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            topBar.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
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
            bottomBar.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
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
            let velocity = gesture.velocity(in: view)
            if abs(translation.y) > 130 || abs(velocity.y) > 900 {
                dismissViewer(thrownDown: velocity.y >= 0, velocity: velocity)
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


    /// Draws `view` in the chat again and stops drawing the next one: one tile is out at a time,
    /// the one whose picture the viewer is showing.
    private func takeOut(_ view: UIView?) {
        guard outView !== view else { return }
        outView?.alpha = 1
        outView = view
        view?.alpha = 0
    }

    private var currentHome: PictureHome? {
        items.indices.contains(index) ? homes?(items[index].id) : nil
    }

    /// The home of the page being shown and where it is on this screen, while it is in sight.
    private func homeInSight() -> (home: PictureHome, frame: CGRect)? {
        guard let home = currentHome, let frame = home.frame(in: view) else { return nil }
        return (home, frame)
    }

    /// Where a page fits a picture of this size: the page's own arithmetic, so the last frame of
    /// a flight is the first frame of the page.
    private func stage(for size: CGSize) -> CGRect {
        ImagePageCell.fittedFrame(of: size, in: collectionView.bounds.size)
            .offsetBy(dx: collectionView.frame.minX, dy: collectionView.frame.minY)
    }

    /// Opens the picture out of its tile: the tile's own pixels fly to where the page fits them
    /// while the dark and then the bars arrive around it, so nothing waits for a decode and no
    /// frame is black before the motion. With no tile in sight, or with motion reduced, the
    /// viewer appears where it stands.
    private func arrive() {
        view.layoutIfNeeded()
        let reduced = UIAccessibility.isReduceMotionEnabled
        guard !reduced, let start = homeInSight(),
            let picture = start.home.image ?? currentCell?.image
        else {
            appearInPlace(reduced: reduced)
            return
        }
        let target = stage(for: picture.size)
        guard target.width > 0, target.height > 0 else {
            appearInPlace(reduced: reduced)
            return
        }
        transitionView.image = picture
        transitionView.frame = start.frame
        transitionView.layer.cornerRadius = start.home.cornerRadius
        transitionView.alpha = 1
        transitionView.isHidden = false
        collectionView.isHidden = true
        collectionView.alpha = 1
        takeOut(start.home.view)
        let flight = UIViewPropertyAnimator(
            duration: PictureFlight.springDuration,
            timingParameters: UISpringTimingParameters(dampingRatio: PictureFlight.springDamping))
        flight.addAnimations {
            self.transitionView.frame = target
            self.transitionView.layer.cornerRadius = 0
        }
        flight.addCompletion { _ in self.landed() }
        flight.startAnimation()
        surround(arriving: true, over: PictureFlight.springDuration)
    }

    /// The dark and the bars around a flight `length` seconds long, on a straight clock: the dark
    /// is in before the bars begin, and on the way home the bars go first and the dark lifts
    /// across the rest, so the chat the picture is going back to shows while it goes.
    private func surround(arriving: Bool, over length: TimeInterval) {
        let bars: CGFloat = arriving && !chromeHidden ? 1 : 0
        let dark = arriving ? (0, PictureFlight.backdropEnd) : (PictureFlight.backdropHold, 1)
        let words = arriving ? (PictureFlight.chromeStart, 1) : (0, PictureFlight.chromeLeave)
        let fades = UIViewPropertyAnimator(duration: length, curve: .linear)
        fades.addAnimations {
            UIView.animateKeyframes(
                withDuration: length, delay: 0, options: [.calculationModeLinear]
            ) {
                UIView.addKeyframe(
                    withRelativeStartTime: dark.0, relativeDuration: dark.1 - dark.0
                ) { self.backdrop.alpha = arriving ? 1 : 0 }
                UIView.addKeyframe(
                    withRelativeStartTime: words.0, relativeDuration: words.1 - words.0
                ) { for bar in self.chrome { bar.alpha = bars } }
            }
        }
        fades.startAnimation()
    }

    /// The flight is over and the page takes the picture's place. A page still loading keeps the
    /// tile's pixels in front of it until its own arrive, so the picture never turns into a
    /// spinner in the reader's hand.
    private func landed() {
        collectionView.isHidden = false
        guard currentCell?.image == nil else {
            transitionView.isHidden = true
            return
        }
        posterIndex = index
    }

    /// Takes the tile's pixels from in front of a page that has its own now, or that the reader
    /// has started to turn.
    fileprivate func dropPoster() {
        guard posterIndex != nil else { return }
        posterIndex = nil
        transitionView.isHidden = true
    }

    private func appearInPlace(reduced: Bool) {
        takeOut(currentHome?.view)
        collectionView.alpha = 0
        if !reduced {
            let scale = 1 - PictureFlight.fadeShrink
            collectionView.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        UIView.animate(
            withDuration: reduced ? PictureFlight.reducedDuration : PictureFlight.fadeDuration,
            delay: 0, options: [.curveEaseOut]
        ) {
            self.collectionView.alpha = 1
            self.collectionView.transform = .identity
            self.backdrop.alpha = 1
            for bar in self.chrome { bar.alpha = self.chromeHidden ? 0 : 1 }
        }
    }

    /// Puts the picture back in the tile it lives in now, carrying the finger's speed when a drag
    /// let go of it. With no tile in sight there is nowhere honest to put it: it fades where it
    /// stands, and one that was thrown keeps its direction as it does.
    fileprivate func dismissViewer(thrownDown: Bool = true, velocity: CGPoint = .zero) {
        guard !isDismissing else { return }
        isDismissing = true
        let pageImage = currentCell?.image
        let standing = posterIndex == index
        let image = pageImage ?? (standing ? transitionView.image : nil)
        let from =
            pageImage != nil
            ? currentCell?.imageFrame(in: view) ?? view.bounds
            : (standing ? transitionView.frame : view.bounds)
        posterIndex = nil
        transitionView.image = image
        transitionView.frame = from
        transitionView.layer.cornerRadius = 0
        transitionView.alpha = 1
        transitionView.isHidden = image == nil
        collectionView.isHidden = true
        let reduced = UIAccessibility.isReduceMotionEnabled
        guard !reduced, image != nil, let home = homeInSight() else {
            leaveInPlace(thrown: velocity == .zero ? nil : thrownDown, reduced: reduced, from: from)
            return
        }
        takeOut(home.home.view)
        let flight = UIViewPropertyAnimator(
            duration: Self.homewardDuration,
            timingParameters: UISpringTimingParameters(
                dampingRatio: Self.homewardDamping,
                initialVelocity: Self.relative(velocity, from: from, to: home.frame)))
        flight.addAnimations {
            self.transitionView.frame = home.frame
            self.transitionView.layer.cornerRadius = home.home.cornerRadius
        }
        flight.addCompletion { _ in
            self.takeOut(nil)
            self.dismiss(animated: false)
        }
        flight.startAnimation()
        surround(arriving: false, over: PictureFlight.closeDuration)
    }

    /// The spring that carries a picture home: a little longer than the fades around it, because
    /// a spring spends its last third settling on the spot.
    private static let homewardDuration: TimeInterval = 0.34
    private static let homewardDamping: CGFloat = 0.9

    /// A finger's speed as the spring wants it: as a share of the way still to go on each axis,
    /// held to what a hand can do so a flick across a short distance does not fling the picture.
    private static func relative(_ velocity: CGPoint, from: CGRect, to: CGRect) -> CGVector {
        func share(_ speed: CGFloat, _ distance: CGFloat) -> CGFloat {
            abs(distance) > 1 ? min(max(speed / distance, -12), 12) : 0
        }
        return CGVector(
            dx: share(velocity.x, to.midX - from.midX), dy: share(velocity.y, to.midY - from.midY))
    }

    private func leaveInPlace(thrown down: Bool?, reduced: Bool, from: CGRect) {
        let length = reduced ? PictureFlight.reducedDuration : (down == nil ? PictureFlight.fadeDuration : 0.3)
        UIView.animate(
            withDuration: length, delay: 0, options: [.curveEaseInOut],
            animations: {
                if let down, !reduced {
                    self.transitionView.frame = from.offsetBy(dx: 0, dy: down ? 420 : -420)
                } else if !reduced {
                    let inset = PictureFlight.fadeShrink / 2
                    self.transitionView.frame = from.insetBy(
                        dx: from.width * inset, dy: from.height * inset)
                }
                self.transitionView.alpha = 0
                self.backdrop.alpha = 0
                for bar in self.chrome { bar.alpha = 0 }
            },
            completion: { _ in
                self.takeOut(nil)
                self.dismiss(animated: false)
            })
    }

    #if DEBUG
        /// Turns to a page and closes, as a hand would, for a launch that films the viewer.
        func stagedTurn(to page: Int) {
            guard items.indices.contains(page), collectionView.bounds.width > 0 else { return }
            dropPoster()
            collectionView.setContentOffset(
                CGPoint(x: CGFloat(page) * collectionView.bounds.width, y: 0), animated: false)
        }

        func stagedClose() { dismissViewer() }
    #endif
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
            if indexPath.item == self.posterIndex { self.dropPoster() }
            guard indexPath.item == self.index else { return }
            self.updateChromeContent()
        }
        cell.configure(items[indexPath.item], backend: backend, fetch: fetch, liveText: liveTextOn)
        return cell
    }
}

extension ImageViewerViewController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView, collectionView.bounds.width > 0, !isDismissing else {
            return
        }
        let page = Int((scrollView.contentOffset.x / collectionView.bounds.width).rounded())
        guard page != index, items.indices.contains(page) else { return }
        index = page
        takeOut(currentHome?.view)
        currentCell?.setLiveText(liveTextOn)
        updateChromeContent()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
        dropPoster()
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
        scrollView.contentInsetAdjustmentBehavior = .scrollableAxes
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

    func configure(
        _ item: GalleryImage, backend: (any CodingAgentBackend)?,
        fetch: ImageViewerViewController.Fetch? = nil, liveText: Bool
    ) {
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
        if let fetch {
            spinner.working(true, spoken: String(localized: "Loading the picture"))
            let token = self.token
            Task { [weak self] in
                let bytes = await fetch(item)
                guard let self, self.token == token else { return }
                self.spinner.working(false)
                guard let bytes, let decoded = UIImage(data: bytes) else {
                    self.failure.text = String(localized: "Couldn't load \(item.filename)")
                    self.failure.isHidden = false
                    return
                }
                AttachmentImageStore.shared.store(decoded, for: item.file, data: bytes)
                self.show(decoded, data: bytes)
            }
            return
        }
        guard let backend else {
            failure.text = String(localized: "Couldn't load \(item.filename)")
            failure.isHidden = false
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

    /// Where a page as large as `bounds` draws a picture of this size at rest.
    static func fittedFrame(of size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let fitted = Self.fitted(size, in: bounds)
        return CGRect(
            x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
            width: fitted.width, height: fitted.height)
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

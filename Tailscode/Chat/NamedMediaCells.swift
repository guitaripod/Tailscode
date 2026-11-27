import AVFoundation
import CodingAgentKit
import TailscodeCore
import UIKit

/// A video an agent named by its path (`MediaMentions`): its first frame in a 16:9 frame at a
/// picture's width, a play mark, its length, and its name under it. A press opens the system
/// player; a long press shares the file. A file that could not be had is one quiet line instead.
final class VideoTileCell: UICollectionViewCell {
    static let reuseID = "VideoTileCell"

    /// The press, and what the cell asks the chat to do with the file.
    var onPlay: ((FileReference) -> Void)?
    var onShare: ((FileReference, UIView) -> Void)?
    var onSaveToPhotos: ((FileReference) -> Void)?
    var onRetry: ((FileReference) -> Void)?
    /// The row's height moved (a file turned out to be missing), so the list measures it again.
    var onResized: (() -> Void)?

    private let frameView = UIView()
    private let poster = UIImageView()
    private let mark = UIImageView(image: UIImage(systemName: "play.fill"))
    private let markBackdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let length = PaddedLabel()
    private let caption = UILabel()
    private let line = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var file: FileReference?
    private var failed: NamedMediaFailure?
    private var listening: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        frameView.backgroundColor = .black
        frameView.layer.cornerRadius = Theme.Radius.bubble
        frameView.layer.cornerCurve = .continuous
        frameView.clipsToBounds = true
        frameView.isAccessibilityElement = true
        frameView.accessibilityTraits = [.button, .startsMediaSession]
        frameView.answersPointer(cornerRadius: Theme.Radius.bubble)
        poster.contentMode = .scaleAspectFit
        mark.tintColor = .white
        mark.contentMode = .scaleAspectFit
        markBackdrop.layer.cornerRadius = 26
        markBackdrop.clipsToBounds = true
        length.font = Theme.Ramp.font(.rowStamp)
        length.textColor = .white
        length.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        length.layer.cornerRadius = 4
        length.clipsToBounds = true
        caption.font = Theme.Ramp.font(.panelFootnote)
        caption.textColor = Theme.Color.secondaryLabel
        caption.lineBreakMode = .byTruncatingMiddle
        line.font = Theme.Ramp.font(.panelFootnote)
        line.textColor = Theme.Color.tertiaryLabel
        line.numberOfLines = 2
        line.isUserInteractionEnabled = true
        spinner.color = .white
        spinner.hidesWhenStopped = true
        for view in [frameView, poster, mark, markBackdrop, length, caption, line, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        let column = UIStackView(arrangedSubviews: [frameView, caption, line])
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = Theme.Spacing.xs
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        frameView.addSubview(poster)
        frameView.addSubview(markBackdrop)
        markBackdrop.contentView.addSubview(mark)
        frameView.addSubview(length)
        frameView.addSubview(spinner)
        let width = frameView.widthAnchor.constraint(
            equalTo: contentView.widthAnchor, multiplier: CGFloat(ImagePreview.share(0.72, mine: false)))
        width.priority = UILayoutPriority(999)
        let frameHeight = frameView.heightAnchor.constraint(
            equalTo: frameView.widthAnchor, multiplier: 9.0 / 16.0)
        frameHeight.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            frameView.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            width,
            frameHeight,
            poster.topAnchor.constraint(equalTo: frameView.topAnchor),
            poster.bottomAnchor.constraint(equalTo: frameView.bottomAnchor),
            poster.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
            poster.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
            markBackdrop.centerXAnchor.constraint(equalTo: frameView.centerXAnchor),
            markBackdrop.centerYAnchor.constraint(equalTo: frameView.centerYAnchor),
            markBackdrop.widthAnchor.constraint(equalToConstant: 52),
            markBackdrop.heightAnchor.constraint(equalToConstant: 52),
            mark.centerXAnchor.constraint(equalTo: markBackdrop.contentView.centerXAnchor, constant: 2),
            mark.centerYAnchor.constraint(equalTo: markBackdrop.contentView.centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: 22),
            mark.heightAnchor.constraint(equalToConstant: 22),
            length.trailingAnchor.constraint(equalTo: frameView.trailingAnchor, constant: -Theme.Spacing.s),
            length.bottomAnchor.constraint(equalTo: frameView.bottomAnchor, constant: -Theme.Spacing.s),
            spinner.centerXAnchor.constraint(equalTo: frameView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: frameView.centerYAnchor),
        ])
        frameView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(play)))
        line.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(retry)))
        frameView.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let listening { NotificationCenter.default.removeObserver(listening) }
        listening = nil
        file = nil
        failed = nil
        poster.image = nil
        onPlay = nil
        onShare = nil
        onSaveToPhotos = nil
        onRetry = nil
        onResized = nil
    }

    /// A clip a reply named that is not on its server: one quiet line, nothing to read.
    func showMissing(_ name: String) {
        if let listening { NotificationCenter.default.removeObserver(listening) }
        listening = nil
        file = nil
        failed = .missing
        line.text = MediaTileReading.missing(name)
        line.isHidden = false
        frameView.isHidden = true
        caption.isHidden = true
    }

    func configure(file: FileReference, backend: (any CodingAgentBackend)?) {
        self.file = file
        let key = NamedMediaStore.key(file)
        if let listening { NotificationCenter.default.removeObserver(listening) }
        listening = NotificationCenter.default.addObserver(
            forName: NamedMediaStore.changed, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.userInfo?[NamedMediaStore.keyInfo] as? String) == key else { return }
            MainActor.assumeIsolated { self?.render() }
        }
        NamedMediaStore.shared.read(file, backend: backend)
        render()
    }

    private func render() {
        guard let file else { return }
        let name = MediaTileReading.name(of: file)
        let state = NamedMediaStore.shared.state(for: file)
        let wasFailed = failed != nil
        if case .failed(let failure)? = state {
            failed = failure
            line.text = MediaTileReading.words(failure, name: name)
            line.isHidden = false
            frameView.isHidden = true
            caption.isHidden = true
            if !wasFailed { onResized?() }
            return
        }
        failed = nil
        line.isHidden = true
        frameView.isHidden = false
        caption.isHidden = false
        if wasFailed { onResized?() }
        switch state {
        case .ready(let ready)?:
            spinner.stopAnimating()
            poster.image = ready.poster.map { UIImage(cgImage: $0) }
            markBackdrop.isHidden = false
            let clock = MediaTileReading.progress(at: nil, of: ready.duration)
            length.text = clock
            length.isHidden = clock == nil
            caption.text = MediaTileReading.caption(name: name, kind: .video, duration: ready.duration)
        default:
            spinner.startAnimating()
            markBackdrop.isHidden = true
            length.isHidden = true
            caption.text = MediaTileReading.caption(name: name, kind: .video, duration: nil)
        }
        frameView.accessibilityLabel = String(localized: "Play \(name)")
    }

    @objc private func play() {
        guard let file, case .ready? = NamedMediaStore.shared.state(for: file) else { return }
        onPlay?(file)
    }

    @objc private func retry() {
        guard let file, failed?.isRetryable == true else { return }
        onRetry?(file)
    }
}

extension VideoTileCell: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let file else { return nil }
        guard case .ready(let ready)? = NamedMediaStore.shared.state(for: file) else { return nil }
        return UIContextMenuConfiguration(
            identifier: nil, previewProvider: { NamedVideoPeek(ready: ready) }
        ) { [weak self] _ in
            let play = UIAction(
                title: String(localized: "Play"), image: UIImage(systemName: "play.fill")
            ) { _ in self?.onPlay?(file) }
            let photos = UIAction(
                title: String(localized: "Save to Photos"), image: UIImage(systemName: "square.and.arrow.down")
            ) { _ in self?.onSaveToPhotos?(file) }
            let share = UIAction(
                title: String(localized: "Share"), image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in
                guard let self else { return }
                self.onShare?(file, self.frameView)
            }
            let path = UIAction(
                title: String(localized: "Copy path"), image: UIImage(systemName: "doc.on.doc")
            ) { _ in UIPasteboard.general.string = ServerFile.path(of: file) ?? file.path }
            return UIMenu(children: [play, photos, share, path])
        }
    }
}

/// A song or a recording an agent named: one slim line that plays where it is — a play button, its
/// name, where it is against its length and a thin bar. One plays at a time (`NamedMediaStore`).
final class AudioLineCell: UICollectionViewCell {
    static let reuseID = "AudioLineCell"

    var onRetry: ((FileReference) -> Void)?
    var onResized: (() -> Void)?

    private let card = UIView()
    private let button = UIButton(type: .system)
    private let title = UILabel()
    private let detail = UILabel()
    private let bar = UISlider()
    private let line = UILabel()
    private var file: FileReference?
    private var failed: NamedMediaFailure?
    private var listening: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.backgroundColor = Theme.Color.assistantBubble
        card.layer.cornerRadius = Theme.Radius.bubble
        card.layer.cornerCurve = .continuous
        button.tintColor = Theme.Color.accent
        button.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        title.font = Theme.Ramp.font(.rowTitle)
        title.textColor = Theme.Color.label
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = Theme.Ramp.font(.rowStamp)
        detail.textColor = Theme.Color.secondaryLabel
        bar.maximumTrackTintColor = Theme.Color.tertiaryLabel.withAlphaComponent(0.3)
        bar.minimumTrackTintColor = Theme.Color.accent
        bar.setThumbImage(Self.thumb, for: .normal)
        bar.addTarget(self, action: #selector(seek), for: .valueChanged)
        bar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapBar(_:))))
        line.font = Theme.Ramp.font(.panelFootnote)
        line.textColor = Theme.Color.tertiaryLabel
        line.numberOfLines = 2
        line.isUserInteractionEnabled = true
        let words = UIStackView(arrangedSubviews: [title, detail, bar])
        words.axis = .vertical
        words.spacing = 3
        for view in [card, button, words, line] { view.translatesAutoresizingMaskIntoConstraints = false }
        let column = UIStackView(arrangedSubviews: [card, line])
        column.axis = .vertical
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        card.addSubview(button)
        card.addSubview(words)
        let width = card.widthAnchor.constraint(
            equalTo: contentView.widthAnchor, multiplier: CGFloat(ImagePreview.share(0.72, mine: false)))
        width.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            width,
            button.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Spacing.s),
            button.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
            words.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: Theme.Spacing.s),
            words.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.Spacing.m),
            words.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Spacing.s),
            words.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.Spacing.s),
        ])
        line.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(retry)))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let listening { NotificationCenter.default.removeObserver(listening) }
        listening = nil
        file = nil
        failed = nil
        onRetry = nil
        onResized = nil
    }

    func configure(file: FileReference, backend: (any CodingAgentBackend)?) {
        self.file = file
        let key = NamedMediaStore.key(file)
        if let listening { NotificationCenter.default.removeObserver(listening) }
        listening = NotificationCenter.default.addObserver(
            forName: NamedMediaStore.changed, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.userInfo?[NamedMediaStore.keyInfo] as? String) == key else { return }
            MainActor.assumeIsolated { self?.render() }
        }
        NamedMediaStore.shared.read(file, backend: backend)
        render()
    }

    private func render() {
        guard let file else { return }
        let store = NamedMediaStore.shared
        let name = MediaTileReading.name(of: file)
        let state = store.state(for: file)
        let wasFailed = failed != nil
        if case .failed(let failure)? = state {
            failed = failure
            line.text = MediaTileReading.words(failure, name: name)
            line.isHidden = false
            card.isHidden = true
            if !wasFailed { onResized?() }
            return
        }
        failed = nil
        line.isHidden = true
        card.isHidden = false
        if wasFailed { onResized?() }
        title.text = name
        let playing = store.playingKey == NamedMediaStore.key(file)
        let running = playing && !store.isPaused
        let symbol = running ? "pause.circle.fill" : "play.circle.fill"
        button.setImage(
            UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 30)),
            for: .normal)
        button.accessibilityLabel = running ? String(localized: "Pause \(name)") : String(localized: "Play \(name)")
        guard case .ready(let ready)? = state else {
            button.isEnabled = false
            detail.text = String(localized: "Loading…")
            bar.value = 0
            bar.isEnabled = false
            return
        }
        button.isEnabled = true
        bar.isEnabled = ready.duration != nil
        let position = playing ? store.position : nil
        detail.text = MediaTileReading.progress(at: position, of: ready.duration)
            ?? MediaTileReading.kindWord(.audio)
        if !bar.isTracking {
            bar.value = Float(MediaTileReading.fraction(at: position, of: ready.duration))
        }
    }

    @objc private func toggle() {
        guard let file else { return }
        NamedMediaStore.shared.toggle(file)
    }

    /// A hand on the bar: the song moves there, or starts there when it was not playing.
    @objc private func seek() {
        guard let file else { return }
        NamedMediaStore.shared.toggle(file, at: Double(bar.value))
    }

    /// A tap on the bar's track goes there, as on any player's: a slider alone moves only by its thumb.
    @objc private func tapBar(_ tap: UITapGestureRecognizer) {
        guard bar.isEnabled, bar.bounds.width > 0 else { return }
        let track = bar.trackRect(forBounds: bar.bounds)
        let x = tap.location(in: bar).x
        let fraction = min(1, max(0, (x - track.minX) / max(1, track.width)))
        bar.value = Float(fraction)
        seek()
    }

    /// A small round thumb, so the bar reads as a song's place rather than a settings slider.
    private static let thumb: UIImage = {
        let size = CGSize(width: 14, height: 14)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)).fill()
        }
    }()

    @objc private func retry() {
        guard let file, failed?.isRetryable == true else { return }
        onRetry?(file)
    }
}


/// What a long press on a named video shows above its menu: the clip itself, playing silently and
/// over again at its own shape.
final class NamedVideoPeek: UIViewController {
    private let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    private let aspect: Double

    init(ready: NamedMediaStore.Ready) {
        let item = AVPlayerItem(url: ready.source)
        player = AVQueuePlayer()
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: item)
        aspect = ready.aspect ?? 16.0 / 9.0
        super.init(nibName: nil, bundle: nil)
        let width: CGFloat = 320
        preferredContentSize = CGSize(width: width, height: (width / aspect).rounded())
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = PeekView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        self.view = view
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        player.play()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        player.pause()
    }

    private final class PeekView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

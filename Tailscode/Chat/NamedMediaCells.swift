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
        guard let file, case .ready? = NamedMediaStore.shared.state(for: file) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let play = UIAction(
                title: String(localized: "Play"), image: UIImage(systemName: "play.fill")
            ) { _ in self?.onPlay?(file) }
            let share = UIAction(
                title: String(localized: "Share"), image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in
                guard let self else { return }
                self.onShare?(file, self.frameView)
            }
            return UIMenu(children: [play, share])
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
    private let bar = UIProgressView(progressViewStyle: .bar)
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
        bar.trackTintColor = Theme.Color.tertiaryLabel.withAlphaComponent(0.3)
        bar.progressTintColor = Theme.Color.accent
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
            bar.progress = 0
            return
        }
        button.isEnabled = true
        let position = playing ? store.position : nil
        detail.text = MediaTileReading.progress(at: position, of: ready.duration)
            ?? MediaTileReading.kindWord(.audio)
        bar.progress = Float(MediaTileReading.fraction(at: position, of: ready.duration))
    }

    @objc private func toggle() {
        guard let file else { return }
        NamedMediaStore.shared.toggle(file)
    }

    @objc private func retry() {
        guard let file, failed?.isRetryable == true else { return }
        onRetry?(file)
    }
}

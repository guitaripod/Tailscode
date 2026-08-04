import AVFoundation
import AVKit
import AppKit
import TailscodeCore

/// A stream living inside the split tree. The Mac plays through AVKit rather than embedding a
/// player process — a foreign process cannot draw into this app's view — so the page is resolved
/// to a stream first and handed to `AVPlayer`, which the pane then owns like any other subview:
/// the dividers resize it, zoom hides its siblings, and closing the pane hands the space back.
@MainActor
final class VideoSlotView: NSView {
    private(set) var slot: VideoSlot
    private let playerView = AVPlayerView()
    private let promptStack = NSStackView()
    private let field = NSTextField()
    private let headingLabel = NSTextField(labelWithString: Localized.text("Watch"))
    private let reasonLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var resolving: Task<Void, Never>?

    /// Told to the pane whenever the slot changes what it says about itself, so the identity strip
    /// and the persisted layout follow the stream rather than lag a state behind.
    var onChange: (() -> Void)?

    init(target: VideoTarget?) {
        slot = VideoSlot(target: target)
        super.init(frame: .zero)
        build()
        if let target {
            point(at: target)
        } else {
            render()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.isHidden = true
        addSubview(playerView)

        headingLabel.font = MacTheme.Font.emphasis()
        reasonLabel.font = MacTheme.Font.caption()
        reasonLabel.textColor = MacTheme.Color.secondaryLabel
        hintLabel.font = MacTheme.Font.caption()
        hintLabel.textColor = MacTheme.Color.secondaryLabel
        hintLabel.stringValue = slot.hint

        field.placeholderString = slot.prompt
        field.font = MacTheme.Font.body()
        field.target = self
        field.action = #selector(submit)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 320).isActive = true

        noticeLabel.font = MacTheme.Font.caption()
        noticeLabel.textColor = MacTheme.Color.secondaryLabel
        noticeLabel.alignment = .center
        noticeLabel.isSelectable = false
        noticeLabel.stringValue = slot.notice
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        noticeLabel.widthAnchor.constraint(equalToConstant: 320).isActive = true

        promptStack.orientation = .vertical
        promptStack.alignment = .centerX
        promptStack.spacing = MacTheme.Spacing.m
        promptStack.translatesAutoresizingMaskIntoConstraints = false
        promptStack.setViews(
            [headingLabel, field, reasonLabel, hintLabel, Self.noticeCard(around: noticeLabel)],
            in: .center)
        addSubview(promptStack)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            promptStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            promptStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// The tinted card the split-cost notice sits in. Content rather than chrome, so it is a plain
    /// rounded fill on the opaque canvas and never glass — prose does not sit on glass.
    private static func noticeCard(around content: NSView) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = MacTheme.Radius.card
        card.layer?.backgroundColor = MacTheme.Color.accent.withAlphaComponent(0.10).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = MacTheme.Color.accent.withAlphaComponent(0.30).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(
                equalTo: card.leadingAnchor, constant: MacTheme.Spacing.m),
            content.trailingAnchor.constraint(
                equalTo: card.trailingAnchor, constant: -MacTheme.Spacing.m),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: MacTheme.Spacing.s),
            content.bottomAnchor.constraint(
                equalTo: card.bottomAnchor, constant: -MacTheme.Spacing.s),
        ])
        return card
    }

    var target: VideoTarget? { slot.target }
    var isAsking: Bool { slot.isAsking }

    /// One line for the headless selftest: the phase, then what the slot is showing.
    var summary: String {
        let phase: String
        switch slot.phase {
        case .asking: phase = "asking"
        case .loading: phase = "loading"
        case .playing: phase = "playing"
        case .failed: phase = "failed"
        }
        return "\(phase) \(slot.target?.address ?? "-") [\(slot.title)] \(slot.subtitle)"
    }

    func focusPrompt() {
        window?.makeFirstResponder(field)
    }

    @objc private func submit() {
        guard let target = VideoTarget.classify(field.stringValue) else { return }
        point(at: target)
    }

    func point(at target: VideoTarget) {
        slot.point(at: target)
        render()
        resolving?.cancel()
        resolving = Task { [weak self] in
            let outcome = await Self.resolve(target)
            guard !Task.isCancelled else { return }
            self?.finish(outcome)
        }
    }

    private static func resolve(_ target: VideoTarget) async -> Result<URL, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                return .success(try VideoResolver.directURL(for: target))
            } catch {
                return .failure(error)
            }
        }.value
    }

    private func finish(_ outcome: Result<URL, Error>) {
        switch outcome {
        case .success(let url):
            play(url)
        case .failure(let error):
            slot.failed("\(error)")
            render()
        }
    }

    private func play(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = slot.muted
        playerView.player = player
        self.player = player
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.slot.loaded(title: nil)
                case .failed:
                    self.slot.failed(
                        item.error?.localizedDescription ?? Localized.text("That would not play"))
                default:
                    return
                }
                self.render()
            }
        }
        player.play()
    }

    /// Back to the question with the old target in the box — a mistyped channel is a correction,
    /// not a retype.
    func ask() {
        slot.ask()
        field.stringValue = slot.draft
        stop()
        render()
        focusPrompt()
    }

    func handle(_ command: VideoCommand) {
        guard command != .change else {
            ask()
            return
        }
        guard let player, !slot.isAsking else { return }
        switch command {
        case .playPause:
            slot.paused.toggle()
            slot.paused ? player.pause() : player.play()
        case .mute:
            slot.muted.toggle()
            player.isMuted = slot.muted
        case .volumeUp:
            player.volume = min(1, player.volume + 0.05)
        case .volumeDown:
            player.volume = max(0, player.volume - 0.05)
        case .seekBack, .seekForward:
            let delta = command == .seekBack ? -10.0 : 10.0
            let time = player.currentTime() + CMTime(seconds: delta, preferredTimescale: 600)
            player.seek(to: time)
        case .reload:
            if let target = slot.target { point(at: target) }
        case .change:
            return
        }
        render()
    }

    func shutdown() {
        resolving?.cancel()
        resolving = nil
        stop()
    }

    private func stop() {
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player = nil
        playerView.player = nil
    }

    private func render() {
        let showing = !slot.isAsking
        var failed = false
        if case .failed(let reason) = slot.phase {
            failed = true
            reasonLabel.stringValue = reason
        }
        reasonLabel.isHidden = !failed
        playerView.isHidden = !showing || failed
        promptStack.isHidden = showing && !failed
        hintLabel.stringValue = slot.hint
        onChange?()
    }
}

import AppKit
import CodingAgentKit
import TailscodeCore

/// The rows a video or a song an agent named stands as (`MediaMentions`): a video is its first frame
/// at a picture's size with a play mark, opened in the viewer's clip player; a song is one slim line
/// that plays where it is. A row is built from `NamedMediaStore` and rebuilt by the transcript when
/// what it is changes; a playing song's line moves in place.
@MainActor
enum NamedMediaRowView {
    static let frameWidth: CGFloat = 360

    static func make(
        _ reference: FileReference, kind: MediaKind, key: String, context: TranscriptContext
    ) -> NSView {
        let store = NamedMediaStore.shared
        let name = MediaTileReading.name(of: reference)
        let state = store.state(for: reference)
        if state == nil { context.requestMedia?(reference, false) }
        if case .failed(let failure)? = state {
            return failed(failure, name: name, reference: reference, context: context)
        }
        var ready: NamedMediaStore.Ready?
        if case .ready(let held)? = state { ready = held }
        switch kind {
        case .audio:
            return AudioLine(reference: reference, name: name, ready: ready)
        default:
            return video(reference, name: name, ready: ready, context: context)
        }
    }

    private static func video(
        _ reference: FileReference, name: String, ready: NamedMediaStore.Ready?,
        context: TranscriptContext
    ) -> NSView {
        let height = (frameWidth * 9 / 16).rounded()
        let stage = ClipStage(cornerRadius: CGFloat(ChatChrome.Radius.control), fill: .black)
        stage.setContentHuggingPriority(.required, for: .horizontal)
        let poster = NSImageView()
        poster.imageScaling = .scaleProportionallyUpOrDown
        poster.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(poster)
        NSLayoutConstraint.activate([
            stage.widthAnchor.constraint(equalToConstant: frameWidth),
            stage.heightAnchor.constraint(equalToConstant: height),
            poster.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            poster.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            poster.topAnchor.constraint(equalTo: stage.topAnchor),
            poster.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
        ])
        if let ready {
            if let frame = ready.poster {
                poster.image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
            }
            let mark = NSImageView(
                image: NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil) ?? NSImage())
            mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
                .applying(.init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.55)]))
            mark.translatesAutoresizingMaskIntoConstraints = false
            stage.addSubview(mark)
            NSLayoutConstraint.activate([
                mark.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
                mark.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            ])
            if let clock = MediaTileReading.progress(at: nil, of: ready.duration) {
                let chip = RowKit.label(clock, font: MacTheme.Ramp.font(.rowStamp), color: .white)
                chip.translatesAutoresizingMaskIntoConstraints = false
                let plate = GroundView(cornerRadius: 4, fill: NSColor.black.withAlphaComponent(0.6))
                plate.addSubview(chip)
                stage.addSubview(plate)
                NSLayoutConstraint.activate([
                    chip.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 5),
                    chip.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -5),
                    chip.topAnchor.constraint(equalTo: plate.topAnchor, constant: 1),
                    chip.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -1),
                    plate.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -8),
                    plate.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -8),
                ])
            }
            let play = context.playMedia
            stage.onPress = { play?(reference) }
            let share = context.shareMedia
            stage.menuItems = {
                [
                    ClosureMenuItem(title: Localized.text("Play")) { play?(reference) },
                    ClosureMenuItem(title: Localized.text("Share…")) { share?(reference, stage) },
                ]
            }
            stage.setAccessibilityRole(.button)
            stage.setAccessibilityLabel(Localized.text("Play %@", name))
            stage.toolTip = name
        } else {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimation(nil)
            stage.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            ])
        }
        let caption = RowKit.label(
            MediaTileReading.caption(name: name, kind: .video, duration: ready?.duration),
            font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel)
        caption.lineBreakMode = .byTruncatingMiddle
        let column = NSStackView(views: [stage, caption])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        caption.widthAnchor.constraint(lessThanOrEqualToConstant: frameWidth).isActive = true
        return column
    }

    private static func failed(
        _ failure: NamedMediaFailure, name: String, reference: FileReference,
        context: TranscriptContext
    ) -> NSView {
        let line = RowKit.label(
            MediaTileReading.words(failure, name: name), font: MacTheme.Ramp.font(.panelFootnote),
            color: MacTheme.Color.tertiaryLabel)
        guard failure.isRetryable else { return line }
        let request = context.requestMedia
        let press = ClipStage(cornerRadius: 0, fill: .clear)
        line.translatesAutoresizingMaskIntoConstraints = false
        press.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: press.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: press.trailingAnchor),
            line.topAnchor.constraint(equalTo: press.topAnchor),
            line.bottomAnchor.constraint(equalTo: press.bottomAnchor),
        ])
        press.onPress = { request?(reference, true) }
        press.setAccessibilityRole(.button)
        press.setAccessibilityLabel(line.stringValue)
        return press
    }

    /// A video's frame that opens on a click, on Space or Return under Full Keyboard Access, and on a
    /// right click offers Play and Share.
    final class ClipStage: NSView {
        var onPress: (() -> Void)?
        var menuItems: (() -> [NSMenuItem])?

        init(cornerRadius: CGFloat, fill: NSColor) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            layer?.cornerRadius = cornerRadius
            layer?.masksToBounds = true
            layer?.backgroundColor = fill.cgColor
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
        override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseUp(with event: NSEvent) {
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            onPress?()
        }

        override func keyDown(with event: NSEvent) {
            if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
                onPress?()
            } else {
                super.keyDown(with: event)
            }
        }

        override func accessibilityPerformPress() -> Bool {
            onPress?()
            return onPress != nil
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let items = menuItems?(), !items.isEmpty else { return nil }
            let menu = NSMenu()
            items.forEach(menu.addItem)
            return menu
        }

        override func resetCursorRects() {
            if onPress != nil { addCursorRect(bounds, cursor: .pointingHand) }
        }
    }

    /// A song as one line that keeps itself current while it plays: the button, the name, where it
    /// is against its length, and a thin bar.
    final class AudioLine: NSView {
        private let reference: FileReference
        private let ready: NamedMediaStore.Ready?
        private let button = NSButton()
        private let detail: NSTextField
        private let bar = NSProgressIndicator()
        private var listening: NSObjectProtocol?

        init(reference: FileReference, name: String, ready: NamedMediaStore.Ready?) {
            self.reference = reference
            self.ready = ready
            detail = RowKit.label("", font: MacTheme.Ramp.font(.rowStamp), color: MacTheme.Color.secondaryLabel)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            let ground = GroundView(
                cornerRadius: CGFloat(ChatChrome.Radius.control), fill: MacTheme.Color.canvasRaised)
            addSubview(ground)
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageOnly
            button.contentTintColor = MacTheme.Color.accent
            button.target = self
            button.action = #selector(toggle)
            button.isEnabled = ready != nil
            let title = RowKit.label(name, font: MacTheme.Ramp.font(.rowTitle), color: MacTheme.Color.label)
            title.lineBreakMode = .byTruncatingMiddle
            bar.style = .bar
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.controlSize = .small
            let words = NSStackView(views: [title, detail, bar])
            words.orientation = .vertical
            words.alignment = .leading
            words.spacing = 2
            for view in [button, words] {
                view.translatesAutoresizingMaskIntoConstraints = false
                ground.addSubview(view)
            }
            NSLayoutConstraint.activate([
                ground.leadingAnchor.constraint(equalTo: leadingAnchor),
                ground.topAnchor.constraint(equalTo: topAnchor),
                ground.bottomAnchor.constraint(equalTo: bottomAnchor),
                ground.widthAnchor.constraint(equalToConstant: NamedMediaRowView.frameWidth),
                ground.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                button.leadingAnchor.constraint(equalTo: ground.leadingAnchor, constant: 8),
                button.centerYAnchor.constraint(equalTo: ground.centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 32),
                button.heightAnchor.constraint(equalToConstant: 32),
                words.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 8),
                words.trailingAnchor.constraint(equalTo: ground.trailingAnchor, constant: -12),
                words.topAnchor.constraint(equalTo: ground.topAnchor, constant: 8),
                words.bottomAnchor.constraint(equalTo: ground.bottomAnchor, constant: -8),
                bar.widthAnchor.constraint(equalTo: words.widthAnchor),
            ])
            let key = NamedMediaStore.key(reference)
            listening = NotificationCenter.default.addObserver(
                forName: NamedMediaStore.changed, object: nil, queue: .main
            ) { [weak self] note in
                guard (note.userInfo?[NamedMediaStore.keyInfo] as? String) == key else { return }
                MainActor.assumeIsolated { self?.refresh() }
            }
            refresh()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        isolated deinit {
            if let listening { NotificationCenter.default.removeObserver(listening) }
        }

        private func refresh() {
            let store = NamedMediaStore.shared
            let name = MediaTileReading.name(of: reference)
            let playing = store.playingKey == NamedMediaStore.key(reference)
            let running = playing && !store.isPaused
            button.image = NSImage(
                systemSymbolName: running ? "pause.circle.fill" : "play.circle.fill",
                accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 26, weight: .regular))
            button.setAccessibilityLabel(
                running ? Localized.text("Pause %@", name) : Localized.text("Play %@", name))
            guard let ready else {
                detail.stringValue = Localized.text("Loading…")
                bar.doubleValue = 0
                return
            }
            let position = playing ? store.position : nil
            detail.stringValue =
                MediaTileReading.progress(at: position, of: ready.duration)
                ?? MediaTileReading.kindWord(.audio)
            bar.doubleValue = MediaTileReading.fraction(at: position, of: ready.duration)
        }

        @objc private func toggle() {
            NamedMediaStore.shared.toggle(reference)
        }
    }
}

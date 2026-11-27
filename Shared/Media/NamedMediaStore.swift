import AVFoundation
import CodingAgentKit
import CoreGraphics
import Foundation
import MediaPlayer
import MidgarCore
import TailscodeCore

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// The videos and songs a transcript names (`MediaMentions`), as this Apple device knows them:
/// where each plays from, how long it is, a video's first frame, and the one song playing.
///
/// A file is read once: a bridge hands a ticket URL AVPlayer streams and seeks in, converting a
/// WebM, a Matroska or an Ogg into a copy AVFoundation reads; a server without tickets has the
/// whole file streamed into Caches first. Cells are reused all the time, so nothing lives in one:
/// a cell reads its state here and listens for `changed`.
///
/// The song playing is the system's as much as the chat's, as a music app's is (Flaccy): it plays on
/// with the screen locked, stands on the lock screen and in Control Center with its name, length
/// and place, answers headphone buttons and the lock screen's scrubber, pauses for a call and comes
/// back after it, and pauses when headphones are pulled out.
@MainActor
final class NamedMediaStore {
    static let shared = NamedMediaStore()

    /// Posted with the changed file's key under `keyInfo` whenever what a row reads moved.
    static let changed = Notification.Name("NamedMediaStore.changed")
    static let keyInfo = "key"

    enum State {
        case reading
        case ready(Ready)
        case failed(NamedMediaFailure)
    }

    struct Ready {
        let source: URL
        let duration: Double?
        let poster: CGImage?
        /// The video's width over its height, as it is shown.
        let aspect: Double?
        /// The type of what plays, which for a converted copy is the copy's.
        var mime: String? = nil
    }

    /// The name a file is handed on under: its own, or for a copy the bridge converted (a WebM
    /// played as an MP4) its own name with the copy's extension, since Photos and the apps a share
    /// sheet offers read a file by what it says it is.
    static func exportName(of file: FileReference, ready: Ready) -> String {
        let name = MediaTileReading.name(of: file)
        guard !MediaKind.playsOnApple(path: name), let mime = ready.mime else { return name }
        let ext = Self.ext(of: mime)
        guard ext != "bin" else { return name }
        let stem = name.split(separator: ".", omittingEmptySubsequences: false).dropLast().joined(separator: ".")
        return (stem.isEmpty ? name : stem) + "." + ext
    }

    nonisolated static func key(_ file: FileReference) -> String { file.url ?? file.path ?? "" }

    private var states: [String: State] = [:]

    private(set) var player: AVPlayer?
    private(set) var playingKey: String?
    private var playingName = ""
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var systemObservers: [NSObjectProtocol] = []
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var resumeAfterInterruption = false

    func state(for file: FileReference) -> State? { states[Self.key(file)] }

    /// Finds out what a named file is, once: asking again for a file already read, or being read,
    /// costs nothing, so every configure of every cell may ask. `force` reads a failed one again.
    func read(_ file: FileReference, backend: (any CodingAgentBackend)?, force: Bool = false) {
        let key = Self.key(file)
        if let known = states[key] {
            guard force, case .failed = known else { return }
        }
        guard let backend, let kind = MediaKind.of(file), kind != .picture else { return }
        states[key] = .reading
        if force { announce(key) }
        Task { [weak self] in
            let outcome = await Self.resolve(file, kind: kind, backend: backend)
            if case .failure(.missing) = outcome { MediaMisses.note(file) }
            guard let self else { return }
            switch outcome {
            case .success(let ready): self.states[key] = .ready(ready)
            case .failure(let failure): self.states[key] = .failed(failure)
            }
            self.announce(key)
        }
    }

    /// A file whose source stopped answering (a ticket the bridge forgot when it restarted) is read
    /// again from the start.
    func forget(_ file: FileReference) {
        let key = Self.key(file)
        if playingKey == key { stop() }
        states[key] = nil
        announce(key)
    }

    private func announce(_ key: String) {
        NotificationCenter.default.post(name: Self.changed, object: self, userInfo: [Self.keyInfo: key])
    }

    /// Where a file plays from, its length and a video's first frame.
    nonisolated private static func resolve(
        _ file: FileReference, kind: MediaKind, backend: any CodingAgentBackend
    ) async -> Result<Ready, NamedMediaFailure> {
        let path = ServerFile.path(of: file) ?? file.path ?? file.filename ?? ""
        let clock = ContinuousClock()
        let began = clock.now
        let source: URL
        var servedMime: String?
        do {
            if let streaming = backend as? any MediaStreamingBackend,
                let stream = try await streaming.mediaStream(for: file, playback: .apple)
            {
                let served = stream.mime.map { MediaKind.playsOnApple(path: "x." + Self.ext(of: $0)) }
                guard served ?? MediaKind.playsOnApple(path: path) else { return .failure(.unplayable) }
                source = stream.url
                servedMime = stream.mime
            } else {
                guard MediaKind.playsOnApple(path: path) else { return .failure(.unplayable) }
                source = try await cached(file, path: path, backend: backend)
            }
        } catch {
            MidgarLog.info("named media unavailable: \(error)", category: .ui)
            return .failure(MediaTileReading.failure(error))
        }
        let located = clock.now - began
        let asset = AVURLAsset(url: source)
        guard (try? await asset.load(.isPlayable)) == true else { return .failure(.unplayable) }
        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
        let duration = seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard kind == .video else {
            return .success(
                Ready(source: source, duration: duration, poster: nil, aspect: nil, mime: servedMime))
        }
        let opened = clock.now - began
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let at = CMTime(seconds: min((duration ?? 0) * 0.1, 3), preferredTimescale: 600)
        let poster = try? await generator.image(at: at).image
        let aspect = poster.map { Double($0.width) / Double(max(1, $0.height)) }
        MidgarLog.info(
            "named video read: located \(located), opened \(opened), frame \(clock.now - began)",
            category: .performance)
        return .success(
            Ready(source: source, duration: duration, poster: poster, aspect: aspect, mime: servedMime))
    }

    /// The extension a type is written with, for asking whether Apple's players read it.
    nonisolated static func ext(of mime: String) -> String {
        switch mime.lowercased().split(separator: ";").first.map(String.init) ?? "" {
        case "video/mp4": "mp4"
        case "video/quicktime": "mov"
        case "video/x-m4v": "m4v"
        case "audio/mp4", "audio/x-m4a": "m4a"
        case "audio/mpeg": "mp3"
        case "audio/aac": "aac"
        case "audio/wav", "audio/x-wav": "wav"
        case "audio/flac": "flac"
        case "audio/aiff", "audio/x-aiff": "aiff"
        default: "bin"
        }
    }

    /// The whole file in Caches, streamed there, for a server that hands out no tickets.
    nonisolated private static func cached(
        _ file: FileReference, path: String, backend: any CodingAgentBackend
    ) async throws -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("named-media", isDirectory: true)
        let ext = path.split(separator: ".").last.map { String($0).lowercased() } ?? "bin"
        let target = directory.appendingPathComponent(stem(key(file)) + "." + ext)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        try await backend.fetchFile(file, to: target)
        return target
    }

    /// FNV-1a over the file's key, which carries its path and the message that named it.
    nonisolated private static func stem(_ key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Drops what servers without tickets left in Caches more than three days ago.
    nonisolated static func prune() {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("named-media", isDirectory: true)
        let cutoff = Date().addingTimeInterval(-3 * 86400)
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    var isPaused: Bool { (player?.rate ?? 0) == 0 }

    /// Where the playing song is, in seconds.
    var position: Double? {
        guard let player else { return nil }
        let seconds = CMTimeGetSeconds(player.currentTime())
        return seconds.isFinite ? seconds : nil
    }

    private var playingDuration: Double? {
        guard let key = playingKey, case .ready(let ready)? = states[key] else { return nil }
        return ready.duration
    }

    /// Plays a row's song, pauses it when it is the one playing, and stops whatever else was.
    /// `at` starts it at, or moves it to, a fraction of its length: a hand on its bar.
    func toggle(_ file: FileReference, at fraction: Double? = nil) {
        let key = Self.key(file)
        guard case .ready(let ready)? = states[key] else { return }
        if playingKey == key, let player {
            if let fraction, let duration = ready.duration {
                seek(to: fraction * duration)
                return
            }
            if player.rate == 0 {
                if let duration = ready.duration, let position, position >= duration - 0.25 {
                    player.seek(to: .zero)
                }
                player.play()
            } else {
                player.pause()
            }
            publishNowPlaying()
            announce(key)
            return
        }
        stop()
        let item = AVPlayerItem(url: ready.source)
        let player = AVPlayer(playerItem: item)
        self.player = player
        playingKey = key
        playingName = MediaTileReading.name(of: file)
        let start = fraction.flatMap { part in ready.duration.map { part * $0 } }
            ?? MediaPlayhead.start(for: key)
        if let start, start > 0 {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let key = self.playingKey else { return }
                self.announce(key)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let key = self.playingKey else { return }
                MediaPlayhead.keep(0, of: nil, for: key)
                self.stop(keeping: false)
            }
        }
        becomeSystemPlayer()
        player.play()
        publishNowPlaying()
        announce(key)
    }

    func seek(to seconds: Double) {
        guard let player, let key = playingKey else { return }
        let target = max(0, min(playingDuration ?? seconds, seconds))
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishNowPlaying()
                self?.announce(key)
            }
        }
    }

    /// Stops the song, for another row's or for a chat closing; where it was is kept unless it ran
    /// to its end.
    func stop(keeping: Bool = true) {
        guard let player else { return }
        if keeping, let key = playingKey, let position {
            MediaPlayhead.keep(position, of: playingDuration, for: key)
        }
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        self.player = nil
        let was = playingKey
        playingKey = nil
        leaveSystemPlayer()
        if let was { announce(was) }
    }

    /// The song becomes the device's: audible with the ring switch off and the screen locked, on
    /// the lock screen and in Control Center, under the headphones' buttons.
    private func becomeSystemPlayer() {
        #if os(iOS)
            ClipAudio.makeAudible()
            let center = NotificationCenter.default
            systemObservers = [
                center.addObserver(
                    forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
                ) { [weak self] note in
                    let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                        .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                    let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map(AVAudioSession.InterruptionOptions.init(rawValue:))
                    MainActor.assumeIsolated { self?.interrupted(type, options: options) }
                },
                center.addObserver(
                    forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
                ) { [weak self] note in
                    let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                        .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                    guard reason == .oldDeviceUnavailable else { return }
                    MainActor.assumeIsolated { self?.pauseForTheDevice() }
                },
            ]
        #endif
        let commands = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ act: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { event in
                MainActor.assumeIsolated { act(event) }
                return .success
            }
            commandTargets.append((command, target))
        }
        on(commands.playCommand) { [weak self] _ in self?.resume() }
        on(commands.pauseCommand) { [weak self] _ in self?.pause() }
        on(commands.togglePlayPauseCommand) { [weak self] _ in
            guard let self else { return }
            if self.isPaused { self.resume() } else { self.pause() }
        }
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.preferredIntervals = [15]
        on(commands.skipForwardCommand) { [weak self] _ in self?.skip(by: 15) }
        on(commands.skipBackwardCommand) { [weak self] _ in self?.skip(by: -15) }
        on(commands.changePlaybackPositionCommand) { [weak self] event in
            guard let change = event as? MPChangePlaybackPositionCommandEvent else { return }
            self?.seek(to: change.positionTime)
        }
    }

    private func leaveSystemPlayer() {
        for observer in systemObservers { NotificationCenter.default.removeObserver(observer) }
        systemObservers = []
        for (command, target) in commandTargets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        commandTargets = []
        resumeAfterInterruption = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    private func resume() {
        guard let player, let key = playingKey else { return }
        player.play()
        publishNowPlaying()
        announce(key)
    }

    private func pause() {
        guard let player, let key = playingKey else { return }
        player.pause()
        publishNowPlaying()
        announce(key)
    }

    private func skip(by seconds: Double) {
        guard let position else { return }
        seek(to: position + seconds)
    }

    #if os(iOS)
        /// A call or another app's sound pauses the song; it plays on after if the system says to.
        private func interrupted(
            _ type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions?
        ) {
            switch type {
            case .began?:
                resumeAfterInterruption = !isPaused
                pause()
            case .ended?:
                if resumeAfterInterruption, options?.contains(.shouldResume) == true { resume() }
                resumeAfterInterruption = false
            default:
                break
            }
        }

        /// Headphones pulled out pause the song rather than play it out loud.
        private func pauseForTheDevice() {
            pause()
        }
    #endif

    /// What the lock screen and Control Center say about the song.
    private func publishNowPlaying() {
        guard let player else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: playingName,
            MPMediaItemPropertyArtist: "Tailscode",
            MPNowPlayingInfoPropertyPlaybackRate: Double(player.rate),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position ?? 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let duration = playingDuration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
            MPNowPlayingInfoCenter.default().playbackState = player.rate == 0 ? .paused : .playing
        #endif
    }
}

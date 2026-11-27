import AVFoundation
import CodingAgentKit
import CoreGraphics
import Foundation
import MidgarCore
import TailscodeCore

/// The videos and songs a transcript names (`MediaMentions`), as this Apple device knows them:
/// where each plays from, how long it is, a video's first frame, and the one song playing.
///
/// A file is read once: a bridge hands a ticket URL AVPlayer streams and seeks in, and a server
/// without tickets has the whole file fetched into Caches first. WebM, Matroska and Ogg are never
/// fetched, because nothing on this device plays them. Cells are reused all the time, so nothing
/// lives in one: a cell reads its state here and listens for `changed`.
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
    }

    nonisolated static func key(_ file: FileReference) -> String { file.url ?? file.path ?? "" }

    private var states: [String: State] = [:]

    private(set) var player: AVPlayer?
    private(set) var playingKey: String?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

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
        guard MediaKind.playsOnApple(path: path) else { return .failure(.unplayable) }
        let clock = ContinuousClock()
        let began = clock.now
        let source: URL
        do {
            if let streaming = backend as? any MediaStreamingBackend,
                let url = try await streaming.streamingURL(for: file)
            {
                source = url
            } else {
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
        let opened = clock.now - began
        let duration = seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard kind == .video else {
            return .success(Ready(source: source, duration: duration, poster: nil, aspect: nil))
        }
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
        return .success(Ready(source: source, duration: duration, poster: poster, aspect: aspect))
    }

    /// The whole file in Caches, for a server that hands out no tickets.
    nonisolated private static func cached(
        _ file: FileReference, path: String, backend: any CodingAgentBackend
    ) async throws -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("named-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = path.split(separator: ".").last.map { String($0).lowercased() } ?? "bin"
        let target = directory.appendingPathComponent(stem(key(file)) + "." + ext)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let data = try await backend.attachmentData(file)
        try data.write(to: target, options: .atomic)
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

    /// Plays a row's song, pauses it when it is the one playing, and stops whatever else was.
    func toggle(_ file: FileReference) {
        let key = Self.key(file)
        guard case .ready(let ready)? = states[key] else { return }
        if playingKey == key, let player {
            if player.rate == 0 {
                if let duration = ready.duration, let position, position >= duration - 0.25 {
                    player.seek(to: .zero)
                }
                player.play()
            } else {
                player.pause()
            }
            announce(key)
            return
        }
        stop()
        let player = AVPlayer(url: ready.source)
        self.player = player
        playingKey = key
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let key = self.playingKey else { return }
                self.announce(key)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        #if os(iOS)
            ClipAudio.makeAudible()
        #endif
        player.play()
        announce(key)
    }

    /// Stops the song, for another row's or for a chat closing.
    func stop() {
        guard let player else { return }
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        self.player = nil
        let was = playingKey
        playingKey = nil
        if let was { announce(was) }
    }
}

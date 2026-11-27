import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The videos and songs this desk's transcripts name (`MediaMentions`): where each can be played
/// from, how long it is, its first frame, and the one song playing.
///
/// A file is read once per row: a bridge hands a ticket URL libmpv can stream and seek in, and a
/// server without tickets has the whole file streamed into the cache first. A video's first frame
/// and every file's length come from a headless libmpv probe off the main thread, the frame decoded
/// into the device's picture store like any transcript picture. Rows are rebuilt all the time, so
/// nothing here lives in a widget: a row reads its state and the panes listening redraw it when
/// what it is changes. A playing song's line is the exception: its time, its bar and its button are
/// moved where they stand twice a second (`attach`), so a drag on the bar is never rebuilt away.
///
/// Main thread only, except the work it hands to detached tasks.
final class MediaDeck: @unchecked Sendable {
    static let shared = MediaDeck()

    enum State: Sendable, Equatable {
        case reading
        case ready(Ready)
        case failed(NamedMediaFailure)
    }

    struct Ready: Sendable, Equatable {
        /// What a player opens: a ticket URL, or a file in this desk's cache.
        let source: String
        let duration: Double?
        /// The first frame on disk, for a video whose probe wrote one.
        let poster: String?
    }

    /// The widgets of a song's line that move while it plays, as bits: a line is GTK's, and GTK
    /// destroys it with its row.
    struct LiveLine {
        let button: UInt
        let detail: UInt
        let bar: UInt
    }

    /// The key a video's first frame is kept under in the picture store.
    static func posterKey(_ key: String) -> String { "poster|" + key }

    /// What each row's file turned out to be, held with the URL it was read for: a row keeps its
    /// key when the words naming its file change, and a different file is a fresh read.
    private var states: [String: (url: String, state: State)] = [:]
    private var listeners: [Int: @Sendable (String) -> Void] = [:]
    private var nextListener = 0
    private var restoring: Set<String> = []
    private var pruned = false
    private var lines: [String: LiveLine] = [:]

    private var audio: OpaquePointer?
    private var audioBox: UnsafeMutableRawPointer?
    /// The GL area libmpv makes with every player. A song never draws, so the area is never put in
    /// a window; the deck holds the one reference that keeps it from leaking and lets it go after
    /// the player.
    private var audioArea: UnsafeMutablePointer<GtkWidget>?
    private var audioOwner: ObjectIdentifier?
    private var audioStart: Double?
    private(set) var playingKey: String?
    private(set) var audioPaused = false
    private var ticking = false
    private var settingBar = false

    func state(_ key: String, url: String?) -> State? {
        guard let entry = states[key], entry.url == (url ?? "") else { return nil }
        return entry.state
    }

    func listen(_ heard: @escaping @Sendable (String) -> Void) -> Int {
        nextListener += 1
        listeners[nextListener] = heard
        return nextListener
    }

    func stopListening(_ id: Int) {
        listeners[id] = nil
    }

    private func announce(_ key: String) {
        for heard in listeners.values { heard(key) }
    }

    /// Finds out what a named file is, once: asking again for a row already read, or being read,
    /// costs nothing, so every rebuild of every row may ask. `force` reads a failed one again.
    func read(
        _ reference: FileReference, key: String, backend: (any CodingAgentBackend)?,
        force: Bool = false
    ) {
        let url = reference.url ?? ""
        if let known = states[key], known.url == url {
            guard force, case .failed = known.state else { return }
        }
        guard let backend, let kind = MediaKind.of(reference), kind != .picture else { return }
        if playingKey == key { stopAudio() }
        states[key] = (url, .reading)
        if force { announce(key) }
        pruneOnce()
        tailscode_mpv_numeric_locale()
        let cache = Self.cacheDirectory
        Task.detached(priority: .utility) { [weak self] in
            let outcome = await Self.resolve(reference, kind: kind, backend: backend, cache: cache)
            if case .failure(.missing) = outcome { MediaMisses.note(reference) }
            Gtk.onMain { [weak self] in self?.settle(key, url: url, outcome) }
        }
    }

    private func settle(_ key: String, url: String, _ outcome: Result<Ready, NamedMediaFailure>) {
        guard states[key]?.url == url else { return }
        switch outcome {
        case .success(let ready):
            states[key] = (url, .ready(ready))
            if let poster = ready.poster { restorePoster(key, from: poster) }
        case .failure(let failure):
            states[key] = (url, .failed(failure))
        }
        announce(key)
    }

    /// The first frame back in the picture store, for a row whose frame was shed while nothing
    /// drew it. Main thread.
    func restorePoster(_ key: String, from path: String) {
        guard !restoring.contains(key) else { return }
        restoring.insert(key)
        Task.detached(priority: .utility) { [weak self] in
            let preview = (try? Data(contentsOf: URL(fileURLWithPath: path)))
                .flatMap(PictureDecode.preview(of:))
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.restoring.remove(key)
                guard let preview else { return }
                PictureStore.shared.store(preview, forKey: Self.posterKey(key))
                self.announce(key)
            }
        }
    }

    /// A row whose source stopped answering (a ticket the bridge forgot when it restarted) is read
    /// again from the start.
    func forget(_ key: String) {
        states[key] = nil
        announce(key)
    }

    /// Where a file is played from, its length, and for a video its first frame.
    private static func resolve(
        _ reference: FileReference, kind: MediaKind, backend: any CodingAgentBackend, cache: URL
    ) async -> Result<Ready, NamedMediaFailure> {
        let source: String
        do {
            if let streaming = backend as? any MediaStreamingBackend,
                let stream = try await streaming.mediaStream(for: reference, playback: .any)
            {
                source = stream.url.absoluteString
            } else {
                let file = cache.appendingPathComponent(cacheName(reference))
                if !FileManager.default.fileExists(atPath: file.path) {
                    try await backend.fetchFile(reference, to: file)
                }
                source = file.path
            }
        } catch {
            return .failure(MediaTileReading.failure(error))
        }
        guard tailscode_mpv_available() != 0 else {
            return .success(Ready(source: source, duration: nil, poster: nil))
        }
        let posterDirectory = kind == .video
            ? cache.appendingPathComponent("posters/" + stem(reference), isDirectory: true) : nil
        if let posterDirectory {
            try? FileManager.default.removeItem(at: posterDirectory)
            try? FileManager.default.createDirectory(
                at: posterDirectory, withIntermediateDirectories: true)
        }
        let (opened, duration) = await probe(source, posters: posterDirectory?.path)
        let poster = posterDirectory?.appendingPathComponent("00000001.jpg").path
        let wrote = poster.map { FileManager.default.fileExists(atPath: $0) } ?? false
        guard opened == 0 || wrote else { return .failure(.unplayable) }
        return .success(
            Ready(source: source, duration: duration > 0 ? duration : nil, poster: wrote ? poster : nil))
    }

    private static let probes = DispatchQueue(label: "tailscode.media.probe", qos: .utility)

    /// One probe at a time, on a thread of its own. A probe blocks until mpv has the frame, and a
    /// transcript that names six clips used to start six players at once on the pool every other
    /// task waits for: 683 MB of decoders and read-ahead at the peak, for six small pictures.
    private static func probe(_ source: String, posters: String?) async -> (Int32, Double) {
        await withCheckedContinuation { continuation in
            probes.async {
                var duration = -1.0
                let opened = tailscode_mpv_probe(source, posters, 25, &duration)
                HeapReturn.soon()
                continuation.resume(returning: (opened, duration))
            }
        }
    }

    static var cacheDirectory: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map {
            URL(fileURLWithPath: $0)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return base.appendingPathComponent("tailscode/media", isDirectory: true)
    }

    private static func cacheName(_ reference: FileReference) -> String {
        let ext = (reference.filename ?? reference.path ?? "").split(separator: ".").last.map(String.init) ?? "bin"
        return stem(reference) + "." + ext.lowercased()
    }

    /// A name for a reference that is the same every run: FNV-1a over its URL, which carries the
    /// path and the message that named it.
    private static func stem(_ reference: FileReference) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (reference.url ?? reference.path ?? "").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Files fetched for servers without tickets are kept three days: long enough that reopening
    /// a chat plays at once, short enough that a week of renders does not fill the disk.
    private func pruneOnce() {
        guard !pruned else { return }
        pruned = true
        let directory = Self.cacheDirectory
        Task.detached(priority: .background) {
            let cutoff = Date().addingTimeInterval(-3 * 86400)
            let manager = FileManager.default
            guard
                let walker = manager.enumerator(
                    at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            else { return }
            for case let file as URL in walker {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                if let modified, modified < cutoff { try? manager.removeItem(at: file) }
            }
        }
    }

    /// The mpv plugin that puts a player on the desktop's media controls and media keys (MPRIS),
    /// when the machine has it: libmpv loads no scripts of its own accord.
    static let mprisScript: String? = [
        "/etc/mpv/scripts/mpris.so", "/usr/lib/mpv-mpris/mpris.so", "/usr/lib/mpv/mpris.so",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mpv/scripts/mpris.so").path,
    ].first { FileManager.default.fileExists(atPath: $0) }

    /// Readies a player for what a chat named: its title is the file's name (what the desktop's
    /// media controls show) and it is put on those controls when the machine can.
    static func dress(_ player: OpaquePointer, title: String) {
        command(player, ["set", "force-media-title", title])
        if let script = mprisScript { command(player, ["load-script", script]) }
    }

    /// Plays a row's song, pauses it when it is the one playing, and stops whatever else was.
    /// `owner` is the pane that pressed: the song stops when that pane closes or shows another chat.
    /// `at` starts it at a fraction of its length, for a press on its bar.
    func toggleAudio(_ key: String, name: String, owner: ObjectIdentifier, at fraction: Double? = nil) {
        guard let entry = states[key], case .ready(let ready) = entry.state else { return }
        if playingKey == key, let audio {
            if let fraction {
                seekAudio(to: fraction)
                return
            }
            if audioPaused, let duration = ready.duration, let position = audioPosition,
                position >= duration - 0.3
            {
                Self.command(audio, ["seek", "0", "absolute"])
            }
            Self.command(audio, ["cycle", "pause"])
            audioPaused.toggle()
            refreshLine(key)
            return
        }
        stopAudio()
        guard tailscode_mpv_available() != 0 else {
            states[key] = (entry.url, .failed(.unplayable))
            announce(key)
            return
        }
        let box = Unmanaged.passRetained(AudioBox(deck: self)).toOpaque()
        guard
            let player = tailscode_mpv_new(
                { user, kind, text in
                    guard let user, let kind else { return }
                    let event = String(cString: kind)
                    let payload = text.map { String(cString: $0) } ?? ""
                    let box = Unmanaged<AudioBox>.fromOpaque(user).takeUnretainedValue()
                    box.deck?.heard(event, payload)
                }, box)
        else {
            Unmanaged<AudioBox>.fromOpaque(box).release()
            states[key] = (entry.url, .failed(.unplayable))
            announce(key)
            return
        }
        audio = player
        audioBox = box
        audioArea = tailscode_mpv_area(player)
        if let audioArea { g_object_ref_sink(UnsafeMutableRawPointer(audioArea)) }
        audioOwner = owner
        Self.command(player, ["set", "vid", "no"])
        Self.command(player, ["set", "audio-display", "no"])
        Self.dress(player, title: name)
        audioStart = fraction.flatMap { part in ready.duration.map { part * $0 } }
            ?? MediaPlayhead.start(for: entry.url)
        tailscode_mpv_play(player, ready.source)
        playingKey = key
        audioPaused = false
        announce(key)
        tick()
    }

    /// Moves the playing song to a fraction of its length.
    func seekAudio(to fraction: Double) {
        guard let audio, let key = playingKey, let entry = states[key],
            case .ready(let ready) = entry.state, let duration = ready.duration
        else { return }
        let target = max(0, min(duration, fraction * duration))
        Self.command(audio, ["seek", String(format: "%.2f", target), "absolute"])
        refreshLine(key)
    }

    /// Where the playing song is, in seconds.
    var audioPosition: Double? {
        guard let audio else { return nil }
        let position = tailscode_mpv_number(audio, "time-pos")
        return position >= 0 ? position : nil
    }

    /// Stops the song a pane started, when that pane closes or turns to another chat.
    func release(owner: ObjectIdentifier) {
        guard audioOwner == owner else { return }
        stopAudio()
    }

    func stopAudio() {
        let was = playingKey
        if let was, let entry = states[was], case .ready(let ready) = entry.state,
            let position = audioPosition
        {
            MediaPlayhead.keep(position, of: ready.duration, for: entry.url)
        }
        playingKey = nil
        audioPaused = false
        audioOwner = nil
        audioStart = nil
        let player = audio.map { UInt(bitPattern: $0) }
        let box = audioBox.map { UInt(bitPattern: $0) }
        let area = audioArea.map { UInt(bitPattern: $0) }
        audio = nil
        audioBox = nil
        audioArea = nil
        if player != nil || box != nil {
            Gtk.onMain {
                if let player, let pointer = OpaquePointer(bitPattern: player) {
                    tailscode_mpv_free(pointer)
                    HeapReturn.soon()
                }
                if let box, let raw = UnsafeMutableRawPointer(bitPattern: box) {
                    Unmanaged<AudioBox>.fromOpaque(raw).release()
                }
                if let area, let raw = UnsafeMutableRawPointer(bitPattern: area) { g_object_unref(raw) }
            }
        }
        if let was {
            refreshLine(was)
            announce(was)
        }
    }

    private func heard(_ event: String, _ payload: String) {
        switch event {
        case "loaded":
            if let audio, let start = audioStart, start > 0 {
                Self.command(audio, ["seek", String(format: "%.2f", start), "absolute"])
            }
            audioStart = nil
        case "pause":
            audioPaused = payload == "1"
            if let key = playingKey { refreshLine(key) }
        case "end":
            if let key = playingKey, let url = states[key]?.url { MediaPlayhead.keep(0, of: nil, for: url) }
            stopAudio()
        case "error":
            if let key = playingKey, let url = states[key]?.url { states[key] = (url, .failed(.unreachable)) }
            stopAudio()
        default:
            break
        }
    }

    /// The widgets of a song's line that move while it plays. A line asks again each time it is
    /// built, and is forgotten when GTK destroys it.
    func attach(_ key: String, line: LiveLine) {
        lines[key] = line
        refreshLine(key)
        if let bar = UnsafeMutableRawPointer(bitPattern: line.bar) {
            Gtk.connect(bar, "destroy") { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, self.lines[key]?.bar == line.bar else { return }
                    self.lines[key] = nil
                }
            }
        }
    }

    /// Whether a change of a line's bar is the deck's own setting of it rather than a hand.
    var isSettingBar: Bool { settingBar }

    /// The line of `key` as it is now: its button, where it is against its length, its bar.
    private func refreshLine(_ key: String) {
        guard let line = lines[key], let entry = states[key], case .ready(let ready) = entry.state
        else { return }
        let playing = playingKey == key
        let running = playing && !audioPaused
        let position = playing ? audioPosition : nil
        if let button = UnsafeMutablePointer<GtkWidget>(bitPattern: line.button) {
            gtk_button_set_label(ptr(button), running ? "⏸" : "▶")
        }
        if let detail = UnsafeMutablePointer<GtkWidget>(bitPattern: line.detail) {
            gtk_label_set_text(
                op(detail),
                MediaTileReading.progress(at: position, of: ready.duration)
                    ?? MediaTileReading.kindWord(.audio))
        }
        if let bar = UnsafeMutablePointer<GtkWidget>(bitPattern: line.bar) {
            settingBar = true
            gtk_range_set_value(ptr(bar), MediaTileReading.fraction(at: position, of: ready.duration))
            settingBar = false
        }
    }

    /// Twice a second while a song plays, its line is moved where it stands.
    private func tick() {
        guard !ticking else { return }
        ticking = true
        Gtk.after(500) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.ticking = false
                guard let key = self.playingKey else { return }
                if !self.audioPaused { self.refreshLine(key) }
                self.tick()
            }
        }
    }

    static func command(_ player: OpaquePointer, _ arguments: [String]) {
        var pointers: [UnsafePointer<CChar>?] = arguments.map { UnsafePointer(strdup($0)) }
        pointers.append(nil)
        pointers.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress { tailscode_mpv_command(player, base) }
        }
        for pointer in pointers where pointer != nil {
            free(UnsafeMutableRawPointer(mutating: pointer))
        }
    }

    private final class AudioBox {
        weak var deck: MediaDeck?
        init(deck: MediaDeck) { self.deck = deck }
    }
}

import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A decoded preview and the pixel size of the picture it came from.
struct DecodedPreview: Sendable {
    let bits: UInt
    let width: Int32
    let height: Int32
}

enum PictureDecode {
    /// The transcript preview of encoded picture bytes: at most `bubbleMaxDimension` on its long
    /// side, a memory texture over a premultiplied surface the picture widgets share. Runs on the
    /// decode gate's threads and touches no widget; the caller owns the returned reference.
    static func preview(of data: Data) -> DecodedPreview? {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return nil }
            var width: Int32 = 0
            var height: Int32 = 0
            guard
                let texture = tailscode_texture_scaled(
                    base, gsize(buffer.count), TranscriptContext.bubbleMaxDimension, &width, &height)
            else { return nil }
            return DecodedPreview(bits: UInt(bitPattern: texture), width: width, height: height)
        }
    }
}

/// Every decoded transcript picture on the device, kept once: the panes of one chat, and a chat
/// reopened a moment later, share the same previews instead of each decoding their own under a
/// cap of their own. A preview is a memory texture whose bytes are a cairo surface the picture
/// widgets draw from, so a widget holding one costs a reference, not a copy.
///
/// Main thread only — the previews are toolkit objects and the order they are shed in is the
/// order the main thread drew them. Only the observer list is locked, because a transcript
/// context unregisters from wherever it happens to be released.
///
/// The bound is on the bytes the previews actually hold. A preview a picture widget is drawing is
/// never shed: dropping the store's reference to it frees nothing, and the row that shows it
/// would only ask for it again — which is the flicker an eviction ordered by decode time once
/// made of a long session, every rebuild asking for every picture the cache had dropped. What is
/// shed is what nothing shows, least recently drawn first, and the cap follows the governor's
/// level so landing a picture never refills what a relief just emptied. A picture that landed or
/// was drawn in the last few seconds is spared too, because between landing and the row that
/// wants it being rebuilt nothing shows it yet, and shedding it there is the same loop again.
final class PictureStore: @unchecked Sendable {
    static let shared: PictureStore = {
        let store = PictureStore()
        store.registerRelief()
        return store
    }()

    /// How long a failed picture is left alone before it is asked for again, and how many times
    /// it is asked for at all.
    static let retryAfter: TimeInterval = 60
    static let attemptLimit = 3

    private struct Entry {
        let bits: UInt
        let dimensions: (Int32, Int32)
        let bytes: Int
        var used: UInt64
        var touched: TimeInterval
    }

    private struct Failure {
        var attempts: Int
        var at: TimeInterval
    }

    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private var inFlight: Set<String> = []
    private var failures: [String: Failure] = [:]
    private(set) var cachedBytes = 0
    let byteCap: Int
    let grace: TimeInterval

    private let observerLock = NSLock()
    private var observers: [Int: @Sendable (String, Bool) -> Void] = [:]
    private var nextObserver = 0
    private var reliefToken: MemoryReliefToken?

    init(byteCap: Int = 256 * 1024 * 1024, grace: TimeInterval = 3) {
        self.byteCap = byteCap
        self.grace = grace
    }

    deinit {
        reliefToken?.cancel()
    }

    var count: Int { entries.count }

    private func registerRelief() {
        reliefToken = MemoryRelief.shared.register(name: "transcript pictures") { [weak self] depth in
            Gtk.onMain { [weak self] in self?.relieve(depth) }
        }
    }

    /// The cap at the window's shed level: whole until it is strained, half there, an eighth at
    /// the critical level. Read when a picture lands, so a window that has recovered gets its
    /// whole cap back without anyone telling the store.
    private func effectiveCap(at level: ShedLevel) -> Int {
        switch level {
        case .calm, .busy, .loaded: return byteCap
        case .strained: return byteCap / 2
        case .critical: return byteCap / 8
        }
    }

    /// What the governor asks for when it relieves memory: down to half the cap at the strained
    /// level, everything nothing is showing at the critical one.
    func relieve(_ depth: ReliefDepth) {
        shed(to: depth == .half ? byteCap / 2 : 0)
    }

    func addObserver(_ handler: @escaping @Sendable (_ key: String, _ restored: Bool) -> Void) -> Int {
        observerLock.lock()
        defer { observerLock.unlock() }
        nextObserver += 1
        observers[nextObserver] = handler
        return nextObserver
    }

    func removeObserver(_ id: Int) {
        observerLock.lock()
        observers[id] = nil
        observerLock.unlock()
    }

    private func notify(_ key: String, restored: Bool) {
        observerLock.lock()
        let handlers = Array(observers.values)
        observerLock.unlock()
        for handler in handlers { handler(key, restored) }
    }

    /// The decoded preview for a picture, marked as drawn now, or zero when it is not decoded.
    func texture(forKey key: String) -> UInt {
        guard var entry = entries[key] else { return 0 }
        clock += 1
        entry.used = clock
        entry.touched = Self.uptime
        entries[key] = entry
        return entry.bits
    }

    func has(_ key: String) -> Bool { entries[key] != nil }

    func dimensions(forKey key: String) -> (Int32, Int32)? { entries[key]?.dimensions }

    /// Takes a decoded preview in, replacing any earlier one, and tells every transcript that
    /// asked. Failure memory for the key is cleared: it arrived.
    func store(_ preview: DecodedPreview, forKey key: String) {
        guard let texture = OpaquePointer(bitPattern: Int(bitPattern: preview.bits)) else { return }
        release(key)
        let bytes = Int(tailscode_texture_width(texture)) * Int(tailscode_texture_height(texture)) * 4
        clock += 1
        entries[key] = Entry(
            bits: preview.bits, dimensions: (preview.width, preview.height), bytes: bytes, used: clock,
            touched: Self.uptime)
        cachedBytes += bytes
        inFlight.remove(key)
        failures[key] = nil
        shed(to: effectiveCap(at: CascadeBudget.level))
        notify(key, restored: false)
    }

    /// Tells the transcripts that something about the picture changed that they should look at
    /// again, without a new preview: its original bytes are back on disk.
    func announceRestored(_ key: String) {
        notify(key, restored: true)
    }

    /// Whether a picture may be asked for now, and if so, marks it asked. A picture already
    /// decoded or already on its way is not asked for again by every rebuild of every pane, and
    /// one that failed waits out `retryAfter` and is given up on after `attemptLimit` tries; a
    /// person asking for it by hand is not made to wait.
    func claim(_ key: String, urgent: Bool, at now: TimeInterval) -> Bool {
        guard entries[key] == nil, !inFlight.contains(key) else { return false }
        if let failure = failures[key] {
            if failure.attempts >= Self.attemptLimit, !urgent { return false }
            if now - failure.at < Self.retryAfter, !urgent { return false }
        }
        inFlight.insert(key)
        return true
    }

    func fail(_ key: String, at now: TimeInterval) {
        inFlight.remove(key)
        var failure = failures[key] ?? Failure(attempts: 0, at: now)
        failure.attempts += 1
        failure.at = now
        failures[key] = failure
    }

    func cancel(_ key: String) {
        inFlight.remove(key)
    }

    private func release(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        cachedBytes -= entry.bytes
        Self.unref(entry.bits)
    }

    /// Sheds pictures nothing shows and nothing has just asked for, least recently drawn first,
    /// until the store is at `target` bytes or only those are left.
    private func shed(to target: Int) {
        guard cachedBytes > target else { return }
        let horizon = Self.uptime - grace
        let candidates = entries.filter { $0.value.touched <= horizon && !Self.isShown($0.value.bits) }
            .sorted { $0.value.used < $1.value.used }
        for (key, _) in candidates {
            guard cachedBytes > target else { return }
            release(key)
        }
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func isShown(_ bits: UInt) -> Bool {
        guard let texture = OpaquePointer(bitPattern: Int(bitPattern: bits)) else { return false }
        return tailscode_texture_held_elsewhere(texture) != 0
    }

    private static func unref(_ bits: UInt) {
        guard let texture = OpaquePointer(bitPattern: Int(bitPattern: bits)) else { return }
        g_object_unref(UnsafeMutableRawPointer(texture))
    }
}

/// How a picture gets from the tailnet or the disk to the store: disk first, tailnet second, both
/// through the decode gate, and never tied to the pane that asked — the store belongs to the
/// device, so a picture that lands after the pane moved on is simply there for the next chat that
/// shows it.
enum PictureLoader {
    /// Asks for a picture. A picture already decoded, already on its way or recently failed is
    /// left alone, so every rebuild of every row may ask without costing anything. Main thread.
    static func request(
        _ reference: FileReference, key: String, backend: (any CodingAgentBackend)?,
        urgent: Bool = false, store: PictureStore = .shared
    ) {
        ImageDecodeGate.shared.adapt(to: CascadeBudget.level)
        if store.has(key) {
            restoreOriginal(reference, key: key, backend: backend, store: store)
            return
        }
        guard store.claim(key, urgent: urgent, at: now) else { return }
        Task.detached(priority: .utility) {
            let preview = await load(reference, backend: backend, urgent: urgent)
            Gtk.onMain {
                if let preview {
                    store.store(preview, forKey: key)
                } else {
                    store.fail(key, at: now)
                }
            }
        }
    }

    /// A preview whose original has left the disk cache — pruned while the transcript was open —
    /// has its original fetched again, quietly, so the gallery's save and 1:1 page still hand
    /// over the server's bytes. Main thread.
    private static func restoreOriginal(
        _ reference: FileReference, key: String, backend: (any CodingAgentBackend)?,
        store: PictureStore
    ) {
        guard let backend, !ImageCache.exists(reference) else { return }
        let ticket = "original|" + key
        guard store.claim(ticket, urgent: true, at: now) else { return }
        Task.detached(priority: .utility) {
            let data = try? await backend.attachmentData(reference)
            if let data {
                _ = await ImageDecodeGate.shared.run(urgent: true) { ImageCache.save(data, for: reference) }
            }
            Gtk.onMain {
                if data != nil {
                    store.cancel(ticket)
                    store.announceRestored(key)
                } else {
                    store.fail(ticket, at: now)
                }
            }
        }
    }

    private static func load(
        _ reference: FileReference, backend: (any CodingAgentBackend)?, urgent: Bool
    ) async -> DecodedPreview? {
        let gate = ImageDecodeGate.shared
        let cached = await gate.run(urgent: urgent) {
            ImageCache.load(reference).flatMap { PictureDecode.preview(of: $0) }
        }
        if let cached, let preview = cached { return preview }
        guard let backend, let data = try? await backend.attachmentData(reference) else { return nil }
        let fetched = await gate.run(urgent: urgent) {
            ImageCache.save(data, for: reference)
            return PictureDecode.preview(of: data)
        }
        return fetched ?? nil
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

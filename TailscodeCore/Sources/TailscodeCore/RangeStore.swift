import CodingAgentKit
import Foundation

/// What this device has seen the account's quota windows do, and what it has already said about
/// them, kept across launches.
///
/// One file under Application Support rather than a defaults key, for the reason `SendQueueStore`
/// is one: corelibs keys its defaults to the running executable, and a week of samples is a
/// hundred kilobytes that has no business in a preferences plist. Reading is a lock and a copy of
/// a dictionary; writing happens only when a reading changed the trail, on a utility queue, so
/// nothing that polls ever waits on the disk.
public enum RangeStore {
    private struct File: Codable {
        var trail = QuotaTrail()
        var ledger = RunningLowLedger()
    }

    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "tailscode.range-store", qos: .utility)
    nonisolated(unsafe) private static var state: File?

    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Tailscode", isDirectory: true)
            .appendingPathComponent("range.json")
    }

    /// What has been seen, for a pace to read its recent rate from.
    public static var trail: QuotaTrail {
        lock.lock()
        defer { lock.unlock() }
        return load().trail
    }

    /// Records a fresh report from the account and, when `announce` is true, decides which windows
    /// are worth saying something about.
    ///
    /// - Returns: the notices to post. Empty almost always.
    @discardableResult
    public static func observe(
        quotas: [UsageQuota], announce: Bool, now: Date = Date(), clock: RangeClock = .current
    ) -> [RunningLowNotice] {
        lock.lock()
        var file = load()
        var changed = file.trail.note(quotas: quotas, at: now)
        var notices: [RunningLowNotice] = []
        if announce {
            let before = file.ledger
            notices = RunningLow.decide(
                quotas: quotas, ledger: &file.ledger, trail: file.trail, now: now, clock: clock)
            if file.ledger != before { changed = true }
        }
        state = file
        lock.unlock()
        if changed { persist(file) }
        return notices
    }

    /// Forgets everything. For a test, and for a person who wants the history gone.
    public static func reset() {
        lock.lock()
        state = File()
        let file = state ?? File()
        lock.unlock()
        persist(file)
    }

    private static func load() -> File {
        if let state { return state }
        let loaded =
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.range.decode(File.self, from: $0) }
            ?? File()
        state = loaded
        return loaded
    }

    private static func persist(_ file: File) {
        queue.async {
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder.range.encode(file) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension JSONEncoder {
    fileprivate static var range: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var range: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

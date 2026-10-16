import CodingAgentKit
import Foundation

/// The numbers and names a check carries, read as what they are. A daemon sends every fact as text
/// and a newer daemon may send one this app has never heard of, so nothing here traps on a missing or
/// malformed value; it answers `nil` and the reading falls back.
public struct SetupFacts: Sendable, Equatable {
    public let values: [String: String]

    public init(_ values: [String: String]) { self.values = values }

    public func text(_ key: String) -> String? {
        guard let raw = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    public func integer(_ key: String) -> Int64? { text(key).flatMap { Int64($0) } }

    public func number(_ key: String) -> Double? { text(key).flatMap { Double($0) } }
}

/// Every word one capability's checks, fixes and failures are written in. A capability the app knows
/// registers one, and anything it does not know is read from the report's own `detail`. The readers
/// answer `nil` for an id they have no words for, so a newer daemon never makes a wrong sentence.
public protocol SetupCapabilityReader: Sendable {
    var capability: String { get }
    var name: String { get }
    var setUpLabel: String { get }
    var readyHeadline: String { get }
    var readyActionLabel: String { get }
    var beta: BetaFeature? { get }

    func title(of check: SetupCheck) -> String?
    func line(of check: SetupCheck, locale: Locale) -> String?
    func impossibility(of check: SetupCheck, locale: Locale) -> String?
    func fixLabel(of fix: SetupFix) -> String?
    func fixReason(of fix: SetupFix) -> String?
    func jobPhrase(of fixID: String) -> String?
    func failure(of job: SetupJob, locale: Locale) -> String?
}

extension SetupCapabilityReader {
    public var beta: BetaFeature? { nil }

    public func title(of check: SetupCheck) -> String? { nil }
    public func line(of check: SetupCheck, locale: Locale) -> String? { nil }
    public func impossibility(of check: SetupCheck, locale: Locale) -> String? { nil }
    public func fixLabel(of fix: SetupFix) -> String? { nil }
    public func fixReason(of fix: SetupFix) -> String? { nil }
    public func jobPhrase(of fixID: String) -> String? { nil }
    public func failure(of job: SetupJob, locale: Locale) -> String? { nil }
}

/// The readers the process knows, by capability. The voice reader is always here; another capability
/// adds its own with `register` before its first report is drawn.
public final class SetupReaders: @unchecked Sendable {
    public static let shared = SetupReaders()

    private let lock = NSLock()
    private var readers: [String: any SetupCapabilityReader]

    private init() {
        let voice = VoiceSetupReader()
        readers = [voice.capability: voice]
    }

    public func register(_ reader: any SetupCapabilityReader) {
        lock.withLock { readers[reader.capability] = reader }
    }

    public func reader(for capability: String) -> (any SetupCapabilityReader)? {
        lock.withLock { readers[capability] }
    }

    public func reader(forCheck id: String) -> (any SetupCapabilityReader)? {
        guard let dot = id.firstIndex(of: ".") else { return nil }
        return reader(for: String(id[..<dot]))
    }

    public var capabilities: [String] { lock.withLock { readers.keys.sorted() } }
}

/// What the app says of a check, a fix or a job: the capability's reader first, the daemon's own
/// English second, and a neutral line last, so every state of every id has some honest words.
public enum SetupReading {
    public static func register(_ reader: any SetupCapabilityReader) { SetupReaders.shared.register(reader) }

    public static func name(of capability: String) -> String {
        if let reader = SetupReaders.shared.reader(for: capability) { return reader.name }
        return capability.prefix(1).uppercased() + capability.dropFirst()
    }

    public static func title(of check: SetupCheck) -> String {
        if let title = SetupReaders.shared.reader(forCheck: check.id)?.title(of: check) { return title }
        return check.detail.flatMap { $0.isEmpty ? nil : $0 } ?? Localized.text("Something to check")
    }

    public static func line(of check: SetupCheck, locale: Locale = .current) -> String? {
        if let line = SetupReaders.shared.reader(forCheck: check.id)?.line(of: check, locale: locale) {
            return line
        }
        if let detail = check.detail, !detail.isEmpty { return detail }
        return neutral(check.state)
    }

    public static var unreachableAdvice: String {
        Localized.text("check that it is on and that Tailscale is connected")
    }

    public static func neutral(_ state: SetupState) -> String {
        switch state {
        case .ok: return Localized.text("Done")
        case .todo: return Localized.text("Not done yet")
        case .working: return Localized.text("Working on it")
        case .blocked: return Localized.text("Needs attention")
        case .unavailable: return Localized.text("Not possible on this machine")
        }
    }

    public static func stateWord(_ state: SetupState) -> String {
        switch state {
        case .ok: return Localized.text("Done")
        case .todo: return Localized.text("To do")
        case .working: return Localized.text("Working")
        case .blocked: return Localized.text("Needs you")
        case .unavailable: return Localized.text("Not possible")
        }
    }

    /// The fragment that completes "Not possible on this machine: …".
    public static func impossibility(of check: SetupCheck, locale: Locale = .current) -> String? {
        if let line = SetupReaders.shared.reader(forCheck: check.id)?.impossibility(of: check, locale: locale) {
            return line
        }
        return check.detail.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func fixLabel(of fix: SetupFix, capability: String? = nil) -> String {
        let reader = capability.flatMap { SetupReaders.shared.reader(for: $0) } ?? SetupReaders.shared.reader(forCheck: fix.id)
        if let label = reader?.fixLabel(of: fix) { return label }
        return fix.kind == .command ? Localized.text("Copy command") : Localized.text("Set it up")
    }

    public static func fixReason(of fix: SetupFix, capability: String? = nil) -> String? {
        let reader = capability.flatMap { SetupReaders.shared.reader(for: $0) } ?? SetupReaders.shared.reader(forCheck: fix.id)
        if let reason = reader?.fixReason(of: fix) { return reason }
        return fix.reason.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// What a fix will cost, before it is started: `44 GB, about 12 minutes`.
    public static func fixCost(of fix: SetupFix, locale: Locale = .current) -> String? {
        let size = fix.bytes.flatMap { $0 > 0 ? SetupFormat.bytes($0, locale: locale) : nil }
        let time = fix.minutes.flatMap { $0 > 0 ? SetupFormat.duration(minutes: $0, locale: locale) : nil }
        switch (size, time) {
        case (let size?, let time?): return Localized.text("%1$@, %2$@", size, time)
        case (let size?, nil): return size
        case (nil, let time?): return time
        case (nil, nil): return nil
        }
    }

    public static func jobPhrase(of fixID: String) -> String {
        SetupReaders.shared.reader(forCheck: fixID)?.jobPhrase(of: fixID) ?? Localized.text("setting things up")
    }

    public static func step(_ step: String?) -> String? {
        switch step {
        case "download": return Localized.text("Downloading")
        case "verify": return Localized.text("Checking the download")
        case "unpack": return Localized.text("Unpacking")
        case "pull": return Localized.text("Downloading the image")
        case "load": return Localized.text("Loading the model")
        case "start": return Localized.text("Starting")
        default: return nil
        }
    }

    /// Why a job did not finish, in words. A cancelled job is the person's own doing and needs none.
    public static func failure(of job: SetupJob, locale: Locale = .current) -> String? {
        guard job.state == .failed else { return nil }
        if let line = SetupReaders.shared.reader(forCheck: job.fix)?.failure(of: job, locale: locale) { return line }
        return generalFailure(of: job, locale: locale)
    }

    public static func generalFailure(of job: SetupJob, locale: Locale = .current) -> String {
        let facts = SetupFacts(job.facts)
        switch job.failure {
        case "diskFull":
            if let free = facts.integer("freeMB"), let need = facts.integer("needMB") {
                return Localized.text(
                    "There is not enough room on the disk: %1$@ free, %2$@ needed.",
                    SetupFormat.megabytes(free, locale: locale), SetupFormat.megabytes(need, locale: locale))
            }
            return Localized.text("There is not enough room on the disk.")
        case "network":
            return Localized.text("The download was interrupted. Trying again picks up where it stopped.")
        case "checksum":
            return Localized.text("The download did not check out and was thrown away. Try again.")
        default:
            return Localized.text("It stopped before it finished. Trying again picks up where it left off.")
        }
    }

    /// What a followed job says under its bar: `11 of 44 GB, about 8 minutes left`, falling back to
    /// whichever half the daemon reported, and to the step's name when it reported neither.
    public static func jobLine(_ job: SetupJob, eta: TimeInterval?, locale: Locale = .current) -> String? {
        let measure: String
        if let done = job.bytesDone, let total = job.bytesTotal, total > 0 {
            measure = SetupFormat.progress(done: done, total: total, locale: locale)
        } else if let fraction = job.fraction {
            measure = SetupFormat.percent(fraction, locale: locale)
        } else {
            return step(job.step)
        }
        guard let eta, eta > 0 else { return measure }
        return Localized.text("%1$@, %2$@ left", measure, SetupFormat.duration(seconds: eta, locale: locale))
    }
}

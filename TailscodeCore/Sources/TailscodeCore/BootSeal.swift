import Foundation

/// Whether what an app has saved is sealed: written on an earlier launch and unreadable now.
///
/// A phone that has restarted keeps everything an app saved encrypted until it is unlocked once, and
/// still wakes the app in the background before that: a silent push, a background refresh, a transfer
/// that finished. Preferences then read as if nothing had ever been set and a saved file refuses to
/// open, and a process that takes those answers for the truth opens later as a first launch with no
/// servers and no purchase, though nothing on disk has changed.
///
/// Sealed is narrower than locked. A phone locked in a pocket after its first unlock reads all of
/// this, and its background wakes are the ones that keep widgets, notices and Live Activities true,
/// so a locked phone alone is never the answer: the evidence has to say that something is there and
/// will not be read. A copy with nothing saved is a first launch, and has nothing to protect.
public enum BootSeal: Sendable {
    /// What a launch can find out without reading anything that might be sealed.
    public struct Evidence: Sendable, Equatable {
        /// Whether the system says protected data can be read. False on every locked phone, sealed
        /// or not, so it only ever rules a seal out.
        public var protectedDataAvailable: Bool
        /// The saved servers' file is on disk.
        public var serversFileExists: Bool
        /// That file opens for reading.
        public var serversFileOpens: Bool
        /// The preferences file is on disk, so some earlier launch wrote preferences.
        public var preferencesFileExists: Bool
        /// A preference every earlier launch has written reads back.
        public var canaryReadsBack: Bool

        public init(
            protectedDataAvailable: Bool, serversFileExists: Bool, serversFileOpens: Bool,
            preferencesFileExists: Bool, canaryReadsBack: Bool
        ) {
            self.protectedDataAvailable = protectedDataAvailable
            self.serversFileExists = serversFileExists
            self.serversFileOpens = serversFileOpens
            self.preferencesFileExists = preferencesFileExists
            self.canaryReadsBack = canaryReadsBack
        }
    }

    /// The preferences that stand for "an earlier launch got this far": the first is written by
    /// every launch that has ever made the server list, the second by every launch since this rule.
    public static let canaryKeys = ["tailscode.sharedStoreMigrated", "tailscode.bootSeal.opened"]

    public static func isSealed(_ evidence: Evidence) -> Bool {
        guard !evidence.protectedDataAvailable else { return false }
        if evidence.serversFileExists, !evidence.serversFileOpens { return true }
        return evidence.preferencesFileExists && !evidence.canaryReadsBack
    }
}

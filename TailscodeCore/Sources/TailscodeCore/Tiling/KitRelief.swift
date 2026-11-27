import CodingAgentKit
import Foundation

/// What the Kit keeps for the life of a process, in the registry the governor relieves. A bridge's
/// transcripts are held to be answered "unchanged" on the next read, megabytes for each long
/// conversation on every server; they are let go when everything is, and the next read of each is
/// answered in full.
public enum KitRelief {
    private static let token = MemoryRelief.shared.register(name: "held transcripts") { depth in
        if depth == .all { HeldTranscripts.release() }
    }

    /// Puts the Kit's holdings in the registry, once however often it is asked.
    public static func install() {
        _ = token
    }
}

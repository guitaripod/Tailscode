import CodingAgentKit
import Foundation

extension SpokenDigest {
    public static let starting = "Working. Starting on it."

    /// The account of an agent whose client has just handed it a prompt the server has not echoed
    /// back yet. Until the transcript grows, the conversation still reads as idle or done, and the
    /// model, asked for status straight after `Sent.`, would say so. A question or an approval that
    /// is waiting still outranks the prompt in flight.
    public static func snapshot(
        from state: ConversationState, sending: Bool, after previous: VoiceAgentSnapshot? = nil,
        now: Date = Date()
    ) -> VoiceAgentSnapshot {
        let reading = snapshot(from: state, after: previous, now: now)
        guard sending, !reading.busy, !reading.digest.hasPrefix("Waiting for you.") else { return reading }
        let candidate = VoiceAgentSnapshot(busy: true, digest: starting, turn: reading.turn)
        guard let previous else { return candidate }
        return VoiceAgentSnapshot(
            busy: true, digest: starting, turn: candidate.sameMeaning(as: previous) ? previous.turn : previous.turn + 1)
    }
}

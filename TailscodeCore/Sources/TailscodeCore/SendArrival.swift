import Foundation

/// Whether words this device sent have since turned up in the server's account of the conversation.
///
/// A send that errors says only that the wire failed, never that the server did not get it: the
/// request lands, the phone is suspended before the answer comes back, and the error that follows
/// is the connection's. The transcript is the one witness that settles it, so a message offered
/// again after a failure is first compared with what the server holds.
public enum SendArrival {
    /// Whether `text` appears among the user messages written after the first `baselineUserCount`
    /// of them, which is how many the conversation held when the send began. Counting from the
    /// baseline is what lets the same words be sent twice on purpose: an earlier copy never stands
    /// in for a later one.
    public static func arrived(
        _ text: String, baselineUserCount: Int, userTexts: [String]
    ) -> Bool {
        let wanted = normalized(text)
        guard !wanted.isEmpty else { return false }
        return userTexts.dropFirst(max(0, baselineUserCount)).contains { normalized($0) == wanted }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension PendingSendLedger {
    /// Removes every failed send whose words the transcript already holds.
    ///
    /// - Returns: the sends retired, so a caller can let go of anything it was keeping for them.
    @discardableResult
    public mutating func retireArrived(userTexts: [String]) -> [PendingSend] {
        let arrived = sends.filter {
            $0.isFailed
                && SendArrival.arrived(
                    $0.text, baselineUserCount: $0.baselineUserCount, userTexts: userTexts)
        }
        for send in arrived { remove(id: send.id) }
        return arrived
    }
}

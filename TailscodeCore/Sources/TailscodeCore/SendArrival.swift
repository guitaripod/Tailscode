import CodingAgentKit
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

    /// The same question asked of whole messages, which is what a send that carried only pictures
    /// needs: it has no words to look for, so a user message written after the baseline with no
    /// words either and as many files as were attached is the send's own.
    public static func arrived(
        _ text: String, attachments: Int, baselineUserCount: Int, in messages: [ChatMessage]
    ) -> Bool {
        let users = messages.lazy.filter { $0.role == .user }.dropFirst(max(0, baselineUserCount))
        let wanted = normalized(text)
        guard wanted.isEmpty else {
            return users.contains { normalized($0.text) == wanted }
        }
        guard attachments > 0 else { return false }
        return users.contains { message in
            normalized(message.text).isEmpty && files(in: message) == attachments
        }
    }

    public static func arrived(_ send: PendingSend, in messages: [ChatMessage]) -> Bool {
        arrived(
            send.text, attachments: send.attachments.count,
            baselineUserCount: send.baselineUserCount, in: messages)
    }

    private static func files(in message: ChatMessage) -> Int {
        message.parts.count { part in
            if case .file = part.kind { return true }
            return false
        }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension PendingSendLedger {
    /// Removes every send holding words — a failure, or one waiting for the connection — whose
    /// words the transcript already holds.
    ///
    /// - Returns: the sends retired, so a caller can let go of anything it was keeping for them.
    @discardableResult
    public mutating func retireArrived(userTexts: [String]) -> [PendingSend] {
        let arrived = sends.filter {
            $0.isUnsent
                && SendArrival.arrived(
                    $0.text, baselineUserCount: $0.baselineUserCount, userTexts: userTexts)
        }
        for send in arrived { remove(id: send.id) }
        return arrived
    }

    /// The same, read from whole messages so a send of pictures alone is retired too. Costs
    /// nothing while no row is holding words, because it runs on every state a conversation
    /// emits and most of them carry nothing but a longer answer.
    @discardableResult
    public mutating func retireArrived(in messages: [ChatMessage]) -> [PendingSend] {
        guard hasUnsent else { return [] }
        let arrived = sends.filter { $0.isUnsent && SendArrival.arrived($0, in: messages) }
        for send in arrived { remove(id: send.id) }
        return arrived
    }
}

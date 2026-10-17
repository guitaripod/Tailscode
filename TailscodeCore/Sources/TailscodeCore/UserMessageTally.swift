import CodingAgentKit
import Foundation

/// How many messages in a transcript are the person's, kept between states so that a state which
/// only adds to the end counts the additions.
///
/// The count is asked on every state and a conversation emits one for every token, so counting
/// the whole transcript each time was the length of the conversation spent on a number that moves
/// once per prompt. What was counted is trusted for as long as the transcript still starts the way
/// it did — the same messages at the places the tally sampled them — and anything else, a message
/// dropped from the middle, a revert, another conversation, is counted again from the beginning.
public struct UserMessageTally: Sendable {
    private var counted = 0
    private var users = 0
    private var landmarks: [String] = []

    public init() {}

    public mutating func users(in messages: [ChatMessage]) -> Int {
        if messages.count >= counted, counted > 0, standsAsCounted(in: messages) {
            if messages.count == counted { return users }
            for message in messages[counted...] where message.role == .user { users += 1 }
        } else {
            users = messages.count { $0.role == .user }
        }
        counted = messages.count
        landmarks = Self.landmarks(of: messages)
        return users
    }

    private func standsAsCounted(in messages: [ChatMessage]) -> Bool {
        let places = Self.places(upTo: counted)
        guard places.count == landmarks.count else { return false }
        for (place, id) in zip(places, landmarks) where messages[place].id != id { return false }
        return true
    }

    private static func landmarks(of messages: [ChatMessage]) -> [String] {
        places(upTo: messages.count).map { messages[$0].id }
    }

    /// The first, the middle and the last of the first `count` messages.
    private static func places(upTo count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return Array(Set([0, count / 2, count - 1])).sorted()
    }
}

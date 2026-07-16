import ActivityKit
import Foundation

struct ChatActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            case thinking, tool, responding, approval, done, error
        }

        var phase: Phase
        var statusText: String
        var lastTool: String?
        var toolCount: Int
        var startedAt: Date
        var endedAt: Date?
        /// Sessions get auto-titled after their first turn; attributes are
        /// immutable, so the freshest title travels in the state.
        var title: String?
    }

    let sessionID: String
    let sessionTitle: String
    let serverName: String
}

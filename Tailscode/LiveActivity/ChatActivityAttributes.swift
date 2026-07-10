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
    }

    let sessionID: String
    let sessionTitle: String
    let serverName: String
}

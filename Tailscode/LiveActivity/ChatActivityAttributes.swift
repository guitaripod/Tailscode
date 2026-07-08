import ActivityKit

struct ChatActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var status: String
        var lastTool: String?
        var textSummary: String?
    }
    let sessionTitle: String
    let serverName: String
}

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
        /// The state's face from the shared vocabulary, computed by the app where Core lives —
        /// a running shell wears the terminal on the Lock Screen exactly as it does in the
        /// transcript. Optional so an activity started by an older process still decodes.
        var symbol: String?
        /// The face's meaning as `ActivityTone.rawValue`; the widget resolves it to colour, the
        /// same division of labour every other badge follows.
        var tone: String?
    }

    let sessionID: String
    let sessionTitle: String
    let serverName: String
}

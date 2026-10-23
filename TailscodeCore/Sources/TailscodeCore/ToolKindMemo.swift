import CodingAgentKit
import Foundation

/// What kind of call a tool name is, remembered. Classifying a name searches it for a score of
/// words, which costs two microseconds for a name the table knows and eight for one it does not,
/// and the answer depends on the name alone, while a transcript holds a call for every step the
/// agent ever took and asks the question of each one whenever it is read. A conversation uses a
/// few dozen names, so this holds them all and gives the table up only past `limit`.
public enum ToolKindMemo {
    static let limit = 2_048

    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: ToolCallSummary.Kind] = [:]

    public static func kind(ofToolNamed name: String) -> ToolCallSummary.Kind {
        lock.lock()
        if let hit = known[name] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let made = ToolCall(id: "", name: name, status: .completed).summaryKind
        lock.lock()
        if known.count >= limit { known.removeAll(keepingCapacity: true) }
        known[name] = made
        lock.unlock()
        return made
    }
}

extension ToolCall {
    /// `summaryKind`, found once per tool name.
    public var cachedKind: ToolCallSummary.Kind { ToolKindMemo.kind(ofToolNamed: name) }
}

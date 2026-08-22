import Foundation

/// How far through the whole graph the render is, counted in nodes. The sampler's own progress
/// frames are useless as a percentage: there are two passes, so the step counter reaches its
/// maximum, resets, and climbs again — a bar driven from it fills, empties and fills, which reads
/// as a failure. The node census is the honest number, because it counts every node in the graph
/// the same way from the first frame to the last.
public struct ForgeCensus: Sendable, Equatable {
    public let finished: Int
    public let total: Int
    /// Which node the server says is working, when one is — the graph's own key, which the board
    /// turns into a phrase a person can read.
    public let running: String?

    public init(finished: Int, total: Int, running: String?) {
        self.finished = finished
        self.total = total
        self.running = running
    }

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(finished) / Double(total)))
    }
}

/// One frame off the renderer's socket. Every type the server actually sends has a case here,
/// including the two that are easy to miss and impossible to work without: the null-node
/// `executing` frame that is how a finished job announces itself, and the binary preview frames
/// that must be dropped rather than parsed. Anything else the server grows later reads as
/// `ignored`, so a new frame type is a no-op instead of a crash.
public enum ForgeEvent: Sendable, Equatable {
    case status(queued: Int)
    case started(String)
    case cached(String, nodes: [String])
    case progressed(String, census: ForgeCensus)
    case executing(String, node: String)
    case executed(String, node: String)
    /// The sampler's step inside one pass. Worth showing as words — "step 3 of 8" — and never as
    /// the overall percentage, because there are two passes and this counter restarts between them.
    case sampling(String, node: String, step: Int, steps: Int)
    /// `executing` with a null node: the terminal success sentinel, and the frame the reference
    /// clients treat as done. `execution_success` arrives too, but this one arrives first.
    case finished(String)
    case succeeded(String)
    case failed(String, reason: String)
    case interrupted(String)
    case ignored

    /// The prompt this frame is about, when it names one. A socket carries every job this client
    /// started, so a frame that does not name the job in hand is not the job in hand.
    public var promptID: String? {
        switch self {
        case .status, .ignored: return nil
        case .started(let id), .cached(let id, _), .progressed(let id, _),
            .executing(let id, _), .executed(let id, _), .sampling(let id, _, _, _),
            .finished(let id), .succeeded(let id), .failed(let id, _), .interrupted(let id):
            return id
        }
    }

    /// Whether nothing more will arrive for this job. A render that ends and a client that keeps
    /// listening is a spinner nobody stops.
    public var isTerminal: Bool {
        switch self {
        case .finished, .succeeded, .failed, .interrupted: return true
        default: return false
        }
    }

    /// Reads one text frame. Public because the frame shapes are the server's, not this app's:
    /// each client's selftest pins them against real payloads so a ComfyUI upgrade that renames a
    /// field fails a test here rather than showing an empty progress bar on three platforms.
    public static func read(_ text: String) -> ForgeEvent {
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .ignored }
        return read(frame: object)
    }

    public static func read(frame: [String: Any]) -> ForgeEvent {
        guard let type = frame["type"] as? String else { return .ignored }
        let data = frame["data"] as? [String: Any] ?? [:]
        let promptID = data["prompt_id"] as? String ?? ""
        switch type {
        case "status":
            return .status(queued: queueRemaining(in: data))
        case "execution_start":
            return .started(promptID)
        case "execution_cached":
            return .cached(promptID, nodes: (data["nodes"] as? [Any] ?? []).compactMap { $0 as? String })
        case "progress_state":
            return .progressed(promptID, census: census(in: data))
        case "executing":
            guard let node = data["node"] as? String else { return .finished(promptID) }
            return .executing(promptID, node: node)
        case "executed":
            return .executed(promptID, node: data["node"] as? String ?? "")
        case "progress":
            return .sampling(
                promptID, node: data["node"] as? String ?? "", step: whole(data["value"]),
                steps: whole(data["max"]))
        case "execution_success":
            return .succeeded(promptID)
        case "execution_error":
            return .failed(promptID, reason: sentence(forError: data))
        case "execution_interrupted":
            return .interrupted(promptID)
        default:
            return .ignored
        }
    }

    private static func queueRemaining(in data: [String: Any]) -> Int {
        let status = data["status"] as? [String: Any] ?? [:]
        let info = status["exec_info"] as? [String: Any] ?? [:]
        return whole(info["queue_remaining"])
    }

    private static func census(in data: [String: Any]) -> ForgeCensus {
        let nodes = data["nodes"] as? [String: Any] ?? [:]
        var finished = 0
        var running: String?
        for (key, value) in nodes.sorted(by: { $0.key < $1.key }) {
            guard let entry = value as? [String: Any] else { continue }
            switch entry["state"] as? String {
            case "finished": finished += 1
            case "running": running = running ?? (entry["display_node_id"] as? String ?? key)
            default: break
            }
        }
        return ForgeCensus(finished: finished, total: nodes.count, running: running)
    }

    /// The server's own words about what blew up, preferred over anything invented here — a
    /// missing model file, an out-of-memory, a node this build does not have all read differently
    /// and only the server knows which happened.
    private static func sentence(forError data: [String: Any]) -> String {
        let message = (data["exception_message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = (data["exception_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let node = (data["node_type"] as? String) ?? (data["node_id"] as? String)
        let body = [message, kind].compactMap { $0 }.first { !$0.isEmpty }
        guard let body else { return Localized.text("The render failed and said nothing about why") }
        guard let node, !node.isEmpty else { return body }
        return Localized.text("%@ failed: %@", node, body)
    }

    private static func whole(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) ?? 0 }
        return 0
    }
}

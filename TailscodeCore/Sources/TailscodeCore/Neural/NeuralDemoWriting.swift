import CodingAgentKit
import Foundation

extension NeuralDemo {
    /// A turn that writes a file of a hundred and forty lines and then edits another, answered in a
    /// line: the long diff a client's reader opens. The turn's messages record no model and no
    /// effort, as a Claude transcript's do.
    public static func writing(
        prefix: String = "", origin: TimeInterval = 1_792_000_000, answer: Bool = true
    ) -> [ChatMessage] {
        func date(_ n: Int) -> Date { Date(timeIntervalSince1970: origin + Double(n) * 12) }
        func message(_ n: Int, _ kinds: [MessagePart.Kind]) -> ChatMessage {
            ChatMessage(
                id: "\(prefix)m\(n)", role: .assistant, agentType: .claudeCode,
                parts: kinds.enumerated().map { MessagePart(id: "p\($0.offset)", kind: $0.element) },
                createdAt: date(n), completedAt: date(n).addingTimeInterval(0.5))
        }
        func tool(_ name: String, _ input: [String: JSONValue], out: String) -> MessagePart.Kind {
            .tool(
                ToolCall(
                    id: "call-\(prefix)\(name)", name: name, status: .completed, input: .object(input),
                    output: out))
        }
        let path = "/home/marcus/Dev/rust/flaccy/linux/shared/src/lyrics/status.rs"
        var out: [ChatMessage] = [
            ChatMessage(
                id: "\(prefix)u0", role: .user, agentType: .claudeCode,
                parts: [MessagePart(id: "t", kind: .text("Start with the lyrics failure model, shared Rust first."))],
                createdAt: date(0), completedAt: date(0))
        ]
        out.append(
            message(
                1,
                [
                    .reasoning(
                        "Starting with the lyrics failure model (shared Rust first, then Swift, then the three panels)."),
                    tool(
                        "Write", ["file_path": .string(path), "content": .string(writtenFile)],
                        out: "File created successfully."),
                ]))
        out.append(
            message(
                2,
                [
                    tool(
                        "Edit",
                        [
                            "file_path": .string(path.replacingOccurrences(of: "status.rs", with: "mod.rs")),
                            "old_string": .string("mod cache;"),
                            "new_string": .string("mod cache;\nmod status;\npub use status::LyricsFailure;"),
                        ], out: "The file has been updated."),
                    answer ? .text("The failure model is in; the Swift side and the panels come next.") : .reasoning("..."),
                ]))
        return out
    }

    /// The file the demo's Write puts on disk: a hundred and forty lines of Rust.
    public static var writtenFile: String {
        (0..<140).map { index -> String in
            let case_ = index / 14
            switch index % 14 {
            case 0: return "/// Why lrclib could not be asked, or did not answer usefully. Case \(case_)."
            case 1: return "#[derive(Clone, Copy, Debug, PartialEq, Eq)]"
            case 2: return "pub enum LyricsFailure\(case_) {"
            case 3: return "    Unreachable,"
            case 4: return "    TimedOut,"
            case 5: return "    Busy,"
            case 6: return "    Server(u16),"
            case 7: return "    Rejected(u16),"
            case 8: return "}"
            case 9: return ""
            case 10: return "impl LyricsFailure\(case_) {"
            case 11: return "    /// What an HTTP status other than success and 404 means for the lookup."
            case 12:
                return
                    "    pub fn from_status(code: u16) -> LyricsFailure\(case_) { if code >= 500 { Self::Server(code) } else { Self::Rejected(code) } }"
            default: return "}"
            }
        }.joined(separator: "\n")
    }
}

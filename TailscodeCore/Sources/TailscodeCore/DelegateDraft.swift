import CodingAgentKit
import Foundation

/// A packet being written. Three things matter and the form says so — the goal, where the worker
/// may write, and how the result is judged — and everything else is a default the daemon's own
/// class table already knows.
public struct DelegateDraft: Sendable, Equatable {
    public var taskClass: String
    public var goal: String
    public var paths: String
    public var verify: String
    public var read: String
    public var notes: String
    public var tier: String?
    public var ceiling: String?
    public var mode: DelegateMode
    public var effort: DelegateEffort?
    public var repo: String

    public init(capabilities: DelegateCapabilities?, repo: String = "") {
        let classes = capabilities?.classes ?? []
        taskClass = classes.contains("default") ? "default" : (classes.first ?? "default")
        goal = ""
        paths = ""
        verify = ""
        read = ""
        notes = ""
        tier = nil
        ceiling = nil
        mode = .normal
        effort = nil
        self.repo = repo
    }

    /// A draft of a packet that already ran, for the next attempt at the same task.
    public init(packet: DelegatePacket) {
        taskClass = packet.taskClass
        goal = packet.goal
        paths = packet.paths.joined(separator: "\n")
        verify = packet.verify ?? ""
        read = packet.read.joined(separator: "\n")
        notes = packet.notes ?? ""
        tier = packet.tier
        ceiling = packet.ceiling
        mode = packet.mode ?? .normal
        effort = packet.effort
        repo = packet.repo ?? ""
    }

    public var pathList: [String] { Self.list(paths) }

    public var readList: [String] { Self.list(read) }

    static func list(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// What stops the packet from being sent. Empty means it can go.
    public var problems: [String] {
        var problems: [String] = []
        if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append(Localized.text("Say what the worker must achieve."))
        }
        if taskClass.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append(Localized.text("Pick a class."))
        }
        if repo.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append(Localized.text("Name the repository on that machine."))
        }
        return problems
    }

    /// What is worth saying before sending, though nothing stops it: an open scope, no verifier.
    public var cautions: [String] {
        var cautions: [String] = []
        if pathList.isEmpty {
            cautions.append(Localized.text("No paths: the worker may change any file in the repository."))
        }
        if verify.trimmingCharacters(in: .whitespaces).isEmpty {
            cautions.append(Localized.text("No verify command: the packet passes as soon as the worker changes a file."))
        }
        return cautions
    }

    public var canSend: Bool { problems.isEmpty }

    public func packet() -> DelegatePacket? {
        guard canSend else { return nil }
        var packet = DelegatePacket.draft(
            taskClass: taskClass.trimmingCharacters(in: .whitespaces),
            goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
            repo: repo.trimmingCharacters(in: .whitespaces))
        packet.paths = pathList
        let verify = verify.trimmingCharacters(in: .whitespaces)
        packet.verify = verify.isEmpty ? nil : verify
        packet.read = readList
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        packet.notes = notes.isEmpty ? nil : notes
        packet.tier = tier
        packet.ceiling = ceiling
        packet.effort = effort
        packet.mode = mode == .normal ? nil : mode
        return packet
    }

    /// Verifiers worth offering for the repository named, judged from what a path in it looks like.
    public static func verifySuggestions(paths: [String], repo: String) -> [String] {
        let joined = (paths + [repo]).joined(separator: " ").lowercased()
        var suggestions: [String] = []
        if joined.contains(".rs") || joined.contains("cargo") || joined.contains("/rust/") {
            suggestions += ["cargo test", "cargo build && cargo clippy --all-targets -- -D warnings && cargo test"]
        }
        if joined.contains(".swift") || joined.contains("/ios/") || joined.contains("/swift/") {
            suggestions += ["swift test", "swift build"]
        }
        if joined.contains(".ts") || joined.contains(".js") || joined.contains("package.json") {
            suggestions += ["npm test", "bun test"]
        }
        if joined.contains(".py") {
            suggestions += ["pytest"]
        }
        if joined.contains(".go") {
            suggestions += ["go test ./..."]
        }
        return suggestions
    }
}

/// The form's words, typed once. A phone draws fields, a Mac draws a sheet, Linux draws a dialog,
/// and none of them invents a label.
public enum DelegateComposerWords {
    public static var title: String { DelegateEntryPoint.newPacketTitle }
    public static var goalLabel: String { Localized.text("Goal") }
    public static var goalPlaceholder: String {
        Localized.text("What the worker must achieve, written for a reader with no other context. Name the files.")
    }
    public static var pathsLabel: String { Localized.text("Allowed paths") }
    public static var pathsPlaceholder: String { Localized.text("src/lib.rs\ntests/") }
    public static var pathsHelp: String {
        Localized.text("One path or glob per line. Anything the worker changes outside them fails the attempt.")
    }
    public static var verifyLabel: String { Localized.text("Verify") }
    public static var verifyPlaceholder: String { Localized.text("cargo test") }
    public static var verifyHelp: String {
        Localized.text("Runs in the isolated worktree after the worker finishes; exit 0 passes.")
    }
    public static var readLabel: String { Localized.text("Read first") }
    public static var notesLabel: String { Localized.text("Notes") }
    public static var classLabel: String { Localized.text("Class") }
    public static var repoLabel: String { Localized.text("Repository") }
    public static var repoPlaceholder: String { Localized.text("/home/me/Dev/project") }
    public static var ladderLabel: String { Localized.text("Ladder") }
    public static var ladderHelp: String {
        Localized.text("Tap a rung to start there; drag the cap to set how far the run may climb. Unset means the class decides.")
    }
    public static var modeLabel: String { Localized.text("Mode") }
    public static var effortLabel: String { Localized.text("Effort") }
    public static var effortDefault: String { Localized.text("Runner default") }
    public static var sendTitle: String { Localized.text("Run packet") }
    public static var sendingTitle: String { Localized.text("Starting…") }
    public static var cautionsTitle: String { Localized.text("Before it goes") }
}

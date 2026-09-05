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

    /// Picks a class and lets it fill the verifier: a blank one, or one that was only ever the
    /// previous class's own default, becomes the new class's — a command somebody typed stays.
    public mutating func choose(taskClass name: String, capabilities: DelegateCapabilities?) {
        let previous = capabilities?.policy(for: taskClass)?.verify ?? ""
        taskClass = name
        let current = verify.trimmingCharacters(in: .whitespaces)
        guard current.isEmpty || current == previous else { return }
        verify = capabilities?.policy(for: name)?.verify ?? ""
    }

    /// Where this packet will start and how far it may climb once the daemon fills every blank
    /// from its own table, resolved the way the daemon resolves it.
    public func plan(capabilities: DelegateCapabilities?, tierOrder: [String]) -> DelegateDraftPlan {
        DelegateDraftPlan(draft: self, capabilities: capabilities, tierOrder: tierOrder)
    }

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

/// Where a packet will start and how far it may climb once every blank is filled by the class it
/// belongs to and the mode it runs in — and the sentence that says so before it goes, because a
/// ladder whose unset rungs read "the class decides" is a ladder nobody can read.
public struct DelegateDraftPlan: Sendable, Equatable {
    public var start: String?
    public var ceiling: String?
    public var startIsYours: Bool
    public var ceilingIsYours: Bool
    public var askBefore: String?
    public var legend: String

    public init(draft: DelegateDraft, capabilities: DelegateCapabilities?, tierOrder: [String]) {
        let policy = capabilities?.policy(for: draft.taskClass)
        guard !tierOrder.isEmpty else {
            start = draft.tier ?? policy?.tier
            ceiling = draft.ceiling ?? policy?.ceiling
            startIsYours = draft.tier != nil
            ceilingIsYours = draft.ceiling != nil
            askBefore = nil
            legend = Localized.text("The ladder is read from the machine once it answers.")
            return
        }
        let last = tierOrder.count - 1
        func index(_ tier: String?) -> Int? { tier.flatMap { tierOrder.firstIndex(of: $0) } }
        startIsYours = index(draft.tier) != nil
        ceilingIsYours = index(draft.ceiling) != nil
        var startIndex = index(draft.tier) ?? index(policy?.tier) ?? 0
        var ceilingIndex = index(draft.ceiling) ?? index(policy?.ceiling) ?? last
        let mode: DelegateModePolicy? = {
            switch draft.mode {
            case .normal: return nil
            case .conserve: return capabilities?.modePolicies?.conserve ?? DelegateModePolicy(shift: -1)
            case .rush: return capabilities?.modePolicies?.rush ?? DelegateModePolicy(shift: 1)
            }
        }()
        let unshifted = startIndex
        if let mode {
            let verified = policy?.verified == true || !draft.verify.trimmingCharacters(in: .whitespaces).isEmpty
                || !(policy?.verify ?? "").isEmpty
            if verified, let cap = index(mode.ceilingVerified), cap < ceilingIndex { ceilingIndex = cap }
            startIndex = min(max(startIndex + mode.shift, 0), last)
        }
        if startIndex > ceilingIndex { ceilingIndex = startIndex }
        start = tierOrder[startIndex]
        ceiling = tierOrder[ceilingIndex]
        if let mode, let ask = index(mode.askBefore), ask > startIndex, ask <= ceilingIndex {
            askBefore = tierOrder[ask]
        } else {
            askBefore = nil
        }
        let range: String
        switch (startIsYours, ceilingIsYours) {
        case (false, false):
            range = startIndex == ceilingIndex
                ? Localized.text("Runs only at %@ — the %@ class's own rung.", tierOrder[startIndex], draft.taskClass)
                : Localized.text("Starts at %@ and may climb to %@ — the %@ class's own range.", tierOrder[unshifted], tierOrder[ceilingIndex], draft.taskClass)
        case (true, false):
            range = Localized.text("Starts at %@ because you set it, and may climb to %@, the class's ceiling.", tierOrder[unshifted], tierOrder[ceilingIndex])
        case (false, true):
            range = Localized.text("Starts at %@, the class's own rung, and may climb to %@ because you set it.", tierOrder[unshifted], tierOrder[ceilingIndex])
        case (true, true):
            range = unshifted == ceilingIndex
                ? Localized.text("Runs only at %@, as you set it.", tierOrder[unshifted])
                : Localized.text("Starts at %@ and may climb to %@, as you set it.", tierOrder[unshifted], tierOrder[ceilingIndex])
        }
        var extra: [String] = []
        if draft.mode == .conserve {
            if startIndex != unshifted {
                extra.append(Localized.text("Conserve moves the start down to %@", tierOrder[startIndex]))
            }
            if let askBefore { extra.append(Localized.text("asks before %@", askBefore)) }
        } else if draft.mode == .rush, startIndex != unshifted {
            extra.append(Localized.text("Rush moves the start up to %@", tierOrder[startIndex]))
        }
        legend = extra.isEmpty ? range : range + " " + extra.joined(separator: Localized.text(" and ")) + "."
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
    public static var classHelp: String {
        Localized.text("A class is the daemon's own table: where a blank packet starts, how far it may climb, and what judges it.")
    }
}

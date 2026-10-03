import CodingAgentKit
import Foundation

/// One run as a row on the board: what it set out to do, where it is or how it ended, which repository,
/// how long ago, and a ladder small enough to read at a glance.
public struct DelegateRunRow: Sendable, Equatable, Identifiable {
    public var runID: String
    public var headline: String
    public var detail: String
    public var repo: String
    public var age: String
    public var badge: String?
    public var tone: ActivityTone
    public var activity: ActivityKind?
    /// One state per tier, cheapest first — the run's ladder at the size of a row.
    public var rungs: [DelegateRungState]
    public var spoken: String

    public var id: String { runID }

    public init(story: DelegateRunStory, run: DelegateRun?, now: Date = Date()) {
        runID = story.runID
        headline = story.headline
        detail = story.subtitle
        repo = run.map { DelegateWords.repoName($0.repo) } ?? story.packet?.repo.map(DelegateWords.repoName) ?? ""
        let stamp = run?.finished ?? run?.created
        age = stamp.map { SessionRowModel.age(of: $0, asOf: now) } ?? ""
        badge = story.badge
        tone = story.tone
        activity = story.activity
        rungs = story.ladder.rungs.map(\.state)
        spoken = [headline, badge, detail, repo].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// The board's runs grouped by what they ask of the person reading them: the ones waiting on you, the
/// ones still out, and everything that has settled.
public struct DelegateRunSection: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case needsYou
        case running
        case earlier
    }

    public var kind: Kind
    public var rows: [DelegateRunRow]

    public var id: String { kind.rawValue }

    public var title: String {
        switch kind {
        case .needsYou: return Localized.text("Needs you")
        case .running: return Localized.text("Running")
        case .earlier: return Localized.text("Earlier")
        }
    }

    public init(kind: Kind, rows: [DelegateRunRow]) {
        self.kind = kind
        self.rows = rows
    }
}

/// One tier as the board draws it: the rung, the model answering there, whether it is up, and what
/// the table says it has done.
public struct DelegateBoardRung: Sendable, Hashable, Identifiable {
    public var tier: String
    public var label: String
    public var model: String
    public var fullModel: String
    /// Said only when it means something: answering, or down and why. An entry with no health check
    /// says nothing rather than "not probed", which reads like a fault.
    public var health: String?
    public var tone: ActivityTone
    /// "93% of 45 · 6.4s" across every class, or nil for a rung nothing has run on yet.
    public var record: String?

    public var id: String { tier }

    public var title: String { label.isEmpty ? tier : label }

    public init(tier: DelegateTier, stats: [DelegateStat]) {
        self.tier = tier.tier
        label = tier.label
        let entry = tier.activeEntry
        fullModel = entry?.model ?? tier.chain.first?.model ?? "–"
        model = DelegateWords.shortModel(fullModel)
        if entry == nil {
            health = tier.chain.compactMap(\.reason).first ?? Localized.text("nothing answering")
            tone = .danger
        } else if entry?.healthy == true {
            health = Localized.text("answering")
            tone = .live
        } else {
            health = nil
            tone = .quiet
        }
        let mine = stats.filter { $0.tier == tier.tier }
        let attempts = mine.reduce(0) { $0 + $1.attempts }
        if attempts > 0 {
            let passes = mine.reduce(0) { $0 + $1.passes }
            let weighted = mine.reduce(0.0) { $0 + $1.averageMS * Double($1.attempts) } / Double(attempts)
            let rate = Int((Double(passes) / Double(attempts) * 100).rounded())
            record = Localized.text("%d%% of %d · %@", rate, attempts, DelegateWords.seconds(Int(weighted)))
        } else {
            record = nil
        }
    }
}

/// Something a run invites a person to do, with the weight it is drawn at.
public struct DelegateRunAction: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case approve
        case hold
        case apply
        case discard
        case cancel
        case replay(tier: String)
        case duplicate
    }

    public enum Role: Sendable, Hashable {
        case primary
        case normal
        case destructive
    }

    public var kind: Kind
    public var title: String
    public var detail: String?
    public var role: Role

    public var id: String {
        switch kind {
        case .approve: return "approve"
        case .hold: return "hold"
        case .apply: return "apply"
        case .discard: return "discard"
        case .cancel: return "cancel"
        case .replay(let tier): return "replay:\(tier)"
        case .duplicate: return "duplicate"
        }
    }

    public init(kind: Kind, title: String, detail: String? = nil, role: Role = .normal) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.role = role
    }
}

/// A file in a run's patch, with how much it changes when the patch has been read.
public struct DelegateFileRow: Sendable, Hashable, Identifiable {
    public var path: String
    public var name: String
    public var folder: String
    /// "+12 −3", or nil until the patch is read.
    public var counts: String?
    public var added: Int?
    public var removed: Int?

    public var id: String { path }

    public init(path: String, file: DelegatePatchFile? = nil) {
        self.path = path
        let parts = path.split(separator: "/")
        name = parts.last.map(String.init) ?? path
        folder = parts.dropLast().joined(separator: "/")
        added = file?.added
        removed = file?.removed
        counts = file.map { $0.isBinary ? Localized.text("binary") : "+\($0.added) −\($0.removed)" }
    }
}

/// One run as its own screen reads it: the headline, the facts in a line, the one thing that matters
/// most right now, the ladder, what can be done, the files, and the timeline — every word decided
/// here so the three clients tell one run the same way and draw only the boxes.
public struct DelegateRunReading: Sendable, Equatable {
    /// The block under the headline: why it stopped, what it is waiting for, where the patch went.
    public struct Lead: Sendable, Hashable {
        public var title: String
        /// Where the lead was found — "t2 · attempt 1 · the verifier exited 1".
        public var caption: String?
        public var body: String?
        /// The body is a program's own output and is set in the monospaced face.
        public var bodyIsOutput: Bool
        public var tone: ActivityTone

        public init(title: String, caption: String? = nil, body: String? = nil, bodyIsOutput: Bool = false, tone: ActivityTone) {
            self.title = title
            self.caption = caption
            self.body = body
            self.bodyIsOutput = bodyIsOutput
            self.tone = tone
        }
    }

    public var runID: String
    public var headline: String
    public var facts: String
    public var badge: String?
    public var tone: ActivityTone
    public var activity: ActivityKind?
    public var lead: Lead?
    public var ladder: DelegateLadder
    public var primary: DelegateRunAction?
    public var secondary: [DelegateRunAction]
    /// Every rung the packet can be run again on, for the "Run again on…" menu; empty while it runs.
    public var replayTiers: [String]
    public var filesTitle: String?
    public var files: [DelegateFileRow]
    public var timeline: [DelegateStoryLine]
    public var repo: String
    public var isLive: Bool

    public static var timelineTitle: String { Localized.text("What happened") }
    public static var replayMenuTitle: String { Localized.text("Run again on…") }

    public init(story: DelegateRunStory, run: DelegateRun?, tierOrder: [String], patch: String? = nil) {
        runID = story.runID
        headline = story.headline
        badge = story.badge
        tone = story.tone
        activity = story.activity
        ladder = story.ladder
        isLive = story.isLive
        repo = run?.repo ?? story.packet?.repo ?? ""
        facts = Self.facts(story: story, run: run)
        lead = Self.lead(story: story, repo: repo)
        let order = tierOrder.isEmpty ? story.tierOrder : tierOrder
        (primary, secondary) = Self.actions(story: story, tierOrder: order)
        replayTiers = story.isLive ? [] : order
        let parsed = patch.map(DelegatePatch.files) ?? []
        let paths = story.patchFiles.isEmpty ? parsed.map(\.path) : story.patchFiles
        files = paths.map { path in DelegateFileRow(path: path, file: parsed.first { $0.path == path }) }
        filesTitle = Self.filesTitle(story: story, count: paths.count)
        timeline = story.isLive ? story.lines : story.lines.filter { !$0.isProgress }
    }

    public static func == (lhs: DelegateRunReading, rhs: DelegateRunReading) -> Bool {
        lhs.runID == rhs.runID && lhs.facts == rhs.facts && lhs.badge == rhs.badge && lhs.lead == rhs.lead
            && lhs.ladder == rhs.ladder && lhs.primary == rhs.primary && lhs.secondary == rhs.secondary
            && lhs.files == rhs.files && lhs.timeline == rhs.timeline && lhs.filesTitle == rhs.filesTitle
    }

    private static func facts(story: DelegateRunStory, run: DelegateRun?) -> String {
        var parts: [String] = []
        if let taskClass = run?.taskClass ?? story.packet?.taskClass { parts.append(taskClass) }
        if let start = story.startTier, let ceiling = story.ceiling {
            parts.append(start == ceiling ? start : "\(start) → \(ceiling)")
        }
        if story.mode != .normal { parts.append(DelegateWords.mode(story.mode).lowercased()) }
        let repo = run?.repo ?? story.packet?.repo ?? ""
        if !repo.isEmpty { parts.append(DelegateWords.repoName(repo)) }
        if let duration = story.durationMS ?? Self.duration(run) { parts.append(DelegateWords.seconds(duration)) }
        let tokens = story.tokensIn + story.tokensOut
        if tokens > 0 { parts.append(Localized.text("%@ tokens", DelegateWords.tokens(tokens))) }
        return parts.joined(separator: " · ")
    }

    private static func duration(_ run: DelegateRun?) -> Int? {
        guard let start = run?.created, let end = run?.finished else { return nil }
        return Int(end.timeIntervalSince(start) * 1000)
    }

    private static func lead(story: DelegateRunStory, repo: String) -> Lead? {
        switch story.status {
        case .running:
            if let pending = story.pendingApproval {
                return Lead(
                    title: Localized.text("%@ is waiting for you", pending.tier),
                    body: Localized.text("Approve to let the run spend %@; hold to stop it here.", pending.tier),
                    tone: .attention)
            }
            guard let tier = story.currentTier else {
                return Lead(title: Localized.text("Starting"), tone: .live)
            }
            let attempt = story.attempts.filter { $0.tier == tier }.count + 1
            var caption = Localized.text("%@ · attempt %d", tier, attempt)
            if let model = story.currentModel[tier] { caption += " · " + DelegateWords.shortModel(model) }
            let doing = story.lines.last.flatMap { $0.isProgress && $0.tier == tier ? $0.text : nil }
            return Lead(title: Localized.text("Working"), caption: caption, body: doing, tone: .live)
        case .passed:
            let verified = story.attempts.last { $0.status == .pass }?.verifyExit != nil
            let passedAt = story.passedTier.map { Localized.text("Passed at %@", $0) } ?? DelegateWords.status(.passed)
            switch story.delivery {
            case .pending:
                return Lead(
                    title: Localized.text("Ready for your review"),
                    caption: passedAt,
                    body: verified
                        ? Localized.text("Its verifier passed. Nothing is in your tree until you apply it.")
                        : Localized.text("Nothing judged this one: no verifier ran, so passing only means a file changed. Read it before you apply it."),
                    tone: .attention)
            case .discarded:
                return Lead(
                    title: Localized.text("Discarded"), caption: passedAt,
                    body: Localized.text("The tree never saw it. The patch is still here to read."), tone: .quiet)
            case .applied, nil:
                return Lead(
                    title: Localized.text("Applied to the tree"), caption: passedAt,
                    body: repo.isEmpty
                        ? Localized.text("Unstaged — read it the way you would read a pull request before you commit it.")
                        : Localized.text("Unstaged in %@ — read it the way you would read a pull request before you commit it.", DelegateWords.repoName(repo)),
                    tone: .live)
            }
        case .failed:
            guard let last = story.lastFailure else {
                return Lead(title: Localized.text("Why it stopped"), body: Localized.text("No rung could take it."), tone: .danger)
            }
            let detail = DelegateRunStory.failureDetail(last)
            return Lead(
                title: Localized.text("Why it stopped"),
                caption: Localized.text("%@ · attempt %d · %@", last.tier, last.attempt, DelegateRunStory.attemptReason(last)),
                body: detail ?? DelegateWords.tail(last.workerSummary),
                bodyIsOutput: detail != nil,
                tone: .danger)
        case .held:
            return Lead(
                title: Localized.text("Held before %@", story.currentTier ?? "-"),
                body: Localized.text("You held it before it spent that rung. Run it again there to let it climb."),
                tone: .attention)
        case .cancelled:
            return Lead(title: Localized.text("Cancelled"), tone: .quiet)
        case .error:
            return Lead(
                title: Localized.text("The dispatcher hit an error"),
                body: DelegateWords.tail(story.summary), bodyIsOutput: true, tone: .danger)
        }
    }

    private static func actions(story: DelegateRunStory, tierOrder: [String]) -> (DelegateRunAction?, [DelegateRunAction]) {
        if story.needsApproval, let tier = story.pendingApproval?.tier {
            return (
                DelegateRunAction(kind: .approve, title: Localized.text("Approve %@", tier), role: .primary),
                [
                    DelegateRunAction(kind: .hold, title: Localized.text("Hold")),
                    DelegateRunAction(kind: .cancel, title: Localized.text("Cancel run"), role: .destructive),
                ])
        }
        if story.isLive {
            return (nil, [DelegateRunAction(kind: .cancel, title: Localized.text("Cancel run"), role: .destructive)])
        }
        if story.needsReview {
            return (
                DelegateRunAction(
                    kind: .apply, title: Localized.text("Apply to the tree"),
                    detail: Localized.text("Lands the files unstaged; nothing is committed."), role: .primary),
                [
                    DelegateRunAction(
                        kind: .discard, title: Localized.text("Discard"),
                        detail: Localized.text("Sets the patch aside; the tree never sees it."), role: .destructive),
                    action(DelegateNextStep.duplicate),
                ])
        }
        let steps = story.nextSteps(tierOrder: tierOrder).map(action)
        guard story.status != .passed, let first = steps.first, first.kind != .duplicate else { return (nil, steps) }
        var lead = first
        lead.role = .primary
        return (lead, Array(steps.dropFirst()))
    }

    private static func action(_ step: DelegateNextStep) -> DelegateRunAction {
        switch step.kind {
        case .replay(let tier): return DelegateRunAction(kind: .replay(tier: tier), title: step.title, detail: step.detail)
        case .duplicate: return DelegateRunAction(kind: .duplicate, title: step.title, detail: step.detail)
        }
    }

    private static func filesTitle(story: DelegateRunStory, count: Int) -> String? {
        guard count > 0, story.status == .passed else { return nil }
        switch story.delivery {
        case .pending:
            return count == 1 ? Localized.text("1 file to review") : Localized.text("%d files to review", count)
        case .discarded:
            return count == 1 ? Localized.text("1 file, discarded") : Localized.text("%d files, discarded", count)
        case .applied, nil:
            return count == 1 ? Localized.text("1 file applied") : Localized.text("%d files applied", count)
        }
    }
}

/// One file's part of a unified diff.
public struct DelegatePatchFile: Sendable, Hashable, Identifiable {
    public var path: String
    public var patch: String
    public var added: Int
    public var removed: Int
    public var isBinary: Bool

    public var id: String { path }
}

/// A run's patch split by file, so each file opens its own diff with the gutter every desk already
/// draws for the repository surface.
public enum DelegatePatch {
    public static func files(_ patch: String) -> [DelegatePatchFile] {
        var files: [DelegatePatchFile] = []
        var current: DelegatePatchFile?
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                if let current { files.append(current) }
                current = DelegatePatchFile(path: path(header: line), patch: "", added: 0, removed: 0, isBinary: false)
            }
            guard var file = current else { continue }
            file.patch += file.patch.isEmpty ? String(line) : "\n" + line
            if line.hasPrefix("+++ ") {
                let target = line.dropFirst(4)
                if target.hasPrefix("b/") { file.path = String(target.dropFirst(2)) }
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                file.isBinary = true
            } else if line.hasPrefix("+"), !line.hasPrefix("+++") {
                file.added += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                file.removed += 1
            }
            current = file
        }
        if let current { files.append(current) }
        return files
    }

    private static func path(header: Substring) -> String {
        let rest = header.dropFirst("diff --git ".count)
        guard let range = rest.range(of: " b/", options: .backwards) else { return String(rest) }
        return String(rest[range.upperBound...])
    }
}

/// A conversation as the dispatcher's surfaces see it: where it works and whether a turn is running
/// there now. Every client already lists its chats; this is the slice of a row these readings need.
public struct DelegateChatFootprint: Sendable, Hashable {
    public var title: String
    public var directory: String
    public var isWorking: Bool

    public init(title: String, directory: String, isWorking: Bool) {
        self.title = title
        self.directory = directory
        self.isWorking = isWorking
    }

    /// The chats a listing holds on one machine, newest first, each with the directory it works in;
    /// a subagent is part of its parent's chat and a chat with no directory has nothing to offer.
    public static func from(_ entries: [SessionEntry], host: String) -> [DelegateChatFootprint] {
        entries
            .filter { $0.host == host && !$0.session.isSubagent }
            .sorted { $0.session.updatedAt > $1.session.updatedAt }
            .compactMap { entry in
                guard let directory = entry.session.directory, !directory.isEmpty else { return nil }
                let title = entry.session.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return DelegateChatFootprint(
                    title: title.isEmpty ? DelegateWords.repoName(directory) : title, directory: directory,
                    isWorking: entry.session.isWorking)
            }
    }
}

/// A repository the composer can offer, so a packet's most error-prone field is picked rather than
/// typed on a phone.
public struct DelegateRepoChoice: Sendable, Hashable, Identifiable {
    public var path: String
    public var name: String
    public var detail: String

    public var id: String { path }
}

public enum DelegateRepoChoices {
    /// Where this machine's chats work, most recent first, then every repository its runs used — each
    /// path once, named by its last directory and told by what put it on the list.
    public static func make(runs: [DelegateRun], chats: [DelegateChatFootprint], limit: Int = 8) -> [DelegateRepoChoice] {
        var seen: Set<String> = []
        var choices: [DelegateRepoChoice] = []
        func add(_ path: String, _ detail: String) {
            let key = normalized(path)
            guard !key.isEmpty, !seen.contains(key), choices.count < limit else { return }
            seen.insert(key)
            choices.append(DelegateRepoChoice(path: key, name: DelegateWords.repoName(key), detail: detail))
        }
        for chat in chats { add(chat.directory, Localized.text("Chat · %@", chat.title)) }
        let counts = Dictionary(grouping: runs, by: { normalized($0.repo) }).mapValues(\.count)
        for run in runs {
            let count = counts[normalized(run.repo)] ?? 1
            add(run.repo, count == 1 ? Localized.text("1 run here") : Localized.text("%d runs here", count))
        }
        return choices
    }

    static func normalized(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1, trimmed.hasSuffix("/") else { return trimmed }
        return String(trimmed.dropLast())
    }
}

/// What applying a held patch would land under: a chat that is working in the same repository right
/// now writes those files too, and the person deserves to hear that before the press, not after.
public enum DelegateApplyCheck {
    public static func cautions(repo: String, chats: [DelegateChatFootprint]) -> [String] {
        let root = DelegateRepoChoices.normalized(repo)
        guard !root.isEmpty else { return [] }
        return chats.filter { chat in
            let directory = DelegateRepoChoices.normalized(chat.directory)
            return chat.isWorking
                && (directory == root || directory.hasPrefix(root + "/") || root.hasPrefix(directory + "/"))
        }
        .map { Localized.text("“%@” is working in this repository right now, and applying lands files under it.", $0.title) }
    }

    public static var confirmTitle: String { Localized.text("Apply while a chat is working here?") }
    public static var confirmAction: String { Localized.text("Apply anyway") }
}

/// A packet started from a conversation: the words the person typed, the repository the chat works
/// in, and the machine it runs on — so the composer opens with its hardest fields already right.
public struct DelegateHandoff: Sendable, Equatable {
    public var host: String
    public var serverName: String
    public var goal: String
    public var repo: String

    public init(host: String, serverName: String, goal: String, repo: String) {
        self.host = host
        self.serverName = serverName
        self.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        self.repo = repo
    }

    public func draft(capabilities: DelegateCapabilities?) -> DelegateDraft {
        var draft = DelegateDraft(capabilities: capabilities, repo: repo)
        draft.goal = goal
        draft.choose(taskClass: draft.taskClass, capabilities: capabilities)
        return draft
    }

    /// The catalog row's words and the menu title wherever a chat offers the door.
    public static var menuTitle: String { Localized.text("Delegate a task…") }
    public static var details: String { Localized.text("Hand a bounded task in this repository to a cheaper tier") }
    public static var argumentHint: String { Localized.text("<the task>") }
}

/// What a refused apply or discard says. The daemon answers 409 with its own reason in JSON — git's
/// words when the tree moved under the patch — and that reason is the message, not the status.
public struct DelegateRefusal: Sendable, Equatable {
    public var title: String
    public var body: String
    /// The body is git's or the daemon's own output and is set in the monospaced face.
    public var bodyIsOutput: Bool

    public init(_ error: Error) {
        guard let agentError = error as? AgentError, case .http(let status, let raw) = agentError else {
            title = Localized.text("The dispatcher could not be reached")
            body = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            bodyIsOutput = false
            return
        }
        let said = Self.message(raw)
        switch status {
        case 409 where said.contains("patch") && (said.contains("check") || said.contains("does not apply") || said.contains("failed")):
            title = Localized.text("The tree moved under this patch")
            body = said
            bodyIsOutput = true
        case 409:
            title = Localized.text("Nothing is waiting here any more")
            body = said
            bodyIsOutput = false
        case 404:
            title = Localized.text("This dispatcher cannot hold a patch")
            body = Localized.text("It answered without the review routes. delegate 0.4 can hold, apply and discard a patch.")
            bodyIsOutput = false
        default:
            title = Localized.text("The dispatcher refused")
            body = "HTTP \(status) · \(said)"
            bodyIsOutput = false
        }
    }

    static func message(_ raw: String) -> String {
        if let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? String
        {
            return error
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

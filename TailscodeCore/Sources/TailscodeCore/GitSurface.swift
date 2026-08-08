import CodingAgentKit
import Foundation

/// What a git colour means, named by the meaning rather than the colour. Five slots, nothing
/// shared: a client maps them to its own palette once and every surface agrees after that.
public enum GitTone: String, Sendable, Equatable, CaseIterable {
    /// Something that did not exist before — an added file, a line arriving.
    case added
    /// Something that is going away — a deleted file, a line leaving.
    case removed
    /// The same thing, differently: modified, renamed, retyped.
    case changed
    /// Outside version control entirely. Quiet on purpose: untracked files are usually noise.
    case untracked
    /// The repository is stopped and wants a person — a conflict, a half-finished rebase.
    case conflict
    /// A fact with no charge: a branch name, a hash, a date.
    case neutral
}

/// What happened to one path, in the vocabulary a reader already has. The letter is git's own, so
/// anyone who has read `git status` recognises the column without a legend.
public enum GitChangeKind: String, Sendable, Equatable, CaseIterable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case typeChanged
    case untracked
    case untrackedDirectory
    case conflicted
    case submodule

    /// The single letter a text client draws, and an Apple client puts beside its symbol. One
    /// column wide everywhere, so a list of paths stays a column of paths.
    public var glyph: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .untracked, .untrackedDirectory: return "?"
        case .conflicted: return "!"
        case .submodule: return "S"
        }
    }

    public var symbol: String {
        switch self {
        case .added: return "plus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .deleted: return "minus.circle.fill"
        case .renamed: return "arrow.triangle.turn.up.right.circle.fill"
        case .copied: return "doc.on.doc.fill"
        case .typeChanged: return "arrow.triangle.2.circlepath.circle.fill"
        case .untracked: return "questionmark.circle.fill"
        case .untrackedDirectory: return "folder.badge.questionmark"
        case .conflicted: return "exclamationmark.triangle.fill"
        case .submodule: return "shippingbox.circle.fill"
        }
    }

    public var word: String {
        switch self {
        case .added: return Localized.text("Added")
        case .modified: return Localized.text("Modified")
        case .deleted: return Localized.text("Deleted")
        case .renamed: return Localized.text("Renamed")
        case .copied: return Localized.text("Copied")
        case .typeChanged: return Localized.text("Type changed")
        case .untracked: return Localized.text("Untracked")
        case .untrackedDirectory: return Localized.text("Untracked folder")
        case .conflicted: return Localized.text("Conflicted")
        case .submodule: return Localized.text("Submodule")
        }
    }

    public var tone: GitTone {
        switch self {
        case .added, .copied: return .added
        case .deleted: return .removed
        case .modified, .renamed, .typeChanged, .submodule: return .changed
        case .untracked, .untrackedDirectory: return .untracked
        case .conflicted: return .conflict
        }
    }

    /// Reads git's status letter for one side of a change. `nil` is "this side is unchanged",
    /// which the caller has already decided is not the side it is describing.
    public static func from(letter: String?) -> GitChangeKind {
        switch letter?.uppercased() {
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        case "U": return .conflicted
        case "?": return .untracked
        default: return .modified
        }
    }
}

/// One path as a list draws it: what happened, where it is, and how much of it moved.
public struct GitRow: Sendable, Hashable, Identifiable {
    public let path: String
    public let name: String
    /// The directories above the file, without a trailing slash; empty at the repository root.
    public let folder: String
    public let original: String?
    public let kind: GitChangeKind
    /// The row is describing what a commit would take, rather than what it would leave behind.
    public let staged: Bool
    public let insertions: Int
    public let deletions: Int
    /// The right-hand fact: line counts for a diff, a file count for an untracked folder, a size
    /// for something with no lines to count.
    public let detail: String
    public let binary: Bool
    public let submodule: Bool

    public var id: String { (staged ? "staged:" : "worktree:") + path }
    public var tone: GitTone { kind.tone }
    public var hasCounts: Bool { insertions > 0 || deletions > 0 }

    /// What a screen reader says instead of reading a letter, a slash-heavy path and two numbers.
    public var spoken: String {
        var parts = [kind.word, name]
        if !folder.isEmpty { parts.append(Localized.text("in %@", folder)) }
        if insertions > 0 { parts.append(Localized.text("%d added", insertions)) }
        if deletions > 0 { parts.append(Localized.text("%d removed", deletions)) }
        return parts.joined(separator: ", ")
    }
}

/// A run of rows under one heading. The order is the order a person triages in: what is broken,
/// what is about to be committed, what is not, and finally what git does not track at all.
public struct GitSection: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case conflicts
        case staged
        case changed
        case untracked

        public var title: String {
            switch self {
            case .conflicts: return Localized.text("CONFLICTS")
            case .staged: return Localized.text("STAGED")
            case .changed: return Localized.text("CHANGED")
            case .untracked: return Localized.text("UNTRACKED")
            }
        }

        public var tone: GitTone {
            switch self {
            case .conflicts: return .conflict
            case .staged: return .added
            case .changed: return .changed
            case .untracked: return .untracked
            }
        }
    }

    public let kind: Kind
    public let rows: [GitRow]

    public var id: String { kind.rawValue }
    public var title: String { kind.title }
    public var tone: GitTone { kind.tone }
    public var insertions: Int { rows.reduce(0) { $0 + $1.insertions } }
    public var deletions: Int { rows.reduce(0) { $0 + $1.deletions } }
}

/// A labelled fact from the header — branch, upstream, head, stash, last fetch. A pair, because
/// every client draws these as a two-column list and none of them should decide what goes in it.
public struct GitFact: Sendable, Hashable, Identifiable {
    public let label: String
    public let value: String
    public let tone: GitTone

    public var id: String { label }

    public init(label: String, value: String, tone: GitTone = .neutral) {
        self.label = label
        self.value = value
        self.tone = tone
    }
}

public struct GitCommitRow: Sendable, Hashable, Identifiable {
    public let hash: String
    public let short: String
    public let subject: String
    public let author: String
    public let age: String
    /// Branch and tag names sitting on this commit, cleaned of git's `HEAD -> ` decoration.
    public let refs: [String]
    public let isHead: Bool

    public var id: String { hash }
}

/// The whole repository, arranged for reading rather than for operating.
///
/// Nothing in this type describes an action, because the app does not offer one: a commit made
/// from a phone is a commit nobody reviewed on the machine that has to live with it. What it does
/// offer is the state a change is landing in — which branch, how far from the upstream, what the
/// working tree is already holding — which is the thing that is genuinely hard to know from a
/// transcript, and the thing that decides whether a person tells the agent to keep going.
public struct GitState: Sendable, Equatable {
    public let snapshot: GitSnapshot
    public let sections: [GitSection]
    public let facts: [GitFact]
    public let commits: [GitCommitRow]

    /// The branch, or the commit when there is no branch to name.
    public let title: String
    /// What the branch owes its upstream, said in words: "2 ahead", "up to date", "no upstream".
    public let sync: String
    public let syncTone: GitTone
    /// One line for what the working tree holds: "12 changed · 3 staged", or "Working tree clean".
    public let summary: String
    /// A state that has stopped and wants a person — a conflict, or an operation left half-done.
    public let alert: String?
    public let insertions: Int
    public let deletions: Int
    public let changedCount: Int
    public let stagedCount: Int
    public let untrackedCount: Int
    public let conflictCount: Int

    public var isClean: Bool { changedCount == 0 && stagedCount == 0 && untrackedCount == 0 }
    public var isRepository: Bool { snapshot.repo }
    /// More paths changed than the server listed, so a client says so instead of implying the
    /// working tree is smaller than it is.
    public var truncated: Bool { snapshot.truncated }
    public var hiddenCount: Int { max(0, snapshot.changedTotal - snapshot.changes.count) }

    public init(snapshot: GitSnapshot, now: Date = Date()) {
        self.snapshot = snapshot
        let rows = Self.rows(of: snapshot)
        self.sections = Self.sections(from: rows)
        self.commits = snapshot.commits.map { commit in
            GitCommitRow(
                hash: commit.hash, short: commit.short, subject: commit.subject,
                author: commit.author, age: Self.age(commit.at, now: now),
                refs: commit.refs.map(Self.cleanRef).filter { !$0.isEmpty },
                isHead: commit.refs.contains { $0.contains("HEAD") })
        }
        self.conflictCount = rows.filter { $0.kind == .conflicted }.count
        self.stagedCount = rows.filter { $0.staged && $0.kind != .conflicted }.count
        self.untrackedCount = rows.filter {
            $0.kind == .untracked || $0.kind == .untrackedDirectory
        }.count
        self.changedCount = rows.filter {
            !$0.staged && $0.kind != .conflicted && $0.kind != .untracked
                && $0.kind != .untrackedDirectory
        }.count
        self.insertions = rows.reduce(0) { $0 + $1.insertions }
        self.deletions = rows.reduce(0) { $0 + $1.deletions }
        if snapshot.detached {
            self.title = Localized.text("detached at %@", snapshot.head ?? "?")
        } else {
            self.title = snapshot.branch ?? snapshot.head ?? Localized.text("no branch")
        }
        let sync = Self.sync(snapshot)
        self.sync = sync.0
        self.syncTone = sync.1
        self.summary = Self.summary(
            changed: changedCount, staged: stagedCount, untracked: untrackedCount,
            conflicts: conflictCount, truncated: snapshot.truncated,
            hidden: max(0, snapshot.changedTotal - snapshot.changes.count))
        self.alert = Self.alert(snapshot, conflicts: conflictCount)
        self.facts = Self.facts(snapshot, sync: sync.0, syncTone: sync.1, now: now)
    }

    /// The chip a chat's chrome wears: the branch, and how far the tree has drifted from it. Short
    /// enough to sit beside a model name, and never a number without its meaning.
    public var badge: String {
        var text = title
        if snapshot.ahead > 0 { text += " ↑\(snapshot.ahead)" }
        if snapshot.behind > 0 { text += " ↓\(snapshot.behind)" }
        let dirty = changedCount + stagedCount + conflictCount
        if dirty > 0 { text += " ●\(dirty)" }
        return text
    }

    public var badgeTone: GitTone {
        if conflictCount > 0 || snapshot.operation != nil { return .conflict }
        if changedCount + stagedCount > 0 { return .changed }
        return .neutral
    }

    /// What the badge says out loud, which is a sentence rather than three symbols.
    public var spokenBadge: String {
        var parts = [Localized.text("Branch %@", title), sync]
        parts.append(summary)
        return parts.joined(separator: ", ")
    }

    private static func rows(of snapshot: GitSnapshot) -> [GitRow] {
        var rows: [GitRow] = []
        for change in snapshot.changes {
            if change.conflicted {
                rows.append(row(change, staged: false, kind: .conflicted))
                continue
            }
            if change.untracked {
                rows.append(
                    row(
                        change, staged: false,
                        kind: change.directory ? .untrackedDirectory : .untracked))
                continue
            }
            if change.index != nil {
                rows.append(
                    row(change, staged: true, kind: GitChangeKind.from(letter: change.index)))
            }
            if change.worktree != nil {
                rows.append(
                    row(change, staged: false, kind: GitChangeKind.from(letter: change.worktree)))
            }
        }
        return rows
    }

    private static func row(_ change: GitChange, staged: Bool, kind: GitChangeKind) -> GitRow {
        let trimmed = change.path.hasSuffix("/") ? String(change.path.dropLast()) : change.path
        let components = trimmed.split(separator: "/")
        let name = components.last.map(String.init) ?? trimmed
        let folder = components.dropLast().joined(separator: "/")
        let insertions = staged ? change.stagedInsertions : change.insertions
        let deletions = staged ? change.stagedDeletions : change.deletions
        return GitRow(
            path: change.path, name: name, folder: folder,
            original: change.original.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 },
            kind: change.submodule ? .submodule : kind, staged: staged, insertions: insertions,
            deletions: deletions,
            detail: detail(change, insertions: insertions, deletions: deletions),
            binary: change.binary, submodule: change.submodule)
    }

    /// The one fact that fits at the end of a row. Lines when there are lines, files when the row
    /// stands for a folder, bytes when there is nothing countable — and nothing at all rather than
    /// a decorative zero.
    private static func detail(_ change: GitChange, insertions: Int, deletions: Int) -> String {
        if change.directory {
            guard let contains = change.contains, contains > 0 else { return "" }
            let count = number(contains) + (change.containsAtLeast ? "+" : "")
            return Localized.text("%@ files", count)
        }
        if change.binary { return Localized.text("binary") }
        if insertions > 0 || deletions > 0 {
            var parts: [String] = []
            if insertions > 0 { parts.append("+\(number(insertions))") }
            if deletions > 0 { parts.append("−\(number(deletions))") }
            return parts.joined(separator: " ")
        }
        guard let bytes = change.bytes, bytes > 0 else { return "" }
        return size(bytes)
    }

    private static func sections(from rows: [GitRow]) -> [GitSection] {
        let order: [(GitSection.Kind, (GitRow) -> Bool)] = [
            (.conflicts, { $0.kind == .conflicted }),
            (.staged, { $0.staged && $0.kind != .conflicted }),
            (
                .changed,
                {
                    !$0.staged && $0.kind != .conflicted && $0.kind != .untracked
                        && $0.kind != .untrackedDirectory
                }
            ),
            (.untracked, { $0.kind == .untracked || $0.kind == .untrackedDirectory }),
        ]
        return order.compactMap { kind, belongs in
            let matching = rows.filter(belongs).sorted { left, right in
                if left.folder == right.folder { return left.name < right.name }
                return left.folder < right.folder
            }
            return matching.isEmpty ? nil : GitSection(kind: kind, rows: matching)
        }
    }

    private static func sync(_ snapshot: GitSnapshot) -> (String, GitTone) {
        guard snapshot.repo else { return (Localized.text("not a repository"), .neutral) }
        guard snapshot.upstream != nil else {
            return (Localized.text("no upstream"), .untracked)
        }
        switch (snapshot.ahead, snapshot.behind) {
        case (0, 0): return (Localized.text("up to date"), .neutral)
        case (let ahead, 0): return (Localized.text("%d ahead", ahead), .added)
        case (0, let behind): return (Localized.text("%d behind", behind), .removed)
        case (let ahead, let behind):
            return (Localized.text("%1$d ahead, %2$d behind", ahead, behind), .conflict)
        }
    }

    private static func summary(
        changed: Int, staged: Int, untracked: Int, conflicts: Int, truncated: Bool, hidden: Int
    ) -> String {
        var parts: [String] = []
        if conflicts > 0 { parts.append(Localized.text("%d conflicted", conflicts)) }
        if staged > 0 { parts.append(Localized.text("%d staged", staged)) }
        if changed > 0 { parts.append(Localized.text("%d changed", changed)) }
        if untracked > 0 { parts.append(Localized.text("%d untracked", untracked)) }
        if parts.isEmpty { return Localized.text("Working tree clean") }
        if truncated, hidden > 0 { parts.append(Localized.text("%d more", hidden)) }
        return parts.joined(separator: " · ")
    }

    /// The one line that overrides everything else on the header, or nothing. An operation left
    /// half-finished is the state a person most needs told about, because every other number on
    /// the screen is describing a working tree that is mid-manoeuvre.
    private static func alert(_ snapshot: GitSnapshot, conflicts: Int) -> String? {
        if let operation = snapshot.operation {
            if conflicts > 0 {
                return Localized.text(
                    "%1$@ in progress · %2$d conflicted", operationWord(operation), conflicts)
            }
            return Localized.text("%@ in progress", operationWord(operation))
        }
        if conflicts > 0 { return Localized.text("%d files conflicted", conflicts) }
        return nil
    }

    private static func operationWord(_ raw: String) -> String {
        switch raw {
        case "rebase": return Localized.text("Rebase")
        case "merge": return Localized.text("Merge")
        case "cherry-pick": return Localized.text("Cherry-pick")
        case "revert": return Localized.text("Revert")
        case "bisect": return Localized.text("Bisect")
        default: return raw
        }
    }

    private static func facts(
        _ snapshot: GitSnapshot, sync: String, syncTone: GitTone, now: Date
    ) -> [GitFact] {
        var facts: [GitFact] = []
        if let upstream = snapshot.upstream {
            facts.append(GitFact(label: Localized.text("Upstream"), value: upstream, tone: syncTone))
        } else if snapshot.repo {
            facts.append(
                GitFact(label: Localized.text("Upstream"), value: sync, tone: .untracked))
        }
        if let head = snapshot.head {
            facts.append(GitFact(label: Localized.text("Head"), value: head))
        }
        if snapshot.stashes > 0 {
            facts.append(
                GitFact(
                    label: Localized.text("Stashed"),
                    value: Localized.text("%d", snapshot.stashes), tone: .changed))
        }
        if let fetched = snapshot.fetchedAt {
            facts.append(
                GitFact(label: Localized.text("Fetched"), value: age(fetched, now: now)))
        }
        if let remote = snapshot.remote {
            facts.append(GitFact(label: Localized.text("Remote"), value: shortRemote(remote)))
        }
        if !snapshot.root.isEmpty {
            facts.append(GitFact(label: Localized.text("Root"), value: snapshot.root))
        }
        return facts
    }

    /// A remote as a person names it — `owner/repo` — rather than the URL they cloned it with.
    public static func shortRemote(_ raw: String) -> String {
        var text = raw
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        let host = text.prefix { $0 != "/" }
        if let at = host.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        text = text.replacingOccurrences(of: ":", with: "/")
        let parts = text.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return text }
        return parts.suffix(2).joined(separator: "/")
    }

    public static func cleanRef(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let arrow = text.range(of: "-> ") { text = String(text[arrow.upperBound...]) }
        if text.hasPrefix("tag: ") { text = String(text.dropFirst(5)) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// How long ago, at the precision a reader cares about: minutes today, days this month, a date
    /// after that — never "1,209 hours ago".
    public static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return Localized.text("just now") }
        if seconds < 3600 { return Localized.text("%dm ago", Int(seconds / 60)) }
        if seconds < 86400 { return Localized.text("%dh ago", Int(seconds / 3600)) }
        if seconds < 86400 * 30 { return Localized.text("%dd ago", Int(seconds / 86400)) }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    public static func number(_ value: Int) -> String {
        guard value >= 1000 else { return "\(value)" }
        var digits = Array(String(value))
        var index = digits.count - 3
        while index > 0 {
            digits.insert(",", at: index)
            index -= 3
        }
        return String(digits)
    }

    public static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return Localized.text("%d B", bytes) }
        if bytes < 1024 * 1024 {
            return Localized.text("%@ KB", String(format: "%.1f", Double(bytes) / 1024))
        }
        return Localized.text("%@ MB", String(format: "%.1f", Double(bytes) / (1024 * 1024)))
    }
}

/// A unified diff, read once here so three clients draw the same colours down the same gutter.
public enum GitDiffLineKind: String, Sendable, Equatable {
    case meta
    case hunk
    case addition
    case deletion
    case context

    public var tone: GitTone {
        switch self {
        case .addition: return .added
        case .deletion: return .removed
        case .hunk: return .changed
        case .meta, .context: return .neutral
        }
    }
}

public struct GitDiffLine: Sendable, Hashable, Identifiable {
    public let index: Int
    public let kind: GitDiffLineKind
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?

    public var id: Int { index }
}

/// Turns a patch into lines with their own numbers. The numbering is the point: a diff a reader
/// cannot locate in the file is a diff they have to open an editor to act on.
public enum GitPatchReader {
    public static let lineLimit = 4000

    public static func lines(_ patch: String, limit: Int = lineLimit) -> [GitDiffLine] {
        var result: [GitDiffLine] = []
        var oldLine = 0
        var newLine = 0
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if result.count >= limit { break }
            let text = String(raw)
            let index = result.count
            if text.hasPrefix("@@") {
                let numbers = hunkNumbers(text)
                oldLine = numbers.0
                newLine = numbers.1
                result.append(
                    GitDiffLine(index: index, kind: .hunk, text: text, oldLine: nil, newLine: nil))
                continue
            }
            if isMeta(text) {
                result.append(
                    GitDiffLine(index: index, kind: .meta, text: text, oldLine: nil, newLine: nil))
                continue
            }
            if text.hasPrefix("+") {
                result.append(
                    GitDiffLine(
                        index: index, kind: .addition, text: String(text.dropFirst()),
                        oldLine: nil, newLine: newLine))
                newLine += 1
                continue
            }
            if text.hasPrefix("-") {
                result.append(
                    GitDiffLine(
                        index: index, kind: .deletion, text: String(text.dropFirst()),
                        oldLine: oldLine, newLine: nil))
                oldLine += 1
                continue
            }
            let body = text.hasPrefix(" ") ? String(text.dropFirst()) : text
            result.append(
                GitDiffLine(
                    index: index, kind: .context, text: body, oldLine: oldLine, newLine: newLine))
            oldLine += 1
            newLine += 1
        }
        while let last = result.last, last.kind == .context, last.text.isEmpty {
            result.removeLast()
        }
        return result
    }

    public static func stats(_ lines: [GitDiffLine]) -> (insertions: Int, deletions: Int) {
        (
            lines.filter { $0.kind == .addition }.count,
            lines.filter { $0.kind == .deletion }.count
        )
    }

    private static func isMeta(_ text: String) -> Bool {
        text.hasPrefix("diff --git") || text.hasPrefix("index ") || text.hasPrefix("--- ")
            || text.hasPrefix("+++ ") || text.hasPrefix("new file") || text.hasPrefix("deleted file")
            || text.hasPrefix("similarity index") || text.hasPrefix("rename ")
            || text.hasPrefix("old mode") || text.hasPrefix("new mode")
            || text.hasPrefix("Binary files") || text.hasPrefix("\\ No newline")
    }

    /// `@@ -12,7 +12,9 @@` — the two starting line numbers, which is all the header is for here.
    private static func hunkNumbers(_ text: String) -> (Int, Int) {
        let fields = text.split(separator: " ")
        var old = 0
        var new = 0
        for field in fields {
            guard let first = field.first, first == "-" || first == "+" else { continue }
            let value = Int(field.dropFirst().split(separator: ",").first ?? "") ?? 0
            if first == "-" { old = value } else { new = value }
        }
        return (old, new)
    }
}

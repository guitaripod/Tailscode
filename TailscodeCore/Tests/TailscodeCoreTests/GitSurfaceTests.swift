import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("What the repository is doing")
struct GitSurfaceTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func snapshot(
        branch: String? = "master", upstream: String? = "origin/master", ahead: Int = 0,
        behind: Int = 0, changes: [GitChange] = [], operation: String? = nil, stashes: Int = 0,
        detached: Bool = false, head: String? = "abc12345", truncated: Bool = false,
        changedTotal: Int? = nil, commits: [GitCommitSummary] = []
    ) -> GitSnapshot {
        GitSnapshot(
            root: "/home/dev/project", repo: true, branch: branch, detached: detached, head: head,
            upstream: upstream, ahead: ahead, behind: behind, stashes: stashes,
            operation: operation, remote: "git@github.com:acme/project.git", fetchedAt: nil,
            changes: changes, commits: commits, truncated: truncated,
            changedTotal: changedTotal ?? changes.count)
    }

    @Test("A file staged and edited again appears in both sections, counted apart")
    func splitsBothSides() {
        let change = GitChange(
            path: "Sources/App/Main.swift", index: "M", worktree: "M", insertions: 3, deletions: 1,
            stagedInsertions: 10, stagedDeletions: 2)
        let state = GitState(snapshot: Self.snapshot(changes: [change]), now: Self.now)
        #expect(state.stagedCount == 1)
        #expect(state.changedCount == 1)
        #expect(state.sections.map(\.kind) == [.staged, .changed])
        let staged = state.sections.first { $0.kind == .staged }?.rows.first
        let unstaged = state.sections.first { $0.kind == .changed }?.rows.first
        #expect(staged?.insertions == 10)
        #expect(unstaged?.insertions == 3)
        #expect(staged?.id != unstaged?.id)
    }

    @Test("Sections lead with what is broken and end with what git does not track")
    func sectionOrder() {
        let state = GitState(
            snapshot: Self.snapshot(changes: [
                GitChange(path: "z.txt", worktree: "?", untracked: true),
                GitChange(path: "a.swift", worktree: "M"),
                GitChange(path: "b.swift", index: "A"),
                GitChange(path: "c.swift", index: "U", worktree: "U", conflicted: true),
            ]), now: Self.now)
        #expect(state.sections.map(\.kind) == [.conflicts, .staged, .changed, .untracked])
        #expect(state.conflictCount == 1)
        #expect(state.summary == "1 conflicted · 1 staged · 1 changed · 1 untracked")
    }

    @Test("A clean tree says so rather than counting to zero")
    func cleanTree() {
        let state = GitState(snapshot: Self.snapshot(), now: Self.now)
        #expect(state.isClean)
        #expect(state.summary == "Working tree clean")
        #expect(state.sections.isEmpty)
        #expect(state.badge == "master")
        #expect(state.badgeTone == .neutral)
    }

    @Test("Drift from the upstream is stated in both directions")
    func syncWording() {
        #expect(GitState(snapshot: Self.snapshot(ahead: 2), now: Self.now).sync == "2 ahead")
        #expect(GitState(snapshot: Self.snapshot(behind: 3), now: Self.now).sync == "3 behind")
        let both = GitState(snapshot: Self.snapshot(ahead: 2, behind: 3), now: Self.now)
        #expect(both.sync == "2 ahead, 3 behind")
        #expect(both.syncTone == .conflict)
        #expect(GitState(snapshot: Self.snapshot(upstream: nil), now: Self.now).sync == "no upstream")
    }

    @Test("An operation left half-done outranks every other number on the header")
    func operationAlert() {
        let state = GitState(
            snapshot: Self.snapshot(
                changes: [GitChange(path: "a.swift", index: "U", worktree: "U", conflicted: true)],
                operation: "rebase"), now: Self.now)
        #expect(state.alert == "Rebase in progress · 1 conflicted")
        #expect(state.badgeTone == .conflict)
    }

    @Test("A detached head names the commit instead of pretending to be a branch")
    func detachedHead() {
        let state = GitState(
            snapshot: Self.snapshot(branch: nil, upstream: nil, detached: true), now: Self.now)
        #expect(state.title == "detached at abc12345")
    }

    @Test("An untracked folder stands for its contents and says how many")
    func untrackedFolder() {
        let state = GitState(
            snapshot: Self.snapshot(changes: [
                GitChange(
                    path: "build/", worktree: "?", untracked: true, directory: true,
                    contains: 2000, containsAtLeast: true)
            ]), now: Self.now)
        let row = state.sections.first?.rows.first
        #expect(row?.kind == .untrackedDirectory)
        #expect(row?.name == "build")
        #expect(row?.detail == "2,000+ files")
    }

    @Test("A listing that was cut short admits it in the summary")
    func truncation() {
        let state = GitState(
            snapshot: Self.snapshot(
                changes: [GitChange(path: "a.swift", worktree: "M")], truncated: true,
                changedTotal: 900), now: Self.now)
        #expect(state.hiddenCount == 899)
        #expect(state.summary.hasSuffix("899 more"))
    }

    @Test("The chrome chip carries branch, drift and dirt in that order")
    func badge() {
        let state = GitState(
            snapshot: Self.snapshot(
                ahead: 1, behind: 2,
                changes: [
                    GitChange(path: "a.swift", worktree: "M"),
                    GitChange(path: "b.swift", index: "A"),
                ]), now: Self.now)
        #expect(state.badge == "master ↑1 ↓2 ●2")
        #expect(state.badgeTone == .changed)
    }

    @Test("A remote is named the way a person names it")
    func remoteNaming() {
        #expect(GitState.shortRemote("git@github.com:acme/project.git") == "acme/project")
        #expect(GitState.shortRemote("https://github.com/acme/project.git") == "acme/project")
        #expect(GitState.shortRemote("/srv/git/bare.git") == "git/bare")
        #expect(GitState.shortRemote("ssh://git@host.tail/repo.git") == "host.tail/repo")
    }

    @Test("Commits carry their decoration cleaned of git's arrow")
    func commitRefs() {
        let state = GitState(
            snapshot: Self.snapshot(commits: [
                GitCommitSummary(
                    hash: "deadbeefcafe", short: "deadbeef", subject: "fix the thing",
                    author: "dev", at: Self.now.addingTimeInterval(-7200),
                    refs: ["HEAD -> master", "tag: v1.2", "origin/master"])
            ]), now: Self.now)
        let commit = state.commits.first
        #expect(commit?.refs == ["master", "v1.2", "origin/master"])
        #expect(commit?.isHead == true)
        #expect(commit?.age == "2h ago")
    }

    @Test("Every status letter git can write has a face, and modified is the fallback")
    func changeKinds() {
        #expect(GitChangeKind.from(letter: "A") == .added)
        #expect(GitChangeKind.from(letter: "D") == .deleted)
        #expect(GitChangeKind.from(letter: "R") == .renamed)
        #expect(GitChangeKind.from(letter: "T") == .typeChanged)
        #expect(GitChangeKind.from(letter: nil) == .modified)
        for kind in GitChangeKind.allCases {
            #expect(kind.glyph.count == 1)
            #expect(!kind.symbol.isEmpty)
            #expect(!kind.word.isEmpty)
        }
    }

    @Test("A patch is read into numbered lines with the right side of each")
    func patchNumbering() {
        let patch = """
            diff --git a/a.swift b/a.swift
            index 1111111..2222222 100644
            --- a/a.swift
            +++ b/a.swift
            @@ -10,3 +10,4 @@ func thing() {
             let kept = 1
            -let gone = 2
            +let arrived = 2
            +let alsoNew = 3
            """
        let lines = GitPatchReader.lines(patch)
        #expect(lines.filter { $0.kind == .meta }.count == 4)
        #expect(lines.filter { $0.kind == .hunk }.count == 1)
        let stats = GitPatchReader.stats(lines)
        #expect(stats.insertions == 2)
        #expect(stats.deletions == 1)
        let context = lines.first { $0.kind == .context }
        #expect(context?.oldLine == 10)
        #expect(context?.newLine == 10)
        let deletion = lines.first { $0.kind == .deletion }
        #expect(deletion?.oldLine == 11)
        #expect(deletion?.newLine == nil)
        #expect(deletion?.text == "let gone = 2")
        let addition = lines.first { $0.kind == .addition }
        #expect(addition?.newLine == 11)
        #expect(addition?.oldLine == nil)
    }

    @Test("A patch longer than the reader's limit stops at it")
    func patchLimit() {
        let patch = (0..<200).map { "+line \($0)" }.joined(separator: "\n")
        #expect(GitPatchReader.lines(patch, limit: 50).count == 50)
    }

    @Test("A directory with no repository is an answer, not a failure")
    func notARepository() {
        let state = GitState(snapshot: GitSnapshot(root: "/tmp", repo: false), now: Self.now)
        #expect(!state.isRepository)
        #expect(state.sync == "not a repository")
        #expect(state.isClean)
    }
}

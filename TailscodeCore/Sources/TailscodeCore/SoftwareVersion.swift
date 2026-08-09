import Foundation

/// A version string read off a machine, parsed far enough to be compared honestly.
///
/// The numbers in this app arrive in four dialects and none of them is clean semver: an App Store
/// record says `1.9`, a git tag says `v1.5`, a checkout between tags says `v1.5-12-gab34cd`, and a
/// checkout with edits says `v1.5-12-gab34cd-dirty`. Comparing those as text puts `1.10` before
/// `1.9` and calls a dev build older than the tag it descends from, which is exactly the kind of
/// confident lie an update surface must never tell.
///
/// So parsing is deliberately narrow: a version is the dotted numbers, plus what git appended to
/// them. Anything with no numbers at all — `unknown`, a commit hash — refuses to parse, because a
/// thing that cannot be ordered must be *said* to be unorderable rather than guessed at.
public struct SoftwareVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// The dotted numbers, most significant first. Missing trailing components compare as zero, so
    /// `1.9` and `1.9.0` are the same version.
    public let components: [Int]
    /// Commits past the tag, when the string came from `git describe`.
    public let commitsSinceTag: Int
    /// The commit `git describe` named, without its `g` prefix.
    public let commit: String?
    /// A checkout with uncommitted edits: a build nobody else has, which no comparison can rank.
    public let isDirty: Bool
    /// A `-beta.2` style suffix. Ranks below the same numbers without one, as semver says.
    public let prerelease: [String]
    /// Exactly what was read, kept because that is what a person should be shown.
    public let raw: String

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        raw = trimmed

        var body = trimmed
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }

        var dirty = false
        if body.hasSuffix("-dirty") {
            dirty = true
            body.removeLast("-dirty".count)
        }
        isDirty = dirty

        var pieces = body.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let numbers = pieces.removeFirst()

        var ahead = 0
        var sha: String?
        if pieces.count >= 2, let count = Int(pieces[pieces.count - 2]),
            Self.isDescribedCommit(pieces[pieces.count - 1])
        {
            ahead = count
            sha = String(pieces.removeLast().dropFirst())
            pieces.removeLast()
        }
        commitsSinceTag = ahead
        commit = sha
        prerelease = pieces.filter { !$0.isEmpty }

        guard Self.looksLikeVersion(numbers) else { return nil }
        let parsed = numbers.split(separator: ".").map { Int($0) }
        guard !parsed.isEmpty, parsed.allSatisfy({ $0 != nil }) else { return nil }
        components = parsed.compactMap { $0 }
    }

    /// `git describe --tags --always` on a checkout with no tags answers with a bare short hash,
    /// and about one hash in thirty is all digits. Read as a version, `1234567` outranks every real
    /// release forever — so a single run of more than four digits is refused rather than believed.
    private static func looksLikeVersion(_ numbers: String) -> Bool {
        guard !numbers.isEmpty else { return false }
        guard !numbers.contains(".") else { return true }
        return numbers.count <= 4
    }

    /// `git describe` writes the commit as `g` followed by a short hash. Requiring the prefix keeps
    /// a real prerelease word — `-gamma` — from being mistaken for a commit.
    private static func isDescribedCommit(_ piece: String) -> Bool {
        guard piece.count >= 5, piece.hasPrefix("g") else { return false }
        return piece.dropFirst().allSatisfy(\.isHexDigit)
    }

    public var description: String { raw }

    /// A build made from a checkout that had moved past its last tag, or had edits in it. Nobody
    /// published this exact thing, so an update surface says so instead of ranking it.
    public var isDevelopmentBuild: Bool { commitsSinceTag > 0 || isDirty }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    /// The tag part alone — what this build descends from.
    public var release: String {
        components.map(String.init).joined(separator: ".")
    }

    /// The only ordering that means anything: the numbers, then prerelease, then how far past the
    /// tag. Two builds that tie here are *not* thereby the same build — see ``isSameBuild(as:)``.
    public func ranksBelow(_ other: SoftwareVersion) -> Bool {
        let width = max(components.count, other.components.count)
        for index in 0..<width {
            let left = index < components.count ? components[index] : 0
            let right = index < other.components.count ? other.components[index] : 0
            if left != right { return left < right }
        }
        if isPrerelease != other.isPrerelease { return isPrerelease }
        if prerelease != other.prerelease {
            return Self.ordered(prerelease, before: other.prerelease)
        }
        return commitsSinceTag < other.commitsSinceTag
    }

    /// A total order, so sorting is well defined. The tail-breakers — dirt, then the commit itself —
    /// carry no meaning about which build is newer; they exist only so two distinct builds never
    /// compare equal.
    public static func < (lhs: SoftwareVersion, rhs: SoftwareVersion) -> Bool {
        if lhs.ranksBelow(rhs) { return true }
        if rhs.ranksBelow(lhs) { return false }
        if lhs.isDirty != rhs.isDirty { return !lhs.isDirty }
        return (lhs.commit ?? "") < (rhs.commit ?? "")
    }

    private static func ordered(_ lhs: [String], before rhs: [String]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right {
            if let a = Int(left), let b = Int(right) { return a < b }
            return left < right
        }
        return lhs.count < rhs.count
    }

    /// Two versions are equal when they are the same build. `1.9`, `1.9.0` and `v1.9` are one
    /// version written three ways; two seven-character hashes off the same tag are two builds.
    public static func == (lhs: SoftwareVersion, rhs: SoftwareVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
        hasher.combine(prerelease)
        hasher.combine(commitsSinceTag)
        hasher.combine(isDirty)
        hasher.combine(commit)
    }

    /// Whether two readings describe the same build. Two dirty checkouts sharing a version string
    /// are *not* the same build, and neither are two different commits off one tag — which is what
    /// keeps "you already have it" from being claimed about a tree only one machine has seen.
    public func isSameBuild(as other: SoftwareVersion) -> Bool {
        guard !isDirty, !other.isDirty else { return false }
        if let mine = commit, let theirs = other.commit {
            return mine.hasPrefix(theirs) || theirs.hasPrefix(mine)
        }
        if commit != nil || other.commit != nil { return false }
        return !ranksBelow(other) && !other.ranksBelow(self)
    }
}

/// Comparing two version strings when either of them may be nonsense.
public enum VersionComparison: Sendable, Equatable {
    case same
    case newerAvailable
    case installedIsNewer
    /// One side or the other could not be parsed, or the two rank the same while being different
    /// builds. No claim can be made about which is newer.
    case notComparable

    public static func between(installed: String?, available: String?) -> VersionComparison {
        guard let installed = installed.flatMap(SoftwareVersion.init),
            let available = available.flatMap(SoftwareVersion.init)
        else { return .notComparable }
        if installed.isDirty || available.isDirty { return .notComparable }
        if installed.isSameBuild(as: available) { return .same }
        if installed.ranksBelow(available) { return .newerAvailable }
        if available.ranksBelow(installed) { return .installedIsNewer }
        return .notComparable
    }
}

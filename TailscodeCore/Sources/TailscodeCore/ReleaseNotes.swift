import CodingAgentKit
import Foundation

/// One release's worth of change, in the words a person decides on.
///
/// A count of commits is not news, and a commit subject in these projects is a whole paragraph. A
/// bridge new enough to read its project's changelog sends short lines per release; an older one
/// sends only its commit subjects, and those are cut to the claim they lead with. Either way the
/// surface lists what the update brings rather than how many things it brings.
public struct ReleaseNote: Sendable, Equatable, Hashable, Codable {
    /// Nil for changes past the newest release, which no version names yet.
    public let version: String?
    public let date: String?
    public let items: [String]

    public init(version: String?, date: String? = nil, items: [String]) {
        self.version = version
        self.date = date
        self.items = items
    }

    init(_ note: ServerUpdate.Release.Note) {
        self.init(version: note.version, date: note.date, items: note.items)
    }

    /// The commits' own subjects, cut to their headlines, as the one note an older bridge can give.
    public static func fromSubjects(_ subjects: [String], version: String? = nil) -> [ReleaseNote] {
        let items = subjects.map(ChangeHeadline.short).filter { !$0.isEmpty }
        guard !items.isEmpty else { return [] }
        return [ReleaseNote(version: version, items: items)]
    }

    /// The heading over a set of notes: one release is named, several are simply what is new, and
    /// changes no release names yet are what changed.
    public static func title(for notes: [ReleaseNote]) -> String? {
        guard let first = notes.first else { return nil }
        guard notes.count == 1 else { return Localized.text("What's new") }
        guard let version = first.version.flatMap(VersionLabel.short) else {
            return Localized.text("What's changed")
        }
        return Localized.text("What's new in %@", version)
    }

    /// Every line across the notes, in order, capped — the most a compact surface shows before it
    /// offers the rest.
    public static func lines(_ notes: [ReleaseNote], limit: Int) -> [String] {
        Array(notes.flatMap(\.items).prefix(limit))
    }
}

/// The claim a commit subject leads with.
///
/// These projects write a commit's subject as its whole argument — a claim, a colon, and a
/// paragraph proving it — so the claim is the part worth listing and the paragraph is not.
public enum ChangeHeadline {
    public static let limit = 110

    public static func short(_ subject: String) -> String {
        let text = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [": ", " — ", ". ", "; "] {
            if let range = text.range(of: separator) {
                let head = String(text[..<range.lowerBound])
                if head.count >= 12, head.count <= limit { return capitalized(head) }
            }
        }
        guard text.count > limit else { return capitalized(text) }
        let cut = text.prefix(limit)
        let clean = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return capitalized(clean) + "…"
    }

    private static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

/// A version as a person reads it.
///
/// `git describe` is exact and unreadable — `1.9.2-3-ge877732-dirty` — and the exact form lives in
/// the details beside who said it. What leads is the release it descends from, with how many
/// commits past it when there are any: `1.9.2+3`.
public enum VersionLabel {
    public static func short(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard let parsed = SoftwareVersion(raw) else { return raw }
        var label = parsed.release
        if parsed.isPrerelease { label += "-" + parsed.prerelease.joined(separator: ".") }
        if parsed.commitsSinceTag > 0 { label += "+\(parsed.commitsSinceTag)" }
        return label
    }
}

/// What a machine's update actually installs, named the way its project names itself.
public enum UpdateProduct {
    public static func name(for agent: AgentType) -> String {
        switch agent {
        case .claudeCode: return "claude-bridge"
        case .omp: return "omp-bridge"
        case .openCode: return "opencode"
        }
    }

    /// The command that updates an install nothing here can reach, for each kind of machine.
    public static func updateCommand(for agent: AgentType) -> String {
        switch agent {
        case .claudeCode: return BridgeInstall.installCommand
        case .omp:
            return
                "curl -fsSL https://raw.githubusercontent.com/guitaripod/omp-bridge/master/install.sh | OMP_REPO=https://github.com/guitaripod/omp-bridge bash"
        case .openCode: return "opencode upgrade"
        }
    }
}

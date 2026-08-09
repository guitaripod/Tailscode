import Foundation

/// The identity of a project — a directory on one machine — and the arithmetic of scoping a
/// listing to it. A scope is decided on the exact (profile, directory) pair: two servers holding
/// a path spelled the same are two projects, and a path is matched whole, never as a substring,
/// so `~/Dev/app` can never pull in `~/Dev/app-site`. Sessions with no directory form a real
/// scope of their own rather than being unreachable.
public struct ProjectScope: Hashable, Sendable {
    public let profileID: String
    public let directory: String?

    public init(profileID: String, directory: String?) {
        self.profileID = profileID
        self.directory = directory
    }

    public init(of entry: SessionEntry) {
        self.init(profileID: entry.profileID, directory: entry.session.directory)
    }

    /// What the board is called: the directory's last path component, or the honest wording for
    /// conversations that never had one.
    public var name: String {
        guard let directory, !directory.isEmpty else { return Localized.text("No project") }
        return URL(fileURLWithPath: directory).lastPathComponent
    }

    public func matches(_ entry: SessionEntry) -> Bool {
        entry.profileID == profileID && entry.session.directory == directory
    }

    public func apply(_ entries: [SessionEntry]) -> [SessionEntry] {
        entries.filter(matches)
    }

    /// The clearable banner a scoped list wears, naming both halves of the identity so a scope
    /// on one of two same-named checkouts still reads unambiguously.
    public func banner(serverName: String) -> String {
        Localized.text("Only %@ on %@", name, serverName)
    }
}

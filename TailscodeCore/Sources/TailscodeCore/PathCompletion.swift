import Foundation

/// One directory of the server's real disk, held by the chooser so the letters being typed
/// complete against the machine the chat will live on rather than this device's memory. The
/// parent is kept exactly as it was asked for — `~/De` completes to `~/Dev`, never to the
/// expansion only the server knows.
public struct NewChatListing: Sendable, Equatable {
    public let profileID: String
    public let parent: String
    /// Subdirectory names only — a chat starts in a folder, so files have no row here.
    public let folders: [String]
    /// The server could not answer — no such folder, or a bridge too old to say. Held so the
    /// same dead parent is not asked for on every keystroke.
    public let failed: Bool

    public init(profileID: String, parent: String, folders: [String], failed: Bool = false) {
        self.profileID = profileID
        self.parent = parent
        self.folders = folders
        self.failed = failed
    }
}

/// What the chooser wants fetched: one parent folder on one server. Equatable and Hashable so a
/// client can cache answers and drop duplicate flights without inventing its own key.
public struct NewChatListingRequest: Sendable, Equatable, Hashable {
    public let profileID: String
    public let parent: String

    public init(profileID: String, parent: String) {
        self.profileID = profileID
        self.parent = parent
    }
}

/// The shell's half of the new-chat modal: a path being typed is split into the folder to list
/// and the half-typed name to finish, and one press of tab does what it does in a terminal —
/// the unambiguous rest of the name, case corrected to what the disk actually says.
public enum PathCompletion {
    /// The directory whose listing would complete this query, or nil when the letters are still
    /// a search rather than a path. `~/De` asks for `~`, `/ho` asks for `/`, a query ending in
    /// `/` asks for itself.
    public static func parent(of query: String) -> String? {
        guard NewChatChooser.isPathLike(query) else { return nil }
        guard let mark = query.lastIndex(of: "/") else { return query }
        if mark == query.startIndex { return "/" }
        return String(query[..<mark])
    }

    /// The half-typed last component — what tab is being asked to finish.
    public static func component(of query: String) -> String {
        guard let mark = query.lastIndex(of: "/") else { return "" }
        return String(query[query.index(after: mark)...])
    }

    public static func joined(parent: String, name: String) -> String {
        parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }

    /// The listing's folders ranked against the half-typed component the way every list in this
    /// app ranks — case-insensitive, prefix first — with each hit's offsets shifted to land in
    /// the full path a row shows.
    public static func matches(query: String, listing: NewChatListing)
        -> [(path: String, name: String, highlight: [Int])]
    {
        guard let parent = parent(of: query), parent == listing.parent, !listing.failed else {
            return []
        }
        let typed = component(of: query)
        let start = parent == "/" ? 1 : parent.count + 1
        return listing.folders
            .compactMap { name -> (String, String, FuzzyHit)? in
                FuzzyRank.hit(typed, in: name).map { (joined(parent: parent, name: name), name, $0) }
            }
            .sorted { lhs, rhs in
                if lhs.2.tier != rhs.2.tier { return lhs.2.tier < rhs.2.tier }
                return lhs.1.localizedCaseInsensitiveCompare(rhs.1) == .orderedAscending
            }
            .map { (path, name, hit) in (path, name, hit.highlight.map { start + $0 }) }
    }

    /// One press of tab: the longest unambiguous continuation of what is typed, spelled the way
    /// the disk spells it. A single candidate completes whole and opens itself with a trailing
    /// slash; several complete to their common prefix; none, or nothing to add, answers nil so
    /// the caller can fall back to adopting the focused row.
    public static func completed(query: String, listing: NewChatListing) -> String? {
        guard let parent = parent(of: query), parent == listing.parent, !listing.failed else {
            return nil
        }
        let typed = component(of: query).lowercased()
        let candidates = listing.folders.filter { $0.lowercased().hasPrefix(typed) }
        guard let first = candidates.first else { return nil }
        if candidates.count == 1 {
            return joined(parent: parent, name: first) + "/"
        }
        let prefix = commonPrefix(of: candidates)
        guard prefix.count > typed.count else { return nil }
        return joined(parent: parent, name: prefix)
    }

    /// The longest prefix every candidate shares, compared case-insensitively and spelled the way
    /// the first candidate spells it — one folder's casing is a fact, an argument between two is
    /// settled arbitrarily and corrected by the next tab.
    static func commonPrefix(of names: [String]) -> String {
        guard var shared = names.first.map(Array.init) else { return "" }
        for name in names.dropFirst() {
            let letters = Array(name)
            var kept = 0
            while kept < shared.count, kept < letters.count,
                String(shared[kept]).lowercased() == String(letters[kept]).lowercased()
            {
                kept += 1
            }
            shared = Array(shared.prefix(kept))
        }
        return String(shared)
    }
}

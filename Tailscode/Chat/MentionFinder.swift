import CodingAgentKit
import Foundation
import TailscodeCore

/// Reads a project's folders for the `@` list, with the listing route the server already has. It
/// asks for what the person is looking at first, then walks outward from the root a few folders at
/// a time while the list is on screen, and stops the moment it is not.
@MainActor
final class MentionFinder {
    private(set) var shelf: MentionShelf
    private let backend: any FileBrowsingBackend
    private var asked: Set<String> = []
    private var waiting: [String] = []
    private var flying = 0
    private var walkedAt: Date = .distantPast
    var onChange: (() -> Void)?

    /// How long a walk stands before the next look at the list reads the folders again: an agent
    /// that has been working has been making files.
    private static let fresh: TimeInterval = 45

    /// Whether the list is being looked at. The walk only goes on while it is.
    var watching = false {
        didSet {
            guard watching, !oldValue else { return }
            if Date().timeIntervalSince(walkedAt) > Self.fresh || shelf.listedFolders == 0 { rewalk() }
            pump()
        }
    }

    init(root: String, backend: any FileBrowsingBackend) {
        shelf = MentionShelf(root: root)
        self.backend = backend
    }

    /// Whether a folder is being read right now.
    var isLooking: Bool { flying > 0 }

    /// Reads one folder ahead of the walk: the one the person has typed their way into.
    func want(_ folder: String) {
        guard !shelf.isListed(folder), asked.insert(folder).inserted else { return }
        waiting.insert(folder, at: 0)
        pump()
    }

    /// What the working tree has changed, named from the project's root. A deleted file and a
    /// whole untracked folder are left out: neither is a file a prompt can point at.
    func note(_ snapshot: GitSnapshot?) {
        guard let snapshot else { return }
        let changed = snapshot.changes
            .filter { !$0.directory && $0.worktree != "D" && $0.index != "D" }
            .compactMap { shelf.relative($0.path, under: snapshot.root) }
            .filter { !$0.isEmpty }
        guard changed != shelf.changed else { return }
        shelf.changed = changed
        onChange?()
    }

    private func rewalk() {
        walkedAt = Date()
        shelf.forgive()
        let known = shelf.folderPaths
        asked = Set(known)
        waiting = known
    }

    private func pump() {
        while flying < MentionCrawl.abreast {
            if waiting.isEmpty, watching {
                waiting = shelf.frontier(excluding: asked, limit: MentionCrawl.abreast - flying)
                asked.formUnion(waiting)
            }
            guard !waiting.isEmpty else { return }
            read(waiting.removeFirst())
        }
    }

    private func read(_ folder: String) {
        flying += 1
        let path = shelf.absolute(folder)
        let backend = backend
        Task { [weak self] in
            let nodes = try? await backend.listFiles(path: path)
            guard let self else { return }
            self.flying -= 1
            if let nodes {
                self.shelf.shelve(nodes.map { (name: $0.name, isDirectory: $0.isDirectory) }, in: folder)
            } else {
                self.shelf.fail(folder)
            }
            self.onChange?()
            self.pump()
        }
    }
}

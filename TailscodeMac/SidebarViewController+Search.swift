import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension SidebarViewController {
    @objc func filterChanged() {
        // Typing again is the way back to the list: results are about words that were submitted,
        // and leaving them up while the box says something else would be a lie about both.
        if searchBoard != nil || searchRunning { leaveTranscriptSearch(render: false) }
        filter = searchField.stringValue
        cursor = 0
        render()
    }

    /// Enter searches what was actually said, everywhere. The filter above it is titles-only and
    /// instant; this asks every machine at once and takes as long as the slowest one, so the list
    /// says it is looking rather than appearing to have found nothing.
    func runTranscriptSearch() {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TranscriptSearch.isSearchable(query) else { return }
        searchTask?.cancel()
        searchRunning = true
        searchBoard = nil
        lastSidebar = nil
        render()
        let listed = entries
        searchTask = Task { [weak self] in
            let sources = ServerDirectory.shared.profiles.compactMap { profile in
                ServerDirectory.shared.backend(for: profile).map {
                    TranscriptSearch.Source(
                        profileID: profile.id,
                        name: ServerLabel.display(name: profile.name, backend: profile.backend),
                        backend: $0,
                        entries: listed.filter { $0.profileID == profile.id })
                }
            }
            let board = await TranscriptSearch.run(query: query, sources: sources)
            guard !Task.isCancelled else { return }
            self?.searchRunning = false
            self?.searchBoard = board
            self?.lastSidebar = nil
            self?.render()
        }
    }

    /// The list, replaced by what was found.
    func searchRows() -> [SidebarRow] {
        let query = searchBoard?.query ?? filter
        var next: [SidebarRow] = [.searchHeader(query, searchBoard?.rows.count ?? 0, searchRunning)]
        if searchRunning {
            next.append(.empty(Localized.text("Asking every server…")))
            return next
        }
        if let caveat = searchBoard.flatMap(TranscriptSearch.caveat) { next.append(.banner(caveat)) }
        guard let found = searchBoard?.rows, !found.isEmpty else {
            next.append(.empty(Localized.text("Nothing said “%@”", query)))
            return next
        }
        next.append(contentsOf: found.prefix(sidebarLimit).map(SidebarRow.searchResult))
        return next
    }

    func leaveTranscriptSearch(render shouldRender: Bool = true) {
        searchTask?.cancel()
        searchTask = nil
        searchRunning = false
        searchBoard = nil
        lastSidebar = nil
        if shouldRender { render() }
    }

    /// A result opens the conversation it names. The listing may not carry it — a chat on a server
    /// this device has not listed lately — so one the list cannot resolve says so instead of
    /// doing nothing.
    func openSearchResult(profileID: String, sessionID: String) {
        guard let entry = entries.first(where: {
            $0.profileID == profileID && $0.session.id == sessionID
        }) else {
            onToast?(Localized.text("That chat is not in this server's listing right now."))
            return
        }
        leaveTranscriptSearch(render: false)
        searchField.stringValue = ""
        filter = ""
        open(entry)
        render()
    }
}

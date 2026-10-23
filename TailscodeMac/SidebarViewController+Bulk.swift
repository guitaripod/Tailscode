import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension SidebarViewController {
    /// One chat's delete is the bulk delete with a set of one, so the tombstone, the optimistic
    /// removal and the way a refusal is reported have exactly one implementation.
    func deleteOptimistically(_ entry: SessionEntry, backend: any CodingAgentBackend) {
        delete([DeleteTarget(entry: entry, backend: backend)])
    }

    /// Optimistic on confirm, concurrent behind it: the rows leave before the round trip, every
    /// server is asked at once rather than in turn, and what came back is reported in one sentence
    /// from `BulkChatCopy` — a partial failure that said nothing would read as a delete that
    /// silently skipped. Tombstones are keyed on the `(profile, session)` pair and lifted only
    /// once the refresh behind the request has reconciled.
    private func delete(_ targets: [DeleteTarget]) {
        guard !targets.isEmpty else { return }
        let keys = Set(targets.map { ChatSelection.key($0.entry) })
        pendingDeletes.formUnion(keys)
        entries.removeAll { keys.contains(ChatSelection.key($0)) }
        if let fresh = freshlyCreated, keys.contains(ChatSelection.key(fresh)) {
            freshlyCreated = nil
        }
        for target in targets { onDeleted?(target.entry) }
        if let openID = selectedID, targets.contains(where: { $0.entry.session.id == openID }) {
            selectedID = nil
            if let next = entries.first { open(next) }
        }
        lastSidebar = nil
        render()
        Task { [weak self] in
            let outcome = await Self.fanOutDelete(targets)
            guard let self else { return }
            if outcome.deleted > 0 { await self.refresh() }
            self.pendingDeletes.subtract(keys)
            guard !outcome.isClean else { return }
            if let sentence = BulkChatCopy.outcome(outcome) { self.onNotice?(sentence) }
            self.lastSidebar = nil
            self.render()
            await self.refresh()
        }
    }

    private nonisolated static func fanOutDelete(_ targets: [DeleteTarget]) async
        -> BulkChatOutcome
    {
        await withTaskGroup(of: String?.self) { group in
            for target in targets {
                group.addTask {
                    do {
                        try await target.backend.deleteSession(target.entry.session.id)
                        return nil
                    } catch {
                        return "\(error)"
                    }
                }
            }
            var deleted = 0
            var reasons: [String] = []
            for await failure in group {
                if let failure { reasons.append(failure) } else { deleted += 1 }
            }
            return BulkChatOutcome(
                deleted: deleted, failed: reasons.count, reason: reasons.first)
        }
    }

    /// The marked chats in the order the list is drawing them, so a confirm dialog names them the
    /// way the eye just read them — taken from everything the list knows rather than from what the
    /// filter is showing, because a mark made before a keystroke in the filter field is still a
    /// mark the person made.
    var markedModels: [SessionRowModel] {
        known.filter { selection.contains($0.entry) }
    }

    func renderBulkBar() {
        let marked = markedModels
        bulkBar.isHidden = marked.isEmpty
        guard !marked.isEmpty else { return }
        bulkBar.render(count: marked.count, actions: Self.bulkActions(for: marked))
    }

    /// What the verbs mean for what is held. A set that is entirely archived offers to unarchive,
    /// an entirely saved set offers to unsave, and a set holding anything unread offers to mark it
    /// read — a button must never do the opposite of the word on it.
    private static func bulkActions(for models: [SessionRowModel]) -> [BulkChatAction] {
        let archived = models.allSatisfy {
            ArchivedChatStore.contains(
                profileID: $0.entry.profileID, sessionID: $0.entry.session.id)
        }
        let saved = models.allSatisfy(\.saved)
        let unread = models.contains { $0.unread }
        return [
            .delete, archived ? .unarchive : .archive, saved ? .unsave : .save,
            unread ? .markRead : .markUnread,
        ]
    }

    func applyBulk(_ action: BulkChatAction) {
        let marked = markedModels
        guard !marked.isEmpty else { return }
        switch action {
        case .delete:
            presentBulkDelete(marked)
        case .archive, .unarchive:
            let wanted = action == .archive
            for model in marked {
                let archived = ArchivedChatStore.contains(
                    profileID: model.entry.profileID, sessionID: model.entry.session.id)
                guard archived != wanted else { continue }
                ArchivedChatStore.toggle(
                    profileID: model.entry.profileID, sessionID: model.entry.session.id)
            }
            finishBulk()
        case .save:
            for model in marked where !model.saved { SavedChatStore.save(model.entry) }
            finishBulk()
        case .unsave:
            for model in marked {
                SavedChatStore.remove(
                    profileID: model.entry.profileID, sessionID: model.entry.session.id)
            }
            finishBulk()
        case .markRead:
            for model in marked { SessionSeenStore.markSeen(model.entry.session.id) }
            finishBulk()
        case .markUnread:
            for model in marked {
                SessionSeenStore.markUnread(
                    model.entry.session.id, updatedAt: model.entry.session.updatedAt)
            }
            finishBulk()
        }
    }

    /// A verb that acted on the whole set ends the set: the marks are a gesture in progress, and
    /// leaving them held invites the next verb to act on rows that already changed.
    private func finishBulk() {
        selection.clear()
        lastSidebar = nil
        render()
    }

    /// The selection spent on the window itself: the hub opens every marked chat at once as one
    /// even tiling, in the order the list was drawing the rows, and the gesture spends the marks
    /// like every other bulk verb.
    func applyMarkedSplit(_ arrangement: SplitArrangement) {
        let entries = markedModels.map(\.entry)
        guard !SplitEven.offers(count: entries.count).isEmpty else { return }
        finishBulk()
        onOpenSplit?(entries, arrangement)
    }

    func presentBulkDelete(_ models: [SessionRowModel]) {
        guard !models.isEmpty else { return }
        let count = models.count
        MacDialogs.confirm(
            on: view.window,
            title: BulkChatCopy.title(.delete, count: count),
            body: BulkChatCopy.message(count: count, titles: models.map(\.title)),
            confirmLabel: BulkChatCopy.confirm(.delete, count: count)
        ) { [weak self] in
            guard let self else { return }
            let targets = models.compactMap { model in
                self.backend(for: model.entry).map {
                    DeleteTarget(entry: model.entry, backend: $0)
                }
            }
            self.selection.clear()
            guard !targets.isEmpty else {
                self.onNotice?(Localized.text("That server is not configured."))
                self.lastSidebar = nil
                self.render()
                return
            }
            self.delete(targets)
        }
    }

    func backend(for entry: SessionEntry) -> (any CodingAgentBackend)? {
        guard
            let profile = ServerDirectory.shared.profiles.first(where: {
                $0.id == entry.profileID
            })
        else { return nil }
        return ServerDirectory.shared.backend(for: profile)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onToast?(Localized.text("Copied"))
    }
}

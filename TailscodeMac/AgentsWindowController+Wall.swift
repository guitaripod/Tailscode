import AppKit
import TailscodeCore

extension AgentsWindowController {
    /// What the wall is given and what it hands back: the verbs the board uses, the hour, and the
    /// doors out of it (a peek, a chat, watching a listed session).
    func wireWall() {
        wall.actions = actions
        wall.fetchHour = { [feed] in await feed.hour() }
        wall.onPeek = { [weak self] key in self?.peekFromWall(key) }
        wall.onOpenChat = { [weak self] key in self?.openChat(key) }
        wall.onWatch = { [weak self] key in self?.feed.watch(key) }
        wall.onClosePeek = { [weak self] in self?.closeWallPeek() }
        wallPeek.peek.onOpenChat = { [weak self] key in self?.openChat(key) }
        wallPeek.peek.onWatch = { [weak self] key in self?.feed.watch(key) }
        wallPeek.onClose = { [weak self] in self?.wallPeekClosed() }
    }

    /// A press on a tile: its peek, in the inspector when the person has it open and otherwise in a
    /// popover beside the tile, so the wall never moves to make room. The wall dims behind either.
    func peekFromWall(_ key: String) {
        if !inspector.isCollapsed {
            select(key: key, from: .code)
            wall.isPeeking = true
            return
        }
        guard let subject = AgentsSubject.resolve(key: key, in: feed.board, lane: nil),
            let rect = wall.rect(forTile: key)
        else {
            NSSound.beep()
            return
        }
        selectedKey = key
        board.select(key: key)
        following?.cancel()
        following = nil
        wallPeek.show(subject, beside: rect, of: wall.root, now: context.now())
        if isWatching { follow(key) }
        wall.isPeeking = true
        wall.applyCadence()
    }

    /// Esc, with no full screen to leave: whatever peek the wall opened goes away.
    func closeWallPeek() {
        guard wall.isPeeking || wallPeek.isShown else { return }
        wall.isPeeking = false
        wallPeek.close()
        if !inspector.isCollapsed, selectedKey != nil { select(key: nil, from: .code) }
        wall.applyCadence()
    }

    func wallPeekClosed() {
        wall.isPeeking = false
        if inspector.isCollapsed, selectedKey != nil { select(key: nil, from: .code) }
        wall.applyCadence()
    }
}

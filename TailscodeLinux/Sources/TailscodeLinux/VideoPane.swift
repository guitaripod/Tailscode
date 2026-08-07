import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A stream living inside the split tree. libmpv draws into this pane's own GL area, so the video
/// is a widget the tiling owns: the dividers resize it, zoom hides its siblings, and closing it
/// hands the space back — none of which is true of a player that owns a window.
///
/// An empty slot is not an empty box. It asks what to watch in its own body, and it answers most of
/// the question itself: `WatchChooser` holds the board — what is live among the channels this
/// device follows, what is popular now, the categories to browse — and this pane fills it in as the
/// sources answer. Typing narrows it to those words without taking the old behaviour away: a line
/// submitted still means exactly what `VideoTarget.classify` always said it meant.
final class VideoPane: @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private(set) var slot: VideoSlot
    private(set) var board = WatchChooser()
    private var player: OpaquePointer?
    private var surface: UnsafeMutablePointer<GtkWidget>?
    private let askBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let entry = gtk_entry_new()!
    private let headingLabel: UnsafeMutablePointer<GtkWidget>
    private let hintLabel: UnsafeMutablePointer<GtkWidget>
    private let reasonLabel: UnsafeMutablePointer<GtkWidget>
    private let noticeLabel: UnsafeMutablePointer<GtkWidget>
    private let boardScroller = gtk_scrolled_window_new()!
    private let boardHolder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private var callbackBox: UnsafeMutableRawPointer?

    private let directory = MediaDirectory()
    private let following = MediaFollowing()
    private var loads: [String: Task<Void, Never>] = [:]
    private var searchGeneration = 0
    private var ticking = false
    private var typing = false
    private var loadedCategory: String?
    private var accountWatch: (any NSObjectProtocol)?

    /// Told to the pane's owner whenever what this slot says about itself changes, so the identity
    /// strip and the persisted layout follow the stream rather than lag a state behind.
    var onChange: (@Sendable () -> Void)?

    init(target: VideoTarget?) {
        slot = VideoSlot(target: target)
        headingLabel = Gtk.label(Localized.text("Watch"), css: "video-heading", selectable: false)
        hintLabel = Gtk.label(slot.hint, css: "dim", wrap: true, selectable: false)
        reasonLabel = Gtk.label("", css: "dim", selectable: false)
        noticeLabel = Gtk.label(slot.notice, css: "video-notice", wrap: true, selectable: false)
        buildRoot()
        accountWatch = NotificationCenter.default.addObserver(
            forName: MediaAccounts.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            Gtk.onMain { [weak self] in
                guard let self, self.slot.isAsking else { return }
                self.stockBoard()
                self.renderBoard()
            }
        }
        MediaImageCache.shared.observe(self) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.slot.isAsking else { return }
                self.renderBoard()
            }
        }
        if let target {
            point(at: target)
        } else {
            stockBoard()
            render()
            beginTicking()
        }
    }

    private func buildRoot() {
        Gtk.addClass(root, "canvas")
        Gtk.addClass(root, "video-pane")
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)

        Gtk.addClass(askBox, "watch-ask")
        gtk_widget_set_vexpand(askBox, 1)
        Gtk.margins(askBox, top: 14, bottom: 12, leading: 14, trailing: 14)
        gtk_entry_set_placeholder_text(ptr(entry), board.prompt)
        gtk_widget_set_hexpand(entry, 1)
        Gtk.connect(UnsafeMutableRawPointer(entry), "activate") { [weak self] in
            self?.submit()
        }
        Gtk.connect(UnsafeMutableRawPointer(entry), "changed") { [weak self] in
            self?.typed()
        }
        gtk_label_set_xalign(op(hintLabel), 0)
        gtk_label_set_wrap(op(hintLabel), 0)
        gtk_label_set_ellipsize(op(hintLabel), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(op(noticeLabel), 0)
        gtk_label_set_max_width_chars(op(noticeLabel), 46)

        gtk_scrolled_window_set_policy(
            op(boardScroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(op(boardScroller), boardHolder)
        gtk_scrolled_window_set_min_content_height(op(boardScroller), 0)
        gtk_widget_set_vexpand(boardScroller, 1)
        gtk_widget_set_hexpand(boardScroller, 1)
        gtk_widget_set_hexpand(boardHolder, 1)
        gtk_widget_set_valign(boardHolder, GTK_ALIGN_START)

        gtk_box_append(ptr(askBox), headingLabel)
        gtk_box_append(ptr(askBox), entry)
        gtk_box_append(ptr(askBox), reasonLabel)
        gtk_box_append(ptr(askBox), boardScroller)
        gtk_box_append(ptr(askBox), hintLabel)
        gtk_box_append(ptr(askBox), noticeLabel)
        gtk_box_append(ptr(root), askBox)
    }

    var target: VideoTarget? { slot.target }
    var isAsking: Bool { slot.isAsking }

    /// One line for the headless driver: the phase, what the slot is showing, and what the board
    /// under it currently holds.
    var summary: String {
        let phase: String
        switch slot.phase {
        case .asking: phase = "asking"
        case .loading: phase = "loading"
        case .playing: phase = "playing"
        case .failed: phase = "failed"
        }
        var line = "\(phase) \(slot.target?.address ?? "-") [\(slot.title)] \(slot.subtitle)"
        if slot.isAsking {
            let sections = board.sections.map(\.id).joined(separator: ",")
            line += " board=\(board.rows.count) sections=\(sections.isEmpty ? "-" : sections)"
            line += " cursor=\(board.focused?.title ?? "-")"
        }
        return line
    }

    /// The board alone, for the headless driver: what it is showing, how it is grouped, and the row
    /// under the cursor.
    var boardSummary: String {
        let sections = board.sections.map { "\($0.id):\($0.rows.count)\($0.hidden > 0 ? "+\($0.hidden)" : "")" }
        return
            "rows=\(board.rows.count) [\(sections.joined(separator: " "))] cursor=\(board.focused?.title ?? "-") query=\(board.query.isEmpty ? "-" : board.query) open=\(board.opened?.name ?? "-") loading=\(board.isLoading)"
    }

    /// Types into the prompt as a person would, so the driver exercises the same path a keystroke
    /// does rather than a private one that could drift from it.
    func driveQuery(_ text: String) {
        typing = true
        gtk_editable_set_text(op(entry), text)
        typing = false
        typed()
    }

    func focusPrompt() {
        gtk_widget_grab_focus(entry)
    }

    func submit() {
        guard let raw = gtk_editable_get_text(op(entry)) else { return }
        let text = String(cString: raw)
        guard let target = VideoTarget.classify(text) else { return }
        point(at: target)
    }

    func point(at target: VideoTarget) {
        slot.point(at: target)
        WatchStore.record(target, title: slot.mediaTitle)
        SettingsFile.capture()
        stopTicking()
        cancelLoads()
        guard tailscode_mpv_available() != 0 else {
            slot.failed(Localized.text("This build has no libmpv, so a slot cannot play"))
            render()
            return
        }
        guard ensurePlayer() else {
            slot.failed(String(cString: tailscode_mpv_last_error()))
            render()
            return
        }
        tailscode_mpv_play(player, target.playbackURL)
        render()
    }

    /// Back to the question with the old target in the box — a mistyped channel is a correction,
    /// not a retype — and with the board filled in again around it.
    func ask() {
        slot.ask()
        typing = true
        gtk_editable_set_text(op(entry), slot.draft)
        typing = false
        board.type(slot.draft)
        stockBoard()
        render()
        focusPrompt()
    }

    func handle(_ command: VideoCommand) {
        guard command != .change else {
            ask()
            return
        }
        guard let player, !slot.isAsking else { return }
        let arguments = command.mpvCommand
        guard !arguments.isEmpty else { return }
        withCommand(arguments) { tailscode_mpv_command(player, $0) }
    }

    /// The board's own keys, offered before the entry sees them. Only chords a text field cannot
    /// want are claimed, so every letter and digit still types into the box the board sits under.
    func handleBoardChord(_ chord: KeyChord) -> Bool {
        guard slot.isAsking, let command = WatchChooser.command(for: chord) else { return false }
        let (handled, action) = board.handle(command)
        guard handled else { return false }
        guard let action else {
            renderBoard()
            return true
        }
        switch action {
        case .play(let target):
            point(at: target)
        case .follow(let channel):
            follow(channel)
        case .reload:
            loadBoard(force: true)
            renderBoard()
        }
        return true
    }

    func shutdown() {
        stopTicking()
        cancelLoads()
        MediaImageCache.shared.stopObserving(self)
        if let accountWatch { NotificationCenter.default.removeObserver(accountWatch) }
        accountWatch = nil
        if let player {
            tailscode_mpv_free(player)
            self.player = nil
            surface = nil
        }
        if let callbackBox {
            Unmanaged<Box>.fromOpaque(callbackBox).release()
            self.callbackBox = nil
        }
    }

    /// What was typed, read as it is typed. The classified target leads the board immediately —
    /// nothing waits on a network answer to tell somebody what their own words mean — and the
    /// search that fills the rest in is asked once the typing settles.
    private func typed() {
        guard !typing, slot.isAsking else { return }
        guard let raw = gtk_editable_get_text(op(entry)) else { return }
        board.type(String(cString: raw))
        renderBoard()
        scheduleSearch()
    }

    /// What the board is listing, before anything is checked: the channels this device added by
    /// hand, immediately, then the ones a signed-in account follows once the site answers. The
    /// local list never waits on the network — a board that shows nothing until Twitch replies is a
    /// board that shows nothing on a train.
    private func stockBoard() {
        board.stock(watchlist: WatchStore.watchlist(), followed: WatchStore.channels())
        board.attribute(Self.attribution)
        loadBoard(force: false)
        guard MediaSource.allCases.contains(where: MediaAccounts.isSignedIn) else { return }
        start(Self.followingKey, force: true) { [weak self] in
            let feed = await self?.following.watchlist(local: WatchStore.watchlist()) ?? MediaFeed()
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.board.stock(
                    watchlist: feed.entries.map(\.channel), followed: WatchStore.channels())
                self.board.attribute(Self.attribution)
                self.renderBoard()
            }
        }
    }

    /// Whose follow list this is, when it is somebody's. Nil when nothing is signed in, which is
    /// what leaves the section counting its own offline rows the way it always did.
    private static var attribution: String? {
        MediaSource.allCases.contains(where: MediaAccounts.isSignedIn)
            ? WatchAccounts.summary : nil
    }

    private static let followingKey = "following"

    /// Asks every source for the sections the board is showing. Each section is its own task keyed
    /// by its own name, so a second ask replaces the first rather than racing it, and a slow source
    /// never holds up a fast one.
    private func loadBoard(force: Bool) {
        let channels = WatchStore.watchlist()
        let signedIn = MediaSource.allCases.contains(where: MediaAccounts.isSignedIn)
        if !channels.isEmpty || signedIn {
            board.loading(WatchChooser.liveID)
            start(WatchChooser.liveID, force: force) { [weak self] in
                let feed = await self?.following.live(local: channels) ?? MediaFeed()
                Gtk.onMain { [weak self] in
                    self?.board.filled(live: feed)
                    self?.renderBoard()
                }
            }
        }
        board.loading(WatchChooser.topID)
        start(WatchChooser.topID, force: force) { [weak self] in
            let feed = await self?.directory.top(limit: 6) ?? MediaFeed()
            Gtk.onMain { [weak self] in
                self?.board.filled(top: feed)
                self?.renderBoard()
            }
        }
        board.loading(WatchChooser.browseID)
        start(WatchChooser.browseID, force: force) { [weak self] in
            let feed = await self?.directory.categories(limit: 8) ?? MediaFeed()
            Gtk.onMain { [weak self] in
                self?.board.filled(categories: feed)
                self?.renderBoard()
            }
        }
    }

    private func loadCategory(_ category: MediaCategory) {
        start(WatchChooser.insideID, force: true) { [weak self] in
            let feed = await self?.directory.inside(category, limit: 12) ?? MediaFeed()
            Gtk.onMain { [weak self] in
                self?.board.filled(inside: feed, of: category)
                self?.renderBoard()
            }
        }
    }

    /// A search waits for the typing to settle. Every keystroke would otherwise be a round trip to
    /// two sites, and the answer to a word somebody has already finished typing past is noise.
    private func scheduleSearch() {
        guard let words = board.pendingSearch else {
            loads[WatchChooser.resultsID]?.cancel()
            loads[WatchChooser.resultsID] = nil
            return
        }
        searchGeneration += 1
        let generation = searchGeneration
        start(WatchChooser.resultsID, force: true) { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, generation == self.searchGeneration else { return }
            let feed = await self.directory.search(words, limit: 6)
            Gtk.onMain { [weak self] in
                self?.board.filled(results: feed, for: words)
                self?.renderBoard()
            }
        }
    }

    private func start(_ key: String, force: Bool, _ work: @escaping @Sendable () async -> Void) {
        if !force, let existing = loads[key], !existing.isCancelled { return }
        loads[key]?.cancel()
        loads[key] = Task { await work() }
    }

    private func cancelLoads() {
        for task in loads.values { task.cancel() }
        loads.removeAll()
    }

    /// An open board keeps its uptimes honest. A minute is the coarsest unit any of them is shown
    /// in, so a minute is how often the board is asked to re-read the clock.
    private func beginTicking() {
        guard !ticking else { return }
        ticking = true
        tick()
    }

    private func tick() {
        Gtk.after(60_000) { [weak self] in
            guard let self, self.ticking else { return }
            guard self.slot.isAsking else {
                self.ticking = false
                return
            }
            self.board.tick()
            self.renderBoard()
            self.tick()
        }
    }

    private func stopTicking() {
        ticking = false
    }

    private func ensurePlayer() -> Bool {
        if player != nil { return true }
        guard tailscode_mpv_available() != 0 else { return false }
        let box = Box(pane: self)
        let raw = Unmanaged.passRetained(box).toOpaque()
        guard
            let created = tailscode_mpv_new(
                { user, kind, text in
                    guard let user, let kind else { return }
                    let event = String(cString: kind)
                    let payload = text.map { String(cString: $0) } ?? ""
                    let box = Unmanaged<Box>.fromOpaque(user).takeUnretainedValue()
                    box.pane?.received(event: event, payload: payload)
                }, raw)
        else {
            Unmanaged<Box>.fromOpaque(raw).release()
            return false
        }
        player = created
        callbackBox = raw
        guard let area = tailscode_mpv_area(created) else { return false }
        surface = area
        gtk_widget_set_hexpand(area, 1)
        gtk_widget_set_vexpand(area, 1)
        gtk_box_append(ptr(root), area)
        return true
    }

    /// mpv's own words about the stream, turned into the slot's. A failure keeps the pane and
    /// explains itself; it never empties the slot, because the pane still holds its share of the
    /// grid and has to account for it.
    private func received(event: String, payload: String) {
        switch event {
        case "loaded":
            slot.loaded(title: slot.mediaTitle)
        case "title":
            slot.loaded(title: payload)
            if let target = slot.target {
                WatchStore.record(target, title: payload)
                SettingsFile.capture()
            }
        case "pause":
            slot.paused = payload == "1"
        case "mute":
            slot.muted = payload == "1"
        case "error":
            slot.failed(
                payload.isEmpty ? Localized.text("That would not play") : payload)
        case "end":
            if case .loading = slot.phase {
                slot.failed(Localized.text("That would not play"))
            }
        default:
            return
        }
        render()
    }

    private func render() {
        let asking = slot.isAsking
        gtk_widget_set_visible(askBox, asking ? 1 : 0)
        if let surface { gtk_widget_set_visible(surface, asking ? 0 : 1) }
        if case .failed(let reason) = slot.phase {
            gtk_widget_set_visible(askBox, 1)
            if let surface { gtk_widget_set_visible(surface, 0) }
            gtk_label_set_text(op(reasonLabel), reason)
            gtk_widget_set_visible(reasonLabel, 1)
        } else {
            gtk_widget_set_visible(reasonLabel, 0)
        }
        gtk_label_set_text(op(headingLabel), board.heading)
        gtk_label_set_text(op(hintLabel), asking ? board.hint : slot.hint)
        renderNotice()
        renderBoard()
        onChange?()
    }

    /// The board, rebuilt whole. Widgets are cheap here and answers land constantly; what is not
    /// rebuilt is the picture behind each row, which lives in the cache rather than in the tree.
    /// What a stream costs the grid, at the width the pane has left for it. An empty slot still
    /// gets the whole paragraph in its tinted card — there is nothing else in the pane to read —
    /// but a slot showing a board has spent that room on what is actually on, so the same fact
    /// rides one line under it.
    private func renderNotice() {
        let whole = board.isEmpty
        gtk_label_set_wrap(op(noticeLabel), whole ? 1 : 0)
        gtk_label_set_ellipsize(
            op(noticeLabel), whole ? PANGO_ELLIPSIZE_NONE : PANGO_ELLIPSIZE_END)
        gtk_label_set_text(op(noticeLabel), whole ? slot.notice : VideoNotice.splitCostLine)
    }

    private func renderBoard() {
        guard slot.isAsking else {
            Gtk.removeChildren(of: boardHolder)
            gtk_widget_set_visible(boardScroller, 0)
            return
        }
        gtk_widget_set_visible(boardScroller, board.isEmpty ? 0 : 1)
        renderNotice()
        Gtk.removeChildren(of: boardHolder)
        let built = WatchBoard.make(board) { [weak self] section, offset in
            Gtk.onMain { [weak self] in self?.activate(section: section, offset: offset) }
        }
        gtk_box_append(ptr(boardHolder), built.root)
        gtk_label_set_text(op(headingLabel), board.heading)
        reveal(built.focused)
        guard let category = board.opened else {
            loadedCategory = nil
            return
        }
        guard loadedCategory != category.id else { return }
        loadedCategory = category.id
        loadCategory(category)
    }

    private func activate(section: String, offset: Int) {
        board.focus(section: section, offset: offset)
        guard let action = board.activate() else {
            renderBoard()
            return
        }
        switch action {
        case .play(let target): point(at: target)
        case .follow(let channel): follow(channel)
        case .reload:
            loadBoard(force: true)
            renderBoard()
        }
    }

    /// Follows a channel, or stops. `UserDefaults` on Linux is keyed to the executable's path, so
    /// the durable copy is written in the same breath — otherwise the list a person built survives
    /// only until the next install puts the binary somewhere else.
    private func follow(_ channel: MediaChannel) {
        WatchStore.toggle(channel)
        SettingsFile.capture()
        stockBoard()
        renderBoard()
    }

    /// Scrolls the row under the cursor into view. The board is rebuilt on every answer, so the
    /// widget is found again at the moment it is measured rather than remembered from the frame
    /// that made it — the one it was is very likely already freed.
    private func reveal(_ position: Int?) {
        guard let position else { return }
        Gtk.after(0) { [weak self] in
            guard let self, let column = gtk_widget_get_first_child(self.boardHolder) else {
                return
            }
            var child = gtk_widget_get_first_child(column)
            var index = 0
            while let current = child, index < position {
                child = gtk_widget_get_next_sibling(current)
                index += 1
            }
            guard let target = child, index == position,
                let bounds = Gtk.bounds(of: target, in: column),
                let adjustment = gtk_scrolled_window_get_vadjustment(op(self.boardScroller))
            else { return }
            let page = gtk_adjustment_get_page_size(adjustment)
            let value = gtk_adjustment_get_value(adjustment)
            if bounds.y < value {
                gtk_adjustment_set_value(adjustment, bounds.y)
            } else if bounds.y + bounds.height > value + page {
                gtk_adjustment_set_value(adjustment, bounds.y + bounds.height - page)
            }
        }
    }

    private func withCommand(_ arguments: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> Void) {
        var pointers: [UnsafePointer<CChar>?] = arguments.map { argument in
            UnsafePointer(strdup(argument))
        }
        pointers.append(nil)
        pointers.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress { body(base) }
        }
        for pointer in pointers where pointer != nil {
            free(UnsafeMutableRawPointer(mutating: pointer))
        }
    }

    /// The C callback carries a raw pointer, so the pane reaches it through a box it owns and
    /// releases at shutdown — an event arriving after the pane is gone finds nothing rather than
    /// a dangling object.
    private final class Box {
        weak var pane: VideoPane?
        init(pane: VideoPane) { self.pane = pane }
    }
}

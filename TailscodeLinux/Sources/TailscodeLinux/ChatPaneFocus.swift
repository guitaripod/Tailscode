import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ChatPane {
    /// The window's focus moved onto or off this pane. The focused pane drains first and is the one
    /// pane that runs the reveal; a pane that loses the focus mid-answer hands its live row back
    /// whole and shows the rest of the answer as it arrives.
    func setFocused(_ focused: Bool) {
        guard focused != isFocusedPane else { return }
        isFocusedPane = focused
        if !focused {
            letGoOfCascade()
            preview?.focusLost()
        }
        restateDrainPriority()
        if focused, !isParked, let state = lastState, lastFullRows.count > renderedRows.count {
            apply(state: state, rows: lastFullRows)
        }
    }

    /// Focused first, then a pane that needs the person or failed, then everyone else.
    func restateDrainPriority() {
        let priority: DrainPriority
        if isFocusedPane {
            priority = .focused
        } else {
            switch presence {
            case .awaitingApproval, .failed: priority = .attention
            default: priority = .full
            }
        }
        guard priority != drainPriority else { return }
        drainPriority = priority
        restateDrainSlot()
    }

    /// Re-registers the drain slot's priority and rate, after either changed.
    func restateDrainSlot() {
        brains.budgetChanged()
        if !revealsHere { letGoOfCascade() }
        if let drainToken, let host { host.live.drain.update(drainToken, to: drainSlot()) }
    }

    /// Hidden by a zoom: the lease, the pump, the drain slot, the ticker, the reveal, the identity
    /// pulse and any rise in progress end, and the pane keeps showing its last rows, frozen. A turn
    /// still in flight is handed to the window's watch so the chat list keeps its LIVE NOW seat.
    func park() {
        guard !isParked else { return }
        if let entry, presence.isInFlight { host?.keepWatching(entry) }
        isParked = true
        brains.suspend()
        call.setSuspended(true)
        preview?.park()
        leaveFreshCanvas()
        releaseStream()
        agentStreamTask?.cancel()
        agentStreamTask = nil
        agentStreamSessionID = nil
    }

    /// Shown again: the watch hands the chat back and a fresh lease brings the newest state at
    /// once, so the pane catches up in one apply rather than replaying what it missed.
    func unpark() {
        guard isParked else { return }
        isParked = false
        brains.resume()
        preview?.unpark()
        guard !isShutDown else { return }
        call.setSuspended(false)
        if let entry { host?.stopWatching(LiveKey(entry).pinKey) }
        attachStream()
        refreshIdentity()
    }

    /// What the pane owns right now, for the harness: whether it holds a lease and a drain slot,
    /// how many of its clocks are running and whether it is parked.
    var liveReading: String {
        "parked=\(isParked) lease=\(lease != nil) slot=\(drainToken != nil) "
            + "reveal=\(cascade.isActive) ticker=\(tickerTask != nil) "
            + "rise=\(canvasSettle != nil) agents=\(agentStreamTask != nil)"
    }

    /// The strip that says whose conversation this pane is — only worth its line once a second
    /// pane exists, so a lone pane stays exactly the window it always was.
    func setIdentityVisible(_ visible: Bool) {
        gtk_widget_set_visible(identityLabel, visible ? 1 : 0)
        if visible { refreshIdentity() }
    }

    /// What the strip says about the pane beyond its name: that it is kept live, and which other
    /// pane shows the same conversation.
    func setIdentityExtras(pinned: Bool, alsoOpenIn other: Int?) {
        guard pinned != identityPinned || other != identityAlsoOpenIn else { return }
        identityPinned = pinned
        identityAlsoOpenIn = other
        refreshIdentity()
    }

    /// What kind of pane this is, for layout and the governor: a slot by what it shows, a chat by
    /// holding or waiting for a conversation, and nothing otherwise.
    func paneKind(held: Bool) -> PaneKind {
        if let kindOverride { return kindOverride }
        if preview != nil { return .preview }
        if drawEndpoint != nil { return .draw }
        if webTarget != nil { return .web }
        if videoTarget != nil { return .video }
        if entry != nil || held { return .chat }
        return .empty
    }

    /// Messages this device is holding for the conversation, for a glance's footer.
    var queuedCount: Int { queueDisplay.count }

    /// Lets go of the transcript's row widgets while the pane is parked, keeping the rows' memo so
    /// the next lease refills the tail through the ordinary first fill. A demoted pane keeps them
    /// for a while so a glance pressed again comes back as it was; after that they are only
    /// memory.
    func releaseRows() {
        guard isParked, !isShutDown, !renderedRows.isEmpty, !pointerHeld else { return }
        messageBar.dismiss()
        tearDownAllRows()
        fillComplete = false
        followsBottom = true
        heldRows = nil
    }

    var rowCount: Int { renderedRows.count }

    /// The calm figure of the governor's peer row window, which a peer wears until the canvas has
    /// decided one. A peer is read at a glance, and every row it holds is a widget the window lays
    /// out, paints and pays memory for, so panes opened together were thousands of rows put back
    /// one frame at a time, most of them above a fold nobody was looking at. The focused pane keeps
    /// the person's own window, a peer takes it the moment the focus arrives, and a peer whose
    /// reader pressed the earlier-rows button keeps what was asked for.
    static let peerRowWindow = TileGovernor.peerRowWindow(level: .calm)

    var rowLimit: Int {
        let preferred = max(windowLimit, Preferences.transcriptWindow)
        guard !isFocusedPane, !windowWidened else { return preferred }
        return min(preferred, rowWindowOverride ?? Self.peerRowWindow)
    }

    func setRowWindow(_ rows: Int?) {
        let wanted = rows.map { max(60, $0) }
        guard wanted != rowWindowOverride else { return }
        rowWindowOverride = wanted
        guard !isParked, !isShutDown, let state = lastState, !placeholderShown else { return }
        apply(state: state, rows: lastFullRows)
    }

    /// Turns this pane into a video slot, or points the one it already is at something else. The
    /// chat furniture is hidden rather than destroyed, so a slot is a state of a pane and not a
    /// second kind of object the split tree would have to learn.
    func showVideo(_ target: VideoTarget?) {
        becomeSlot()
        leaveSlots(except: video.map(ObjectIdentifier.init))
        if video == nil {
            let pane = VideoPane(target: target)
            video = pane
            gtk_box_append(ptr(root), pane.root)
            setChatFurnitureVisible(false)
            pane.onChange = { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.refreshIdentity()
                    self.host?.videoSlotChanged()
                }
            }
        } else if let target {
            video?.point(at: target)
        }
        if target == nil { video?.focusPrompt() }
        refreshIdentity()
    }

    /// Turns this pane into a browser slot, or points the one it already is at another address.
    func showWeb(_ target: WebTarget?) {
        becomeSlot()
        leaveSlots(except: page.map(ObjectIdentifier.init))
        if page == nil {
            let pane = WebPane(target: target)
            page = pane
            gtk_box_append(ptr(root), pane.root)
            setChatFurnitureVisible(false)
            pane.onChange = { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.refreshIdentity()
                    self.host?.videoSlotChanged()
                }
            }
        } else if let target {
            page?.point(at: target)
        }
        if target == nil { page?.focusPrompt() }
        refreshIdentity()
    }

    /// Turns this pane into a draw slot, or points the one it already is at another server. The
    /// endpoint persists in the layout snapshot, so a restart reopens the pane on the machine it
    /// was painting on.
    func showDraw(_ endpoint: ImageGenEndpoint?) {
        becomeSlot()
        leaveSlots(except: draw.map(ObjectIdentifier.init))
        if draw == nil {
            let pane = DrawPane(endpoint: endpoint)
            draw = pane
            gtk_box_append(ptr(root), pane.root)
            setChatFurnitureVisible(false)
            pane.wireChips()
            pane.setOnChange { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.refreshIdentity()
                    self.host?.videoSlotChanged()
                }
            }
        }
        draw?.focusPrompt()
        refreshIdentity()
    }

    var isDrawing: Bool { draw != nil }

    /// A drawing pane claims only the chords a draw slot owns; every other key belongs to the
    /// entry, which is typing a prompt as often as not.
    func handleDrawChord(_ chord: KeyChord) -> Bool {
        guard let draw else { return false }
        if Gtk.focusTakesText(draw.hostWindow ?? draw.root) {
            guard let command = ImageGenCommand.command(for: chord), command == .submit, !chord.shift
            else {
                return false
            }
            draw.handle(command)
            return true
        }
        guard let command = ImageGenCommand.command(for: chord) else { return false }
        if command == .submit, Gtk.focusIsButton(in: draw.hostWindow ?? draw.root) { return false }
        draw.handle(command)
        return true
    }

    var drawEndpoint: ImageGenEndpoint? { draw?.target }

    /// Turns this pane into a preview slot, or points the one it already is at another app. A
    /// pane built from a snapshot starts its runner at once; one asked for with no target asks in
    /// its own body, and `fixedHost` names the Mac the chooser row already chose.
    func showPreview(_ target: PreviewTarget?, fixedHost: String? = nil, runs: Bool = true) {
        becomeSlot()
        leaveSlots(except: preview.map(ObjectIdentifier.init))
        if preview == nil {
            let pane = PreviewPane(target: target, fixedHost: fixedHost, runs: runs)
            preview = pane
            gtk_box_append(ptr(root), pane.root)
            setChatFurnitureVisible(false)
            pane.onChange = { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.refreshIdentity()
                    self.host?.previewTitleChanged(self)
                    self.host?.videoSlotChanged()
                }
            }
            pane.onAskAgent = { [weak self] words in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.host?.previewAsksAgent(words, from: self)
                }
            }
            if isParked { pane.park() }
        } else if let target {
            preview?.point(at: target)
        } else {
            preview?.ask()
        }
        if target == nil { preview?.focusPrompt() }
        refreshIdentity()
        host?.previewTitleChanged(self)
    }

    /// What the window's title bar says while this pane is a preview: the app and what it is
    /// doing, never the title of a chat the pane held before it became a slot.
    var previewHeaderTitle: String? {
        preview.map { "\($0.slot.title) · \($0.slot.subtitle)" }
    }

    var previewTarget: PreviewTarget? { preview?.target }

    var previewSummary: String? { preview?.summary }

    var previewLensSummary: String? { preview?.lensSummary }

    /// A preview pane claims only plain letters, and only while the person is not typing into one
    /// of its fields: the picture takes no keys, so everything else belongs to the window.
    func handlePreviewChord(_ chord: KeyChord) -> Bool {
        guard let preview, !preview.isAsking else { return false }
        if preview.keysOn, preview.forwardKey(chord) { return true }
        if let lens = PreviewLensKeys.lens(for: chord) { return preview.chooseLens(lens) }
        if PreviewLensKeys.isEscape(chord) { return preview.escape() }
        guard let command = PreviewCommand.command(for: chord) else { return false }
        preview.handle(command)
        return true
    }

    var isBrowsing: Bool { page != nil }

    var webTarget: WebTarget? {
        page.flatMap { pane in pane.currentAddress.map(WebTarget.page) ?? pane.target }
    }

    var webSummary: String? { page?.summary }

    /// A browsing pane claims only the chords a browser owns; every other key belongs to the page,
    /// which is typing into a form as often as not.
    func handleWebChord(_ chord: KeyChord) -> Bool {
        guard let page else { return false }
        if page.isAsking {
            guard let command = WebCommand.command(for: chord), command != .address else {
                return false
            }
            page.handle(command)
            return true
        }
        guard let command = WebCommand.command(for: chord) else { return false }
        page.handle(command)
        return true
    }

    var isWatching: Bool { video != nil }

    var videoTarget: VideoTarget? { video?.target }

    var videoSummary: String? { video?.summary }

    /// A slot answers its own keys while it is focused; everything it does not claim goes on to
    /// the app's shortcut table, so the chat panes lose nothing to a slot in the grid.
    func handleVideoChord(_ chord: KeyChord) -> Bool {
        guard let video, !video.isAsking else { return false }
        guard let command = VideoCommand.command(for: chord) else { return false }
        video.handle(command)
        return true
    }

    /// One line of the board for the headless driver: its sections, its rows and where the cursor
    /// is, so a change to what an empty slot offers is provable without a screenshot.
    var watchBoardSummary: String? {
        guard let video, video.isAsking else { return nil }
        return video.boardSummary
    }

    /// Types into the slot's own prompt from the driver, which is how the board's search half is
    /// exercised without an input harness pushing keys at an X server.
    func driveWatchQuery(_ text: String) {
        video?.driveQuery(text)
    }

    /// The board an empty slot shows, offered its keys before the box it is typed into gets them.
    /// This one is asked in every key context rather than only in normal: the prompt has the
    /// keyboard while the board is up, so the arrows, Enter, Tab, Escape and the deliberate control
    /// chords would never arrive if the board waited for the transcript to be the focused region.
    func handleWatchChord(_ chord: KeyChord) -> Bool {
        guard let video, video.isAsking else { return false }
        return video.handleBoardChord(chord)
    }

    /// Everything the pane draws for a conversation, out of the way while it holds a stream —
    /// walked rather than named so a new piece of chat chrome cannot forget to hide itself.
    ///
    /// Hiding remembers which pieces were showing, and showing again brings back exactly those: a
    /// find bar that was closed or a banner with nothing to say stays hidden when a slot gives the
    /// pane back to a chat.
    func setChatFurnitureVisible(_ visible: Bool) {
        guard !visible else {
            for bits in hiddenFurniture {
                guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { continue }
                gtk_widget_set_visible(ptr(raw), 1)
            }
            hiddenFurniture = []
            return
        }
        var child = gtk_widget_get_first_child(root)
        while let current = child {
            let next = gtk_widget_get_next_sibling(current)
            if current != identityLabel, current != video?.root, current != page?.root,
                current != draw?.root, current != preview?.root, gtk_widget_get_visible(current) != 0
            {
                hiddenFurniture.append(UInt(bitPattern: current))
                gtk_widget_set_visible(current, 0)
            }
            child = next
        }
    }

    /// A pane becoming a slot stops being a chat: its stream, fetches and clocks end (a turn still
    /// in flight is handed to the window's watch), so nothing keeps streaming behind the slot.
    func becomeSlot() {
        chooser = nil
        guard entry != nil else { return }
        leaveChat()
        placeholderShown = false
        host?.paneRebound()
        host?.scheduleSidebarRender()
    }

    /// Takes down whatever slot the pane holds and gives the pane back its chat furniture — what an
    /// open or a chooser does to a pane that was a page, a stream or a painter.
    func leaveSlots(except keep: ObjectIdentifier? = nil) {
        var left = false
        if let video, ObjectIdentifier(video) != keep {
            video.shutdown()
            gtk_box_remove(ptr(root), video.root)
            self.video = nil
            left = true
        }
        if let page, ObjectIdentifier(page) != keep {
            page.shutdown()
            gtk_box_remove(ptr(root), page.root)
            self.page = nil
            left = true
        }
        if let draw, ObjectIdentifier(draw) != keep {
            draw.shutdown()
            gtk_box_remove(ptr(root), draw.root)
            self.draw = nil
            left = true
        }
        if let preview, ObjectIdentifier(preview) != keep {
            preview.shutdown()
            gtk_box_remove(ptr(root), preview.root)
            self.preview = nil
            left = true
        }
        guard left, video == nil, page == nil, draw == nil, preview == nil else { return }
        setChatFurnitureVisible(true)
        refreshIdentity()
    }

    /// Whether the pane is a slot rather than a chat.
    var isSlot: Bool { video != nil || page != nil || draw != nil || preview != nil }

    /// A pane wears what it is doing in its own identity strip, so a grid of four says which one
    /// is working without the reader having to find and read four status bands. The strip is what
    /// a pane is; the band is what its turn is; this is the one fact both have to agree on.
    func refreshIdentity() {
        if let preview {
            setIdentity(
                "\(preview.slot.title) · \(preview.slot.subtitle)", activity: preview.slot.light.activity)
            return
        }
        if let page {
            setIdentity("\(page.slot.title) · \(page.slot.subtitle)", activity: nil)
            return
        }
        if let draw {
            setIdentity(draw.slot.title, activity: draw.isBusy ? ActivityKind.working : nil)
            return
        }
        if let video {
            setIdentity("\(video.slot.title) · \(video.slot.subtitle)", activity: nil)
            return
        }
        guard let entry else {
            setIdentity(Localized.text("No conversation"), activity: nil)
            return
        }
        setIdentity(Self.title(of: entry), activity: identityActivity)
    }

    /// A pane keeps the entry it was opened with, so a conversation the server named after it
    /// opened would wear its first title for as long as the pane stayed open. The listing is what
    /// knows the current one; Core decides whether it is a name worth taking (never the untitled
    /// placeholder), and the strip is redrawn only when it was.
    @discardableResult
    func adoptTitle(from listed: SessionEntry) -> Bool {
        guard let current = entry, let renamed = current.adoptingTitle(from: listed) else {
            return false
        }
        entry = renamed
        refreshIdentity()
        return true
    }

    static func title(of entry: SessionEntry) -> String {
        entry.session.hasPlaceholderTitle
            ? Localized.text("New conversation") : entry.session.title
    }

    /// The name this pane's chat wears in its strip, for comparing with the panes beside it.
    var conversationTitle: String? {
        guard page == nil, draw == nil, video == nil, preview == nil, let entry else { return nil }
        return Self.title(of: entry)
    }

    /// Two panes on screen that carry the same title — the same task opened on two machines —
    /// would be told apart by nothing, so each of them names its server; a pane whose title is
    /// its own keeps the strip to the title. A second view of one and the same chat is told by
    /// its twin note instead, and does not name a server.
    static func markSharedTitles(visible: [ChatPane], others: [ChatPane]) {
        var holders: [String: [ChatPane]] = [:]
        for pane in visible {
            if let title = pane.conversationTitle { holders[title, default: []].append(pane) }
        }
        for pane in visible {
            guard let title = pane.conversationTitle, let entry = pane.entry else {
                pane.setIdentityNamesServer(false)
                continue
            }
            let mine = SessionPinStore.key(entry.profileID, entry.session.id)
            let shared = (holders[title] ?? []).contains { other in
                guard other !== pane, let theirs = other.entry else { return false }
                return SessionPinStore.key(theirs.profileID, theirs.session.id) != mine
            }
            pane.setIdentityNamesServer(shared)
        }
        for pane in others { pane.setIdentityNamesServer(false) }
    }

    func setIdentityNamesServer(_ names: Bool) {
        guard names != identityNamesServer else { return }
        identityNamesServer = names
        refreshIdentity()
    }

    /// The pin and the twin the strip appends to the name, in that order.
    var identityExtras: String {
        var extras = ""
        if identityNamesServer, let entry {
            extras += " · " + ServerLabel.display(name: entry.profileName, backend: entry.backendType)
        }
        if identityPinned { extras += " · ◆" }
        if let other = identityAlsoOpenIn {
            extras += " · " + Localized.text("also open in pane %@", "\(other)")
        }
        return extras
    }

    func setIdentity(_ text: String, activity: ActivityKind?) {
        identityName = text
        let text = text + identityExtras
        guard let activity, !isParked else {
            ActivityPulse.apply(nil, to: identityLabel)
            gtk_label_set_text(op(identityLabel), text)
            return
        }
        let line = activity.icon.glyph + " " + text
        gtk_label_set_text(op(identityLabel), line)
        ActivityPulse.apply(activity.icon, to: identityLabel, text: line) { [identityLabel] frame in
            gtk_label_set_text(op(identityLabel), frame)
        }
    }

    /// Every picture of the conversation in reading order: the ones a strip holds and the ones a
    /// person attached, each under the key its pixels are cached by.
    func galleryItems() -> [ImageGallery.Item] {
        func item(_ key: String, _ reference: FileReference) -> ImageGallery.Item? {
            guard (reference.mime ?? "").hasPrefix("image/") else { return nil }
            return ImageGallery.Item(
                key: key, name: PictureGalleryView.filename(of: reference), reference: reference)
        }
        return lastFullRows.flatMap { row -> [ImageGallery.Item] in
            switch row.kind {
            case .file(let reference, _): return item(row.key, reference).map { [$0] } ?? []
            case .pictures(let pictures):
                return pictures.compactMap { item($0.key, $0.reference) }
            default: return []
            }
        }
    }

    /// The drive-run equivalent of clicking a picture: the gallery over every image in the
    /// conversation, on the first one or on the one a key names. The harness reads the `GALLERY`
    /// lines it prints.
    func driverOpenGallery(key: String? = nil) {
        let items = galleryItems()
        guard let first = items.first(where: { key == nil || $0.key == key }) ?? items.first else {
            FileHandle.standardOutput.write(Data("GALLERY none (\(lastFullRows.count) rows)\n".utf8))
            return
        }
        presentImage(key: first.key, name: first.name)
    }

    /// The keys of the conversation's pictures in reading order, so a harness can name one.
    var galleryKeys: [String] { galleryItems().map(\.key) }

    /// Opens the gallery over every picture in the conversation, landed on the one clicked.
    func presentImage(key: String, name: String) {
        let items = galleryItems()
        guard !items.isEmpty else { return }
        ImageGallery.present(
            items: items, startKey: key, parent: host?.windowWidget, context: context,
            fetch: { [weak self] reference, key in
                Gtk.onMain { [weak self] in self?.fetchImage(reference, key: key, urgent: true) }
            },
            notice: { [weak self] text in
                Gtk.onMain { [weak self] in self?.setNotice(text) }
            })
    }
}

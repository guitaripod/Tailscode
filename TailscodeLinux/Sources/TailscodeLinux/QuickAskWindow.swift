import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The quick-ask surface, drawn as a palette: a borderless card that arrives over whatever was in
/// front, the question as its largest thing, and everything else in the order a hand reaches for
/// it. Under the question one quiet row names where it goes — the machine, the model at its level,
/// what can be handed over — and changes any of it in one press; under that, the list: what was just
/// copied with what can be done with it, the person's actions, what is waiting for later, and what
/// was asked here before, walked with the arrows and run with Enter, the first nine on
/// `alt+1…9`. Typing turns the list into a row of verbs for the words typed (`alt+1…3` hands them
/// to an action), and the foot of the card says, in one line of keys, what the keys do for the box
/// as it is now. Enter is still the whole ceremony: the words and anything attached go out as a new
/// conversation with no project on the machine named in the chip, and the card stays only long
/// enough for that machine to answer, so a failed mint keeps the question in hand.
final class QuickAskWindow: @unchecked Sendable {
    nonisolated(unsafe) static var open: QuickAskWindow?

    let servers: [ConnectionProfile]
    /// What each machine's agent takes as an effort level, read where a backend could be asked:
    /// this window holds profiles rather than connections, and a level it cannot offer honestly
    /// is one it must not offer at all.
    let agentEfforts: [String: [String]]
    /// Which machines resolve their own slash words out of the prompt text. Read where a backend
    /// could be asked, for the same reason the effort levels are: this window holds profiles rather
    /// than connections, and the grammar belongs to the server the question is aimed at.
    let promptTextGrammar: [String: Bool]
    /// What the aimed server can be told to do. Answered from what it last published so the first
    /// keystroke is never blank, and corrected by a fetch behind it.
    var commands: [AgentCommand] = []
    let recents: [SessionEntry]
    var catalogWatch: Task<Void, Never>?
    var targetIndex: Int
    var reachability: [String: Bool] = [:]
    let shortcuts = ShortcutSet.load()
    let onAsk:
        @Sendable (String, QuickAskSend, [PendingAttachment], @escaping @Sendable (NewChatFailure?)
            -> Void) -> Void
    let onResume: @Sendable (SessionEntry) -> Void
    let onAskParty: @Sendable (QuickAskPartySend, @escaping @Sendable (NewChatFailure?) -> Void) -> Void
    /// The aim an action moved for one question, put back once the question has left.
    var hold: QuickAskAimHold?
    /// An action part way through fetching what its template names.
    var gathering: QuickAskGathering?

    let window: UnsafeMutablePointer<GtkWidget>
    /// Where the card stands and how big it is, and the gestures that change either.
    var stage: QuickAskStage!
    let editor: PromptEditor
    let target: UnsafeMutablePointer<GtkWidget>
    let dial: DialPill
    let attach: UnsafeMutablePointer<GtkWidget>
    let screenChip: UnsafeMutablePointer<GtkWidget>
    let send: UnsafeMutablePointer<GtkWidget>
    let chips: UnsafeMutablePointer<GtkWidget>
    let body: UnsafeMutablePointer<GtkWidget>
    let starters: UnsafeMutablePointer<GtkWidget>
    let hint: UnsafeMutablePointer<GtkWidget>
    let footKeys: UnsafeMutablePointer<GtkWidget>
    let chord: UnsafeMutablePointer<GtkWidget>
    var menuItems: [QuickAskMenuItem] = []
    var menuRows: [UnsafeMutablePointer<GtkWidget>] = []
    var menuCursor = QuickAskMenuCursor()
    /// Whether the list was last drawn for a typed box, so it is redrawn as the verbs only when
    /// the box crosses between empty and not, never on every keystroke.
    var typingShown: Bool?
    let vimBadge = Gtk.label("", css: "vim-badge", selectable: false)
    var attachments: [PendingAttachment] = []
    var offered: [QuickAskStarter] = []
    /// What the clipboard held the last time it was read, kept whole so an errand pastes exactly
    /// what the card showed.
    var copiedOffer: ClipboardOffer?
    var copied: QuickAskCopied?
    /// The lines a digit picks, in digit order.
    var picks: [QuickAskMenuItem] = []
    var pastedImageCount = 0
    var asking = false
    var summonWatch: NSObjectProtocol?
    var actionsWatch: NSObjectProtocol?
    var laterWatch: NSObjectProtocol?
    var completion: SlashPopover?

    /// - Parameter onAsk: mints the conversation on the chosen server and answers with nothing
    ///   when it worked, or with the reason it did not; the words and their attachments travel
    ///   with the mint, so the caller owns getting them sent once the chat exists.
    /// - Parameter onResume: opens a question already asked on this machine rather than asking a
    ///   new one.
    /// - Parameter onAskParty: mints one conversation per party slot and opens them side by side.
    static func present(
        servers: [ConnectionProfile], agentEfforts: [String: [String]] = [:],
        promptTextGrammar: [String: Bool] = [:],
        preferredServer: String?, recents: [SessionEntry],
        parent: UnsafeMutablePointer<GtkWidget>?,
        onAsk: @escaping @Sendable (
            String, QuickAskSend, [PendingAttachment], @escaping @Sendable (NewChatFailure?) -> Void
        ) -> Void,
        onResume: @escaping @Sendable (SessionEntry) -> Void,
        onAskParty: @escaping @Sendable (
            QuickAskPartySend, @escaping @Sendable (NewChatFailure?) -> Void
        ) -> Void
    ) {
        guard !servers.isEmpty else { return }
        open?.close()
        open = QuickAskWindow(
            servers: servers, agentEfforts: agentEfforts, promptTextGrammar: promptTextGrammar,
            preferredServer: preferredServer, recents: recents, parent: parent, onAsk: onAsk,
            onResume: onResume, onAskParty: onAskParty)
    }

    init(
        servers: [ConnectionProfile], agentEfforts: [String: [String]],
        promptTextGrammar: [String: Bool],
        preferredServer: String?, recents: [SessionEntry],
        parent: UnsafeMutablePointer<GtkWidget>?,
        onAsk: @escaping @Sendable (
            String, QuickAskSend, [PendingAttachment], @escaping @Sendable (NewChatFailure?) -> Void
        ) -> Void,
        onResume: @escaping @Sendable (SessionEntry) -> Void,
        onAskParty: @escaping @Sendable (
            QuickAskPartySend, @escaping @Sendable (NewChatFailure?) -> Void
        ) -> Void
    ) {
        self.servers = servers
        self.onAskParty = onAskParty
        self.agentEfforts = agentEfforts
        self.promptTextGrammar = promptTextGrammar
        self.recents = recents
        self.onAsk = onAsk
        self.onResume = onResume
        let aimed = QuickAskDefaults.target(
            among: servers.map(\.id), fallback: preferredServer)
        targetIndex = servers.firstIndex { $0.id == aimed } ?? 0

        window = gtk_window_new()!
        gtk_window_set_title(ptr(window), Localized.text("Quick ask"))
        Gtk.addClass(window, "qa-window")

        editor = PromptEditor(css: "ask-entry", placeholder: Localized.text("Ask anything…"))
        Gtk.addClass(editor.widget, "qa-input")
        hint = Gtk.label("", css: "qa-status", wrap: true, selectable: false)
        gtk_label_set_xalign(op(hint), 0)
        gtk_widget_set_visible(hint, 0)
        target = Gtk.menuButton("", css: ["flat", "qa-chip", "qa-machine"]) {
            QuickAskWindow.open?.serverRows() ?? []
        }
        dial = DialPill(
            css: ["flat", "ask-dial"],
            dial: ModelDialPopover(
                makeState: {
                    QuickAskWindow.open?.dialState()
                        ?? ModelDialState(
                            sources: [], selected: nil, effort: nil, options: [], modelWord: "")
                },
                onPick: { pick, effort, notice in
                    Gtk.onMain { QuickAskWindow.open?.pick(pick, effort: effort, notice: notice) }
                },
                onEffort: { level in
                    Gtk.onMain {
                        guard let open = QuickAskWindow.open else { return }
                        open.setEffort(level, on: open.targetServer.id, refocus: false)
                    }
                },
                onOpenCatalog: { Gtk.onMain { QuickAskWindow.open?.chooseModel() } }),
            party: Self.makePartyPopover()
        ) { delta in
            QuickAskWindow.open?.stepEffort(by: delta)
        }
        attach = Gtk.button(Localized.text("📎 Attach"), css: ["flat", "qa-chip"]) {
            Gtk.onMain { QuickAskWindow.open?.pickAttachments() }
        }
        screenChip = Gtk.button(Localized.text("⬚ Screen"), css: ["flat", "qa-chip"]) {
            Gtk.onMain { QuickAskWindow.open?.grabScreen() }
        }
        send = Gtk.button("↵", css: ["flat", "ask-send", "qa-send"]) {
            Gtk.onMain { QuickAskWindow.open?.submit() }
        }
        gtk_widget_set_valign(send, GTK_ALIGN_START)
        chips = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        starters = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        Gtk.addClass(starters, "qa-list")
        body = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(body), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_vexpand(body, 1)
        gtk_scrolled_window_set_child(op(body), starters)
        Gtk.addClass(body, "qa-body")
        footKeys = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        chord = Gtk.label("", css: "qa-foot-word", selectable: false)

        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(card, "qa-card")

        let caret = Gtk.label("›", css: "qa-caret", selectable: false)
        gtk_widget_set_valign(caret, GTK_ALIGN_START)
        gtk_widget_set_visible(vimBadge, 0)
        gtk_label_set_ellipsize(op(vimBadge), PANGO_ELLIPSIZE_NONE)
        let field = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(field, "qa-field")
        gtk_box_append(ptr(field), caret)
        gtk_widget_set_hexpand(editor.widget, 1)
        gtk_box_append(ptr(field), editor.widget)
        gtk_box_append(ptr(field), send)
        let frame = gtk_overlay_new()!
        gtk_overlay_set_child(op(frame), field)
        editor.wearAura(on: frame)

        let aim = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        Gtk.addClass(aim, "qa-aim")
        for chip in [target, dial.button, attach, screenChip] { gtk_box_append(ptr(aim), chip) }
        let slack = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(slack, 1)
        gtk_box_append(ptr(aim), slack)
        gtk_widget_set_valign(vimBadge, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(aim), vimBadge)

        let head = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        Gtk.addClass(head, "qa-head")
        gtk_box_append(ptr(head), frame)
        gtk_box_append(ptr(head), aim)
        gtk_box_append(ptr(head), chips)
        gtk_box_append(ptr(head), hint)

        let foot = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        Gtk.addClass(foot, "qa-foot")
        let keysRoom = Gtk.shrinkable(footKeys)
        gtk_widget_set_hexpand(keysRoom, 1)
        gtk_box_append(ptr(foot), keysRoom)
        gtk_box_append(ptr(foot), chord)

        gtk_box_append(ptr(card), head)
        gtk_box_append(ptr(card), body)
        gtk_box_append(ptr(card), foot)
        editor.carryModeOn(field)
        stage = QuickAskStage(window: window, card: card, parent: parent)
        stage.onBackdrop = { Gtk.onMain { QuickAskWindow.open?.close() } }
        stage.onPlaced = { Gtk.onMain { QuickAskWindow.open?.editor.focus() } }

        let completion = SlashPopover(anchor: field)
        completion.hasProject = false
        completion.onPick = { [weak self] command in
            Gtk.onMain { [weak self] in self?.acceptSlashCommand(command) }
        }
        self.completion = completion

        /// The whole surface takes a drop, not a button on it: something dragged out of a file
        /// manager is a question about that thing, and aiming it at a paperclip is not a gesture
        /// anybody should have to make.
        Gtk.acceptFileDrops(on: card) { [weak self] paths in
            Gtk.onMain { [weak self] in self?.take(paths: paths) }
        }

        editor.onChanged = { [weak self] in
            self?.clearHint()
            self?.releaseHoldIfEmptied()
            self?.stashDraft()
            self?.refreshStarterVisibility()
            self?.refreshSend()
            self?.refreshAura()
            self?.updateSlashCompletion()
            self?.renderTyping()
        }
        Gtk.onKey(window) { [weak self] keyval, state in
            guard let self else { return false }
            let control = state & KeyChord.controlMask != 0
            let shift = state & Keymap.shift != 0
            if self.completion?.isShown == true {
                if keyval == Keymap.down || (control && keyval == UInt32(UnicodeScalar("n").value)) {
                    Gtk.onMain { [weak self] in self?.completion?.move(by: 1) }
                    return true
                }
                if keyval == Keymap.up || (control && keyval == UInt32(UnicodeScalar("p").value)) {
                    Gtk.onMain { [weak self] in self?.completion?.move(by: -1) }
                    return true
                }
                if keyval == Keymap.tab {
                    Gtk.onMain { [weak self] in
                        guard let self, let command = self.completion?.selected else { return }
                        self.acceptSlashCommand(command)
                    }
                    return true
                }
                if keyval == Keymap.escape {
                    Gtk.onMain { [weak self] in self?.completion?.dismiss() }
                    return true
                }
            }
            if state & KeyChord.altMask == 0, !self.asking {
                let down = keyval == Keymap.down || (control && keyval == UInt32(UnicodeScalar("n").value))
                let up = keyval == Keymap.up || (control && keyval == UInt32(UnicodeScalar("p").value))
                if (down || up), self.walksList(down: down) {
                    Gtk.onMain { [weak self] in self?.moveSelection(by: down ? 1 : -1) }
                    return true
                }
                let isReturn = keyval == Keymap.enter || keyval == Keymap.keypadEnter
                if isReturn, self.menuCursor.index != nil {
                    Gtk.onMain { [weak self] in self?.runSelected() }
                    return true
                }
                if keyval == Keymap.escape, self.menuCursor.index != nil {
                    Gtk.onMain { [weak self] in self?.clearSelection() }
                    return true
                }
            }
            if let claimed = self.vimKey(keyval: keyval, state: state) { return claimed }
            if keyval == Keymap.escape {
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    if self.gathering != nil { self.cancelGathering() } else { self.close() }
                }
                return true
            }
            if keyval == Keymap.tab {
                Gtk.onMain { [weak self] in self?.cycleTarget() }
                return true
            }
            if control, keyval == UInt32(UnicodeScalar("v").value) {
                Gtk.onMain { [weak self] in self?.pasteFromClipboard() }
                return true
            }
            if control, state & KeyChord.altMask == 0, keyval == UInt32(UnicodeScalar("s").value) {
                Gtk.onMain { [weak self] in self?.saveAsAction() }
                return true
            }
            /// Return is the send unless the settings say otherwise, and shift always writes the
            /// line break — the same bargain the chat's own box makes, so a question with a
            /// paragraph in it is typed the way a prompt is.
            let isReturn = keyval == Keymap.enter || keyval == Keymap.keypadEnter
            if isReturn, state & KeyChord.altMask != 0, !control {
                Gtk.onMain { [weak self] in self?.submitToParty() }
                return true
            }
            if isReturn, !shift, Preferences.sendOnReturn || control {
                Gtk.onMain { [weak self] in self?.submit() }
                return true
            }
            if isReturn { return false }
            if let party = self.partyAction(keyval: keyval, state: state) {
                Gtk.onMain { [weak self] in self?.perform(party: party) }
                return true
            }
            if control, state & KeyChord.altMask != 0, keyval == Keymap.up {
                Gtk.onMain { [weak self] in self?.stepEffort(by: 1) }
                return true
            }
            if control, state & KeyChord.altMask != 0, keyval == Keymap.down {
                Gtk.onMain { [weak self] in self?.stepEffort(by: -1) }
                return true
            }
            guard state & KeyChord.altMask != 0 else { return false }
            if keyval == UInt32(UnicodeScalar("m").value)
                || keyval == UInt32(UnicodeScalar("e").value)
            {
                Gtk.onMain { [weak self] in self?.dial.openDial() }
                return true
            }
            if keyval == UInt32(UnicodeScalar("a").value) {
                Gtk.onMain { [weak self] in self?.pickAttachments() }
                return true
            }
            if keyval == UInt32(UnicodeScalar("v").value) {
                Gtk.onMain { [weak self] in self?.pasteFromClipboard() }
                return true
            }
            if keyval == UInt32(UnicodeScalar("s").value) {
                Gtk.onMain { [weak self] in self?.grabScreen() }
                return true
            }
            if keyval == UInt32(UnicodeScalar("l").value) {
                Gtk.onMain { [weak self] in self?.offerLater() }
                return true
            }
            guard let digit = Keymap.digit(keyval), digit > 0, digit <= self.picks.count else {
                return false
            }
            Gtk.onMain { [weak self] in self?.pick(at: digit - 1) }
            return true
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") { [weak self] in
            if let self, QuickAskWindow.open === self { QuickAskWindow.open = nil }
        }
        laterWatch = NotificationCenter.default.addObserver(
            forName: QuickAskLaterStore.didChange, object: nil, queue: nil
        ) { _ in
            Gtk.onMain {
                guard let open = QuickAskWindow.open, !open.asking else { return }
                open.renderStarters()
            }
        }
        actionsWatch = NotificationCenter.default.addObserver(
            forName: QuickAskActions.didChange, object: nil, queue: nil
        ) { _ in
            Gtk.onMain { QuickAskWindow.open?.renderStarters() }
        }

        /// The desktop answers about the chord seconds after the app starts, which is often after
        /// this window has already been opened by that very chord.
        summonWatch = NotificationCenter.default.addObserver(
            forName: Summon.didChange, object: nil, queue: nil
        ) { _ in
            Gtk.onMain { QuickAskWindow.open?.renderFooter() }
        }

        /// A Wayland clipboard answers only a window that has the keyboard, and the chord that
        /// opened this one often arrives a frame before the compositor hands it over, so the
        /// clipboard is read again the moment the window is the active one.
        Gtk.onNotify(UnsafeMutableRawPointer(window), property: "is-active") {
            Gtk.onMain {
                guard let open = QuickAskWindow.open, gtk_window_is_active(ptr(open.window)) != 0
                else { return }
                open.readCopied()
            }
        }

        refreshTarget()
        readCopied()
        watchCatalog()
        restoreDraft()
        updateVimBadge()
        loadCommands()
        gtk_window_present(ptr(window))
        editor.focus()
        AppLog.write(.ui, "ASK shown target=\(servers[targetIndex].name)")
    }

    lazy var effortVoice = EffortVoice { [weak self] words in
        Gtk.onMain { [weak self] in self?.announceEffort(words) }
    }
}

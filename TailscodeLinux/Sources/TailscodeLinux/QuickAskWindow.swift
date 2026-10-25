import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The quick-ask surface, drawn: one entry, the aim it remembered, and what the aim can be
/// handed. Enter is the whole ceremony — the words and anything attached to them go out as a new
/// conversation with no project directory on the server named in the chip, and the window stays
/// up only long enough for that server to answer, so a failed mint keeps the question in hand
/// rather than swallowing it. The aim is both halves and both are the quick ask's own: tab or a
/// click moves the machine, and the same dial the chat's composer wears — `alt+m`, `alt+e` or a
/// press — names the model and how hard it is asked to think, the wheel over it stepping the
/// level, and `QuickAskDefaults` remembers all three per server beside the composer's memory
/// rather than inside it.
///
/// Owing no form is not the same as being able to do nothing. `alt+a` attaches a file and
/// `alt+v` takes the clipboard's picture, offered only where the aim can read them; the empty
/// window argues for itself with `QuickAskStarters` — `alt+1…9`, or a click — and hands back the
/// last few questions asked on this machine, so the blank entry is a way into everything the
/// agent can do instead of a text field with a placeholder. Something new on the clipboard leads
/// the empty window as a card of its own (`QuickAskClipboard`), because a question summoned from
/// anywhere is most often about the thing just copied.
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

    let window: UnsafeMutablePointer<GtkWidget>
    let editor: PromptEditor
    let title: UnsafeMutablePointer<GtkWidget>
    let target: UnsafeMutablePointer<GtkWidget>
    let aimStrip: UnsafeMutablePointer<GtkWidget>
    var aimToggles: [UnsafeMutablePointer<GtkWidget>] = []
    let dial: DialPill
    let attach: UnsafeMutablePointer<GtkWidget>
    let send: UnsafeMutablePointer<GtkWidget>
    let chips: UnsafeMutablePointer<GtkWidget>
    let starters: UnsafeMutablePointer<GtkWidget>
    let hint: UnsafeMutablePointer<GtkWidget>
    let vimBadge = Gtk.label("", css: "vim-badge", selectable: false)
    var attachments: [PendingAttachment] = []
    var offered: [QuickAskStarter] = []
    /// What the clipboard held the last time it was read, kept whole so an errand pastes exactly
    /// what the card showed.
    var copiedOffer: ClipboardOffer?
    var copied: QuickAskCopied?
    var picks: [Pick] = []
    var pastedImageCount = 0
    var asking = false
    var summonWatch: NSObjectProtocol?
    var completion: SlashPopover?

    /// - Parameter onAsk: mints the conversation on the chosen server and answers with nothing
    ///   when it worked, or with the reason it did not; the words and their attachments travel
    ///   with the mint, so the caller owns getting them sent once the chat exists.
    /// - Parameter onResume: opens a question already asked on this machine rather than asking a
    ///   new one.
    static func present(
        servers: [ConnectionProfile], agentEfforts: [String: [String]] = [:],
        promptTextGrammar: [String: Bool] = [:],
        preferredServer: String?, recents: [SessionEntry],
        parent: UnsafeMutablePointer<GtkWidget>?,
        onAsk: @escaping @Sendable (
            String, QuickAskSend, [PendingAttachment], @escaping @Sendable (NewChatFailure?) -> Void
        ) -> Void,
        onResume: @escaping @Sendable (SessionEntry) -> Void
    ) {
        guard !servers.isEmpty else { return }
        open?.close()
        open = QuickAskWindow(
            servers: servers, agentEfforts: agentEfforts, promptTextGrammar: promptTextGrammar,
            preferredServer: preferredServer, recents: recents, parent: parent, onAsk: onAsk,
            onResume: onResume)
    }

    init(
        servers: [ConnectionProfile], agentEfforts: [String: [String]],
        promptTextGrammar: [String: Bool],
        preferredServer: String?, recents: [SessionEntry],
        parent: UnsafeMutablePointer<GtkWidget>?,
        onAsk: @escaping @Sendable (
            String, QuickAskSend, [PendingAttachment], @escaping @Sendable (NewChatFailure?) -> Void
        ) -> Void,
        onResume: @escaping @Sendable (SessionEntry) -> Void
    ) {
        self.servers = servers
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
        gtk_window_set_modal(ptr(window), 1)
        gtk_window_set_default_size(ptr(window), 720, -1)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }

        editor = PromptEditor(
            css: "ask-entry", placeholder: Localized.text("Ask anything — no project, no setup"))
        hint = Gtk.label("", css: "ask-hint", wrap: true, selectable: false)
        target = Gtk.menuButton("", css: ["flat", "ask-chip"]) {
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
        attach = Gtk.button("📎", css: ["flat", "ask-chip"]) {
            Gtk.onMain { QuickAskWindow.open?.pickAttachments() }
        }
        send = Gtk.button("↵", css: ["flat", "ask-send"]) {
            Gtk.onMain { QuickAskWindow.open?.submit() }
        }
        aimStrip = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(aimStrip, "linked")
        Gtk.addClass(aimStrip, "ask-aim")
        gtk_widget_set_valign(send, GTK_ALIGN_END)
        chips = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        starters = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)

        /// The window wears the desktop's own bar rather than a row of its own that has to be
        /// read as one: the name of the thing is in the title, the machine it will ask is the
        /// subtitle under it, and the two controls that change either sit where a header keeps
        /// controls. Nothing in the body then competes with the question.
        title = adw_window_title_new(Localized.text("Quick ask"), "")!
        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(op(UnsafeMutableRawPointer(header)), title)
        adw_header_bar_pack_start(op(UnsafeMutableRawPointer(header)), target)
        adw_header_bar_pack_end(op(UnsafeMutableRawPointer(header)), attach)
        adw_header_bar_pack_end(op(UnsafeMutableRawPointer(header)), dial.button)
        gtk_window_set_titlebar(ptr(window), header)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        Gtk.margins(column, top: 16, bottom: 14, leading: 16, trailing: 16)
        gtk_window_set_child(ptr(window), column)

        let caret = Gtk.label("›", css: "ask-caret", selectable: false)
        gtk_widget_set_valign(caret, GTK_ALIGN_START)
        Gtk.margins(caret, top: 8)
        gtk_widget_set_valign(vimBadge, GTK_ALIGN_END)
        gtk_widget_set_visible(vimBadge, 0)
        gtk_label_set_ellipsize(op(vimBadge), PANGO_ELLIPSIZE_NONE)
        let field = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.addClass(field, "ask-field")
        gtk_box_append(ptr(field), caret)
        gtk_box_append(ptr(field), editor.widget)
        gtk_box_append(ptr(field), vimBadge)
        gtk_box_append(ptr(field), send)
        let frame = gtk_overlay_new()!
        gtk_overlay_set_child(op(frame), field)
        editor.wearAura(on: frame)
        buildAimStrip()
        gtk_box_append(ptr(column), aimStrip)
        gtk_box_append(ptr(column), frame)
        gtk_box_append(ptr(column), chips)
        gtk_box_append(ptr(column), hint)
        gtk_box_append(ptr(column), starters)
        editor.carryModeOn(field)

        let completion = SlashPopover(anchor: field)
        completion.hasProject = false
        completion.onPick = { [weak self] command in
            Gtk.onMain { [weak self] in self?.acceptSlashCommand(command) }
        }
        self.completion = completion

        /// The whole surface takes a drop, not a button on it: something dragged out of a file
        /// manager is a question about that thing, and aiming it at a paperclip is not a gesture
        /// anybody should have to make.
        Gtk.acceptFileDrops(on: column) { [weak self] paths in
            Gtk.onMain { [weak self] in self?.take(paths: paths) }
        }

        editor.onHeightChanged = { [weak self] in self?.fitToContents() }
        editor.onChanged = { [weak self] in
            self?.stashDraft()
            self?.refreshStarterVisibility()
            self?.refreshSend()
            self?.refreshAura()
            self?.updateSlashCompletion()
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
            if let claimed = self.vimKey(keyval: keyval, state: state) { return claimed }
            if keyval == Keymap.escape {
                Gtk.onMain { [weak self] in self?.close() }
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
            /// Return is the send unless the settings say otherwise, and shift always writes the
            /// line break — the same bargain the chat's own box makes, so a question with a
            /// paragraph in it is typed the way a prompt is.
            let isReturn = keyval == Keymap.enter || keyval == Keymap.keypadEnter
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
            guard let digit = Keymap.digit(keyval), digit > 0,
                gtk_widget_get_visible(self.starters) != 0
            else { return false }
            Gtk.onMain { [weak self] in self?.pick(at: digit - 1) }
            return true
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") { [weak self] in
            if let self, QuickAskWindow.open === self { QuickAskWindow.open = nil }
        }

        /// The desktop answers about the chord seconds after the app starts, which is often after
        /// this window has already been opened by that very chord.
        summonWatch = NotificationCenter.default.addObserver(
            forName: Summon.didChange, object: nil, queue: nil
        ) { _ in
            Gtk.onMain {
                guard let open = QuickAskWindow.open else { return }
                adw_window_title_set_subtitle(
                    op(UnsafeMutableRawPointer(open.title)), Self.subtitle())
            }
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

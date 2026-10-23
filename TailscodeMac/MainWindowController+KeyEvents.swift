import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension MainWindowController {
    /// One local monitor is the whole engine: ⌘ chords fall through to the menu bar (the adapter
    /// returns nil for them on purpose), text fields keep their letters, and everything else goes
    /// through the shared registry exactly like Linux `installKeymap`.
    func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                SheetStack.shared.conversationChordsEnabled
            else { return event }
            return self.handle(event)
        }
    }

    /// The pointer's own claim on the keyboard: a local monitor sees every button going down
    /// before AppKit dispatches it, so whatever was pressed becomes the focused pane and the
    /// keyboard's region *first* — a band chip, a permission card or a pill in a background pane
    /// then acts on its own conversation instead of on whichever pane the eye had left behind.
    /// The event is returned untouched: the click keeps its ordinary meaning and first responder
    /// lands exactly where the press put it.
    func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.pressLanded(event)
            return event
        }
    }

    private func pressLanded(_ event: NSEvent) {
        guard event.window === window, SheetStack.shared.conversationChordsEnabled
        else { return }
        let point = event.locationInWindow
        if let banner = restoreBanner, banner.bounds.contains(banner.convert(point, from: nil)) {
            return
        }
        if let pane = splitPanes.pane(atWindowPoint: point) {
            regionPressed(.transcript)
            splitPanes.focus(pane, grabKeyboard: false)
            if let paneID = splitPanes.id(of: pane) { wakeParked(paneID) }
            return
        }
        if contains(sidebar, point) {
            regionPressed(.chats)
        } else if terminalPressed(point) {
            regionPressed(.terminal)
        }
    }

    /// Pressing in a region is what makes it the keyboard's region, so Tab cycles from where the
    /// hand actually is. Only the region moves — the press keeps whatever it was going to do, and
    /// nothing is made first responder that the click did not already choose.
    private func regionPressed(_ pane: Pane) {
        guard focused != pane else { return }
        focused = pane
        if pane != .transcript { transcript.composer.dismissCompletion() }
    }

    private func contains(_ controller: NSViewController, _ windowPoint: NSPoint) -> Bool {
        guard controller.isViewLoaded, controller.view.window != nil,
            !controller.view.isHiddenOrHasHiddenAncestor
        else { return false }
        let local = controller.view.convert(windowPoint, from: nil)
        return NSMouseInRect(local, controller.view.bounds, controller.view.isFlipped)
    }

    /// The shell pane is a subprocess this Mac's own directories are open to, which a sandboxed
    /// copy has neither the right nor the reach to run — so the store build has no such pane, and
    /// every question about one is answered rather than asked.
    func retargetTerminal(to directory: String?) {
        #if !TAILSCODE_MAS
            terminalPane.setDirectory(directory)
        #endif
    }

    private func terminalPressed(_ windowPoint: NSPoint) -> Bool {
        #if TAILSCODE_MAS
            return false
        #else
            return terminalItem?.isCollapsed == false && contains(terminalPane, windowPoint)
        #endif
    }

    var terminalHasFocus: Bool {
        #if TAILSCODE_MAS
            return false
        #else
            return terminalPane.ownsFocus(in: window)
        #endif
    }

    private func interruptTerminal() {
        #if !TAILSCODE_MAS
            terminalPane.interrupt()
        #endif
    }

    /// The last thing the app does before it goes: the shell pane's command is stopped rather than
    /// left running with no window to stop it from, and the chat list's cache — written a few
    /// seconds behind the listing so a busy turn does not write it on every status — is written
    /// now, because the few seconds may never come.
    func prepareToQuit() {
        #if !TAILSCODE_MAS
            terminalPane.stopRunning()
        #endif
        MacVoiceCallGate.shared.prepareToQuit()
        SessionListCache.flushPendingSave()
        splitPanes.flushPersistence()
        Seatbelts.shared.finish(panes: splitPanes.paneCount)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if window?.firstResponder is KeyboardPressable, [49, 36, 76].contains(event.keyCode) {
            return event
        }
        if window?.firstResponder is LinkRailPlateView, [36, 49, 76, 125, 126, 53].contains(event.keyCode) {
            return event
        }
        if let taker = window?.firstResponder as? BrainKeyTaker, taker.takesBrainKey(event) {
            return event
        }
        if pendingChords.isEmpty, window?.firstResponder is DividerSplitView,
            DividerSplitView.dividerKey(for: event) != nil
        {
            return event
        }
        if let verdict = composerKey(event) { return verdict ? nil : event }
        guard let chord = MacKeys.chord(for: event) else { return event }
        if terminalHasFocus, chord.control, !chord.shift, !chord.alt,
            chord.keyval == UInt32(UInt8(ascii: "c"))
        {
            interruptTerminal()
            return nil
        }
        let context = keyContext()
        if context == .normal, focused == .transcript, pendingChords.isEmpty,
            transcript.handleChooserChord(chord)
        {
            return nil
        }
        #if !TAILSCODE_MAS
            if focused == .transcript, pendingChords.isEmpty,
                context == .normal || transcript.isChoosingStream,
                transcript.handleVideoChord(chord)
            {
                return nil
            }
        #endif
        if focused == .transcript, pendingChords.isEmpty, transcript.handleWebChord(chord) {
            return nil
        }
        if focused == .transcript, pendingChords.isEmpty, context == .normal,
            transcript.handlePreviewChord(chord)
        {
            return nil
        }
        let awaiting =
            context == .normal
            && !(transcript.currentState?.pendingPermissions.isEmpty ?? true)
        switch shortcuts.resolve(
            chord, context: context, pending: pendingChords, awaitingApproval: awaiting)
        {
        case .run(let action):
            pendingChords = []
            return perform(action) ? nil : event
        case .pending(let chords):
            pendingChords = chords
            return nil
        case .unbound:
            pendingChords = []
            return event
        }
    }

    /// The prompt box's own key handling, decided here rather than in the text view so the same
    /// keystroke means the same thing whether a person typed it or a binding sent it — exactly
    /// Linux `handleComposerKey`: completion keys first while the popover shows, then vim, then
    /// Return-to-send. `nil` means "not the composer's business" and the keystroke falls through
    /// to the shared registry; `false` hands it to the text view for ordinary typing.
    private func composerKey(_ event: NSEvent) -> Bool? {
        guard let pane = splitPanes.orderedPanes.first(where: { $0.composer.editorHasFocus })
        else { return nil }
        splitPanes.focus(pane, grabKeyboard: false)
        focused = .transcript
        let composer = pane.composer
        guard !composer.editorIsComposing else { return false }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if event.modifierFlags.contains(.command) {
            if isReturn {
                composer.sendNow()
                return true
            }
            return nil
        }
        let control = event.modifierFlags.contains(.control)
        let shift = event.modifierFlags.contains(.shift)
        let letter = event.charactersIgnoringModifiers

        if composer.completionVisible {
            switch event.keyCode {
            case 48:
                if shift { composer.moveCompletion(by: -1) } else { composer.acceptCompletion() }
                return true
            case 125:
                composer.moveCompletion(by: 1)
                return true
            case 126:
                composer.moveCompletion(by: -1)
                return true
            case 53:
                composer.dismissCompletion()
                return true
            default:
                if control, letter == "n" {
                    composer.moveCompletion(by: 1)
                    return true
                }
                if control, letter == "p" {
                    composer.moveCompletion(by: -1)
                    return true
                }
            }
        }

        if composer.vimEnabled {
            let key = vimKey(for: event)
            if composer.vimMode == .insert, key.isEscape || (control && letter == "[") {
                composer.applyVim(VimKey(isEscape: true))
                return true
            }
            if composer.vimMode != .insert {
                return composerNormalKey(key, event: event, pane: pane)
            }
        }

        // ↑ in an empty box takes the last thing written back for rewriting. Only from an empty
        // box: in a half-typed paragraph that key is moving the caret, and taking it would be the
        // worse bug by far.
        if event.keyCode == 126, !control, !shift, composer.takeBackQueued() { return true }

        if isReturn, !shift, ComposerView.sendOnReturn || control {
            composer.sendNow()
            return true
        }
        if isReturn, shift || !ComposerView.sendOnReturn { return false }
        return nil
    }

    /// The composer's normal mode is the app's normal mode: every key answers to the shortcut
    /// table first — j scrolls, J switches chats, ? opens the cheatsheet — while vim keeps what
    /// makes it vim: the visual modes, insert and visual entries, Enter to send, and every key of
    /// a command already in flight, so `3x`, `diw` and `ct)` still land. A chord sequence in
    /// flight outranks both, so `ctrl+w v` splits rather than entering visual mode. A key neither
    /// side binds goes back to vim rather than to the text view, so no stray letter types itself
    /// into the draft.
    private func composerNormalKey(
        _ key: VimKey, event: NSEvent, pane: TranscriptViewController
    ) -> Bool? {
        let composer = pane.composer
        if key.control, event.charactersIgnoringModifiers == "c",
            composer.copySelectionToPasteboard()
        {
            toast(Localized.text("Copied"))
            return true
        }
        guard let chord = MacKeys.chord(for: event) else { return nil }
        let awaiting = !(pane.currentState?.pendingPermissions.isEmpty ?? true)
        if awaiting, !chord.control, !chord.alt, pendingChords.isEmpty,
            let action = shortcuts.approval[chord.token]
        {
            pendingChords = []
            return perform(action)
        }
        if key.isEnter, chord.control {
            pendingChords = []
            composer.sendNow()
            return true
        }
        let plain = !chord.control && !chord.alt
        if composer.vimClaims(key, plain: plain, chordPending: !pendingChords.isEmpty) {
            pendingChords = []
            composer.applyVim(key)
            return true
        }
        switch shortcuts.resolve(
            chord, context: .normal, pending: pendingChords, awaitingApproval: false)
        {
        case .run(let action):
            pendingChords = []
            _ = perform(action)
            return true
        case .pending(let chords):
            pendingChords = chords
            return true
        case .unbound:
            pendingChords = []
            composer.applyVim(key)
            return true
        }
    }

    private func vimKey(for event: NSEvent) -> VimKey {
        PromptEditor.vimKey(for: event)
    }

    /// Anything that takes text — the composer, the filter field's editor, a rename sheet — is
    /// insert; the rest of the window is normal. The terminal is stricter than both: a shell's
    /// own Ctrl+B or Ctrl+E is not the app's to take, so while its field or output holds focus
    /// only Ctrl+Shift moves and zoom resolve, exactly like Linux.
    private func keyContext() -> KeyContext {
        if terminalHasFocus { return .terminal }
        guard let responder = window?.firstResponder else { return .normal }
        return responder is NSText ? .insert : .normal
    }
}

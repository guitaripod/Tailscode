import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

@MainActor
private final class DictationStubComposer: MacDictationHost {
    let editor = PromptEditor(placeholder: "Message…")
    let send = NSButton(title: "Send", target: nil, action: nil)
    var sent: [String] = []

    var dictationEditor: PromptEditor { editor }
    var dictationSendControl: NSView { send }
    var dictationKey: String { "selftest" }
    var dictationChord: String? { "⌃⇧D" }
    func dictationVocabulary() -> DictationVocabulary { DictationDemoRecognizer.vocabulary }
    func dictationSend() {
        sent.append(editor.text)
        editor.setText("", caretAtEnd: true)
    }
}

extension SelfTest {
    /// What the Mac's microphone promises with the scripted engine, in a real window: the control's
    /// faces, a click that listens hands-free with the chord in its hint and the field's edge lit,
    /// words snapped and capitalised into the box and landed as one undo step, a held press dragged
    /// left that discards and offers Undo, Esc that discards, Return that settles and sends, typing
    /// that keeps what is shown, and a live call that hides the control.
    static func checkDictation() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure("dictation: \(label)") }
            checks += 1
        }
        func settle(_ seconds: Double, until done: () -> Bool = { false }) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if done() { return true }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return done()
        }
        let host = DictationStubComposer()
        let controller = MacDictationController(host: host, engines: MacDictationEngines(demo: true, wordDelay: 0.05))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 160), styleMask: [.titled], backing: .buffered,
            defer: false)
        let row = NSStackView(views: [host.editor, controller.button, host.send])
        row.orientation = .horizontal
        let column = NSStackView(views: [controller.hint, row])
        column.orientation = .vertical
        window.contentView = column
        controller.harnessReadiness(.ready, language: "en-US")
        try expect(controller.harnessFace == .ready, "a ready Mac shows the microphone")

        controller.harnessDown()
        controller.harnessUp()
        try expect(await settle(4) { controller.harnessSnapshot.words.contains("ComposerView.swift so") }, "a click listens and the words snap")
        if case .listening(.handsFree, .none) = controller.harnessFace { checks += 1 } else {
            throw SelfTestFailure("dictation: a quick click listens hands-free, got \(controller.harnessFace)")
        }
        try expect(controller.harnessHint.contains("⌃⇧D"), "the hint names the chord: \(controller.harnessHint)")
        try expect(host.editor.dictationEdge.isLit, "the field's edge is lit")
        try expect(controller.button.widthConstraint.constant == MacDictationButton.openWidth, "the control grew into the capsule")
        controller.harnessDown()
        controller.harnessUp()
        try expect(await settle(3) { !controller.isOpen }, "the next click stops the take")
        let kept = host.editor.text
        try expect(kept.hasPrefix("Rename the dictation button in ComposerView.swift"), "the words landed: \(kept)")
        try expect(!host.editor.dictationEdge.isLit, "the edge goes out")
        host.editor.focus()
        window.undoManager?.undo()
        try expect(host.editor.text.isEmpty, "the take is one undo step: \(host.editor.text)")

        host.editor.setText("Please", caretAtEnd: true)
        controller.harnessDown()
        try expect(await settle(3) { controller.harnessSnapshot.wordCount > 3 }, "a hold listens")
        try? await Task.sleep(nanoseconds: 350_000_000)
        controller.harnessSlide(dx: -80)
        try expect(await settle(1) { controller.harnessSnapshot.arm == .cancel }, "dragging left arms a cancel")
        try expect(controller.harnessFace.tone == .danger, "an armed cancel wears the danger tone")
        controller.harnessUp()
        try expect(await settle(3) { !controller.isOpen }, "releasing the armed cancel ends the take")
        try expect(host.editor.text == "Please", "the box is as it was: \(host.editor.text)")
        try expect(controller.harnessHint == DictationReading.ending(.discarded)?.text, "the hint says Discarded")

        host.editor.setText("", caretAtEnd: true)
        controller.toggle()
        try expect(await settle(3) { controller.harnessSnapshot.wordCount > 2 }, "the menu's Dictate listens")
        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)
        try expect(escape.map(controller.handleKey) == true, "Esc is taken while listening")
        try expect(await settle(3) { !controller.isOpen }, "Esc ends the take")
        try expect(host.editor.text.isEmpty, "Esc throws the words away")

        controller.toggle()
        try expect(await settle(3) { controller.harnessSnapshot.wordCount > 4 }, "it listens again")
        let enter = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: PromptEditor.sendOnReturn ? [] : [.control], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)
        try expect(enter.map(controller.handleKey) == true, "Return is taken while listening")
        try expect(await settle(3) { host.sent.count == 1 }, "Return settles the take and sends it")
        try expect(host.sent.first?.hasPrefix("Rename") == true, "what was sent is what was said: \(host.sent)")

        controller.callLive = true
        try expect(controller.button.isHidden, "a live call hides the microphone")
        controller.callLive = false
        try expect(!controller.button.isHidden, "and it comes back when the call ends")

        controller.harnessReadiness(.unavailable(.microphoneDenied), language: nil)
        try expect(controller.harnessFace == .blocked(.microphoneDenied), "a denied microphone wears the slash")
        window.orderOut(nil)
        return checks
    }

    /// The quick ask's microphone, in a real panel with the scripted engine: the control stands
    /// between the box and Send with its hint under the field, the registry's chord tapped listens
    /// hands-free, Esc throws the take away and leaves the panel up, Return settles and asks, the
    /// control dims while the question is out, and a panel put away mid-take files what it showed
    /// as the machine's draft.
    static func checkQuickAskDictation() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure("quick ask dictation: \(label)") }
            checks += 1
        }
        func settle(_ seconds: Double, until done: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if done() { return true }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return done()
        }
        func key(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [], in panel: NSWindow)
            -> NSEvent
        {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: keyCode)!
        }
        let defaults = UserDefaults.standard
        let serverKey = "tailscode.quickask.server"
        let keptServer = defaults.string(forKey: serverKey)
        let profile = ConnectionProfile(
            id: "selftest-qd-arch", name: "qd-arch", backend: .openCode, baseURL: URL(string: "http://127.0.0.1:9")!)
        let scope = DraftScope.quickAsk(profileID: profile.id)
        defer {
            QuickAskDefaults.clearOwnAim(forProfileID: profile.id)
            DraftStore.clear(scope)
            if let keptServer { defaults.set(keptServer, forKey: serverKey) } else { defaults.removeObject(forKey: serverKey) }
        }
        DraftStore.clear(scope)
        var asked: [String] = []
        func panel() -> QuickAskPanel {
            var made: QuickAskPanel?
            made = QuickAskPanel(
                servers: [profile], preferredServer: profile.id, recents: [],
                onAsk: { _, _, _, _ in asked.append(made?.editor.text ?? "") }, onResume: { _ in },
                onAskParty: { _, _ in }, dictationEngines: MacDictationEngines(demo: true, wordDelay: 0.05))
            made!.hidesOnDeactivate = false
            made!.orderFrontRegardless()
            made!.dictation.harnessReadiness(.ready, language: "en-US")
            return made!
        }

        let first = panel()
        defer { first.close() }
        guard let field = first.editor.superview as? NSStackView,
            let actions = first.dictation.button.superview as? NSStackView,
            actions === first.sendButton.superview,
            let box = field.arrangedSubviews.firstIndex(of: first.editor),
            let pair = field.arrangedSubviews.firstIndex(of: actions),
            let mic = actions.arrangedSubviews.firstIndex(of: first.dictation.button),
            let send = actions.arrangedSubviews.firstIndex(of: first.sendButton)
        else { throw SelfTestFailure("quick ask dictation: the microphone is in the field beside Send") }
        try expect(box < pair && mic < send, "the microphone stands between the box and Send")
        try expect(first.dictation.hint.superview != nil, "the hint has a place in the panel")
        try expect(first.dictation.harnessFace == .ready, "a ready Mac shows it")
        first.contentView?.layoutSubtreeIfNeeded()
        let restingMic = first.dictation.button.convert(first.dictation.button.bounds, to: nil)
        let sendFrame = first.sendButton.convert(first.sendButton.bounds, to: nil)
        try expect(abs(restingMic.midY - sendFrame.midY) <= 1.5, "the microphone sits level with Send: \(restingMic) \(sendFrame)")

        try expect(
            first.handleDictationKey(key("D", 2, [.control, .shift], in: first), isReturn: false, option: false),
            "the registry's chord is taken")
        first.dictation.keyReleased(keyCode: 2, flags: [])
        try expect(await settle(4) { first.dictation.harnessSnapshot.wordCount > 3 }, "a tapped chord listens")
        if case .listening(.handsFree, .none) = first.dictation.harnessFace { checks += 1 } else {
            throw SelfTestFailure("quick ask dictation: a tap listens hands-free, got \(first.dictation.harnessFace)")
        }
        try expect(first.editor.dictationEdge.isLit, "the field's edge is lit")
        first.contentView?.layoutSubtreeIfNeeded()
        let hintFrame = first.dictation.hint.convert(first.dictation.hint.bounds, to: nil)
        try expect(
            !first.dictation.hint.isHidden && hintFrame.maxY <= field.convert(field.bounds, to: nil).minY + 0.5,
            "the hint shows under the field: \(hintFrame)")
        try expect(
            abs(first.dictation.button.convert(first.dictation.button.bounds, to: nil).midY - sendFrame.midY) <= 1.5,
            "the capsule stays level with Send")
        try expect(
            first.handleDictationKey(key("\u{1B}", 53, in: first), isReturn: false, option: false),
            "Esc is the take's while it listens")
        try expect(await settle(3) { !first.dictation.isOpen }, "Esc ends the take")
        try expect(first.isVisible, "and leaves the panel up")
        try expect(first.editor.text.isEmpty, "with the words thrown away: \(first.editor.text)")

        first.dictation.toggle()
        try expect(await settle(4) { first.dictation.harnessSnapshot.wordCount > 4 }, "the menu's Dictate listens")
        let enter = key("\r", 36, PromptEditor.sendOnReturn ? [] : [.control], in: first)
        try expect(first.handleDictationKey(enter, isReturn: true, option: false), "Return is the take's too")
        try expect(await settle(3) { asked.count == 1 }, "Return settles the take and asks")
        try expect(asked.first?.hasPrefix("Rename") == true, "what was asked is what was said: \(asked)")
        try expect(first.dictation.waiting && first.dictation.button.alphaValue < 1, "the control dims while it asks")
        first.dictation.toggle()
        try expect(!first.dictation.isOpen, "and takes no press")

        let second = panel()
        defer { second.close() }
        second.dictation.toggle()
        try expect(await settle(4) { second.dictation.harnessSnapshot.wordCount > 4 }, "a second panel listens")
        let shown = second.editor.text
        second.close()
        try expect(!second.dictation.isOpen, "putting the panel away ends the take")
        try expect(!shown.isEmpty && DraftStore.text(for: scope) == shown, "and files what it showed as the draft")
        return checks
    }
}

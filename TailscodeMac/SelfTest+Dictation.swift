import AppKit
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
}

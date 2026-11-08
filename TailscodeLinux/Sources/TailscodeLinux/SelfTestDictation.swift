import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

private final class DictationStubHost: DictationPaneHost, @unchecked Sendable {
    let editor = PromptEditor(css: "composer", placeholder: "Message…")
    let sendTarget = gtk_button_new()!
    var sent: [String] = []
    var announced: [String] = []
    var callLive = false

    var dictationEditor: PromptEditor { editor }
    var dictationWindow: UnsafeMutablePointer<GtkWidget>? { nil }
    var dictationSendTarget: UnsafeMutablePointer<GtkWidget>? { sendTarget }
    var dictationKey: String { "selftest" }
    var dictationCallLive: Bool { callLive }
    var dictationShortcuts: ShortcutSet { ShortcutSet.build(overrides: [:]) }
    func dictationVocabulary() -> DictationVocabulary { DictationDemoRecognizer.vocabulary }
    func dictationSend() {
        sent.append(editor.text)
        editor.clear()
    }
    func dictationAnnounce(_ words: String) { announced.append(words) }
}

/// Plays a WAV file (16-bit mono) as the microphone, at `speed` times real time, then silence
/// until stopped, so a take ends when the test says and not when the file does.
private final class WaveCapture: VoiceAudioCapture, @unchecked Sendable {
    private let samples: [Int16]
    private let speed: Double
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<Data>.Continuation?
    private(set) var finishedFile = false

    init?(path: String, speed: Double) {
        guard let data = FileManager.default.contents(atPath: path), data.count > 44,
            let source = Self.decode(data)
        else { return nil }
        samples = Self.resample(source.samples, from: source.rate, to: VoicePCM.sampleRate)
        self.speed = speed
    }

    var level: Double { 0.5 }

    var isDone: Bool { lock.withLock { finishedFile } }

    func start() async throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        lock.withLock { self.continuation = continuation }
        let chunk = VoicePCM.sampleRate * 80 / 1000
        let samples = self.samples
        let delay = UInt64(80_000_000 / speed)
        task = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                let piece: [Int16]
                if index < samples.count {
                    piece = Array(samples[index..<min(samples.count, index + chunk)])
                    index += chunk
                } else {
                    self?.lock.withLock { self?.finishedFile = true }
                    piece = [Int16](repeating: 0, count: chunk)
                }
                continuation.yield(piece.withUnsafeBufferPointer { Data(buffer: $0) })
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        return stream
    }

    func stop() async {
        task?.cancel()
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }

    private static func decode(_ data: Data) -> (samples: [Int16], rate: Int)? {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        var offset = 12
        var rate = 16000
        while offset + 8 <= bytes.count {
            let id = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = u32(offset + 4)
            if id == "fmt " {
                guard u16(offset + 8 + 2) == 1, u16(offset + 8 + 14) == 16 else { return nil }
                rate = u32(offset + 8 + 4)
            } else if id == "data" {
                let start = offset + 8
                let end = min(bytes.count, start + size)
                var out: [Int16] = []
                out.reserveCapacity((end - start) / 2)
                var at = start
                while at + 1 < end {
                    out.append(Int16(bitPattern: UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8))
                    at += 2
                }
                return (out, rate)
            }
            offset += 8 + size + (size & 1)
        }
        return nil
    }

    private static func resample(_ input: [Int16], from rate: Int, to target: Int) -> [Int16] {
        guard rate != target, !input.isEmpty else { return input }
        let count = Int(Double(input.count) * Double(target) / Double(rate))
        return (0..<count).map { index in
            let position = Double(index) * Double(rate) / Double(target)
            let low = Int(position)
            let high = min(input.count - 1, low + 1)
            let mix = position - Double(low)
            return Int16(Double(input[low]) * (1 - mix) + Double(input[high]) * mix)
        }
    }
}

extension SelfTest {
    /// What the mic promises on this desk with the scripted engine: the chip's faces, a tap that
    /// listens hands-free and a hold that talks while held, words snapped into the box at the caret
    /// and landed as one undo step, a slide that discards with Undo, Esc that discards, ⏎ that
    /// settles and sends, typing that keeps what is shown, and a live call that hides the chip.
    static func checkDictation() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("dictation: \(label)") }
            checks += 1
        }
        func pump(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                while g_main_context_iteration(nil, 0) != 0 {}
                if done() { return true }
                usleep(4000)
            }
            return done()
        }
        let host = DictationStubHost()
        let dictation = PaneDictation(host: host, demo: true, demoWordDelay: 0.06)
        _ = pump(0.2)
        try expect(dictation.harnessFace == .ready, "a fresh pane is ready")
        try expect(gtk_widget_get_visible(dictation.chip) != 0, "the chip shows")
        let tooltip = gtk_widget_get_tooltip_text(dictation.chip).map { String(cString: $0) } ?? ""
        try expect(tooltip.contains("^D"), "the tooltip names the chord: \(tooltip)")
        let issues = ShortcutSet.build(overrides: [:]).issues.filter { $0.contains("composer.dictate") }
        try expect(issues.isEmpty, "the chord collides with nothing: \(issues)")

        dictation.harnessPress()
        dictation.harnessRelease()
        try expect(pump(8) { dictation.harnessSnapshot.words.contains("ComposerView.swift so") }, "a tap listens and words arrive, snapped")
        try expect(host.editor.dictating, "the box knows a take is writing into it")
        if case .listening(.handsFree, .none) = dictation.harnessFace {
            checks += 1
        } else {
            throw SelfTestFailure("dictation: a quick press listens hands-free, got \(dictation.harnessFace)")
        }
        try expect(dictation.harnessHint.contains("click to stop"), "the hint says how to stop: \(dictation.harnessHint)")
        try expect(gtk_widget_is_ancestor(dictation.hint, host.editor.widget) != 0, "the status is inside the box, not a label outside it")
        try expect(
            pump(1) { gtk_text_view_get_bottom_margin(ptr(host.editor.textView)) >= 18 },
            "and the words keep clear of it: \(gtk_text_view_get_bottom_margin(ptr(host.editor.textView)))")
        try expect(host.editor.edge.isLit, "the box's edge is lit while the microphone is open")
        dictation.harnessPress()
        dictation.harnessRelease()
        try expect(pump(3) { !dictation.isOpen }, "the next press stops the take")
        let kept = host.editor.text
        try expect(kept.hasPrefix("Rename the dictation button in ComposerView.swift"), "the words snapped and capitalised: \(kept)")
        try expect(!host.editor.edge.isLit, "the edge goes out when the take ends")
        try expect(!host.editor.dictating, "the box is the person's again")
        let buffer = gtk_text_view_get_buffer(ptr(host.editor.textView))
        gtk_text_buffer_undo(buffer)
        try expect(host.editor.text.isEmpty, "the whole take is one undo step")
        gtk_text_buffer_redo(buffer)
        try expect(host.editor.text == kept, "and it redoes as one")

        host.editor.setText("Please")
        dictation.harnessPress()
        try expect(pump(3) { dictation.harnessSnapshot.wordCount > 3 }, "a hold listens")
        try expect(pump(1) { dictation.harnessSnapshot.mode == .held }, "the hold engages at 280 ms")
        try expect(dictation.harnessHint.contains("Release to keep"), "and the box says how a hold ends: \(dictation.harnessHint)")
        try expect(gtk_widget_has_css_class(dictation.chip, "chip-held") != 0, "the chip lifts")
        dictation.harnessSlide(dx: -80)
        try expect(pump(1) { dictation.harnessSnapshot.arm == .cancel }, "sliding left arms a cancel")
        try expect(dictation.harnessFace.tone == .danger, "an armed cancel wears the danger tone")
        dictation.harnessRelease()
        try expect(pump(3) { !dictation.isOpen }, "releasing an armed cancel ends the take")
        try expect(host.editor.text == "Please", "the box is exactly as it was: \(host.editor.text)")
        try expect(dictation.harnessHint == DictationReading.ending(.discarded)?.text, "the hint says Discarded")
        gtk_text_buffer_insert_at_cursor(buffer, "!", -1)
        try expect(pump(1) { dictation.harnessHint.isEmpty }, "typing after a discard takes Undo away, so it never writes over new words: \(dictation.harnessHint) · \(host.editor.dictating) · \(host.editor.text)")

        host.editor.setText("")
        dictation.harnessPress()
        dictation.harnessRelease()
        try expect(pump(3) { dictation.harnessSnapshot.wordCount > 2 }, "a second tap listens")
        try expect(dictation.handleKey(keyval: Keymap.escape, state: 0), "Esc is taken while listening")
        try expect(pump(3) { !dictation.isOpen }, "Esc ends the take")
        try expect(host.editor.text.isEmpty, "Esc throws the words away")

        dictation.harnessPress()
        dictation.harnessRelease()
        try expect(pump(3) { dictation.harnessSnapshot.wordCount > 4 }, "a third tap listens")
        gtk_text_buffer_insert_at_cursor(buffer, "!", -1)
        try expect(pump(2) { !dictation.isOpen }, "typing ends the take")
        try expect(host.editor.text.hasSuffix("!"), "and the keystroke lands after what was shown: \(host.editor.text)")

        host.editor.clear()
        let returnSends = Preferences.sendOnReturn
        dictation.harnessPress()
        dictation.harnessRelease()
        try expect(pump(3) { dictation.harnessSnapshot.wordCount > 4 }, "a fourth tap listens")
        let enterTaken = dictation.handleKey(keyval: Keymap.enter, state: returnSends ? 0 : Keymap.control)
        try expect(enterTaken, "⏎ is taken while listening")
        try expect(pump(3) { host.sent.count == 1 }, "⏎ settles the take and sends it")
        try expect(host.sent.first?.hasPrefix("Rename") == true, "what was sent is what was said: \(host.sent)")

        host.callLive = true
        dictation.refresh()
        try expect(
            pump(1) { gtk_widget_get_visible(dictation.chip) == 0 }, "a live call on this chat fades the chip out")
        host.callLive = false
        dictation.refresh()
        try expect(
            pump(1) { gtk_widget_get_visible(dictation.chip) != 0 && gtk_widget_has_css_class(dictation.chip, "chip-gone") == 0 },
            "and fades back in when the call ends")
        try expect(host.announced.contains(DictationReading.announceOpen), "a screen reader hears Listening")
        dictation.shutdown()

        let fresh = DictationStubHost()
        let first = PaneDictation(host: fresh, demo: false)
        let window = gtk_window_new()!
        let holder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_box_append(ptr(holder), first.chip)
        gtk_window_set_child(ptr(window), holder)
        gtk_window_set_default_size(ptr(window), 480, 320)
        gtk_window_present(ptr(window))
        _ = pump(0.3)
        first.harnessReadiness(.needsDownload(bytes: DictationModelPack.totalBytes))
        try expect(first.harnessFace == .needsModel, "a machine with no model wears the download mark")
        first.harnessPress()
        try expect(!first.isOpen, "the first press does not open a microphone with no engine")
        first.harnessRelease()
        try expect(pump(1) { first.harnessPopover.contains(DictationModelReading.title) }, "it opens the model's popover")
        try expect(first.harnessPopover.contains("Nothing you say leaves"), "which says where it runs: \(first.harnessPopover)")
        first.harnessReadiness(.unavailable(.noMicrophone))
        try expect(first.harnessFace == .blocked(.noMicrophone), "a machine with no microphone says so")
        first.shutdown()
        _ = pump(0.2)
        gtk_window_destroy(ptr(window))
        return checks
    }

    /// The quick ask's microphone, in the real window over the scripted fleet with the scripted
    /// engine: the chip stands between the box and Send with its status inside the box, the words it
    /// knows include the model it would ask, the registry's chord tapped listens hands-free, Esc
    /// throws the take away and leaves the window up, ⏎ settles and asks, the chip greys while the
    /// question is out, Send mid-take settles first, and a window put away mid-take files what it
    /// showed as the machine's draft.
    static func checkQuickAskDictation() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("quick ask dictation: \(label)") }
            checks += 1
        }
        func pump(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                while g_main_context_iteration(nil, 0) != 0 {}
                if done() { return true }
                usleep(4000)
            }
            return done()
        }
        func children(of box: UnsafeMutablePointer<GtkWidget>) -> [UnsafeMutablePointer<GtkWidget>] {
            var out: [UnsafeMutablePointer<GtkWidget>] = []
            var child = gtk_widget_get_first_child(box)
            while let current = child {
                out.append(current)
                child = gtk_widget_get_next_sibling(current)
            }
            return out
        }
        final class Asked: @unchecked Sendable { var texts: [String] = [] }
        MatrixTheme.install()
        let scope = DraftScope.quickAsk(profileID: "arch")
        let keptEngine = QuickAskWindow.dictationDemo
        func discardWindows() {
            QuickAskWindow.open?.close()
            if let standby = QuickAskWindow.standby { gtk_window_destroy(ptr(standby.window)) }
            QuickAskWindow.standby = nil
        }
        discardWindows()
        QuickAskWindow.dictationDemo = (true, 0.05)
        defer {
            discardWindows()
            QuickAskWindow.dictationDemo = keptEngine
            DraftStore.clear(scope)
            QuickAskPartyDemo.restore()
            SettingsFile.capture()
        }
        DraftStore.clear(scope)
        QuickAskPartyDemo.seed()
        let asked = Asked()
        QuickAskWindow.present(
            servers: QuickAskPartyDemo.profiles, preferredServer: "arch", recents: [], parent: nil,
            onAsk: { _, _, _, _ in asked.texts.append(QuickAskWindow.open?.editor.text ?? "") },
            onResume: { _ in }, onAskParty: { _, _ in })
        guard let ask = QuickAskWindow.open else { throw SelfTestFailure("quick ask dictation: no window") }
        _ = pump(0.6)

        guard let field = gtk_widget_get_parent(ask.editor.widget) else {
            throw SelfTestFailure("quick ask dictation: the box has no field")
        }
        let row = children(of: field)
        guard let box = row.firstIndex(of: ask.editor.widget), let mic = row.firstIndex(of: ask.dictation.chip),
            let send = row.firstIndex(of: ask.send)
        else { throw SelfTestFailure("quick ask dictation: the chip is in the field") }
        try expect(box < mic && mic < send, "the chip stands between the box and Send")
        try expect(gtk_widget_is_ancestor(ask.dictation.hint, ask.editor.widget) != 0, "the status lives inside the box")
        try expect(gtk_widget_get_visible(ask.dictation.chip) != 0, "the chip shows")
        try expect(ask.dictation.harnessFace == .ready, "and is ready")
        guard let restingChip = Gtk.bounds(of: ask.dictation.chip, in: field),
            let sendFrame = Gtk.bounds(of: ask.send, in: field)
        else { throw SelfTestFailure("quick ask dictation: the chip and Send are laid out") }
        let level = abs((restingChip.y + restingChip.height / 2) - (sendFrame.y + sendFrame.height / 2))
        try expect(level <= 1.5, "the chip sits level with Send: \(restingChip) \(sendFrame)")
        try expect(abs(restingChip.height - sendFrame.height) <= 1.5, "and is as tall as Send: \(restingChip) \(sendFrame)")
        try expect(restingChip.width <= sendFrame.width + 8, "a resting chip is Send's round sibling, not a pill: \(restingChip)")
        try expect(
            ask.dictationVocabulary().terms.contains(ModelChooserDemo.selected.modelID),
            "the words it knows include the model it would ask")

        let shiftD = UInt32(UnicodeScalar("D").value)
        try expect(
            ask.handleDictationKey(keyval: shiftD, state: KeyChord.controlMask | Keymap.shift),
            "the registry's chord is taken")
        ask.dictation.keyReleased(keyval: shiftD)
        try expect(pump(4) { ask.dictation.harnessSnapshot.wordCount > 3 }, "a tapped chord listens")
        if case .listening(.handsFree, .none) = ask.dictation.harnessFace {
            checks += 1
        } else {
            throw SelfTestFailure("quick ask dictation: a tap listens hands-free, got \(ask.dictation.harnessFace)")
        }
        try expect(ask.editor.edge.isLit, "the box's edge is lit")
        _ = pump(0.3)
        if let listening = Gtk.bounds(of: ask.dictation.chip, in: field),
            let hint = Gtk.bounds(of: ask.dictation.hint, in: ask.editor.widget),
            let box = Gtk.bounds(of: ask.editor.widget, in: ask.editor.widget)
        {
            try expect(listening.width > restingChip.width + 10, "listening, the chip grows to hold its bars: \(listening)")
            try expect(
                hint.height > 0 && hint.y >= box.y && hint.y + hint.height <= box.y + box.height + 0.5
                    && hint.x + hint.width <= box.x + box.width + 0.5,
                "the status shows inside the box: \(hint) in \(box)")
        } else {
            throw SelfTestFailure("quick ask dictation: the listening chip and its hint are laid out")
        }
        try expect(ask.handleDictationKey(keyval: Keymap.escape, state: 0), "Esc is the take's while it listens")
        try expect(pump(3) { !ask.dictation.isOpen }, "Esc ends the take")
        try expect(QuickAskWindow.open === ask, "and leaves the window up")
        try expect(ask.editor.text.isEmpty, "with the words thrown away: \(ask.editor.text)")

        let returnSends = Preferences.sendOnReturn
        ask.dictation.harnessPress()
        ask.dictation.harnessRelease()
        try expect(pump(4) { ask.dictation.harnessSnapshot.wordCount > 4 }, "a tap on the chip listens")
        try expect(
            ask.handleDictationKey(keyval: Keymap.enter, state: returnSends ? 0 : KeyChord.controlMask),
            "⏎ is the take's too")
        try expect(pump(3) { asked.texts.count == 1 }, "⏎ settles the take and asks")
        try expect(asked.texts.first?.hasPrefix("Rename") == true, "what was asked is what was said: \(asked.texts)")
        try expect(gtk_widget_get_sensitive(ask.dictation.chip) == 0, "the chip greys while it asks")
        _ = ask.handleDictationKey(keyval: shiftD, state: KeyChord.controlMask | Keymap.shift)
        ask.dictation.keyReleased(keyval: shiftD)
        try expect(!ask.dictation.isOpen, "and takes no chord")

        ask.unlock()
        ask.editor.clear()
        try expect(gtk_widget_get_sensitive(ask.dictation.chip) != 0, "a question that came back hands the chip back")
        ask.dictation.harnessPress()
        ask.dictation.harnessRelease()
        try expect(pump(4) { ask.dictation.harnessSnapshot.wordCount > 4 }, "it listens again")
        ask.submit()
        try expect(pump(3) { asked.texts.count == 2 }, "Send mid-take settles the words and asks")
        try expect(asked.texts.last?.hasPrefix("Rename") == true, "with every word: \(asked.texts)")

        ask.unlock()
        ask.editor.clear()
        ask.dictation.harnessPress()
        ask.dictation.harnessRelease()
        try expect(pump(4) { ask.dictation.harnessSnapshot.wordCount > 4 }, "a last tap listens")
        let shown = ask.editor.text
        ask.close()
        try expect(!ask.dictation.isOpen, "putting the window away ends the take")
        try expect(!shown.isEmpty && DraftStore.text(for: scope) == shown, "and files what it showed as the draft")
        return checks
    }

    /// The real engine on a recording: the model this machine downloaded hears a WAV played as the
    /// microphone and writes the words. `TAILSCODE_DICTATION_WAV` names the file and
    /// `TAILSCODE_DICTATION_EXPECT` a phrase that must be heard.
    static func checkDictationEngine() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("dictation engine: \(label)") }
            checks += 1
        }
        let environment = ProcessInfo.processInfo.environment
        let store = DictationModelStore.shared
        if environment["TAILSCODE_DICTATION_INSTALL"] == "1", !store.isComplete {
            store.install()
            var last = -1
            while true {
                switch store.state {
                case .installed: break
                case .failed(let reason): throw SelfTestFailure("dictation engine: install failed: \(reason)")
                case .installing(let download):
                    let percent = Int(download.fraction * 100)
                    if percent / 10 != last / 10 {
                        report("dictation engine: \(download.stage) \(percent)% \(DictationModelReading.progress(done: download.done, total: download.total))")
                        last = percent
                    }
                    try await Task.sleep(nanoseconds: 200_000_000)
                    continue
                case .absent:
                    try await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                break
            }
        }
        try expect(store.isComplete, "the model is installed at \(DictationModelStore.directory.path)")
        let recognizer = SherpaDictationRecognizer.shared
        try expect(await recognizer.readiness(language: "en-US") == .ready, "the engine says it is ready")
        guard let path = environment["TAILSCODE_DICTATION_WAV"], let capture = WaveCapture(path: path, speed: 1.5) else {
            throw SelfTestFailure("dictation engine: set TAILSCODE_DICTATION_WAV to a 16-bit mono WAV")
        }
        let started = Date()
        let session = DictationSession(
            capture: capture, recognizer: recognizer, language: "en-US",
            vocabulary: DictationVocabulary(terms: ["ComposerView.swift"]), atStartOfBox: true)
        await session.open(mode: .handsFree)
        var firstWords: TimeInterval?
        while !capture.isDone {
            if firstWords == nil, await session.current().wordCount > 0 { firstWords = Date().timeIntervalSince(started) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let take = await session.finish()
        let expected = environment["TAILSCODE_DICTATION_EXPECT"] ?? ""
        report("dictation engine: heard \"\(take.text)\" (first words after \(String(format: "%.2f", firstWords ?? -1)) s)")
        try expect(!take.text.isEmpty, "the engine heard words")
        try expect(expected.isEmpty || take.text.lowercased().contains(expected.lowercased()), "the words contain \(expected)")
        try expect(firstWords.map { $0 < 4 } ?? false, "the first words arrive while the person is still talking")
        return checks
    }
}

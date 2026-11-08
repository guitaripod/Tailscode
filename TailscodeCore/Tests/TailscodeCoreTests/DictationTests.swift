import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Dictation: where the words go")
struct DictationInsertionTests {
    @Test("A take joins the word before it with one space, and only where it needs one")
    func spacing() {
        #expect(DictationInsertion(before: "Fix", after: "").compose(settled: "the bug", heard: "").text == "Fix the bug")
        #expect(DictationInsertion(before: "Fix ", after: "").compose(settled: "the bug", heard: "").text == "Fix the bug")
        #expect(DictationInsertion(before: "(", after: ")").compose(settled: "see above", heard: "").text == "(see above)")
        #expect(DictationInsertion(before: "Done", after: "").compose(settled: ", thanks", heard: "").text == "Done, thanks")
        #expect(DictationInsertion(before: "a", after: "b").compose(settled: "middle", heard: "").text == "a middle b")
        #expect(DictationInsertion(before: "a", after: ".").compose(settled: "middle", heard: "").text == "a middle.")
    }

    @Test("A take that starts a sentence gets a capital; one in the middle keeps the engine's case")
    func capitals() {
        #expect(DictationInsertion(before: "", after: "").compose(settled: "rename it", heard: "").text == "Rename it")
        #expect(DictationInsertion(before: "Done. ", after: "").compose(settled: "next", heard: "").text == "Done. Next")
        #expect(DictationInsertion(before: "Done.", after: "").compose(settled: "next", heard: "").text == "Done. Next")
        #expect(DictationInsertion(before: "Line\n", after: "").compose(settled: "next", heard: "").text == "Line\nNext")
        #expect(DictationInsertion(before: "Please ", after: "").compose(settled: "rename it", heard: "").text == "Please rename it")
        #expect(DictationInsertion(before: "Use ", after: "").compose(settled: "Swift", heard: "").text == "Use Swift")
        #expect(DictationInsertion(before: "", after: "").compose(settled: "", heard: "heard first").text == "Heard first")
    }

    @Test("The heard tail is measured in UTF-16 and in scalars, after the settled words")
    func ranges() {
        let composition = DictationInsertion(before: "Café", after: "!").compose(settled: "is open", heard: "now 🎉")
        #expect(composition.text == "Café is open now 🎉!")
        #expect(composition.lead == "Café ")
        #expect(composition.settled == "is open ")
        #expect(composition.heard == "now 🎉")
        #expect(composition.heardUTF16 == NSRange(location: 13, length: 6))
        #expect(composition.heardScalars == 13..<18)
        #expect(composition.caretUTF16 == 19)
        #expect(composition.takeUTF16 == NSRange(location: 5, length: 14))
    }

    @Test("Nothing heard leaves the box exactly as it was")
    func empty() {
        let insertion = DictationInsertion(before: "keep", after: " this")
        #expect(insertion.compose(settled: "", heard: "").text == "keep this")
        #expect(insertion.original == "keep this")
    }

    @Test("Two runs of words join with one space, and punctuation hugs the word before")
    func joining() {
        #expect(DictationText.join("one", "two") == "one two")
        #expect(DictationText.join("one ", "two") == "one two")
        #expect(DictationText.join("one", ". Two") == "one. Two")
        #expect(DictationText.join("", "two") == "two")
        #expect(DictationText.wordCount("a  b\nc") == 3)
    }
}

@Suite("Dictation: one control, two hands")
struct DictationPressTests {
    @Test("A tap opens the microphone and leaves it open; the next press stops it")
    func tap() {
        var press = DictationPress()
        #expect(press.down(at: 0, listening: false) == .open)
        #expect(press.up(at: 0.1) == .becomeHandsFree)
        #expect(press.down(at: 2, listening: true) == .stop)
        #expect(press.up(at: 2.05) == .none)
    }

    @Test("A hold keeps the microphone open only while held")
    func hold() {
        var press = DictationPress()
        #expect(press.down(at: 0, listening: false) == .open)
        #expect(!press.isHeld(at: 0.2))
        #expect(press.isHeld(at: 0.3))
        #expect(press.up(at: 1.5) == .stop)
    }

    @Test("Auto-repeat is a press already down, and a lost press never leaves the microphone open")
    func repeatsAndAbandon() {
        var press = DictationPress()
        #expect(press.down(at: 0, listening: false) == .open)
        #expect(press.down(at: 0.05, listening: true) == .none)
        #expect(press.abandon(at: 0.06) == .stop)
        #expect(press.abandon(at: 0.07) == .none)
        #expect(!press.isDown)
    }

    @Test("Sliding away arms a cancel and reaching Send arms a send")
    func slide() {
        let distance = DictationSlide.touchCancelDistance
        #expect(DictationSlide.arm(travelled: -10, overSend: false, cancelDistance: distance) == .none)
        #expect(DictationSlide.arm(travelled: -72, overSend: false, cancelDistance: distance) == .cancel)
        #expect(DictationSlide.arm(travelled: 30, overSend: true, cancelDistance: distance) == .send)
    }
}

@Suite("Dictation: the chat's own words")
struct DictationShaperTests {
    private let shaper = DictationShaper(
        DictationVocabulary(
            terms: ["ComposerView.swift", "ComposerView", "snake_case_name", "TailscodeCore", "v2.0.1", "button"],
            commands: ["compact", "goal"]))

    @Test("A spoken run snaps to the file the chat knows")
    func files() {
        #expect(shaper.shape("Rename composer view dot swift now", atStart: false) == "Rename ComposerView.swift now")
        #expect(shaper.shape("Open Composer View.swift.", atStart: false) == "Open ComposerView.swift.")
        #expect(shaper.shape("in composer view, please", atStart: false) == "in ComposerView, please")
        #expect(shaper.shape("the tailscode core package", atStart: false) == "the TailscodeCore package")
        #expect(shaper.shape("rename snake underscore case underscore name", atStart: false) == "rename snake_case_name")
    }

    @Test("Plain words are left alone, and a miss leaves the words as heard")
    func misses() {
        #expect(shaper.shape("press the button", atStart: false) == "press the button")
        #expect(shaper.shape("composer and view", atStart: false) == "composer and view")
        #expect(shaper.shape("", atStart: true) == "")
    }

    @Test("Slash and a known command at the start of the box become the command")
    func commands() {
        #expect(shaper.shape("Slash compact", atStart: true) == "/compact")
        #expect(shaper.shape("slash goal ship the release", atStart: true) == "/goal ship the release")
        #expect(shaper.shape("slash compact", atStart: false) == "slash compact")
        #expect(shaper.shape("slash deploy", atStart: true) == "slash deploy")
    }
}

@Suite("Dictation: vocabulary from the transcript's tail")
struct DictationVocabularyTests {
    private func message(_ parts: [MessagePart.Kind], role: MessageRole = .assistant) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString, role: role, agentType: .claudeCode,
            parts: parts.enumerated().map { MessagePart(id: "p\($0.offset)", kind: $0.element) }, createdAt: Date())
    }

    @Test("Files the agent touched, code words and the project are read, newest first")
    func reads() {
        let read = ToolCall(
            id: "1", name: "Read", status: .completed,
            input: .object(["file_path": .string("/repo/Tailscode/Chat/ComposerView.swift")]))
        let edit = ToolCall(
            id: "2", name: "Edit", status: .completed,
            input: .object(["file_path": .string("/repo/TailscodeCore/DictationShaper.swift")]))
        let messages = [
            message([.tool(read), .text("The PromptEditor holds the caret.")]),
            message([.text("Look at snake_case_value and the README.")], role: .user),
            message([.tool(edit)]),
        ]
        let vocabulary = DictationVocabulary.read(
            messages: messages, project: "Tailscode", branch: "master", commands: ["compact"], models: ["Opus 5.5"])
        #expect(vocabulary.terms.first == "Tailscode")
        #expect(vocabulary.terms.contains("DictationShaper.swift"))
        #expect(vocabulary.terms.contains("ComposerView"))
        #expect(vocabulary.terms.contains("PromptEditor"))
        #expect(vocabulary.terms.contains("snake_case_value"))
        #expect(!vocabulary.terms.contains("README"))
        #expect(vocabulary.terms.firstIndex(of: "DictationShaper.swift")! < vocabulary.terms.firstIndex(of: "ComposerView.swift")!)
        #expect(vocabulary.commands == ["compact"])
        #expect(vocabulary.phrases.contains("ComposerView"))
        #expect(!vocabulary.phrases.contains("ComposerView.swift"))
    }

    @Test("Only the tail is read, and Apple's engine gets at most a hundred phrases")
    func bounded() {
        let messages = (0..<200).map { index in message([.text("Symbol\(index)Name here")]) }
        let vocabulary = DictationVocabulary.read(messages: messages)
        #expect(vocabulary.terms.contains("Symbol199Name"))
        #expect(!vocabulary.terms.contains("Symbol100Name"))
        let many = DictationVocabulary(terms: (0..<250).map { "Term\($0)Word" })
        #expect(many.phrases.count == DictationVocabulary.phraseLimit)
    }

    @Test("Code-shaped words are told from prose")
    func shapes() {
        #expect(DictationVocabulary.isCodeShaped("ComposerView"))
        #expect(DictationVocabulary.isCodeShaped("snake_case"))
        #expect(DictationVocabulary.isCodeShaped("main.swift"))
        #expect(DictationVocabulary.isCodeShaped("gpt4o"))
        #expect(!DictationVocabulary.isCodeShaped("Hello"))
        #expect(!DictationVocabulary.isCodeShaped("e.g"))
        #expect(!DictationVocabulary.isCodeShaped("https://x.com"))
    }
}

@Suite("Dictation: a take")
struct DictationSessionTests {
    private func session(
        _ recognizer: any DictationRecognizer = DictationDemoRecognizer(wordDelay: 0.01),
        capture: any VoiceAudioCapture = DictationDemoCapture(), atStart: Bool = false
    ) -> DictationSession {
        DictationSession(
            capture: capture, recognizer: recognizer, language: "en-US", vocabulary: DictationDemoRecognizer.vocabulary,
            atStartOfBox: atStart)
    }

    @Test("A take listens, settles and keeps its words, snapped to the chat's terms")
    func keeps() async {
        let take = session()
        await take.open(mode: .handsFree)
        #expect(await eventually { await take.current().phase == .listening })
        #expect(await eventually { await take.current().words.contains("ComposerView.swift so the hold") })
        let result = await take.finish()
        #expect(result.text.contains("ComposerView.swift"))
        guard case .kept(let words) = result.end else {
            Issue.record("expected kept, got \(result.end)")
            return
        }
        #expect(words > 5)
        #expect(await take.current().phase == .idle)
    }

    @Test("A cancelled take leaves nothing behind")
    func cancels() async {
        let take = session()
        await take.open(mode: .held)
        #expect(await eventually { await take.current().wordCount > 2 })
        await take.setArm(.cancel)
        #expect(await take.current().arm == .cancel)
        let result = await take.cancel()
        #expect(result == DictationTake(text: "", end: .discarded))
    }

    @Test("A take with no words ends as nothing heard")
    func silence() async {
        let take = session(DictationDemoRecognizer(script: "", wordDelay: 0.01))
        await take.open(mode: .handsFree)
        let result = await take.finish()
        #expect(result.end == .nothingHeard)
    }

    @Test("Audio heard before the engine wakes is handed over, not dropped")
    func buffers() async {
        let engine = SlowRecognizer(wake: 0.3)
        let take = session(engine)
        await take.open(mode: .held)
        try? await Task.sleep(nanoseconds: 150_000_000)
        let result = await take.finish()
        #expect(engine.acceptedBeforeEnd >= 1)
        #expect(result.text == "heard you")
    }

    @Test("A microphone that says no ends the take as can't hear you")
    func denied() async {
        let take = session(capture: RefusingCapture())
        await take.open(mode: .handsFree)
        #expect(await take.current().ended == .problem(.microphoneDenied))
        #expect(await take.current().phase == .idle)
    }

    @Test("A microphone taken mid-take keeps the words heard so far")
    func taken() async {
        let capture = DictationDemoCapture()
        let take = session(capture: capture)
        await take.open(mode: .handsFree)
        #expect(await eventually { await take.current().wordCount > 3 })
        await capture.stop()
        #expect(await eventually { await take.current().ended == .problem(.taken) })
        #expect(await take.current().settled.split(separator: " ").count > 3)
    }

    @Test("The face reads the take first and the engine second")
    func faces() {
        var listening = DictationSnapshot(phase: .listening, mode: .held, arm: .cancel)
        #expect(DictationFace.read(readiness: .ready, snapshot: listening) == .listening(.held, .cancel))
        #expect(DictationFace.read(readiness: .ready, snapshot: listening).tone == .danger)
        listening.phase = .idle
        #expect(DictationFace.read(readiness: .needsDownload(bytes: 10), snapshot: listening) == .needsModel)
        #expect(DictationFace.read(readiness: .downloading(0.3), snapshot: listening) == .preparing(0.3))
        #expect(DictationFace.read(readiness: .unavailable(.microphoneDenied), snapshot: listening).symbol == "mic.slash")
        #expect(DictationFace.read(readiness: .ready, snapshot: listening, available: false) == .hidden)
        #expect(DictationFace.ready.isTakeable && !DictationFace.needsModel.isTakeable)
        #expect(!DictationFace.blocked(.microphoneDenied).isTakeable && !DictationFace.preparing(0.4).isTakeable)
        #expect(DictationBars.heights(level: 0, time: 1).allSatisfy { $0 == DictationBars.floor })
        #expect(DictationBars.heights(level: 1, time: 1, reduceMotion: true)[2] == 1)
    }

    @Test("The hint says what is true, with the right verb for the surface")
    func hints() {
        let open = DictationSnapshot(phase: .listening, mode: .handsFree, startedAt: 0)
        let face = DictationFace.listening(.handsFree, .none)
        #expect(DictationReading.hint(face: face, snapshot: open, now: 7.4, surface: .touch, chord: nil)?.timer == "0:07")
        #expect(DictationReading.hint(face: face, snapshot: open, now: 7, surface: .touch, chord: nil)?.text == "Tap to stop")
        #expect(DictationReading.hint(face: face, snapshot: open, now: 7, surface: .pointer, chord: "⌃⇧D")?.text.contains("⌃⇧D") == true)
        let discarded = DictationSnapshot(ended: .discarded)
        #expect(DictationReading.hint(face: .ready, snapshot: discarded, now: 0, surface: .touch, chord: nil)?.offersUndo == true)
        #expect(DictationReading.hint(face: .ready, snapshot: DictationSnapshot(ended: .kept(words: 3)), now: 0, surface: .touch, chord: nil) == nil)
        #expect(DictationReading.announce(.kept(words: 1)) == "Added 1 word")
    }

    @Test("The two new cues are felt and fall back to a canned impact")
    func haptics() {
        for cue in [HapticCue.listen, .listenEnd] {
            #expect(!HapticRecipe.beats(for: cue).isEmpty)
            #expect(HapticFallback.of(cue, strength: 1) != nil)
            #expect(HapticCue.Group.everyday.cues.contains(cue))
        }
        #expect(HapticRecipe.scaled(.listen, strength: 0.1).count == 1)
    }

    @Test("⌃⇧D dictates from the composer")
    func chord() {
        let definition = ShortcutRegistry.definition("composer.dictate")
        #expect(definition?.action == .dictate)
        #expect(definition?.defaults == ["ctrl+shift+d"])
    }
}

private final class SlowRecognizer: DictationRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private let wake: TimeInterval
    private var accepted = 0
    private var continuation: AsyncThrowingStream<DictationHeard, Error>.Continuation?

    init(wake: TimeInterval) {
        self.wake = wake
    }

    var acceptedBeforeEnd: Int { lock.withLock { accepted } }

    func language(for choice: String?, hint: String?) async -> String? { "en-US" }
    func readiness(language: String) async -> DictationReadiness { .ready }
    func prepare(language: String) -> AsyncThrowingStream<Double?, Error> { AsyncThrowingStream { $0.finish() } }
    func languages() async -> [String] { ["en-US"] }

    func begin(language: String, vocabulary: [String]) async throws -> AsyncThrowingStream<DictationHeard, Error> {
        try await Task.sleep(nanoseconds: UInt64(wake * 1_000_000_000))
        let (stream, continuation) = AsyncThrowingStream<DictationHeard, Error>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func accept(_ pcm: Data) async {
        lock.withLock { accepted += 1 }
    }

    func end() async {
        lock.withLock {
            if accepted > 0 { continuation?.yield(.final("heard you")) }
            continuation?.finish()
        }
    }

    func abort() async {
        lock.withLock { continuation?.finish() }
    }
}

private final class RefusingCapture: VoiceAudioCapture, @unchecked Sendable {
    var level: Double { 0 }
    func start() async throws -> AsyncStream<Data> { throw VoiceAudioError.microphoneDenied }
    func stop() async {}
}

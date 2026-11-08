import AVFAudio
import AppKit
import TailscodeCore

/// What a composer tells dictation about itself.
@MainActor
protocol MacDictationHost: AnyObject {
    var dictationEditor: PromptEditor { get }
    var dictationSendControl: NSView { get }
    var dictationKey: String { get }
    var dictationChord: String? { get }
    func dictationVocabulary() -> DictationVocabulary
    func dictationSend()
}

/// The engine and the microphone the Mac dictates with: Apple's on-device transcriber, or the
/// scripted one in the demo world.
@MainActor
final class MacDictationEngines {
    static let shared = MacDictationEngines()
    static let didChange = Notification.Name("tailscode.dictation.mac.didChange")

    let demo: Bool
    private lazy var io = AppleVoiceIO()
    let recognizer: any DictationRecognizer

    init(demo: Bool = DemoMode.isActive, wordDelay: TimeInterval = 0.22) {
        self.demo = demo
        recognizer = demo ? DictationDemoRecognizer(wordDelay: wordDelay) : AppleDictationRecognizer()
    }

    func capture() -> any VoiceAudioCapture {
        demo ? DictationDemoCapture() : io.capture
    }

    func readiness() async -> (DictationReadiness, String?) {
        if !demo, AVAudioApplication.shared.recordPermission == .denied {
            return (.unavailable(.microphoneDenied), nil)
        }
        let choice = DictationPreferences.language
        guard let language = await recognizer.language(for: choice, hint: nil) else {
            return (.unavailable(.languageUnsupported(choice ?? Locale.current.identifier)), nil)
        }
        return (await recognizer.readiness(language: language), language)
    }

    func moved() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

/// One composer's microphone on the Mac: the control beside Send, the lit edge on the field, the
/// hint line over it, and the take — from the press or the chord that opens it to the words left in
/// the box as one undo step. A Force Touch trackpad feels the open, the close and an armed slide.
@MainActor
final class MacDictationController {
    let button = MacDictationButton()
    let hint = MacDictationHint()
    var callLive = false {
        didSet {
            guard callLive != oldValue else { return }
            if callLive { stopKeepingShown() }
            redraw(animated: true)
        }
    }

    /// The composer is waiting on what it sent: the control dims and takes no press until it answers.
    var waiting = false {
        didSet {
            guard waiting != oldValue else { return }
            if waiting { stopKeepingShown() }
            button.alphaValue = waiting ? 0.4 : 1
        }
    }

    private weak var host: (any MacDictationHost)?
    private let engines: MacDictationEngines
    private var readiness: DictationReadiness?
    private var language: String?
    private var snapshot = DictationSnapshot.idle
    private var session: DictationSession?
    private var chain: Task<Void, Never>?
    private var follower: Task<Void, Never>?
    private var preparing: Task<Void, Never>?
    private var press = DictationPress()
    private var anchor = DictationInsertion(before: "", after: "")
    private var original = ""
    private var originalSelection = NSRange(location: 0, length: 0)
    private var discarded: String?
    private var detached = false
    private var level = 0.0
    private var lastFrame: CFTimeInterval = 0
    private var ending: DictationEnd?
    private var endingToken = 0
    private var takes = 0
    private var openOnRelease = false
    private var localArm: DictationArm?
    private var notice: DictationHint?
    private var noticeToken = 0
    private var heldKeyCode: UInt16?
    private var lastTimer: String?
    private nonisolated(unsafe) var frameTimer: Timer?
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    init(host: any MacDictationHost, engines: MacDictationEngines = .shared) {
        self.host = host
        self.engines = engines
        button.onDown = { [weak self] _ in self?.down() }
        button.onDrag = { [weak self] dx, windowPoint in self?.dragged(dx: dx, windowPoint: windowPoint) }
        button.onUp = { [weak self] in self?.up() }
        button.onActivate = { [weak self] in self?.toggle() }
        hint.onUndo = { [weak self] in self?.undoDiscard() }
        host.dictationEditor.onEditDuringDictation = { [weak self] in self?.stopKeepingShown() }
        host.dictationEditor.onEditOutsideDictation = { [weak self] in self?.boxEdited() }
        host.dictationEditor.mountDictationFooter(hint)
        let center = NotificationCenter.default
        for name in [DictationPreferences.didChange, MacDictationEngines.didChange, NSApplication.didBecomeActiveNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
        }
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let window = (note.object as? NSWindow).map(ObjectIdentifier.init)
                    MainActor.assumeIsolated { self?.pressLost(window) }
                })
        }
        redraw(animated: false)
        refresh()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        frameTimer?.invalidate()
    }

    var isOpen: Bool { session != nil && !detached }

    private var face: DictationFace {
        DictationFace.read(readiness: readiness, snapshot: seen, available: !callLive)
    }

    /// The take with what the hand already did laid over it: an engaged hold and a slid arm show
    /// at once, and the release decides from them rather than from the session's later word.
    private var seen: DictationSnapshot { snapshot.pressed(engaged: press.isEngaged, arm: localArm) }

    /// The app or the window let go of the keyboard and the pointer mid-press: the release will
    /// never come, so the press ends here the way a release would.
    private func pressLost(_ window: ObjectIdentifier?) {
        if let window, window != button.window.map(ObjectIdentifier.init) { return }
        heldKeyCode = nil
        openOnRelease = false
        guard press.isDown else { return }
        act(press.abandon(at: CACurrentMediaTime()))
    }

    /// The person wrote in the box after a discard: Undo would write the old take over their words,
    /// so it is no longer offered.
    private func boxEdited() {
        guard discarded != nil || ending == .discarded else { return }
        discarded = nil
        if ending == .discarded { ending = nil }
        redraw(animated: true)
    }

    func refresh() {
        Task { [weak self] in
            guard let self else { return }
            let (value, language) = await self.engines.readiness()
            guard self.preparing == nil else { return }
            self.readiness = value
            self.language = language
            self.redraw(animated: false)
        }
    }

    private func down() {
        guard !waiting else { return }
        if !isOpen, !face.isTakeable {
            openOnRelease = true
            return
        }
        act(press.down(at: CACurrentMediaTime(), listening: isOpen))
    }

    private func up() {
        if openOnRelease {
            openOnRelease = false
            pressedWhileNotReady()
            return
        }
        act(press.up(at: CACurrentMediaTime()))
    }

    private func dragged(dx: CGFloat, windowPoint: NSPoint) {
        guard isOpen, press.isDown else { return }
        if !press.isEngaged { act(press.tick(at: CACurrentMediaTime())) }
        guard press.isEngaged, let session, let send = host?.dictationSendControl else { return }
        let local = send.convert(windowPoint, from: nil)
        let overSend = send.bounds.insetBy(dx: -DictationSlide.sendSlop, dy: -DictationSlide.sendSlop).contains(local)
        let arm = DictationSlide.arm(
            travelled: Double(dx), overSend: overSend, cancelDistance: DictationSlide.pointerCancelDistance)
        guard arm != seen.arm else { return }
        MacHaptics.shared.play(arm == .none ? .selection : .notch)
        localArm = arm
        host?.dictationEditor.showDictation(
            anchor.compose(settled: snapshot.settled, heard: snapshot.heard), struck: arm == .cancel)
        redraw(animated: true)
        enqueue { await session.setArm(arm) }
    }

    /// The chord went down: the key is remembered so its release, or the release of one of the
    /// chord's modifiers, ends a hold. Auto-repeat is a press already down.
    func chordDown(keyCode: UInt16) {
        guard !waiting, heldKeyCode == nil else { return }
        heldKeyCode = keyCode
        if !isOpen, !face.isTakeable {
            press = DictationPress()
            pressedWhileNotReady()
            return
        }
        act(press.down(at: CACurrentMediaTime(), listening: isOpen))
    }

    /// A key rose, or the modifiers changed: a hold of the chord ends when any of its keys is let go.
    func keyReleased(keyCode: UInt16?, flags: NSEvent.ModifierFlags) {
        guard heldKeyCode != nil else { return }
        let letterUp = keyCode != nil && keyCode == heldKeyCode
        let modifiersUp = keyCode == nil && !(flags.contains(.control) && flags.contains(.shift))
        guard letterUp || modifiersUp else { return }
        heldKeyCode = nil
        act(press.up(at: CACurrentMediaTime()))
    }

    /// Esc throws an open take away and Return settles it and sends; nothing else is taken.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isOpen else { return false }
        if event.keyCode == 53 {
            cancel()
            return true
        }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let shift = event.modifierFlags.contains(.shift)
        if isReturn, !shift, PromptEditor.sendOnReturn || event.modifierFlags.contains(.control) {
            stop(sending: true)
            return true
        }
        return false
    }

    func stopAndSend() -> Bool {
        guard isOpen else { return false }
        stop(sending: true)
        return true
    }

    func toggle() {
        guard !waiting else { return }
        if isOpen {
            stop(sending: false)
        } else if face.isTakeable {
            open(mode: .handsFree)
        } else {
            pressedWhileNotReady()
        }
    }

    private func act(_ action: DictationPress.Action) {
        switch action {
        case .open:
            open(mode: .handsFree)
            scheduleHoldTick()
        case .becomeHeld:
            guard let session else { return }
            MacHaptics.shared.play(.hold)
            redraw(animated: true)
            enqueue { await session.setMode(.held) }
        case .stop:
            switch localArm ?? snapshot.arm {
            case .cancel: cancel()
            case .send: stop(sending: true)
            case .none: stop(sending: false)
            }
        case .none: break
        }
    }

    /// A press that is still down when the threshold passes engages its hold.
    private func scheduleHoldTick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + DictationPress.holdThreshold + 0.012) { [weak self] in
            guard let self else { return }
            self.act(self.press.tick(at: CACurrentMediaTime()))
        }
    }

    private func pressedWhileNotReady() {
        switch face {
        case .needsModel: prepareModel()
        case .blocked(let problem): presentBlocked(problem)
        default: break
        }
    }

    private func prepareModel() {
        guard preparing == nil, let language else { return }
        let recognizer = engines.recognizer
        readiness = .downloading(nil)
        redraw(animated: true)
        preparing = Task { [weak self] in
            do {
                for try await progress in recognizer.prepare(language: language) {
                    self?.readiness = .downloading(progress)
                    self?.redraw(animated: false)
                }
                guard let self else { return }
                self.preparing = nil
                self.readiness = .ready
                MacHaptics.shared.play(.success)
                self.redraw(animated: true)
                self.button.pulse()
            } catch {
                guard let self else { return }
                self.preparing = nil
                self.readiness = .needsDownload(bytes: nil)
                self.say(DictationHint(text: DictationModelReading.failed, style: .warning))
                MacHaptics.shared.play(.warning)
            }
        }
    }

    private func presentBlocked(_ problem: DictationProblem) {
        guard let window = button.window else { return }
        let alert = NSAlert()
        alert.messageText = DictationReading.blockedTitle(problem)
        alert.informativeText =
            DictationReading.blockedBody(problem, device: "Mac") + "\n\n" + DictationReading.privacy(device: "Mac")
        alert.addButton(
            withTitle: problem == .microphoneDenied ? DictationReading.openSettings : DictationReading.tryAgain)
        alert.addButton(withTitle: DictationReading.notNow)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                if problem == .microphoneDenied,
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                {
                    NSWorkspace.shared.open(url)
                }
                self?.refresh()
            }
        }
    }

    private func open(mode: DictationMode) {
        guard let host, session == nil, let language else { return }
        let editor = host.dictationEditor
        let anchored = editor.dictationAnchor()
        anchor = anchored.insertion
        originalSelection = anchored.selection
        original = editor.text
        localArm = nil
        notice = nil
        discarded = nil
        ending = nil
        detached = false
        takes += 1
        editor.setDictating(true)
        let session = DictationSession(
            capture: engines.capture(), recognizer: engines.recognizer, language: language,
            vocabulary: engines.demo
                ? DictationDemoRecognizer.vocabulary
                : (DictationPreferences.usesChatWords ? host.dictationVocabulary() : .empty),
            atStartOfBox: anchor.before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, take: takes)
        self.session = session
        snapshot = DictationSnapshot(phase: .waking, mode: mode, take: takes)
        level = 0
        MacHaptics.shared.play(.listen)
        redraw(animated: true)
        startFrames()
        follower = Task { [weak self] in
            for await next in session.snapshots {
                self?.apply(next, from: session)
            }
        }
        let key = host.dictationKey
        enqueue {
            await DictationDesk.shared.claim(key, session: session)
            await session.open(mode: mode)
        }
        NSAccessibility.post(
            element: button, notification: .announcementRequested,
            userInfo: [.announcement: DictationReading.announceOpen, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func apply(_ next: DictationSnapshot, from source: DictationSession) {
        guard source === session, !detached, let editor = host?.dictationEditor else { return }
        snapshot = next
        if next.phase != .idle {
            editor.showDictation(anchor.compose(settled: next.settled, heard: next.heard), struck: seen.arm == .cancel)
        } else if let end = next.ended {
            land(DictationTake(text: next.settled, end: end), from: source, sending: false)
            return
        }
        redraw(animated: true)
    }

    private func stop(sending: Bool) {
        guard let session, !detached else { return }
        enqueue { [weak self] in
            let take = await session.finish(sending: sending)
            await MainActor.run { self?.land(take, from: session, sending: sending) }
        }
    }

    private func cancel() {
        guard let session, !detached, let editor = host?.dictationEditor else { return }
        let shown = editor.text
        enqueue { [weak self] in
            _ = await session.cancel()
            await MainActor.run {
                guard let self, session === self.session else { return }
                editor.restoreDictation(self.original, selection: self.originalSelection)
                self.discarded = shown == self.original ? nil : shown
                self.finish(as: .discarded)
            }
        }
    }

    private func land(_ take: DictationTake, from source: DictationSession, sending: Bool) {
        guard source === session, let host else { return }
        let editor = host.dictationEditor
        if take.text.isEmpty {
            editor.restoreDictation(original, selection: originalSelection)
        } else {
            editor.commitDictation(anchor.compose(settled: take.text, heard: ""), from: original)
        }
        finish(as: take.end)
        if sending, !editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { host.dictationSend() }
    }

    private func finish(as end: DictationEnd) {
        if let session { Task { await DictationDesk.shared.release(session) } }
        follower?.cancel()
        follower = nil
        session = nil
        press = DictationPress()
        heldKeyCode = nil
        snapshot = DictationSnapshot(ended: end, take: takes)
        localArm = nil
        ending = end
        endingToken += 1
        button.flash(end)
        stopFrames()
        host?.dictationEditor.setDictating(false)
        if case .problem(.microphoneDenied) = end { readiness = .unavailable(.microphoneDenied) }
        switch end {
        case .kept, .sent, .nothingHeard: MacHaptics.shared.play(.listenEnd)
        case .discarded: MacHaptics.shared.play(.tap)
        case .problem: MacHaptics.shared.play(.warning)
        }
        NSAccessibility.post(
            element: button, notification: .announcementRequested,
            userInfo: [.announcement: DictationReading.announce(end), .priority: NSAccessibilityPriorityLevel.high.rawValue])
        redraw(animated: true)
        if let hint = DictationReading.ending(end) {
            let token = endingToken
            DispatchQueue.main.asyncAfter(deadline: .now() + hint.lingers) { [weak self] in
                guard let self, self.endingToken == token, self.session == nil else { return }
                self.ending = nil
                self.discarded = nil
                self.redraw(animated: true)
            }
        }
    }

    /// The person typed mid-take, the chat changed or the app is leaving: the take stops where it
    /// stands and the box keeps exactly what it shows, in ink.
    func stopKeepingShown() {
        guard let session, !detached else { return }
        detached = true
        enqueue { _ = await session.finish() }
        host?.dictationEditor.keepDictationAsShown()
        finish(as: .kept(words: snapshot.wordCount))
    }

    private func undoDiscard() {
        guard let discarded, let editor = host?.dictationEditor else { return }
        editor.commitDictation(
            DictationInsertion(before: discarded, after: "").compose(settled: "", heard: ""), from: editor.text)
        self.discarded = nil
        ending = nil
        redraw(animated: true)
    }

    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = chain
        chain = Task {
            await previous?.value
            await work()
        }
    }

    private func redraw(animated: Bool) {
        let face = self.face
        button.chord = host?.dictationChord
        button.apply(face, animated: animated)
        invite(face)
        host?.dictationEditor.dictationEdge.setLit(face.litEdge, danger: face.tone == .danger, animated: animated)
        drawHint(face)
    }

    /// Send glows as a place to drop a held take onto, and lights up when the take is armed to send.
    private func invite(_ face: DictationFace) {
        guard let send = host?.dictationSendControl else { return }
        let glow: CGFloat?
        switch face {
        case .listening(.held, .send): glow = 10
        case .listening(.held, .none): glow = 5
        default: glow = nil
        }
        if let glow {
            let shadow = NSShadow()
            shadow.shadowColor = MacTheme.Color.accent.withAlphaComponent(glow > 6 ? 0.95 : 0.5)
            shadow.shadowBlurRadius = glow
            send.shadow = shadow
        } else {
            send.shadow = nil
        }
        (send as? NSButton)?.highlight(glow ?? 0 > 6)
    }

    private func drawHint(_ face: DictationFace) {
        var shown = seen
        if !face.showsBars, let ending { shown.ended = ending }
        let reading = DictationReading.hint(
            face: face, snapshot: shown, now: ProcessInfo.processInfo.systemUptime, surface: .pointer,
            chord: host?.dictationChord, heldByKey: heldKeyCode != nil)
        let live = face.showsBars || face.isPreparing || ending != nil ? reading : nil
        let hint = live ?? notice
        lastTimer = hint?.timer
        self.hint.show(hint, undoAvailable: discarded != nil)
        host?.dictationEditor.setDictationFooterShown(hint != nil, animated: true)
    }

    /// A line that is about dictation rather than about a take — a speech model that did not
    /// arrive — shown in the box for as long as a warning lingers.
    private func say(_ line: DictationHint) {
        notice = line
        noticeToken += 1
        let token = noticeToken
        redraw(animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + line.lingers) { [weak self] in
            guard let self, self.noticeToken == token else { return }
            self.notice = nil
            self.redraw(animated: true)
        }
    }

    private func startFrames() {
        guard frameTimer == nil else { return }
        lastFrame = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func stopFrames() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func frame() {
        let time = CACurrentMediaTime()
        let dt = time - lastFrame
        lastFrame = time
        level = VoiceCallLevels.smoothed(previous: level, target: session?.level ?? 0, dt: dt)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if face == .settling {
            button.setLevels([Double](repeating: DictationBars.floor, count: DictationBars.count))
        } else {
            button.setLevels(DictationBars.heights(level: level, time: time, reduceMotion: reduce))
        }
        button.setHalo(level)
        host?.dictationEditor.dictationEdge.setLevel(level)
        if DictationReading.elapsed(snapshot, ProcessInfo.processInfo.systemUptime) != lastTimer { drawHint(face) }
    }

    var harnessFace: DictationFace { face }
    var harnessSnapshot: DictationSnapshot { snapshot }
    var harnessHint: String { hint.text }
    func harnessDown() { down() }
    func harnessUp() { up() }
    func harnessSlide(dx: CGFloat) {
        dragged(dx: dx, windowPoint: NSPoint(x: -10_000, y: -10_000))
    }
    func harnessReadiness(_ value: DictationReadiness, language: String?) {
        readiness = value
        self.language = language
        redraw(animated: false)
    }
}

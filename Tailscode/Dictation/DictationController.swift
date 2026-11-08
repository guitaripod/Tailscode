import AVFAudio
import MidgarCore
import TailscodeCore
import UIKit

/// What a composer tells dictation about itself: its text view, the glass box the edge is drawn
/// round, its Send, who presents a sheet, how it reacts when words are written into it, and how it
/// seats the take's status line inside the box.
@MainActor
protocol DictationComposerHost: AnyObject {
    var dictationTextView: UITextView { get }
    var dictationBox: UIView { get }
    var dictationSendControl: UIView { get }
    var dictationPresenter: UIViewController? { get }
    func dictationDidWrite()
    func dictationSend()
    func dictationSetListening(_ listening: Bool)
    /// Seats the status line in the row under the words, just left of the microphone, or lets it
    /// go: the row's other tenants step aside while it shows and a one-line box grows that row.
    func dictationShowStatus(_ status: DictationHintView, shown: Bool)
}

/// How Send answers a held take: a faint glow says it is a place to drop onto, and a take armed
/// to send rings it and lifts it.
enum DictationSendInvite: Equatable {
    case none
    case invited
    case armed
}

extension DictationComposerHost {
    /// Lights Send as a drop target while a take is held, and rings it when the take is armed to
    /// send.
    func dictationInvite(_ invite: DictationSendInvite) {
        let send = dictationSendControl
        let accent = Theme.Color.accent.cgColor
        let reduce = UIAccessibility.isReduceMotionEnabled
        let changes = {
            send.transform = invite == .armed && !reduce ? CGAffineTransform(scaleX: 1.15, y: 1.15) : .identity
            send.layer.shadowColor = accent
            send.layer.shadowOffset = .zero
            send.layer.shadowRadius = invite == .armed ? 12 : 8
            send.layer.shadowOpacity = invite == .none ? 0 : (invite == .armed ? 0.95 : 0.45)
        }
        UIView.animate(
            withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.4,
            options: [.allowUserInteraction, .beginFromCurrentState], animations: changes)
    }
}

/// How a composer moves its bottom row when a take's status line takes or leaves its seat: the same
/// spring the capsule opens with, or a short crossfade under Reduced Motion.
enum DictationSeat {
    @MainActor
    static func move(_ changes: @escaping () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            UIView.animate(
                withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0.3,
                options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        }
    }
}

/// The engine and the microphone this process dictates with: Apple's on-device transcriber from
/// iOS 26, a scripted one in the demo world, nothing below 26 (the keyboard's own microphone is
/// still there). Readiness is asked per language and remembered until something says it moved.
@MainActor
final class DictationEngines {
    static let shared = DictationEngines()
    static let didChange = Notification.Name("tailscode.dictation.engines.didChange")

    let demo = DemoMode.isActive
    private lazy var io = AppleVoiceIO()
    private(set) var recognizer: (any DictationRecognizer)?
    private var known: [String: DictationReadiness] = [:]

    init() {
        if demo {
            recognizer = DictationDemoRecognizer()
        } else if #available(iOS 26, *) {
            recognizer = AppleDictationRecognizer()
        }
    }

    var isSupported: Bool { recognizer != nil }

    func capture() -> any VoiceAudioCapture {
        demo ? DictationDemoCapture() : io.capture
    }

    /// The language a take would listen in and whether it can, for the person's choice and the
    /// keyboard's language.
    func readiness(hint: String?) async -> (DictationReadiness, String?) {
        guard let recognizer else { return (.unavailable(.engine("unsupported")), nil) }
        if !demo, AVAudioApplication.shared.recordPermission == .denied {
            return (.unavailable(.microphoneDenied), nil)
        }
        let choice = DictationPreferences.language
        guard let language = await recognizer.language(for: choice, hint: hint) else {
            return (.unavailable(.languageUnsupported(choice ?? hint ?? Locale.current.identifier)), nil)
        }
        let readiness = await recognizer.readiness(language: language)
        known[language] = readiness
        return (readiness, language)
    }

    func languages() async -> [String] {
        await recognizer?.languages() ?? []
    }

    func moved() {
        known = [:]
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

/// One composer's microphone: the control beside Send, the lit edge, the hint over the box, and the
/// take itself — from the touch that opens it to the words left in the box as one undo step. The
/// phone is in the hand, so the take is felt as well as seen: `listen` when it opens, `listenEnd`
/// when the words settle, a notch when a slide arms a cancel or a send.
@MainActor
final class DictationController: NSObject, UIGestureRecognizerDelegate {
    let button = DictationButton()
    let edge = DictationEdge()
    let hint = DictationHintView()
    var vocabulary: () -> DictationVocabulary = { .empty }
    var callLive = false {
        didSet {
            guard callLive != oldValue else { return }
            if callLive { stopKeepingShown() }
            redraw(animated: true)
        }
    }

    private weak var host: (any DictationComposerHost)?
    private let key: String
    private let engines = DictationEngines.shared
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
    private var discarded: (text: String, caret: Int)?
    private var detached = false
    private var writing = false
    private var level = 0.0
    private nonisolated(unsafe) var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var ending: DictationEnd?
    private var endingToken = 0
    private var pressOrigin = CGPoint.zero
    private var lastSettled = 0
    private var takes = 0
    private var openOnRelease = false
    private var lastTimer: String?
    private var localArm: DictationArm?
    private var notice: DictationHint?
    private var noticeToken = 0
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    private var staged = false
    private var lastInvite = DictationSendInvite.none

    init(host: any DictationComposerHost, key: String) {
        self.host = host
        self.key = key
        super.init()
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        gesture.minimumPressDuration = 0
        gesture.allowableMovement = .greatestFiniteMagnitude
        gesture.delegate = self
        button.addGestureRecognizer(gesture)
        hint.onUndo = { [weak self] in self?.undoDiscard() }
        button.onActivate = { [weak self] in self?.toggleFromKeyboard() }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.stopKeepingShown() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.refresh() }
            },
            center.addObserver(forName: DictationPreferences.didChange, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.refresh() }
            },
            center.addObserver(forName: DictationEngines.didChange, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.refresh() }
            },
        ]
        redraw(animated: false)
        refresh()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        displayLink?.invalidate()
    }

    var isOpen: Bool { session != nil && !detached }

    private var face: DictationFace {
        DictationFace.read(
            readiness: readiness, snapshot: seen, available: engines.isSupported && !callLive)
    }

    /// The take with what the hand already did laid over it: an engaged hold and a slid arm show
    /// and are felt at once, and the release decides from them rather than from the session's later
    /// word.
    private var seen: DictationSnapshot { snapshot.pressed(engaged: press.isEngaged, arm: localArm) }

    /// Asks the engine again: on appearing, coming back to the foreground, a language picked.
    func refresh() {
        let hint = host?.dictationTextView.textInputMode?.primaryLanguage
        Task { [weak self] in
            guard let self else { return }
            let (value, language) = await self.engines.readiness(hint: hint)
            guard self.preparing == nil else { return }
            self.readiness = value
            self.language = language
            self.redraw(animated: false)
        }
    }

    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            pressOrigin = gesture.location(in: nil)
            down()
        case .changed:
            moved(gesture)
        case .ended:
            up()
        case .cancelled, .failed:
            openOnRelease = false
            act(press.abandon(at: CACurrentMediaTime()))
        default:
            break
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { false }

    private func down() {
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

    private func moved(_ gesture: UILongPressGestureRecognizer) {
        guard isOpen, press.isDown else { return }
        if !press.isEngaged { act(press.tick(at: CACurrentMediaTime())) }
        guard press.isEngaged, let send = host?.dictationSendControl else { return }
        let point = gesture.location(in: nil)
        let overSend = send.bounds.insetBy(dx: -DictationSlide.sendSlop, dy: -DictationSlide.sendSlop)
            .contains(gesture.location(in: send))
        let arm = DictationSlide.arm(
            travelled: Double(point.x - pressOrigin.x), overSend: overSend,
            cancelDistance: DictationSlide.touchCancelDistance)
        setArm(arm)
    }

    /// The hand slid to an arm: felt, struck and drawn at once, and told to the take after
    /// whatever it was already asked.
    private func setArm(_ arm: DictationArm) {
        guard let session, arm != seen.arm else { return }
        arm == .none ? Theme.Haptics.selection() : Theme.Haptics.notch()
        localArm = arm
        render(anchor.compose(settled: snapshot.settled, heard: snapshot.heard), struck: arm == .cancel)
        redraw(animated: true)
        enqueue { await session.setArm(arm) }
    }

    /// The keyboard's ⌃⇧D on an iPad: a press toggles, because a hardware key's release is not
    /// handed to the screen once the key was spent on a command.
    func toggleFromKeyboard() {
        if isOpen {
            stop(sending: false)
        } else if face.isTakeable {
            open(mode: .handsFree)
        } else {
            pressedWhileNotReady()
        }
    }

    /// Esc: an open take is thrown away.
    func escape() -> Bool {
        guard isOpen else { return false }
        cancel()
        return true
    }

    /// Send pressed or Return sent while a take is open: settle the words, then send them.
    func stopAndSend() -> Bool {
        guard isOpen else { return false }
        stop(sending: true)
        return true
    }

    /// The person is about to change the box with their own hands: the take stops where it stands.
    func userWillEdit() {
        guard !writing else { return }
        guard isOpen else {
            boxEdited()
            return
        }
        stopKeepingShown()
    }

    private func act(_ action: DictationPress.Action) {
        switch action {
        case .open:
            open(mode: .handsFree)
            scheduleHoldTick()
        case .becomeHeld:
            guard let session else { return }
            Theme.Haptics.hold()
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
        case .preparing: Theme.Haptics.tap()
        default: break
        }
    }

    private func prepareModel() {
        guard preparing == nil, let language, let recognizer = engines.recognizer else { return }
        Theme.Haptics.tap()
        readiness = .downloading(nil)
        redraw(animated: true)
        preparing = Task { [weak self] in
            do {
                for try await progress in recognizer.prepare(language: language) {
                    guard let self else { return }
                    self.readiness = .downloading(progress)
                    self.redraw(animated: false)
                }
                guard let self else { return }
                self.preparing = nil
                self.readiness = .ready
                Theme.Haptics.success()
                self.redraw(animated: true)
                self.button.pulse()
                MidgarLog.info("dictation: \(language) assets installed", category: .chat)
            } catch {
                guard let self else { return }
                self.preparing = nil
                self.readiness = .needsDownload(bytes: nil)
                Theme.Haptics.warning()
                self.say(DictationHint(text: DictationModelReading.failed, style: .warning))
                MidgarLog.error("dictation: asset install failed: \(error)", category: .chat)
            }
        }
    }

    private func presentBlocked(_ problem: DictationProblem) {
        Theme.Haptics.warning()
        guard let presenter = host?.dictationPresenter else { return }
        presenter.present(DictationBlockedViewController(problem: problem), animated: true)
    }

    private func open(mode: DictationMode) {
        guard let host, session == nil, let recognizer = engines.recognizer, let language else { return }
        let textView = host.dictationTextView
        let text = textView.text ?? ""
        let selection = textView.selectedRange
        localArm = nil
        notice = nil
        let ns = text as NSString
        let start = min(selection.location, ns.length)
        let end = min(selection.location + selection.length, ns.length)
        anchor = DictationInsertion(before: ns.substring(to: start), after: ns.substring(from: end))
        original = text
        originalSelection = selection
        discarded = nil
        ending = nil
        detached = false
        lastSettled = 0
        takes += 1
        let session = DictationSession(
            capture: engines.capture(), recognizer: recognizer, language: language,
            vocabulary: engines.demo
                ? DictationDemoRecognizer.vocabulary
                : (DictationPreferences.usesChatWords ? vocabulary() : .empty),
            atStartOfBox: anchor.before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, take: takes)
        self.session = session
        snapshot = DictationSnapshot(phase: .waking, mode: mode, take: takes)
        level = 0
        Theme.Haptics.listen()
        host.dictationSetListening(true)
        redraw(animated: true)
        startFrames()
        follower = Task { [weak self] in
            for await next in session.snapshots {
                self?.apply(next, from: session)
            }
        }
        let key = self.key
        enqueue {
            await DictationDesk.shared.claim(key, session: session)
            await session.open(mode: mode)
        }
        UIAccessibility.post(notification: .announcement, argument: DictationReading.announceOpen)
        MidgarLog.info("dictation: take \(takes) opened \(mode.rawValue) in \(language)", category: .chat)
    }

    private func apply(_ next: DictationSnapshot, from source: DictationSession) {
        guard source === session, !detached else { return }
        snapshot = next
        if next.phase != .idle {
            render(anchor.compose(settled: next.settled, heard: next.heard), struck: seen.arm == .cancel)
        } else if let end = next.ended {
            land(DictationTake(text: next.settled, end: end), from: source, sending: false)
            return
        }
        redraw(animated: true)
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: host?.dictationTextView.font ?? Theme.Ramp.font(.answer),
            .foregroundColor: Theme.Color.label,
        ]
    }

    private func render(_ composition: DictationComposition, struck: Bool) {
        guard let host else { return }
        let textView = host.dictationTextView
        let text = NSMutableAttributedString(string: composition.text, attributes: baseAttributes)
        text.addAttribute(
            .foregroundColor, value: Theme.Color.accent.withAlphaComponent(0.88), range: composition.heardUTF16)
        if struck {
            text.addAttributes(
                [.foregroundColor: Theme.Color.tertiaryLabel, .strikethroughStyle: NSUnderlineStyle.single.rawValue],
                range: composition.takeUTF16)
        }
        let settled = composition.settled.utf16.count
        let dried = settled > lastSettled
        lastSettled = settled
        writing = true
        let write = {
            textView.attributedText = text
            textView.selectedRange = NSRange(location: composition.caretUTF16, length: 0)
            textView.typingAttributes = self.baseAttributes
        }
        if dried, !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(
                with: textView, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction],
                animations: write)
        } else {
            write()
        }
        writing = false
        host.dictationDidWrite()
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    private func stop(sending: Bool) {
        guard let session, !detached else { return }
        enqueue { [weak self] in
            let take = await session.finish(sending: sending)
            await MainActor.run { self?.land(take, from: session, sending: sending) }
        }
    }

    private func cancel() {
        guard let session, !detached, let textView = host?.dictationTextView else { return }
        let shown = textView.text ?? ""
        enqueue { [weak self] in
            _ = await session.cancel()
            await MainActor.run {
                guard let self, session === self.session else { return }
                self.restore(self.original, selection: self.originalSelection)
                self.discarded = shown == self.original ? nil : (shown, shown.utf16.count)
                self.finish(as: .discarded)
            }
        }
    }

    private func land(_ take: DictationTake, from source: DictationSession, sending: Bool) {
        guard source === session, let host else { return }
        if take.text.isEmpty {
            restore(original, selection: originalSelection)
        } else {
            commit(anchor.compose(settled: take.text, heard: ""))
        }
        finish(as: take.end)
        let text = host.dictationTextView.text ?? ""
        if sending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { host.dictationSend() }
    }

    /// The take's words as one undo step back to the box as it was before the take.
    private func commit(_ composition: DictationComposition) {
        guard let host else { return }
        let textView = host.dictationTextView
        let before = (original, originalSelection)
        let after = (composition.text, NSRange(location: composition.caretUTF16, length: 0))
        write(after.0, selection: after.1)
        registerUndo(on: textView, back: before, forward: after)
    }

    private func registerUndo(
        on textView: UITextView, back: (String, NSRange), forward: (String, NSRange)
    ) {
        guard let manager = textView.undoManager else { return }
        manager.registerUndo(withTarget: textView) { [weak self] view in
            MainActor.assumeIsolated {
                self?.write(back.0, selection: back.1)
                self?.registerUndo(on: view, back: forward, forward: back)
            }
        }
        manager.setActionName(DictationReading.undoActionName)
    }

    private func restore(_ text: String, selection: NSRange) {
        write(text, selection: selection)
    }

    private func write(_ text: String, selection: NSRange) {
        guard let host else { return }
        let textView = host.dictationTextView
        writing = true
        textView.attributedText = NSAttributedString(string: text, attributes: baseAttributes)
        let length = (text as NSString).length
        let location = min(selection.location, length)
        textView.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
        textView.typingAttributes = baseAttributes
        writing = false
        host.dictationDidWrite()
    }

    private func finish(as end: DictationEnd) {
        if let session {
            Task { await DictationDesk.shared.release(session) }
        }
        follower?.cancel()
        follower = nil
        session = nil
        press = DictationPress()
        snapshot = DictationSnapshot(ended: end, take: takes)
        localArm = nil
        ending = end
        endingToken += 1
        button.flash(end)
        stopFrames()
        host?.dictationSetListening(false)
        switch end {
        case .kept, .sent, .nothingHeard: Theme.Haptics.listenEnd()
        case .discarded: Theme.Haptics.tap()
        case .problem(let problem):
            if problem == .microphoneDenied { readiness = .unavailable(.microphoneDenied) }
            Theme.Haptics.warning()
        }
        UIAccessibility.post(notification: .announcement, argument: DictationReading.announce(end))
        MidgarLog.info("dictation: take \(takes) ended \(end)", category: .chat)
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

    /// The person typed mid-take, left the chat or the app went away: the take stops where it
    /// stands and the box keeps exactly what it shows, in ink.
    func stopKeepingShown() {
        guard let session, !detached else { return }
        detached = true
        enqueue { _ = await session.finish() }
        if let textView = host?.dictationTextView {
            let full = NSRange(location: 0, length: textView.textStorage.length)
            textView.textStorage.beginEditing()
            textView.textStorage.setAttributes(baseAttributes, range: full)
            textView.textStorage.endEditing()
            textView.typingAttributes = baseAttributes
        }
        finish(as: .kept(words: snapshot.wordCount))
    }

    /// The person wrote in the box after a discard: Undo would write the old take over their words,
    /// so it is no longer offered.
    private func boxEdited() {
        guard discarded != nil || ending == .discarded else { return }
        discarded = nil
        if ending == .discarded { ending = nil }
        redraw(animated: true)
    }

    private func undoDiscard() {
        guard let discarded else { return }
        let before = (host?.dictationTextView.text ?? "", host?.dictationTextView.selectedRange ?? NSRange())
        let after = (discarded.text, NSRange(location: discarded.caret, length: 0))
        write(after.0, selection: after.1)
        if let textView = host?.dictationTextView { registerUndo(on: textView, back: before, forward: after) }
        self.discarded = nil
        ending = nil
        Theme.Haptics.tap()
        redraw(animated: true)
    }

    /// Runs `work` after everything already asked of the take, so a quick tap's switch to
    /// hands-free never reaches the take before the take has opened.
    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = chain
        chain = Task {
            await previous?.value
            await work()
        }
    }

    private func redraw(animated: Bool) {
        let face = self.face
        button.apply(face, animated: animated)
        edge.setLit(face.litEdge, danger: face.tone == .danger, animated: animated)
        let invite: DictationSendInvite
        switch face {
        case .listening(.held, .send): invite = .armed
        case .listening(.held, .none): invite = .invited
        default: invite = .none
        }
        if invite != lastInvite {
            lastInvite = invite
            host?.dictationInvite(invite)
        }
        drawHint(face)
    }

    private func drawHint(_ face: DictationFace) {
        var shown = seen
        if !face.showsBars, let ending { shown.ended = ending }
        let reading = DictationReading.hint(
            face: face, snapshot: shown, now: ProcessInfo.processInfo.systemUptime, surface: .touch, chord: nil)
        let live = face.showsBars || face.isPreparing || ending != nil ? reading : nil
        let hint = live ?? notice
        lastTimer = hint?.timer
        self.hint.show(hint, undoAvailable: discarded != nil)
        host?.dictationShowStatus(self.hint, shown: hint != nil)
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
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: FrameTarget(self), selector: #selector(FrameTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastFrame = CACurrentMediaTime()
    }

    private func stopFrames() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func frame(at time: CFTimeInterval) {
        let dt = time - lastFrame
        lastFrame = time
        let target = session?.level ?? 0
        level = VoiceCallLevels.smoothed(previous: level, target: target, dt: dt)
        let reduce = UIAccessibility.isReduceMotionEnabled
        if face == .settling {
            button.setLevels([Double](repeating: DictationBars.floor, count: DictationBars.count))
        } else {
            button.setLevels(DictationBars.heights(level: level, time: time, reduceMotion: reduce))
        }
        button.setHalo(level)
        edge.setLevel(level)
        let timer = DictationReading.elapsed(snapshot, ProcessInfo.processInfo.systemUptime)
        if timer != lastTimer { drawHint(face) }
    }

    #if DEBUG
        /// Stages one state in the demo world for a screenshot: `TAILSCODE_DICTATION=hands`, `held`,
        /// `cancel`, `send`, `discarded`, `preparing` or `blocked`.
        func stageIfAsked() {
            guard !staged, engines.demo, let stage = ProcessInfo.processInfo.environment["TAILSCODE_DICTATION"] else {
                return
            }
            staged = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.stage(stage) }
        }

        private func stage(_ stage: String) {
            switch stage {
            case "preparing":
                readiness = .downloading(0.34)
                redraw(animated: true)
            case "blocked":
                readiness = .unavailable(.microphoneDenied)
                redraw(animated: true)
                presentBlocked(.microphoneDenied)
            case "hands":
                open(mode: .handsFree)
            default:
                act(press.down(at: CACurrentMediaTime(), listening: false))
                let arm: DictationArm? = stage == "cancel" ? .cancel : (stage == "send" ? .send : nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                    guard let self, self.session != nil else { return }
                    if stage == "discarded" {
                        self.cancel()
                    } else if let arm {
                        self.setArm(arm)
                    }
                }
            }
        }
    #endif

    private final class FrameTarget: NSObject {
        weak var owner: DictationController?
        init(_ owner: DictationController) { self.owner = owner }
        @MainActor @objc func tick(_ link: CADisplayLink) {
            guard let owner else {
                link.invalidate()
                return
            }
            owner.frame(at: link.timestamp)
        }
    }
}

/// Why the microphone cannot be heard, and the one thing to do about it.
@MainActor
final class DictationBlockedViewController: UIViewController {
    private let problem: DictationProblem

    init(problem: DictationProblem) {
        self.problem = problem
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.custom { _ in 360 }]
            sheet.prefersGrabberVisible = true
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedSurface
        let icon = UIImageView(
            image: UIImage(
                systemName: "mic.slash",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)))
        icon.tintColor = Theme.Color.warning
        icon.contentMode = .center
        icon.backgroundColor = Theme.Color.warning.withAlphaComponent(0.16)
        icon.layer.cornerRadius = 28
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let title = UILabel()
        title.text = DictationReading.blockedTitle(problem)
        title.font = Theme.Font.display(.title3, weight: .bold)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center
        title.numberOfLines = 0

        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let body = UILabel()
        body.text = DictationReading.blockedBody(problem, device: device)
        body.font = .preferredFont(forTextStyle: .body)
        body.adjustsFontForContentSizeCategory = true
        body.textColor = Theme.Color.secondaryLabel
        body.textAlignment = .center
        body.numberOfLines = 0

        var primary = Theme.Glass.buttonConfiguration(prominent: true)
        primary.cornerStyle = .capsule
        primary.title = problem == .microphoneDenied ? DictationReading.openSettings : DictationReading.tryAgain
        let action = UIButton(configuration: primary)
        action.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                if self.problem == .microphoneDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                DictationEngines.shared.moved()
                self.dismiss(animated: true)
            }, for: .primaryActionTriggered)
        action.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true

        var secondary = UIButton.Configuration.plain()
        secondary.title = DictationReading.notNow
        let later = UIButton(configuration: secondary)
        later.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)

        let fine = UILabel()
        fine.text = DictationReading.privacy(device: device)
        fine.font = .preferredFont(forTextStyle: .footnote)
        fine.adjustsFontForContentSizeCategory = true
        fine.textColor = Theme.Color.tertiaryLabel
        fine.textAlignment = .center
        fine.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, title, body, action, later, fine])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.setCustomSpacing(16, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 32),
            action.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            action.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }
}

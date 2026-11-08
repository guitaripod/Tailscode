import Foundation

/// How the control is reached, which decides the verbs: a finger taps, a pointer clicks.
public enum DictationSurface: Sendable, Equatable {
    case touch
    case pointer
}

/// What the status line inside the box says, and whether it is a warning or offers Undo.
public struct DictationHint: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        case live
        case plain
        case danger
        case warning
    }

    public let text: String
    public let timer: String?
    public let style: Style
    public let offersUndo: Bool

    public init(text: String, timer: String? = nil, style: Style = .plain, offersUndo: Bool = false) {
        self.text = text
        self.timer = timer
        self.style = style
        self.offersUndo = offersUndo
    }

    /// How long a hint about a take that ended stays up.
    public var lingers: TimeInterval {
        if offersUndo { return 5 }
        switch style {
        case .warning, .danger: return 4
        default: return 3
        }
    }
}

/// Every word dictation says, on every desk.
public enum DictationReading {
    public static var name: String { Localized.text("Dictate") }

    public static var stopName: String { Localized.text("Stop dictating") }

    /// The control's spoken name for a screen reader.
    public static func accessibilityLabel(_ face: DictationFace) -> String {
        switch face {
        case .hidden, .ready: return name
        case .needsModel: return Localized.text("Dictate, needs a speech model")
        case .preparing(let progress):
            guard let progress else { return Localized.text("Getting dictation ready") }
            return Localized.text("Getting dictation ready, %lld percent", Int64(percent(progress)))
        case .blocked: return Localized.text("Dictation can't hear you")
        case .waking, .listening: return stopName
        case .settling: return Localized.text("Finishing dictation")
        }
    }

    public static func accessibilityHint(_ face: DictationFace, surface: DictationSurface) -> String? {
        switch face {
        case .ready:
            return surface == .touch
                ? Localized.text("Tap to talk until you tap again. Touch and hold to talk while held.")
                : Localized.text("Click to talk until you click again. Hold to talk while held.")
        case .listening(.held, _): return Localized.text("Release to keep the words. Slide left to cancel.")
        default: return nil
        }
    }

    /// The tooltip a desktop shows on the control.
    public static func tooltip(_ face: DictationFace, chord: String?) -> String {
        let keys = chord.map { " (\($0))" } ?? ""
        switch face {
        case .hidden, .ready:
            return Localized.text("Dictate%@: click to talk, hold to talk while held", keys)
        case .needsModel: return Localized.text("Dictation needs a speech model, once")
        case .preparing(let progress):
            guard let progress else { return Localized.text("Getting dictation ready") }
            return Localized.text("Getting dictation ready · %lld%%", Int64(percent(progress)))
        case .blocked(let problem): return blockedTitle(problem)
        case .waking, .listening: return Localized.text("Stop dictating%@", keys)
        case .settling: return Localized.text("Finishing dictation")
        }
    }

    /// The status line inside the box while a take runs or right after one ended. A hold made with
    /// the keyboard's chord cannot be dragged, so its line says how a key ends it instead.
    public static func hint(
        face: DictationFace, snapshot: DictationSnapshot, now: TimeInterval, surface: DictationSurface,
        chord: String?, heldByKey: Bool = false
    ) -> DictationHint? {
        switch face {
        case .preparing(let progress):
            let timer = progress.map { "\(percent($0))%" }
            return DictationHint(text: Localized.text("Getting dictation ready"), timer: timer, style: .live)
        case .waking, .listening(.handsFree, _):
            if snapshot.nearingLimit {
                return DictationHint(text: Localized.text("Stops at 10 minutes"), timer: elapsed(snapshot, now), style: .warning)
            }
            let stop: String
            switch surface {
            case .touch: stop = Localized.text("Tap to stop")
            case .pointer:
                stop = chord.map { Localized.text("%@ or click to stop · esc cancels", $0) }
                    ?? Localized.text("Click to stop · esc cancels")
            }
            return DictationHint(text: stop, timer: elapsed(snapshot, now), style: .live)
        case .listening(.held, .none):
            switch surface {
            case .touch:
                return DictationHint(text: Localized.text("Release to keep · ‹ slide to cancel"), timer: elapsed(snapshot, now), style: .live)
            case .pointer where heldByKey:
                return DictationHint(text: Localized.text("Release to keep · esc cancels"), timer: elapsed(snapshot, now), style: .live)
            case .pointer:
                return DictationHint(text: Localized.text("Release to keep · drag left to cancel"), timer: elapsed(snapshot, now), style: .live)
            }
        case .listening(.held, .cancel):
            return DictationHint(text: Localized.text("Release to cancel"), style: .danger)
        case .listening(.held, .send):
            return DictationHint(text: Localized.text("Release to send"), style: .live)
        case .settling, .ready, .hidden, .needsModel, .blocked:
            return snapshot.ended.flatMap(ending)
        }
    }

    /// What the hint says about a take that has just ended. A kept or sent take needs no words:
    /// they are in the box, or in the chat.
    public static func ending(_ end: DictationEnd) -> DictationHint? {
        switch end {
        case .kept, .sent: return nil
        case .discarded: return DictationHint(text: Localized.text("Discarded"), offersUndo: true)
        case .nothingHeard: return DictationHint(text: Localized.text("Didn't hear anything"))
        case .problem(let problem):
            switch problem {
            case .taken:
                return DictationHint(text: Localized.text("The microphone was taken. Your words are kept."), style: .warning)
            case .engine:
                return DictationHint(text: Localized.text("Dictation stopped. Your words are kept."), style: .warning)
            case .timeUp:
                return DictationHint(text: Localized.text("Stopped at 10 minutes. Your words are kept."), style: .warning)
            case .microphoneDenied, .noMicrophone, .languageUnsupported:
                return DictationHint(text: blockedTitle(problem), style: .warning)
            }
        }
    }

    public static var undo: String { Localized.text("Undo") }

    public static var undoActionName: String { Localized.text("Dictation") }

    /// What a screen reader hears when a take opens and ends. Live words are never read out: a word
    /// that changes four times would be read four times.
    public static var announceOpen: String { Localized.text("Listening") }

    public static func announce(_ end: DictationEnd) -> String {
        switch end {
        case .kept(let words), .sent(let words):
            return words == 1 ? Localized.text("Added 1 word") : Localized.text("Added %lld words", Int64(words))
        case .discarded: return Localized.text("Discarded")
        case .nothingHeard: return Localized.text("Didn't hear anything")
        case .problem(let problem): return ending(.problem(problem))?.text ?? blockedTitle(problem)
        }
    }

    public static var listeningPlaceholder: String { Localized.text("Listening…") }

    /// The title of the sheet or popover a blocked control opens.
    public static func blockedTitle(_ problem: DictationProblem) -> String {
        switch problem {
        case .microphoneDenied: return Localized.text("Tailscode can't hear you")
        case .noMicrophone: return Localized.text("No microphone answers")
        case .languageUnsupported: return Localized.text("Dictation doesn't speak this language")
        case .engine, .taken, .timeUp: return Localized.text("Dictation stopped")
        }
    }

    public static func blockedBody(_ problem: DictationProblem, device: String) -> String {
        switch problem {
        case .microphoneDenied:
            return Localized.text("Microphone access is off for Tailscode. Turn it on in Settings and the mic beside Send will listen.")
        case .noMicrophone:
            return Localized.text("Nothing on this %@ is offering a microphone. Plug one in or pick one in the sound settings, then try again.", device)
        case .languageUnsupported(let language):
            return Localized.text("Dictation can't listen in %@ on this %@. Pick another language in Settings ▸ Chat ▸ Dictation.", languageName(language), device)
        case .engine, .taken, .timeUp:
            return Localized.text("Try again. If it keeps stopping, the log has what happened.")
        }
    }

    public static var openSettings: String { Localized.text("Open Settings") }

    public static var notNow: String { Localized.text("Not now") }

    public static var tryAgain: String { Localized.text("Try again") }

    public static func privacy(device: String) -> String {
        Localized.text("Dictation runs on this %@. Nothing you say leaves it.", device)
    }

    public static var settingsTitle: String { Localized.text("Dictation") }

    public static var languageTitle: String { Localized.text("Language") }

    public static var automatic: String { Localized.text("Automatic") }

    public static func automaticDetail(_ resolved: String?) -> String {
        guard let resolved else { return automatic }
        return Localized.text("Automatic · %@", languageName(resolved))
    }

    public static func languageFooter(surface: DictationSurface) -> String {
        switch surface {
        case .touch:
            return Localized.text("Automatic follows the keyboard you are typing with. Nothing you say leaves this device.")
        case .pointer:
            return Localized.text("Automatic follows the first language in your Mac's preferred list. Nothing you say leaves it.")
        }
    }

    public static var chatWordsTitle: String { Localized.text("Words from the chat") }

    public static var chatWordsFooter: String {
        Localized.text("Dictation learns the chat's file names, branch, commands and code words, so “composer view dot swift” is written ComposerView.swift. Nothing leaves this device.")
    }

    public static func settingsFooter(device: String, chord: String?, surface: DictationSurface) -> String {
        let keys = chord.map { Localized.text(" Hold %@ to talk while held, or tap it to start and stop.", $0) } ?? ""
        switch surface {
        case .touch:
            return Localized.text("Tap the mic beside Send to talk, or touch and hold it to talk while held. Dictation runs on this %@.", device) + keys
        case .pointer:
            return Localized.text("Click the mic beside Send to talk, or hold it to talk while held. Dictation runs on this %@.", device) + keys
        }
    }

    public static func languageName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    static func percent(_ progress: Double) -> Int {
        Int((min(max(progress, 0), 1) * 100).rounded(.down))
    }

    /// m:ss since the take opened.
    public static func elapsed(_ snapshot: DictationSnapshot, _ now: TimeInterval) -> String? {
        guard let started = snapshot.startedAt else { return nil }
        let seconds = max(0, Int(now - started))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    public static func bytes(_ count: Int64) -> String {
        let megabytes = Double(count) / 1_000_000
        if megabytes >= 1000 { return String(format: "%.1f GB", megabytes / 1000) }
        return String(format: "%.0f MB", megabytes.rounded(.up))
    }
}

/// The words of Linux's first press: the model it needs, once, and the download.
public enum DictationModelReading {
    public static var title: String { Localized.text("Dictation runs on this computer") }

    public static func body(host: String) -> String {
        Localized.text("It listens with a speech model on your own CPU. Nothing you say leaves %@.", host)
    }

    public static var modelLabel: String { Localized.text("Speech model") }

    public static var sizeLabel: String { Localized.text("Download, once") }

    public static var licenseLabel: String { Localized.text("License") }

    public static var download: String { Localized.text("Download") }

    public static var cancel: String { Localized.text("Cancel") }

    public static var remove: String { Localized.text("Remove") }

    public static func progress(done: Int64, total: Int64) -> String {
        Localized.text("%@ of %@", DictationReading.bytes(done), DictationReading.bytes(total))
    }

    public static func remaining(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        if seconds < 60 { return Localized.text("%lld s left", Int64(seconds.rounded(.up))) }
        return Localized.text("%lld min left", Int64((seconds / 60).rounded(.up)))
    }

    public static var unpacking: String { Localized.text("Unpacking…") }

    public static func ready(chord: String?) -> String {
        guard let chord else { return Localized.text("Ready. Click the mic to talk.") }
        return Localized.text("Ready. Click, or hold %@, to talk.", chord)
    }

    public static var failed: String { Localized.text("The download didn't finish. Try again.") }

    public static var onDisk: String { Localized.text("On disk") }

    public static var englishOnly: String { Localized.text("English. The speech model on this computer listens in English only.") }
}

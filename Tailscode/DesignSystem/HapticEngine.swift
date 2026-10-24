import CoreHaptics
import MidgarCore
import TailscodeCore
import UIKit

/// The one thing that actually makes the phone move. Every cue in the app goes through here, so
/// the user's strength setting is applied in a single place and the call sites keep naming
/// meanings rather than amplitudes.
///
/// Core Haptics is the path that matters: `UIImpactFeedbackGenerator` can only ask for one of
/// five canned shapes, while a composed pattern can put a sustained body under a sharp crack and
/// stack a second crack on top of it — which is the difference between a click and a blow you
/// feel through a pocket. Devices without a Taptic Engine fall back to the canned generators,
/// which keep each cue's meaning even though they cannot keep its force.
@MainActor
final class HapticEngine {
    static let shared = HapticEngine()

    private let driver = HapticDriver()
    private var lastPlayed: [HapticCue: CFTimeInterval] = [:]
    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let notificationGenerator = UINotificationFeedbackGenerator()

    let supportsComposedHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private init() {}

    /// Brings the Taptic Engine up before the first cue needs it. Starting is a round trip to the
    /// haptics daemon that has been measured in tens of milliseconds, so it happens on the
    /// driver's own queue: warming the engine must never be the thing that makes a screen late.
    func prepare() {
        guard AppPreferences.hapticsEnabled, AppPreferences.hapticIntensity > HapticStrength.silence
        else { return }
        if supportsComposedHaptics {
            driver.prewarm()
        } else {
            selectionGenerator.prepare()
            notificationGenerator.prepare()
        }
    }

    /// Releases the engine when the app goes away. Holding a running engine across a suspension
    /// is what produces the "haptics stopped working until relaunch" class of bug: the system
    /// stops it for us and a stale handle plays nothing, silently.
    func relinquish() {
        driver.relinquish()
    }

    func play(_ cue: HapticCue) {
        guard AppPreferences.hapticsEnabled else { return }
        let now = CACurrentMediaTime()
        if let last = lastPlayed[cue], now - last < HapticRecipe.minimumGap(for: cue) { return }
        lastPlayed[cue] = now
        play(cue, strength: AppPreferences.hapticIntensity)
    }

    /// Plays a cue at a strength the caller names, which the strength slider uses to let someone
    /// feel the setting they are dragging rather than read a number about it.
    ///
    /// A composed cue is handed to the driver and returns at once. A cue is felt at the moment the
    /// thing it reports happens — a turn ending, a step landing — which is exactly when the main
    /// thread is busiest drawing that thing, so nothing about making the phone move may wait on
    /// the haptics daemon here. Only the canned fallback, which UIKit insists on playing from the
    /// main thread, comes back.
    func play(_ cue: HapticCue, strength: Double) {
        let beats = HapticRecipe.scaled(cue, strength: strength)
        guard !beats.isEmpty else { return }
        guard supportsComposedHaptics else {
            playFallback(cue, strength: strength)
            return
        }
        driver.play(beats) { [weak self] in
            Task { @MainActor in self?.playFallback(cue, strength: strength) }
        }
    }

    private func playFallback(_ cue: HapticCue, strength: Double) {
        switch HapticFallback.of(cue, strength: strength) {
        case .impact(let style, let intensity):
            UIImpactFeedbackGenerator(style: Self.style(style))
                .impactOccurred(intensity: CGFloat(intensity))
        case .selection:
            selectionGenerator.selectionChanged()
        case .notification(let kind):
            notificationGenerator.notificationOccurred(Self.type(kind))
        case .none:
            break
        }
    }

    private static func style(_ style: HapticFallback.Style)
        -> UIImpactFeedbackGenerator.FeedbackStyle
    {
        switch style {
        case .light: return .light
        case .medium: return .medium
        case .heavy: return .heavy
        case .soft: return .soft
        case .rigid: return .rigid
        }
    }

    private static func type(_ kind: HapticFallback.Notification)
        -> UINotificationFeedbackGenerator.FeedbackType
    {
        switch kind {
        case .success: return .success
        case .warning: return .warning
        case .error: return .error
        }
    }
}

/// Owns the Core Haptics engine and every call into it, on one serial queue of its own.
///
/// `CHHapticEngine.start()` and `makePlayer` are synchronous round trips to the haptics daemon.
/// The engine shuts itself down after a few idle seconds, so the first cue after a quiet spell —
/// which is the cue that reports a turn ending, a step landing or a question arriving — used to
/// pay for a cold start on the main thread in the middle of the frame that drew the very change
/// it was reporting. Serial, so cues keep their order, and at user-interactive priority, so the
/// start is as quick as it can be made without being the main thread's problem.
private final class HapticDriver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tailscode.haptics", qos: .userInteractive)
    private var engine: CHHapticEngine?
    private var isRunning = false
    private var hasLoggedFailure = false
    private var coolingUntil: CFTimeInterval = 0

    /// How long a failed start is left alone. A phone whose haptics daemon is refusing the engine
    /// refuses it every time, and each refusal is a slow round trip, so asking again for every cue
    /// turns a missing nicety into a constant cost. The canned generators carry the cue meanwhile.
    private static let retryAfterFailure: CFTimeInterval = 5

    func prewarm() {
        queue.async { [self] in _ = start() }
    }

    func relinquish() {
        queue.async { [self] in
            engine?.stop()
            isRunning = false
        }
    }

    /// Plays the beats, or says so through `failed` when the engine could not be brought up or
    /// refused the pattern, so the caller can fall back to the canned generators.
    func play(_ beats: [HapticBeat], failed: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard start(), let engine else { return failed() }
            do {
                let pattern = try CHHapticPattern(events: beats.map(Self.event), parameters: [])
                let player = try engine.makePlayer(with: pattern)
                try player.start(atTime: CHHapticTimeImmediate)
            } catch {
                noteFailure("play failed: \(error.localizedDescription)")
                isRunning = false
                failed()
            }
        }
    }

    private static func event(_ beat: HapticBeat) -> CHHapticEvent {
        let parameters = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(beat.intensity)),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(beat.sharpness)),
        ]
        guard beat.isContinuous else {
            return CHHapticEvent(
                eventType: .hapticTransient, parameters: parameters, relativeTime: beat.start)
        }
        return CHHapticEvent(
            eventType: .hapticContinuous, parameters: parameters, relativeTime: beat.start,
            duration: beat.duration)
    }

    private func start() -> Bool {
        if isRunning, engine != nil { return true }
        guard CACurrentMediaTime() >= coolingUntil else { return false }
        do {
            let engine = try self.engine ?? CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            engine.stoppedHandler = { [weak self] reason in
                self?.queue.async {
                    self?.isRunning = false
                    MidgarLog.debug("haptic engine stopped: \(reason.rawValue)", category: .ui)
                }
            }
            engine.resetHandler = { [weak self] in
                self?.queue.async {
                    self?.isRunning = false
                    _ = self?.start()
                }
            }
            try engine.start()
            self.engine = engine
            isRunning = true
            return true
        } catch {
            noteFailure("engine unavailable: \(error.localizedDescription)")
            engine = nil
            isRunning = false
            coolingUntil = CACurrentMediaTime() + Self.retryAfterFailure
            return false
        }
    }

    /// A phone that cannot start its engine — locked, in a call, out of resources — will fail
    /// every cue after it, and a log line per tap helps nobody.
    private func noteFailure(_ message: String) {
        guard !hasLoggedFailure else { return }
        hasLoggedFailure = true
        MidgarLog.error("haptics \(message)", category: .ui)
    }
}

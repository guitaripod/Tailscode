import CoreHaptics
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

    private var engine: CHHapticEngine?
    private var isRunning = false
    private var hasLoggedFailure = false
    private var lastPlayed: [HapticCue: CFTimeInterval] = [:]
    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let notificationGenerator = UINotificationFeedbackGenerator()

    let supportsComposedHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private init() {}

    /// Brings the Taptic Engine up before the first cue needs it. Starting costs a few
    /// milliseconds, which is exactly long enough to turn the tap that opened a screen into a
    /// tap that arrives after it.
    func prepare() {
        guard AppPreferences.hapticsEnabled, AppPreferences.hapticIntensity > HapticStrength.silence
        else { return }
        if supportsComposedHaptics {
            start()
        } else {
            selectionGenerator.prepare()
            notificationGenerator.prepare()
        }
    }

    /// Releases the engine when the app goes away. Holding a running engine across a suspension
    /// is what produces the "haptics stopped working until relaunch" class of bug: the system
    /// stops it for us and a stale handle plays nothing, silently.
    func relinquish() {
        engine?.stop()
        isRunning = false
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
    func play(_ cue: HapticCue, strength: Double) {
        let beats = HapticRecipe.scaled(cue, strength: strength)
        guard !beats.isEmpty else { return }
        if supportsComposedHaptics, playComposed(beats) { return }
        playFallback(cue, strength: strength)
    }

    private func playComposed(_ beats: [HapticBeat]) -> Bool {
        guard start(), let engine else { return false }
        do {
            let pattern = try CHHapticPattern(events: beats.map(Self.event), parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            noteFailure("play failed: \(error.localizedDescription)")
            isRunning = false
            return false
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

    @discardableResult
    private func start() -> Bool {
        if isRunning, engine != nil { return true }
        do {
            let engine = try self.engine ?? CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            engine.stoppedHandler = { [weak self] reason in
                Task { @MainActor in
                    self?.isRunning = false
                    AppLogger.ui.debug("haptic engine stopped: \(reason.rawValue)")
                }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor in
                    self?.isRunning = false
                    self?.start()
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
            return false
        }
    }

    /// A phone that cannot start its engine — locked, in a call, out of resources — will fail
    /// every cue after it, and a log line per tap helps nobody.
    private func noteFailure(_ message: String) {
        guard !hasLoggedFailure else { return }
        hasLoggedFailure = true
        AppLogger.ui.error("haptics \(message)")
    }
}

import AppKit
import TailscodeCore

/// The trackpad's answer to the phone's Taptic Engine. A Force Touch trackpad cannot compose a
/// pattern and takes no amplitude — it has three canned shapes, felt only while a hand is on it —
/// so a cue keeps its meaning through which shape plays and how many of its recipe's beats
/// survive the strength setting, exactly the canned-fallback contract the capability spec names.
/// The defaults keys are the phone's own, so the setting is a fact about the person.
@MainActor
final class MacHaptics {
    static let shared = MacHaptics()

    private var lastPlayed: [HapticCue: TimeInterval] = [:]

    private init() {}

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "pref.hapticsEnabled") as? Bool ?? true
    }

    static var strength: Double {
        guard UserDefaults.standard.object(forKey: "pref.hapticIntensity") != nil else {
            return HapticStrength.standard
        }
        return HapticStrength.clamped(UserDefaults.standard.double(forKey: "pref.hapticIntensity"))
    }

    static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "pref.hapticsEnabled")
    }

    static func setStrength(_ value: Double) {
        UserDefaults.standard.set(HapticStrength.clamped(value), forKey: "pref.hapticIntensity")
    }

    func play(_ cue: HapticCue) {
        guard Self.isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastPlayed[cue], now - last < HapticRecipe.minimumGap(for: cue) { return }
        lastPlayed[cue] = now
        play(cue, strength: Self.strength)
    }

    /// Plays a cue at a strength the caller names, which the settings slider uses to let someone
    /// feel the stop under the pointer rather than read a number about it.
    func play(_ cue: HapticCue, strength: Double) {
        let beats = HapticRecipe.scaled(cue, strength: strength)
        guard !beats.isEmpty else { return }
        let pattern = Self.pattern(for: cue)
        for beat in beats {
            guard beat.start > 0 else {
                NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + beat.start) {
                NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
            }
        }
    }

    /// Three canned shapes carrying nine meanings: the lightest tick for touch and a step of the
    /// work, the middle knock for a send and anything that asks, the heaviest for an arrival and
    /// the outcomes. What the recipes express with intensity survives here as beat count — a
    /// needs-you still knocks twice, an error still lands three times at full strength.
    private static func pattern(for cue: HapticCue) -> NSHapticFeedbackManager.FeedbackPattern {
        switch cue {
        case .tap, .selection, .step: return .alignment
        case .send, .needsYou, .warning: return .generic
        case .received, .success, .error: return .levelChange
        }
    }
}

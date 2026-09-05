import CodingAgentKit
import Foundation

/// The door into the dispatcher: one title, one symbol, one promise, so a phone, a Mac and a Linux
/// desk name the same thing the same way wherever the road starts.
public enum DelegateEntryPoint {
    public static var title: String { Localized.text("Delegate") }

    /// The title on a menu row, where the ellipsis is the convention for "this opens something".
    public static var menuTitle: String { Localized.text("Delegate…") }

    public static var symbol: String { "arrow.triangle.branch" }

    public static var glyph: String { "⇶" }

    public static var subtitle: String {
        Localized.text("Hand a bounded task to a cheaper tier and get back a verified patch.")
    }

    /// The row on a server's own screen, which is the first place anyone meets the daemon.
    public static var serverRowTitle: String { Localized.text("Delegate runs") }

    public static var newPacketTitle: String { Localized.text("New packet") }
}

/// What Pro has to do with it. Delegation is the feature that costs the project its machines and
/// its evenings, so on the clients that sell Pro it is the paywall's door: a free copy sees the
/// board's pitch and the purchase, never a half of the feature. A client with no store sells
/// nothing and gates nothing.
public enum DelegateProGate {
    /// The demo world is not the real thing, so it is never behind the price: a copy that has not
    /// bought Pro still works the whole feature on the scripted machines.
    public static func allows(isPro: Bool, sells: Bool, demo: Bool = false) -> Bool { isPro || !sells || demo }

    public static var requirement: String {
        Localized.text("Delegating work to your machines' cheaper tiers is part of Tailscode Pro.")
    }

    public static var pitch: String {
        Localized.text(
            "Write a packet, pick how far up the ladder it may climb, and watch a local or cheap-cloud model earn the frontier's job — every attempt verified before it lands in your tree.")
    }

    public static var perk: ProOffer.Perk {
        ProOffer.Perk(
            symbol: DelegateEntryPoint.symbol,
            text: Localized.text(
                "Delegate: send bounded tasks to your own local and cheap-cloud tiers, verified before they land"))
    }
}

/// The mark the feature wears while it is new. A badge is the whole announcement — an invitation
/// with its own footing stated, never a warning — and the gesture a platform has for asking
/// (hovering on a desk, tapping on a phone) opens the why in the same words everywhere. It leaves
/// by being deleted, not hidden, so every client loses it together.
public enum DelegateBeta {
    public static var label: String { Localized.text("Beta") }

    /// What the badge itself reads, in the caps a badge is set in.
    public static var badge: String { Localized.text("BETA") }

    public static var title: String { Localized.text("Delegate is in beta") }

    /// What a screen reader hears where a sighted person sees the badge.
    public static var spoken: String { Localized.text("Beta. Delegate is new; open this to read what that means.") }

    public static var paragraphs: [String] {
        [
            Localized.text(
                "Delegate is new and still being shaped. It does real work every day, and what it learns there changes it: the packet, the ladder, the words a run is told in and the tier a class starts at will keep moving between releases until the feature is right."),
            Localized.text(
                "Beta does not mean pretend. A run is real work on your machine — every attempt is verified before its patch lands, and a patch lands unstaged in your working tree, so read it the way you would read a pull request before you keep it."),
            Localized.text(
                "When a run, a rung or a sentence here gets something wrong, that is worth reporting: this stage exists to hear it, and the dispatcher's own log on that machine carries every word a report needs."),
        ]
    }

    public static var body: String { paragraphs.joined(separator: "\n\n") }

    /// A line that already says something, with the mark in front of it.
    public static func marked(_ line: String) -> String { Localized.text("Beta · %@", line) }
}

/// The words the daemon's own vocabulary is read in. A tier is a rung, a mode is a posture, and a
/// status is one of six settled words, so no client spells them for itself.
public enum DelegateWords {
    public static func mode(_ mode: DelegateMode) -> String {
        switch mode {
        case .normal: return Localized.text("Normal")
        case .conserve: return Localized.text("Conserve")
        case .rush: return Localized.text("Rush")
        }
    }

    public static func modeDetail(_ mode: DelegateMode) -> String {
        switch mode {
        case .normal: return Localized.text("The class's own start and ceiling")
        case .conserve: return Localized.text("Start one rung lower and ask before the top")
        case .rush: return Localized.text("Start one rung higher")
        }
    }

    public static func effort(_ effort: DelegateEffort) -> String {
        switch effort {
        case .low: return Localized.text("Low")
        case .medium: return Localized.text("Medium")
        case .high: return Localized.text("High")
        }
    }

    public static func status(_ status: DelegateRunStatus) -> String {
        switch status {
        case .running: return Localized.text("Running")
        case .passed: return Localized.text("Passed")
        case .failed: return Localized.text("Failed")
        case .held: return Localized.text("Held")
        case .cancelled: return Localized.text("Cancelled")
        case .error: return Localized.text("Error")
        }
    }

    public static func attemptStatus(_ status: DelegateAttemptStatus) -> String {
        switch status {
        case .pass: return Localized.text("passed")
        case .fail: return Localized.text("failed")
        case .timeout: return Localized.text("timed out")
        case .scope: return Localized.text("out of scope")
        case .error: return Localized.text("never started")
        }
    }

    public static func tone(_ status: DelegateRunStatus) -> ActivityTone {
        switch status {
        case .running: return .live
        case .passed: return .live
        case .held: return .attention
        case .failed, .error: return .danger
        case .cancelled: return .quiet
        }
    }

    public static func tone(_ status: DelegateAttemptStatus) -> ActivityTone {
        switch status {
        case .pass: return .live
        case .fail, .timeout, .scope: return .danger
        case .error: return .quiet
        }
    }

    public static func seconds(_ milliseconds: Int) -> String {
        String(format: "%.1fs", Double(milliseconds) / 1000)
    }

    public static func files(_ count: Int) -> String {
        count == 1 ? Localized.text("1 file") : Localized.text("%d files", count)
    }

    public static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return String(count)
    }
}

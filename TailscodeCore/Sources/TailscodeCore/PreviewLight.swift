import Foundation

/// What a preview says about itself in one glance, in the vocabulary the rest of the app already
/// speaks. A change that is being built breathes, a link being found again sweeps, and anything
/// settled — live, broken, offline — holds perfectly still, because stillness is how a reader
/// tells a stopped picture from a slow one.
public enum PreviewLight: Sendable, Equatable {
    case dark
    case waking
    case needsYou
    case live
    case updating
    case broken
    case stale
    case offline

    public var tone: ActivityTone {
        switch self {
        case .dark, .waking, .stale: return .quiet
        case .needsYou: return .attention
        case .live, .updating: return .live
        case .broken, .offline: return .danger
        }
    }

    public var motion: ActivityMotion {
        switch self {
        case .waking, .stale: return .turning
        case .needsYou: return .attention
        case .updating: return .working
        case .dark, .live, .broken, .offline: return .still
        }
    }

    public var isLit: Bool { self != .dark }

    /// The badge a strip already knows how to wear for this face, so a preview needs no glyph of
    /// its own. Live and dark wear none: a settled picture says nothing, and that is the point.
    public var activity: ActivityKind? {
        switch self {
        case .dark, .live: return nil
        case .waking: return .connecting
        case .needsYou: return .needsAnswer
        case .updating: return .working
        case .broken: return .failed
        case .stale: return .reconnecting
        case .offline: return .offline
        }
    }

    /// The word the identity strip wears beside the light.
    public var line: String {
        switch self {
        case .dark: return ""
        case .waking: return Localized.text("Starting")
        case .needsYou: return Localized.text("Needs you")
        case .live: return Localized.text("Live")
        case .updating: return Localized.text("Updating")
        case .broken: return Localized.text("Could not build")
        case .stale: return Localized.text("Reconnecting")
        case .offline: return Localized.text("Offline")
        }
    }

    /// The sentence for a screen reader and a tooltip, said because the light can only say it to
    /// somebody who can see it.
    public var spoken: String? {
        switch self {
        case .dark: return nil
        case .waking: return Localized.text("Preview — starting")
        case .needsYou: return Localized.text("Preview — waiting for you to finish setting up the Mac")
        case .live: return Localized.text("Preview — live")
        case .updating: return Localized.text("Preview — showing a change")
        case .broken: return Localized.text("Preview — the last change would not build; showing the last picture that worked")
        case .stale: return Localized.text("Preview — the link dropped and is being found again")
        case .offline: return Localized.text("Preview — the Mac is not answering")
        }
    }
}
